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
export function registerFleetTools(ctx, peer, decisionLog, commander, 
/** the recall/query timeouts differ in tests; keep the production defaults */
opts = {}) {
    // ---------------------------------------------------------------------
    // fleet_query -- read game data (the "eyes")
    // ---------------------------------------------------------------------
    addTool(ctx, {
        name: 'fleet_query',
        description: 'Query Avorion game state. what=fleet returns a snapshot of every ship on the Copilot ' +
            'roster (idle/busy, has captain, current progress). what=ship returns one ship capability ' +
            'card (pass brief=true for the SHORT one -- it answers "what can this ship do right now" ' +
            'in one call, which is usually all you need). what=goal returns that ship operating goal ' +
            '(the player text intent and allowed actions). what=sectorFacts returns FACTS about any ' +
            'sector (richness / material probability / centre-ring side / distance from the map centre, ' +
            'plus the same numbers for sectors closer to the centre) -- pass x and y (and optionally ' +
            'ship) -- it returns no verdict about whether to go there. what=dossier returns ONE bounded ' +
            'pre-fetched bundle (ship + rules + plan candidates) -- that is the single-shot path helper; ' +
            'an agent should prefer the individual queries below. The plan queries -- what=tradePlan | ' +
            'minePlan | salvagePlan | sellPlan | scoutPlan | jobPlan (jobPlan takes action=Mine|Salvage) -- ' +
            'are BOUNDED BY DEFAULT: you get the top few candidate boxes with their key numbers, not the ' +
            'full multi-megabyte dump. Use top=N to change how many candidates come back, compact=false ' +
            '(or full=true) only when you really need the complete raw answer, and brief=true on ' +
            'what=fleet for a short roster. This is the ONLY proper way to look at the game -- do ' +
            'not rely on screenshots.',
        parameters: {
            what: {
                type: 'string',
                required: true,
                description: 'fleet | ship | goal | sectorFacts | dossier | tradePlan | minePlan | ' +
                    'salvagePlan | sellPlan | scoutPlan | jobPlan',
            },
            ship: { type: 'string', description: 'ship name; required when what is ship/goal/dossier/any plan' },
            x: { type: 'number', description: 'sector x; required for what=sectorFacts' },
            y: { type: 'number', description: 'sector y; required for what=sectorFacts' },
            compact: {
                type: 'boolean',
                description: 'plan queries: DEFAULT TRUE (small answer: top few candidates, scalar fields only, ' +
                    'the per-box bulk tables dropped -- the response says what it dropped). Pass compact=false ' +
                    'to get the complete raw answer instead (that one is still hard-gated, and says what it cut).',
            },
            top: {
                type: 'number',
                description: 'plan queries: how many candidate boxes to keep (default 4, max 24). Smaller = cheaper. ' +
                    'This is the main knob for answer size.',
            },
            full: { type: 'boolean', description: 'plan queries: same as compact=false (explicit full answer)' },
            brief: {
                type: 'boolean',
                description: 'ship/fleet: return the SHORT view (name/sector/captain/cargo/actions + current-sector ' +
                    'numbers; no depth sampling, no long per-action prose). Answers "what can it do now".',
            },
            action: { type: 'string', description: 'jobPlan only: Mine | Salvage (default Mine)' },
        },
        output: {
            schema: { type: 'string' },
            render: (_args, value) => [{ type: 'text', text: String(value) }],
        },
        async execute(args) {
            // ★ sectorFacts 只需要坐标 ✓；其余"针对某艘船"的 what 才需要 ship ✓（2026-10-17 ✓）
            const needsShip = args.what !== 'fleet' && args.what !== 'sectorFacts';
            if (needsShip && (args.ship === undefined || args.ship === '')) {
                return `what=${args.what} needs the ship parameter`;
            }
            if (args.what === 'sectorFacts' && (args.x === undefined || args.y === undefined)) {
                return 'what=sectorFacts needs the x and y parameters';
            }
            // tradePlan runs a FULL area analysis in the game (PassageMap + flood fill),
            // which takes far longer than a plain query -- give it room (2026-10-16).
            const timeout = args.what === 'tradePlan' ? 120 : 10;
            // ★★ 计划查询的**体积旋钮**（2026-10-17 ✓✓）：原样透传给游戏侧 ✓。
            //   ★ **一个都不默认** ✗ —— 缺省由**游戏侧**定（compact=true / top=4 ✓），
            //     这样"工具说明"与"游戏行为"只有一个真相来源 ✓（不会各改各的 ✓）。
            //   ★ 但**必须**把参数名带过去（漏了它们 = 旋钮静默失效 ✓）。
            const r = await ask(peer, 'query', {
                what: args.what, ship: args.ship, x: args.x, y: args.y,
                compact: args.compact, top: args.top, full: args.full, brief: args.brief,
                action: args.action,
            }, timeout);
            if (!r.ok)
                return `query failed: ${r.why ?? 'unknown'}`;
            const body = text(r.data);
            // ★★ 体积**回显**（2026-10-17 ✓）：查询答复本身也会进上下文 ✓ ——
            //   让调用方**看得见**自己拉了多少字节 ✓（自己决定要不要缩 top ✓）。
            //   这一行是**事实**，不是限制 ✓（游戏侧已经有闸，这里只是让它可见 ✓）。
            const bytes = Buffer.byteLength(body, 'utf8');
            const head = `[fleet_query ${args.what}: ${bytes} bytes` +
                (args.what.endsWith('Plan') || args.what === 'jobPlan'
                    ? `, compact=${args.compact === false || args.full === true ? 'FULL' : 'yes'}${args.top !== undefined ? `, top=${String(args.top)}` : ''}`
                    : '') +
                ']\n';
            return head + body;
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
            sizeX: {
                type: 'number',
                description: 'Trade only: the box WIDTH. Vanilla legal Trade shapes are 17x17 / 29x11 / 11x29 ' +
                    '(two of them are NOT squares), so pass sizeX and sizeY together with the x/y of the ' +
                    'candidate you picked (each tradePlan candidate carries shape / sizeX / sizeY).',
            },
            sizeY: { type: 'number', description: 'Trade only: the box HEIGHT (see sizeX).' },
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
            const r = await ask(peer, 'order', args, opts.orderTimeoutSec ?? 30);
            if (!r.ok)
                return `order failed: ${r.why ?? 'unknown'}`;
            return `ordered: ${args.ship} -> ${args.action}\n${text(r.data)}`;
        },
    }, 'fleet_order tool');
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
    addTool(ctx, {
        name: 'fleet_escort',
        description: 'Send an escort ship to the target ship sector with a Travel background command, so the ' +
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
            render: (_args, value) => [{ type: 'text', text: String(value) }],
        },
        async execute(args) {
            const escort = typeof args.escort === 'string' ? args.escort.trim() : '';
            const target = typeof args.target === 'string' ? args.target.trim() : '';
            if (escort === '' || target === '') {
                return 'fleet_escort needs both escort and target';
            }
            if (escort === target) {
                return `fleet_escort: escort and target are the same ship (${escort}) -- nothing to do`;
            }
            // (1) WHERE is the target? That is the Travel destination.
            const tr = await ask(peer, 'query', { what: 'ship', ship: target }, 10);
            if (!tr.ok) {
                return `fleet_escort failed: cannot read the ship card of target ${target} (${tr.why ?? 'unknown'})`;
            }
            const card = (tr.data ?? {});
            const sector = (card.sector ?? {});
            const x = typeof sector.x === 'number' ? sector.x : undefined;
            const y = typeof sector.y === 'number' ? sector.y : undefined;
            if (x === undefined || y === undefined) {
                return `fleet_escort failed: target ${target} has no readable sector in its card ` +
                    `(card.sector=${JSON.stringify(card.sector ?? null)}) -- cannot choose a destination`;
            }
            // ★ 2026-10-17（主人实机：她尝试护航但失败 ✗）：
            //   原版 **Travel 要求目的地至少 2 跳**（travelcommand.lua 的客户端校验 ✓），
            //   所以"护航船本来就在旁边"时 Travel **根本发不出去** ✗✓ ——
            //   而这种情况**压根不用移动** ✓：它当场就是可用护航 ✓✓。
            //   → 明确说清，别让一次正常的"无需移动"看起来像失败 ✗。
            const er = await ask(peer, 'query', { what: 'ship', ship: escort }, 10);
            if (er.ok) {
                const ecard = (er.data ?? {});
                const esec = (ecard.sector ?? {});
                const ex = typeof esec.x === 'number' ? esec.x : undefined;
                const ey = typeof esec.y === 'number' ? esec.y : undefined;
                const eh = (ecard.hyperspace ?? {});
                const ereach = typeof eh.reach === 'number' ? eh.reach : undefined;
                if (ex !== undefined && ey !== undefined && ereach !== undefined) {
                    const exy = Math.sqrt((ex - x) * (ex - x) + (ey - y) * (ey - y));
                    if (exy <= ereach) {
                        const where = exy === 0
                            ? `is ALREADY in the same sector as ${target} (${x},${y})`
                            : `is ${exy.toFixed(2)} away from ${target} (${x},${y}), inside its own reach ${ereach}`;
                        return `fleet_escort: NO MOVE NEEDED -- ${escort} ${where}. An escort only has to be ` +
                            `within ITS OWN hyperspace reach of the action ship (vanilla simulationutility.lua:161), ` +
                            `not in the same sector. So just pass escorts=["${escort}"] on the action and it takes ` +
                            `part immediately. A Travel order would be refused anyway (destinations must be at ` +
                            `least 2 jumps away).`;
                    }
                }
            }
            // (2) Look at the escort's current state. These are NOTES, not blocks: the game's own
            //     refusal is the authoritative answer and must be reported verbatim.
            const notes = [];
            const fr = await ask(peer, 'query', { what: 'fleet' }, 10);
            if (fr.ok) {
                const fd = (fr.data ?? {});
                if (escort === String(fd.piloted ?? '')) {
                    return `fleet_escort refused: ${escort} is the ship the player is flying right now -- ` +
                        'the Copilot never gives background commands to that ship';
                }
                const ships = Array.isArray(fd.ships) ? fd.ships : [];
                const row = ships.find((s) => s.name === escort);
                if (row === undefined) {
                    notes.push(`${escort} is not on the Copilot roster`);
                }
                else {
                    if (row.busy === true)
                        notes.push(`${escort} is busy (a background command is running)`);
                    if (row.hasCaptain !== true)
                        notes.push(`${escort} has no captain -- Travel needs one`);
                    const es = (row.sector ?? {});
                    if (typeof es.x === 'number' && typeof es.y === 'number') {
                        notes.push(`escort currently at (${es.x},${es.y})`);
                    }
                }
            }
            else {
                notes.push(`fleet snapshot unavailable (${fr.why ?? 'unknown'})`);
            }
            // (3) Issue the Travel order. Destination must be >= 2 jumps away, else the game refuses.
            const ord = await ask(peer, 'order', { ship: escort, action: 'Travel', x, y }, 30);
            const note = notes.length > 0 ? `\nnotes: ${notes.join('; ')}` : '';
            if (!ord.ok) {
                return `fleet_escort REFUSED by the game: Travel ${escort} -> (${x},${y}), the sector of ${target}` +
                    `\nthe game said: ${ord.why ?? 'unknown'}` + note;
            }
            return `fleet_escort OK: ${escort} -> sector (${x},${y}) of ${target}` +
                `\norder receipt: ${text(ord.data)}` + note;
        },
    }, 'fleet_escort tool');
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
    // fleet_recall -- pull a ship back out of its background command
    //
    // Background commands are restored by the game's own simulation (BGS) even
    // across a restart, so the only way to get a ship free is to recall it. The
    // game exposes `Simulation.forceRecall(shipName)` as a callable, and the mod
    // wires it to the `recall` RPC command.
    // ---------------------------------------------------------------------
    addTool(ctx, {
        name: 'fleet_recall',
        description: 'Recall a ship from its background command, returning it to idle. Useful because background ' +
            'commands survive a game restart (the game simulation restores them), so this is the only ' +
            'reliable way to free a ship. Once idle, a roster ship with a goal immediately asks for a ' +
            'fresh decision again.',
        parameters: {
            ship: { type: 'string', required: true, description: 'ship name to recall' },
        },
        output: {
            schema: { type: 'string' },
            render: (_args, value) => [{ type: 'text', text: String(value) }],
        },
        async execute(args) {
            const r = await ask(peer, 'recall', { ship: args.ship }, 20);
            if (!r.ok)
                return `recall failed: ${r.why ?? 'unknown'}`;
            return `recalled: ${args.ship}\n${text(r.data)}`;
        },
    }, 'fleet_recall tool');
    // ---------------------------------------------------------------------
    // fleet_commander -- designate WHICH session receives fleet decisions
    //
    // The owner's scope (2026-10-17): the plugin is the GAME RPC INTERFACE
    // PROVIDER. Decision tasks are delivered into the session HE is already
    // using -- no clone, no new session, no candidate listing.
    //
    // Why explicit and never guessed: `Agent.followup()` performs NO ownership
    // check, so the plugin can push a task block into ANY live session. Guessing
    // wrong pollutes someone else's transcript. So the owner says the id, and
    // clearing it restores today's single-shot behaviour verbatim.
    // ---------------------------------------------------------------------
    if (commander !== undefined) {
        addTool(ctx, {
            name: 'fleet_commander',
            description: 'Show, set or clear WHICH DSH session receives fleet decision tasks from the Avorion ' +
                'copilot plugin -- the fleet COMMANDER switch. There is no clone and no separate ' +
                'commander session: the target is a session you already use, and the plugin is only the ' +
                'game RPC interface provider. While a session is designated, an idle-roster ship that ' +
                'needs a decision gets a delimited <fleet_task> block delivered into that session ' +
                '(visible as a normal user message) and its answer is mapped onto the same order path the ' +
                'plugin already had. Only ONE session is ever the commander: designating a new one ' +
                'displaces the previous one immediately. The session is never interrupted: if you are ' +
                'chatting, the decision falls back to the plugin single-shot model call. Call with no ' +
                'arguments to see the current commander. Pass session=<id> to designate it, or clear=true ' +
                'to stop delivering -- clearing restores the pure single-shot behaviour.',
            parameters: {
                session: {
                    type: 'string',
                    description: 'session id to make the commander; omit to read the current state. Empty string = clear. ' +
                        'If omitted together with action="claim", the CALLING session is used automatically.',
                },
                action: {
                    type: 'string',
                    description: 'optional: "claim" = make the CALLING session the commander (this is the per-session ' +
                        'toggle: open the switch from a session and that session takes over), ' +
                        '"clear" = drop the current commander, "status" = read state only.',
                },
                clear: { type: 'boolean', description: 'true = clear the commander (back to single-shot only)' },
            },
            output: {
                schema: { type: 'string' },
                render: (_args, value) => [{ type: 'text', text: String(value) }],
            },
            async execute(args) {
                const action = typeof args.action === 'string' ? args.action.trim().toLowerCase() : '';
                const wantsClear = args.clear === true || action === 'clear' ||
                    (args.session !== undefined && args.session.trim() === '');
                // ★ "从这个会话打开"：不给 id 的 claim = 用**调用者**自己的会话 ✓（绝不猜别人的 ✗）
                let wanted = args.session;
                if (action === 'claim' && (wanted === undefined || wanted.trim() === '')) {
                    const caller = commander.currentSessionId?.();
                    if (caller === undefined) {
                        return 'fleet_commander: cannot tell which session is calling, so I will not guess. ' +
                            'Pass session=<id> explicitly (or use the switch at the top of the session).';
                    }
                    wanted = caller;
                }
                const previous = commander.state().session;
                if (wanted !== undefined || wantsClear) {
                    commander.set(wantsClear ? null : (wanted ?? null));
                }
                // Report the resulting state truthfully, including whether it is actually alive.
                const st = commander.state();
                const lines = [];
                if (st.session === null || st.session === undefined) {
                    lines.push('fleet commander: NONE');
                    lines.push('  -> decisions go through the plugin single-shot model call (unchanged behaviour)');
                    if (previous !== null && previous !== undefined)
                        lines.push(`  (was ${previous}; it no longer receives tasks)`);
                }
                else {
                    const agent = commander.agent(st.session);
                    const live = agent !== undefined;
                    lines.push(`fleet commander: ${st.session}`);
                    if (previous !== null && previous !== undefined && previous !== st.session) {
                        lines.push(`  displaced: ${previous} -- it no longer receives any fleet task`);
                    }
                    lines.push(`  session live now: ${live ? 'YES' : 'NO (plugin will skip delivery)'}`);
                    if (live)
                        lines.push(`  session status: ${String(agent?.status ?? 'unknown')}`);
                    lines.push(`  lease: ${commander.leaseFresh() ? 'fresh (recently received a task)' : 'stale/never used'} -> ` +
                        `${st.leasedUntil === null ? 'never delivered' : new Date(st.leasedUntil).toISOString()}`);
                    lines.push('  NOTE: a BUSY session is never interrupted; the decision falls back to the ' +
                        'plugin single-shot call instead. Fleet tasks are delimited by <fleet_task> and require ' +
                        'a task=<id> echo, so they never get confused with your own words.');
                }
                lines.push('  mode: shadow by default -- the session answer is recorded and compared with the ' +
                    'single-shot answer, but the single-shot answer is what actually gets ordered. ' +
                    'Set decideMode="live" in the plugin config to let the session answer decide.');
                if (commander.file !== undefined)
                    lines.push(`  persisted at: ${commander.file}`);
                return lines.join('\n');
            },
        }, 'fleet_commander tool');
    }
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