/**
 * tools.ts -- expose the GAME's abilities as DSH tools (design by the master, 2026-10-14).
 *
 * The master's words:
 *   "DSH side: I want a session to take over this DECIDE job, e.g. let you take it over."
 *   "Make it an MCP so you can verify things yourself."
 *   "Not every session may handle it -- only ONE session. Add a switch in the UI:
 *    opening it from this session means this session takes over, others give up."
 *
 * The real `defineTool` shape was copied from an ALREADY-INSTALLED plugin
 * (`@dsh-external/dsh-global-memory`) -- NOT guessed:
 *     defineTool({ name, description, parameters: {...}, output: {schema, render}, execute })
 *     ctx.effect(() => ctx.tools.register(...), 'label')
 * That plugin's `inject` includes 'tools', so ours does too.
 *
 * The exclusive single-session lease ("only one session may take over") is specified in
 * TAKEOVER.md and is the NEXT increment. This file wires up the three operations that are
 * independent of who owns the lease: read / order / set goal.
 *
 * NOTE: kept ASCII-only on purpose -- PowerShell 5.1 here-strings mangle Chinese text
 * occasionally (see NATIVE.md), and a broken plugin would need a DSH restart to detect.
 */

import { defineTool } from '@deepseek-ai/dsh-tools'
import type { RpcPeer } from './rpc.js'
// Type-only import: erased at compile time, so the index <-> tools cycle is harmless.
import type { DecisionRecord } from './index.js'
import { readDecisionFile } from './index.js'

/** The slice of ctx these tools need (structural, so we don't depend on unavailable cordis types). */
interface ToolCtx {
  logger?: { info?: (m: string) => void; warn?: (m: string) => void }
  tools: { register(tool: unknown): void }
  effect(fn: () => void | (() => void), label?: string): void
}

/** Wrap the callback-based RpcPeer.call into a Promise (tool execute is async). */
export function ask(
  peer: RpcPeer,
  cmd: string,
  data: unknown,
  timeoutSec = 15,
): Promise<{ ok: boolean; data?: any; why?: string }> {
  return new Promise((resolve) => {
    const sent = peer.call(
      cmd,
      data,
      (ok, payload, why) => resolve({ ok, data: payload, why }),
      timeoutSec,
    )
    if (!sent) resolve({ ok: false, why: 'not connected to the game' })
  })
}

/** Render any result as text the model can read. */
function text(value: unknown): string {
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

/**
 * Register one tool.
 *
 * The helper does two things:
 *   1. keeps `register(...)`'s return value out of `effect` (effect wants void | cleanup);
 *   2. casts the definition, because `defineTool`'s generic inference breaks on parameters
 *      whose `type` is not 'string' (number/array/boolean make the output schema infer as
 *      `never`, and `execute` then fails to typecheck). The runtime shape is unaffected --
 *      the cast is compile-time only.
 */
function addTool(ctx: ToolCtx, def: any, label: string): void {
  ctx.effect(() => {
    ctx.tools.register(defineTool(def as never))
  }, label)
}

export function registerFleetTools(ctx: ToolCtx, peer: RpcPeer, decisionLog?: DecisionRecord[]): void {
  // ---------------------------------------------------------------------
  // fleet_query -- read game data (the "eyes")
  // ---------------------------------------------------------------------
  addTool(
    ctx,
    {
      name: 'fleet_query',
      description:
        'Query Avorion game state. what=fleet returns a snapshot of every ship on the Copilot ' +
        'roster (idle/busy, has captain, current progress). what=ship returns one ship capability ' +
        'card. what=goal returns that ship operating goal (the player text intent and allowed ' +
        'actions). what=orderSchema returns the currently legal commands and their parameters for ' +
        'that ship. what=sectorFacts returns FACTS about any sector (richness / material ' +
        'probability / centre-ring side / distance from the map centre, plus the same numbers for ' +
        'sectors closer to the centre) -- pass x and y (and optionally ship) -- it returns no ' +
        'verdict about whether to go there. This is the ONLY proper way to look at the game -- do ' +
        'not rely on screenshots.',
      parameters: {
        what: { type: 'string', required: true, description: 'fleet | ship | goal | orderSchema | sectorFacts' },
        ship: { type: 'string', description: 'ship name; required when what is ship/goal/orderSchema' },
        x: { type: 'number', description: 'sector x; required for what=sectorFacts' },
        y: { type: 'number', description: 'sector y; required for what=sectorFacts' },
      },
      output: {
        schema: { type: 'string' },
        render: (_args: unknown, value: unknown) => [{ type: 'text', text: String(value) }],
      },
      async execute(args: { what: string; ship?: string; x?: number; y?: number }) {
        // ★ sectorFacts 只需要坐标 ✓；其余"针对某艘船"的 what 才需要 ship ✓（2026-10-17 ✓）
        const needsShip = args.what !== 'fleet' && args.what !== 'sectorFacts'
        if (needsShip && (args.ship === undefined || args.ship === '')) {
          return `what=${args.what} needs the ship parameter`
        }
        if (args.what === 'sectorFacts' && (args.x === undefined || args.y === undefined)) {
          return 'what=sectorFacts needs the x and y parameters'
        }
        // tradePlan runs a FULL area analysis in the game (PassageMap + flood fill),
        // which takes far longer than a plain query -- give it room (2026-10-16).
        const timeout = args.what === 'tradePlan' ? 120 : 10
        const r = await ask(peer, 'query',
          { what: args.what, ship: args.ship, x: args.x, y: args.y }, timeout)
        if (!r.ok) return `query failed: ${r.why ?? 'unknown'}`
        return text(r.data)
      },
    },
    'fleet_query tool',
  )

  // ---------------------------------------------------------------------
  // fleet_order -- actually command a ship (the "hands")
  // ---------------------------------------------------------------------
  addTool(
    ctx,
    {
      name: 'fleet_order',
      description:
        'Give a background command to a ship on the Copilot roster. action is one of Mine, Salvage, ' +
        'Trade, Travel; the remaining parameters depend on the action (Travel needs a target sector ' +
        'x,y; work commands need an area centre and edge length). The command is ASYNCHRONOUS: the ' +
        'captain takes the ship out of the player sector and is unreachable while working. ' +
        'Call fleet_query with what=orderSchema first, then order.',
      parameters: {
        ship: { type: 'string', required: true, description: 'ship name (must be on the Copilot roster)' },
        action: { type: 'string', required: true, description: 'Mine | Salvage | Trade | Travel' },
        x: { type: 'number', description: 'target sector x (required for Travel; area centre otherwise)' },
        y: { type: 'number', description: 'target sector y' },
        size: { type: 'number', description: 'area edge length (Mine/Salvage 15; Trade 17/29/11)' },
        sizeX: {
          type: 'number',
          description:
            'Trade only: the box WIDTH. Vanilla legal Trade shapes are 17x17 / 29x11 / 11x29 ' +
            '(two of them are NOT squares), so pass sizeX and sizeY together with the x/y of the ' +
            'candidate you picked (each tradePlan candidate carries shape / sizeX / sizeY).',
        },
        sizeY: { type: 'number', description: 'Trade only: the box HEIGHT (see sizeX).' },
        duration: { type: 'number', description: 'task duration in hours, optional' },
        goodName: {
          type: 'string',
          description:
            'Trade only: WHICH trade route to fly. Must be a route name from ' +
            'fleet_query what=tradePlan (e.g. "Drill", "Antigrav Unit"). Without it the ' +
            'game answers "No route selected."',
        },
        deposit: {
          type: 'number',
          description:
            'Trade only: upfront budget in credits. MUST be > 0 (the game refuses 0 with ' +
            '"Error starting command.") and the player must be able to pay it. It decides how ' +
            'much cargo each flight carries.',
        },
        escorts: {
          type: 'array',
          items: { type: 'string' },
          description:
            'Trade only: escort ship names. HARD RULE: an escort must be in the SAME SECTOR as ' +
            'the action ship, otherwise it cannot take part.',
        },
      },
      output: {
        schema: { type: 'string' },
        render: (_args: unknown, value: unknown) => [{ type: 'text', text: String(value) }],
      },
      async execute(args: {
        ship: string
        action: string
        x?: number
        y?: number
        size?: number
        sizeX?: number
        sizeY?: number
        duration?: number
      }) {
        const r = await ask(peer, 'order', args, 30)
        if (!r.ok) return `order failed: ${r.why ?? 'unknown'}`
        return `ordered: ${args.ship} -> ${args.action}\n${text(r.data)}`
      },
    },
    'fleet_order tool',
  )

  // ---------------------------------------------------------------------
  // fleet_escort -- send an escort over to the target ship's sector
  //
  // The owner's feature (2026-10-17): when a job's ambush risk is too high and
  // the only way to lower it is an escort, but no escort is in the action
  // ship's sector, the escort has to TRAVEL there first (HARD RULE: an escort
  // only counts if it is in the SAME SECTOR as the action ship).
  //
  // This is the explicit, human-drivable version of the step the decide flow
  // does on its own (see index.ts: escortNeedOf / pickRendezvousEscort).
  // ---------------------------------------------------------------------
  addTool(
    ctx,
    {
      name: 'fleet_escort',
      description:
        'Send an escort ship to the target ship sector with a Travel background command, so the ' +
        'target can later take a risky job with a SAME-SECTOR escort. HARD RULE: an escort only ' +
        'counts if it is in the same sector as the action ship, so this is the only way to make an ' +
        'escort usable. The target sector is resolved here from the target ship card. Travel needs a ' +
        'destination at least 2 jumps away; if the game refuses for any reason, the refusal is ' +
        'returned verbatim (this tool never retries by itself).',
      parameters: {
        escort: {
          type: 'string',
          required: true,
          description: 'ship name to send over (should be idle and have a captain)',
        },
        target: {
          type: 'string',
          required: true,
          description: 'ship name to escort; its current sector becomes the Travel destination',
        },
      },
      output: {
        schema: { type: 'string' },
        render: (_args: unknown, value: unknown) => [{ type: 'text', text: String(value) }],
      },
      async execute(args: { escort: string; target: string }) {
        const escort = typeof args.escort === 'string' ? args.escort.trim() : ''
        const target = typeof args.target === 'string' ? args.target.trim() : ''
        if (escort === '' || target === '') {
          return 'fleet_escort needs both escort and target'
        }
        if (escort === target) {
          return `fleet_escort: escort and target are the same ship (${escort}) -- nothing to do`
        }

        // (1) WHERE is the target? That is the Travel destination.
        const tr = await ask(peer, 'query', { what: 'ship', ship: target }, 10)
        if (!tr.ok) {
          return `fleet_escort failed: cannot read the ship card of target ${target} (${tr.why ?? 'unknown'})`
        }
        const card = (tr.data ?? {}) as Record<string, unknown>
        const sector = (card.sector ?? {}) as { x?: unknown; y?: unknown }
        const x = typeof sector.x === 'number' ? sector.x : undefined
        const y = typeof sector.y === 'number' ? sector.y : undefined
        if (x === undefined || y === undefined) {
          return `fleet_escort failed: target ${target} has no readable sector in its card ` +
            `(card.sector=${JSON.stringify(card.sector ?? null)}) -- cannot choose a destination`
        }

        // ★ 2026-10-17（主人实机：她尝试护航但失败 ✗）：
        //   原版 **Travel 要求目的地至少 2 跳**（travelcommand.lua 的客户端校验 ✓），
        //   所以"护航船本来就在旁边"时 Travel **根本发不出去** ✗✓ ——
        //   而这种情况**压根不用移动** ✓：它当场就是可用护航 ✓✓。
        //   → 明确说清，别让一次正常的"无需移动"看起来像失败 ✗。
        const er = await ask(peer, 'query', { what: 'ship', ship: escort }, 10)
        if (er.ok) {
          const ecard = (er.data ?? {}) as Record<string, unknown>
          const esec = (ecard.sector ?? {}) as { x?: unknown; y?: unknown }
          const ex = typeof esec.x === 'number' ? esec.x : undefined
          const ey = typeof esec.y === 'number' ? esec.y : undefined
          const eh = (ecard.hyperspace ?? {}) as { reach?: unknown }
          const ereach = typeof eh.reach === 'number' ? eh.reach : undefined
          if (ex !== undefined && ey !== undefined && ereach !== undefined) {
            const exy = Math.sqrt((ex - x) * (ex - x) + (ey - y) * (ey - y))
            if (exy <= ereach) {
              const where = exy === 0
                ? `is ALREADY in the same sector as ${target} (${x},${y})`
                : `is ${exy.toFixed(2)} away from ${target} (${x},${y}), inside its own reach ${ereach}`
              return `fleet_escort: NO MOVE NEEDED -- ${escort} ${where}. An escort only has to be ` +
                `within ITS OWN hyperspace reach of the action ship (vanilla simulationutility.lua:161), ` +
                `not in the same sector. So just pass escorts=["${escort}"] on the action and it takes ` +
                `part immediately. A Travel order would be refused anyway (destinations must be at ` +
                `least 2 jumps away).`
            }
          }
        }

        // (2) Look at the escort's current state. These are NOTES, not blocks: the game's own
        //     refusal is the authoritative answer and must be reported verbatim.
        const notes: string[] = []
        const fr = await ask(peer, 'query', { what: 'fleet' }, 10)
        if (fr.ok) {
          const fd = (fr.data ?? {}) as Record<string, unknown>
          if (escort === String(fd.piloted ?? '')) {
            return `fleet_escort refused: ${escort} is the ship the player is flying right now -- ` +
              'the Copilot never gives background commands to that ship'
          }
          const ships = Array.isArray(fd.ships) ? (fd.ships as Record<string, unknown>[]) : []
          const row = ships.find((s) => s.name === escort)
          if (row === undefined) {
            notes.push(`${escort} is not on the Copilot roster`)
          } else {
            if (row.busy === true) notes.push(`${escort} is busy (a background command is running)`)
            if (row.hasCaptain !== true) notes.push(`${escort} has no captain -- Travel needs one`)
            const es = (row.sector ?? {}) as { x?: unknown; y?: unknown }
            if (typeof es.x === 'number' && typeof es.y === 'number') {
              notes.push(`escort currently at (${es.x},${es.y})`)
            }
          }
        } else {
          notes.push(`fleet snapshot unavailable (${fr.why ?? 'unknown'})`)
        }

        // (3) Issue the Travel order. Destination must be >= 2 jumps away, else the game refuses.
        const ord = await ask(peer, 'order', { ship: escort, action: 'Travel', x, y }, 30)
        const note = notes.length > 0 ? `\nnotes: ${notes.join('; ')}` : ''
        if (!ord.ok) {
          return `fleet_escort REFUSED by the game: Travel ${escort} -> (${x},${y}), the sector of ${target}` +
            `\nthe game said: ${ord.why ?? 'unknown'}` + note
        }
        return `fleet_escort OK: ${escort} -> sector (${x},${y}) of ${target}` +
          `\norder receipt: ${text(ord.data)}` + note
      },
    },
    'fleet_escort tool',
  )

  // ---------------------------------------------------------------------
  // fleet_goal -- set or clear a ship's standing intent
  // ---------------------------------------------------------------------
  addTool(
    ctx,
    {
      name: 'fleet_goal',
      description:
        'Set or clear a ship operating goal. A goal is a STANDING INTENT: every time the ship goes ' +
        'idle it re-requests a decision carrying that goal, until you change or clear it. Use text ' +
        'for free-form intent and options to bound the allowed actions ' +
        '(Mine/Salvage/Trade/Travel). Pass clear=true to remove the goal.',
      parameters: {
        ship: { type: 'string', required: true, description: 'ship name' },
        text: { type: 'string', description: 'free-form intent, e.g. "mine to the north-west, flee if attacked"' },
        options: { type: 'array', items: { type: 'string' }, description: 'allowed actions, e.g. ["Mine"]' },
        clear: { type: 'boolean', description: 'true = clear this ship goal' },
      },
      output: {
        schema: { type: 'string' },
        render: (_args: unknown, value: unknown) => [{ type: 'text', text: String(value) }],
      },
      async execute(args: { ship: string; text?: string; options?: string[]; clear?: boolean }) {
        const r = await ask(peer, 'setGoal', args, 10)
        if (!r.ok) return `set goal failed: ${r.why ?? 'unknown'}`
        return `goal updated for ${args.ship}\n${text(r.data)}`
      },
    },
    'fleet_goal tool',
  )

  // ---------------------------------------------------------------------
  // fleet_recall -- pull a ship back out of its background command
  //
  // Background commands are restored by the game's own simulation (BGS) even
  // across a restart, so the only way to get a ship free is to recall it. The
  // game exposes `Simulation.forceRecall(shipName)` as a callable, and the mod
  // wires it to the `recall` RPC command.
  // ---------------------------------------------------------------------
  addTool(
    ctx,
    {
      name: 'fleet_recall',
      description:
        'Recall a ship from its background command, returning it to idle. Useful because background ' +
        'commands survive a game restart (the game simulation restores them), so this is the only ' +
        'reliable way to free a ship. Once idle, a roster ship with a goal immediately asks for a ' +
        'fresh decision again.',
      parameters: {
        ship: { type: 'string', required: true, description: 'ship name to recall' },
      },
      output: {
        schema: { type: 'string' },
        render: (_args: unknown, value: unknown) => [{ type: 'text', text: String(value) }],
      },
      async execute(args: { ship: string }) {
        const r = await ask(peer, 'recall', { ship: args.ship }, 20)
        if (!r.ok) return `recall failed: ${r.why ?? 'unknown'}`
        return `recalled: ${args.ship}\n${text(r.data)}`
      },
    },
    'fleet_recall tool',
  )

  // ---------------------------------------------------------------------
  // fleet_decisions -- READ THE DECISION PROCESS (requested by the master)
  //
  // Every decide request from the game leaves one record: the goal, the facts
  // fetched over RPC, the MODEL CHAIN OF THOUGHT, the chosen action, and the
  // order receipt. Purely local memory -- safe to call with the game closed.
  // ---------------------------------------------------------------------
  addTool(
    ctx,
    {
      name: 'fleet_decisions',
      description:
        'Show the AI DECISION PROCESS. Each time an idle roster ship asked for a decision, one ' +
        'record is kept here: the standing goal, the facts DSH fetched over RPC (sector, captain, ' +
        'busy), the model CHAIN OF THOUGHT, the chosen action with its parameters, and the order ' +
        'receipt. Use this to explain or audit what the AI decided and why. This is pure local ' +
        'memory, so it is always safe to call -- even with the game closed. verbose=false gives a ' +
        'one-line-per-record summary; verbose=true prints the full chain of thought.',
      parameters: {
        ship: { type: 'string', description: 'only records for this ship (optional)' },
        limit: { type: 'number', description: 'how many recent records to show, default 5, max 50' },
        verbose: { type: 'boolean', description: 'true = print the full chain of thought (default false)' },
      },
      output: {
        schema: { type: 'string' },
        render: (_args: unknown, value: unknown) => [{ type: 'text', text: String(value) }],
      },
      async execute(args: { ship?: string; limit?: number; verbose?: boolean }) {
        // ★ 内存空时回落到**落盘记录** ✓（DSH 刚重启、还没新决策时也能看历史 ✓）
        let source: DecisionRecord[] = decisionLog ?? []
        let fromFile = false
        if (source.length === 0) {
          const hist = readDecisionFile(200)
          if (hist.length > 0) { source = hist; fromFile = true }
        }
        if (source.length === 0) {
          return 'no decisions recorded yet ' +
            '(a ship must be on the roster, have a goal, and be idle)'
        }
        const limit = Math.max(1, Math.min(args.limit ?? 5, 50))
        const verbose = args.verbose === true
        const filtered = (args.ship !== undefined && args.ship !== '')
          ? source.filter((r) => r.ship === args.ship)
          : source

        if (filtered.length === 0) return `no decisions recorded for ship ${args.ship}`

        const recent = filtered.slice(-limit)
        const okCount = filtered.filter((r) => r.ok).length
        const lines: string[] = []
        lines.push(
          `decision records: ${filtered.length} total (${okCount} ok / ${filtered.length - okCount} failed), ` +
          `showing the latest ${recent.length}` + (args.ship !== undefined ? ` for ${args.ship}` : ''),
        )

        // Newest first reads better.
        for (let i = recent.length - 1; i >= 0; i--) {
          const rec = recent[i]
          const idx = filtered.length - recent.length + i + 1
          lines.push('')
          lines.push(`--- #${idx}  ${rec.ship}  ${rec.at}  ${rec.ok ? 'OK' : 'FAILED'} ---`)
          lines.push(`goal: ${rec.goalText !== '' ? rec.goalText : '(no free text)'}`)
          if (rec.goalOptions.length > 0) lines.push(`allowed actions: ${rec.goalOptions.join(', ')}`)

          const card = rec.card as Record<string, unknown> | undefined
          if (card !== undefined) {
            const sector = card.sector as { x?: number; y?: number } | undefined
            const bits: string[] = []
            if (sector !== undefined) bits.push(`sector=(${sector.x},${sector.y})`)
            if (card.busy !== undefined) bits.push(`busy=${String(card.busy)}`)
            if (card.hasCaptain !== undefined) bits.push(`captain=${String(card.hasCaptain)}`)
            if (bits.length > 0) lines.push(`facts: ${bits.join('  ')}`)
          }

          if (verbose) {
            if (rec.reasoning !== undefined && rec.reasoning.trim() !== '') {
              lines.push('reasoning (chain of thought):')
              for (const l of rec.reasoning.trim().split('\n')) lines.push(`  | ${l}`)
            }
            if (rec.modelText !== undefined && rec.modelText.trim() !== '') {
              lines.push('model reply:')
              for (const l of rec.modelText.trim().split('\n')) lines.push(`  | ${l}`)
            }
            if (rec.truncated === true) lines.push('  WARNING: reply was cut off by maxTokens')
          } else {
            lines.push(`reasoning: ${(rec.reasoning ?? '').length} chars (pass verbose=true to see it)`)
          }

          if (rec.answer !== undefined) {
            const extra = Object.keys(rec.answer.params).length > 0
              ? ' ' + JSON.stringify(rec.answer.params)
              : ''
            lines.push(`decision: action=${rec.answer.action}${extra}`)
            if (rec.answer.reason !== undefined) lines.push(`why: ${rec.answer.reason}`)
          }
          if (rec.orderResult !== undefined) {
            lines.push(`order: ${JSON.stringify(rec.orderResult)}`)
          }
          if (!rec.ok && rec.code !== undefined) {
            lines.push(`error: ${rec.code} - ${rec.message ?? ''}`)
          }
        }

        return lines.join('\n')
      },
    },
    'fleet_decisions tool',
  )
}