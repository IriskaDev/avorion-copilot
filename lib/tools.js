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
import { defineTool } from '@deepseek-ai/dsh-tools';
import { readDecisionFile } from './index.js';
/** Wrap the callback-based RpcPeer.call into a Promise (tool execute is async). */
export function ask(peer, cmd, data, timeoutSec = 15) {
    return new Promise((resolve) => {
        const sent = peer.call(cmd, data, (ok, payload, why) => resolve({ ok, data: payload, why }), timeoutSec);
        if (!sent)
            resolve({ ok: false, why: 'not connected to the game' });
    });
}
/** Render any result as text the model can read. */
function text(value) {
    if (typeof value === 'string')
        return value;
    try {
        return JSON.stringify(value, null, 2);
    }
    catch {
        return String(value);
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
function addTool(ctx, def, label) {
    ctx.effect(() => {
        ctx.tools.register(defineTool(def));
    }, label);
}
export function registerFleetTools(ctx, peer, decisionLog) {
    // ---------------------------------------------------------------------
    // fleet_query -- read game data (the "eyes")
    // ---------------------------------------------------------------------
    addTool(ctx, {
        name: 'fleet_query',
        description: 'Query Avorion game state. what=fleet returns a snapshot of every ship on the Copilot ' +
            'roster (idle/busy, has captain, current progress). what=ship returns one ship capability ' +
            'card. what=goal returns that ship operating goal (the player text intent and allowed ' +
            'actions). what=orderSchema returns the currently legal commands and their parameters for ' +
            'that ship. This is the ONLY proper way to look at the game -- do not rely on screenshots.',
        parameters: {
            what: { type: 'string', required: true, description: 'fleet | ship | goal | orderSchema' },
            ship: { type: 'string', description: 'ship name; required when what is ship/goal/orderSchema' },
        },
        output: {
            schema: { type: 'string' },
            render: (_args, value) => [{ type: 'text', text: String(value) }],
        },
        async execute(args) {
            if (args.what !== 'fleet' && (args.ship === undefined || args.ship === '')) {
                return `what=${args.what} needs the ship parameter`;
            }
            // tradePlan runs a FULL area analysis in the game (PassageMap + flood fill),
            // which takes far longer than a plain query -- give it room (2026-10-16).
            const timeout = args.what === 'tradePlan' ? 120 : 10;
            const r = await ask(peer, 'query', { what: args.what, ship: args.ship }, timeout);
            if (!r.ok)
                return `query failed: ${r.why ?? 'unknown'}`;
            return text(r.data);
        },
    }, 'fleet_query tool');
    // ---------------------------------------------------------------------
    // fleet_order -- actually command a ship (the "hands")
    // ---------------------------------------------------------------------
    addTool(ctx, {
        name: 'fleet_order',
        description: 'Give a background command to a ship on the Copilot roster. action is one of Mine, Salvage, ' +
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
            duration: { type: 'number', description: 'task duration in hours, optional' },
            goodName: {
                type: 'string',
                description: 'Trade only: WHICH trade route to fly. Must be a route name from ' +
                    'fleet_query what=tradePlan (e.g. "Drill", "Antigrav Unit"). Without it the ' +
                    'game answers "No route selected."',
            },
            deposit: {
                type: 'number',
                description: 'Trade only: upfront budget in credits. MUST be > 0 (the game refuses 0 with ' +
                    '"Error starting command.") and the player must be able to pay it. It decides how ' +
                    'much cargo each flight carries.',
            },
            escorts: {
                type: 'array',
                items: { type: 'string' },
                description: 'Trade only: escort ship names. HARD RULE: an escort must be in the SAME SECTOR as ' +
                    'the action ship, otherwise it cannot take part.',
            },
        },
        output: {
            schema: { type: 'string' },
            render: (_args, value) => [{ type: 'text', text: String(value) }],
        },
        async execute(args) {
            const r = await ask(peer, 'order', args, 30);
            if (!r.ok)
                return `order failed: ${r.why ?? 'unknown'}`;
            return `ordered: ${args.ship} -> ${args.action}\n${text(r.data)}`;
        },
    }, 'fleet_order tool');
    // ---------------------------------------------------------------------
    // fleet_goal -- set or clear a ship's standing intent
    // ---------------------------------------------------------------------
    addTool(ctx, {
        name: 'fleet_goal',
        description: 'Set or clear a ship operating goal. A goal is a STANDING INTENT: every time the ship goes ' +
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
            render: (_args, value) => [{ type: 'text', text: String(value) }],
        },
        async execute(args) {
            const r = await ask(peer, 'setGoal', args, 10);
            if (!r.ok)
                return `set goal failed: ${r.why ?? 'unknown'}`;
            return `goal updated for ${args.ship}\n${text(r.data)}`;
        },
    }, 'fleet_goal tool');
    // ---------------------------------------------------------------------
    // fleet_decisions -- READ THE DECISION PROCESS (requested by the master)
    //
    // Every decide request from the game leaves one record: the goal, the facts
    // fetched over RPC, the MODEL CHAIN OF THOUGHT, the chosen action, and the
    // order receipt. Purely local memory -- safe to call with the game closed.
    // ---------------------------------------------------------------------
    addTool(ctx, {
        name: 'fleet_decisions',
        description: 'Show the AI DECISION PROCESS. Each time an idle roster ship asked for a decision, one ' +
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
            render: (_args, value) => [{ type: 'text', text: String(value) }],
        },
        async execute(args) {
            // ★ 内存空时回落到**落盘记录** ✓（DSH 刚重启、还没新决策时也能看历史 ✓）
            let source = decisionLog ?? [];
            let fromFile = false;
            if (source.length === 0) {
                const hist = readDecisionFile(200);
                if (hist.length > 0) {
                    source = hist;
                    fromFile = true;
                }
            }
            if (source.length === 0) {
                return 'no decisions recorded yet ' +
                    '(a ship must be on the roster, have a goal, and be idle)';
            }
            const limit = Math.max(1, Math.min(args.limit ?? 5, 50));
            const verbose = args.verbose === true;
            const filtered = (args.ship !== undefined && args.ship !== '')
                ? source.filter((r) => r.ship === args.ship)
                : source;
            if (filtered.length === 0)
                return `no decisions recorded for ship ${args.ship}`;
            const recent = filtered.slice(-limit);
            const okCount = filtered.filter((r) => r.ok).length;
            const lines = [];
            lines.push(`decision records: ${filtered.length} total (${okCount} ok / ${filtered.length - okCount} failed), ` +
                `showing the latest ${recent.length}` + (args.ship !== undefined ? ` for ${args.ship}` : ''));
            // Newest first reads better.
            for (let i = recent.length - 1; i >= 0; i--) {
                const rec = recent[i];
                const idx = filtered.length - recent.length + i + 1;
                lines.push('');
                lines.push(`--- #${idx}  ${rec.ship}  ${rec.at}  ${rec.ok ? 'OK' : 'FAILED'} ---`);
                lines.push(`goal: ${rec.goalText !== '' ? rec.goalText : '(no free text)'}`);
                if (rec.goalOptions.length > 0)
                    lines.push(`allowed actions: ${rec.goalOptions.join(', ')}`);
                const card = rec.card;
                if (card !== undefined) {
                    const sector = card.sector;
                    const bits = [];
                    if (sector !== undefined)
                        bits.push(`sector=(${sector.x},${sector.y})`);
                    if (card.busy !== undefined)
                        bits.push(`busy=${String(card.busy)}`);
                    if (card.hasCaptain !== undefined)
                        bits.push(`captain=${String(card.hasCaptain)}`);
                    if (bits.length > 0)
                        lines.push(`facts: ${bits.join('  ')}`);
                }
                if (verbose) {
                    if (rec.reasoning !== undefined && rec.reasoning.trim() !== '') {
                        lines.push('reasoning (chain of thought):');
                        for (const l of rec.reasoning.trim().split('\n'))
                            lines.push(`  | ${l}`);
                    }
                    if (rec.modelText !== undefined && rec.modelText.trim() !== '') {
                        lines.push('model reply:');
                        for (const l of rec.modelText.trim().split('\n'))
                            lines.push(`  | ${l}`);
                    }
                    if (rec.truncated === true)
                        lines.push('  WARNING: reply was cut off by maxTokens');
                }
                else {
                    lines.push(`reasoning: ${(rec.reasoning ?? '').length} chars (pass verbose=true to see it)`);
                }
                if (rec.answer !== undefined) {
                    const extra = Object.keys(rec.answer.params).length > 0
                        ? ' ' + JSON.stringify(rec.answer.params)
                        : '';
                    lines.push(`decision: action=${rec.answer.action}${extra}`);
                    if (rec.answer.reason !== undefined)
                        lines.push(`why: ${rec.answer.reason}`);
                }
                if (rec.orderResult !== undefined) {
                    lines.push(`order: ${JSON.stringify(rec.orderResult)}`);
                }
                if (!rec.ok && rec.code !== undefined) {
                    lines.push(`error: ${rec.code} - ${rec.message ?? ''}`);
                }
            }
            return lines.join('\n');
        },
    }, 'fleet_decisions tool');
}
//# sourceMappingURL=tools.js.map