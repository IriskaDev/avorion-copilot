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
import { readDecisionFile, deciderOf } from './index.js';
// ★★ 预检/实测的渲染与轮询（2026-10-17 ✓）：与决策路径**共用同一份** ✓（不各写一套 ✗）
import { waitForOrderVerify, preflightText, preflightWarningText, verifyText, } from './index.js';
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
/** ★ 待命裁定（2026-10-17 ✓）：召回/改目标时清掉同船的 None 冷却 ✓ */
standby, 
/** the recall/query timeouts differ in tests; keep the production defaults */
opts = {}) {
    // ---------------------------------------------------------------------
    // fleet_query -- read game data (the "eyes")
    // ---------------------------------------------------------------------
    addTool(ctx, {
        name: 'fleet_query',
        description: 'Query Avorion game state with ATOMIC interfaces -- each call does ONE small thing and the ' +
            'decision-maker composes them (list -> pick a ship -> ship -> goal -> predict/tradeRoutes). ' +
            '★ what=orderStatus returns the POST-ORDER VERIFICATION of one order (pass orderId, or ship for ' +
            'the latest order of that ship): {started, verify:{ok, evidence, busy, moved, atDestination, ' +
            'cargoUsed, cargoUsedDelta, reason, ...}}. It is the ONLY honest answer to "did it actually run?" ' +
            '-- `accepted:true, executed:true` in an order receipt only means the order entered the RPC ' +
            'queue; verify.pending=true means the sample is not due yet (that is NOT success either). ' +
            '★ what=list returns an INDEX-LEVEL roster: only name / idle / has captain / sector per ship ' +
            '(NO per-ship full state, NO cargo detail, NO prediction) -- use it FIRST to pick which ship ' +
            'to look at, then query that one. what=ship returns ONE ship capability card (brief=true for ' +
            'the SHORT view). ★ Identity fields on every ship card (both full and brief, same source): ' +
            'shipTitle / shipTitleRaw / shipTitleKnown / shipTitleNote = the vanilla per-ship TITLE read ' +
            'from ShipDatabaseEntry:getTitle() (the same string the fleet UI shows under the ship name, ' +
            'e.g. "Combat", "Miner", "Carrier"); shipTitle "" with shipTitleKnown=true means the ship ' +
            'genuinely has no title -- that is NOT "unreadable" (that case omits shipTitle and sets ' +
            'shipTitleKnown=false). entityType / entityTypeId = vanilla EntityType (Ship/Drone/Station/...). ' +
            'Do NOT invent a role from the name: if shipTitle is empty, judge the job from turrets + ' +
            'captainClass. what=goal returns that ship operating goal. what=sectorFacts returns FACTS ' +
            'about any sector (pass x,y): richness/material probabilities/ring side/distance, PLUS ' +
            'faction ownership + friendliness -- factionIndex (0 = no faction), factionName, hasFaction, ' +
            'relation (unowned/self/friendly/neutral/ceasefire/hostile, vanilla RelationStatus), isFriendly ' +
            '(boolean from vanilla relation), hasStations (SectorView.numStations>0). Use isFriendly to ' +
            'enforce the owner rule "trader travels only through friendly sectors". ★ what=predict is ' +
            'the CORE computation atom: ONE box (x,y,sizeX,' +
            'sizeY) + ONE action (Mine|Salvage|Trade|Sell|Scout|Travel|Refine) + that action minimal params -> the ' +
            'prediction numbers (risk + value) for THAT box only; batch via boxes=[...] (N<=24, each box ' +
            'independent). ★ Travel is the ONE exception to "the box must contain the ship": a Travel box is ' +
            'the 1x1 DESTINATION (vanilla travelcommand.lua isShipRequiredInArea=false), and its risk is the ' +
            'WHOLE-TRIP ambush chance (the same number the vanilla Travel UI shows) with value.distance / ' +
            'value.travelTime / value.routeSectors. Travel exposes NO separate base value -> ' +
            'risk.baseAttackChance is null and risk.baseAttackChanceKnown=false (+ reason); never read that as 0. ' +
            '★ Refine predict: pass sizeX=31,sizeY=31 (vanilla getAreaSize + isAreaFixed; the game re-centres ' +
            'the box on the ship, so predict reports the ship-centred box and echoes your centre as ' +
            'box.requestedCentre). Refine needs ORE IN THE HOLD, requires no refinery/faction (a refinery only ' +
            'halves duration and lowers tax), outputs into the faction RESOURCE POOL, and its risk is the ' +
            'vanilla hardcoded 0 (that command never registers for attack) -- value.yields / value.duration / ' +
            'value.tax carry the numbers. ' +
            '★ Scout predict returns value.unknownCount/knownCount/totalSectors (unexplored/' +
            'explored/total sectors in that box) + value.revealsNothingNew (true => the box has no ' +
            'unexplored sectors, reveals no new map) + box.containsShip; the Scout box is 21x21 (vanilla ' +
            'scoutcommand getAreaSize). ★ what=tradeRoutes returns the trade routes inside ONE box + ' +
            'per-good numbers ' +
            '(no sorting, no recommendation). ★★ what=tradeEvaluate is the ONE-CALL matrix for trade: ' +
            'boxes[] (1..6) x ALL routes in each box (goodsFilter[] optional) x deposits[] (1..3 tiers) -> ' +
            'ONE array `results` sorted by netProfitLow / durationHours (profitPerHour, the owner-specified ' +
            'unit-time key) plus `rejected[]` with a reason for every dropped combination (EMPTY_RUN when ' +
            'flights.from==0, RISK_OVER_GATE when attackChance>maxAttackChance, RISK_UNKNOWN, ' +
            'PREDICTION_FAILED). Each box is area-analysed exactly ONCE and the numbers come from the SAME ' +
            'code as what=predict (so they match it verbatim). It computes only -- NO recommendation / ' +
            'orderHint / best pick; choosing is yours. Combination cap 60 (over it -> TOO_MANY_COMBINATIONS ' +
            'with a shrink hint). Unknown numbers stay null (never 0). ★★ what=mountQuote is the PURE-FACT ' +
            'turret-base material upgrade quote: pass ship + material (iron|titanium|naonite|trinium|xanion|' +
            'ogonite|avorion or 0-6). It returns every base ({index, material, materialValue, needsUpgrade}), ' +
            'the target material, the resource+credit cost (quote/costs), affordable, and shortfall[] (= what ' +
            'is missing when you cannot pay); it CHANGES NOTHING. what=mountUpgrade EXECUTES the same upgrade ' +
            '(same code as the /copilot mounts command) but ONLY when confirm=true; without confirm it is a ' +
            'preview quote that changes nothing. Its receipt mirrors the CLI result: ok/stage/changed/verified/' +
            'wrong/paid/shape{blocksBefore,blocksAfter,blocksKept,boundingBoxKept}/turrets{before,after,' +
            'designsRestored,designsDropped}/databaseSynced/lines[]. A piloted ship is ALLOWED (verified ' +
            'in-game, Raven) but the response carries piloted=true + warning (a very short stutter is possible ' +
            'at the write-back instant). ★★ what=shipQuote is the PURE-FACT **whole-ship** material upgrade ' +
            'quote: pass ship + material. It returns blockCount, distribution:[{material, materialValue, blocks}] ' +
            '(how many blocks of each material), needUpgrade, the resource+credit cost (quote/costs), affordable, ' +
            'shortfall[] (= what is missing), nothingToDo (everything is already at or above the target) and ' +
            'read-only assertions. The cost is the vanilla repair-dock material-difference formula ' +
            '(repairdock.lua:993-1017) applied to getUndamagedResourceValue/getUndamagedMoneyValue, NOT ' +
            '"per-base quote x block count". It changes NOTHING -- no pay, no setMovePlan, no ship database ' +
            'write. ★★ what=blockQuote / what=blockUpgrade are the GENERIC per-block-type atoms: pass ship + ' +
            'blockType (a vanilla BlockType name such as Hull|Armor|CargoBay|Engine|TurretBase, or a number) + ' +
            'material. blockQuote is a pure-fact quote for exactly that block type (blockCount for that type, ' +
            'distribution, byType, needUpgrade, quote/costs, affordable, shortfall, nothingToDo, read-only ' +
            'assertions). blockUpgrade EXECUTES it but ONLY when confirm=true; without confirm it is a preview ' +
            'quote. ★★ what=shipUpgrade is the SEPARATE whole-ship execute atom: all blocks below the target are ' +
            'upgraded, and it too ONLY executes when confirm=true. mountQuote/mountUpgrade remain the historical ' +
            'shortcut for the four turret-base BlockTypes. Per-block facts are omitted above 200 selected blocks ' +
            '(blocksOmitted). ' +
            '★★ what=renameShip RENAMES one ship. The vanilla entry point is ShipDatabaseEntry:setNewName(name), ' +
            'SERVER-side only; the ship name is a plain string (property string name), NOT a Format, so no ' +
            'translated() is involved (the Format-based field is getTitle(), which this atom does NOT touch). ' +
            'Pass ship (the CURRENT name) + name (the NEW name, plain string; leading/trailing spaces are trimmed ' +
            'and reported as normalized=true). Rejected BEFORE any write: empty / control characters (newline, tab, ' +
            'CR, DEL, NUL) / ' + "this mod's config separator '|' / invalid UTF-8 / more than 32 CHARACTERS " +
            '(that 32 is OUR guard, not a vanilla constant -- vanilla exposes no Lua-side length limit). Also ' +
            'refused: a busy ship (InBackground) -> SHIP_BUSY (recall it first: vanilla warns renaming with pending ' +
            'yield is problematic and background commands are keyed by ship name), an unknown ship -> NO_SUCH_SHIP, ' +
            'a name already used by another ship -> NAME_TAKEN. There is NO confirm parameter: this is a reversible ' +
            'one-field write (renaming back = undo) and every failure is rejected before anything is written. ' +
            'Returns {ok, requestedShip, ship(=the name AFTER the call), oldName, newName, changed, databaseSynced, ' +
            'verified, normalized, piloted, busy, migrated{goalText,goalOptions,designated,config}, evidence{...}}: ' +
            'this mod ALSO migrates its own name-keyed state (goal / panel roster / per-ship config) in the SAME ' +
            'call, so the ship does not silently lose its goal. After a rename, use the NEW name in every later call. ' +
            '★★ what=systemsFacts is the PURE-FACT subsystem read (nothing is written): ' +
            'sockets{num,max,used,free} (★ free = num - used), slots[{index,occupied,subsystemName?,script?,permanent?}] ' +
            '(EVERY socket, empty or full), ppThresholds[{socket,requiredProcessingPower}] (raw values from ' +
            'ShipSystem:getProcessingPowerForSocket, at most 20) and missing{nextSocket?,requiredPP?,currentPP,missingPP} ' +
            '(★ INFERRED: inferred=true, first threshold above currentPP) plus numSockets / maxSockets / numUpgrades ' +
            '(vanilla ShipSystem fields; numUpgrades = OCCUPIED sockets, NOT the number of sockets), ' +
            'processingPower (entry:getPlan().processingPower), equipped:[{name, script, rarity, rarityValue}] ' +
            '(entry:getSystems(), readable for ships far away) and the known flags socketsKnown / slotsKnown / ' +
            'ppThresholdsKnown / missingKnown / systemsKnown / processingPowerKnown. ' +
            '★ thresholdSemanticsKnown=false: the vanilla docs do NOT say what getProcessingPowerForSocket means ' +
            '(per-socket cost vs required threshold) -- never present missing.nextSocket/missingPP as an engine fact. ' +
            '★ For a ship NOT in your current sector there is no entity, so socketsKnown/slotsKnown/ppThresholdsKnown/' +
            'missingKnown=false + a reason -- that is UNKNOWN, never 0 sockets; equipped is still read. ' +
            'The old plan queries -- tradePlan | minePlan | ' +
            'salvagePlan | sellPlan | scoutPlan | jobPlan (jobPlan takes action=Mine|Salvage) -- are LEGACY convenience ' +
            'endpoints that self-scan ~67 boxes and self-rank/recommend; prefer composing the atoms ' +
            '(list -> ship -> predict/tradeRoutes/tradeEvaluate) instead. what=dossier is the single-shot helper (no ' +
            'tools / no file access). This is the ONLY proper way to look at the game -- do not rely on ' +
            'screenshots.',
        parameters: {
            what: {
                type: 'string',
                required: true,
                description: 'list | ship | goal | sectorFacts | predict | tradeRoutes | tradeEvaluate | mountQuote | mountUpgrade | shipQuote | blockQuote | blockUpgrade | shipUpgrade | renameShip | systemsFacts | orderStatus | dossier | ' +
                    'tradePlan | minePlan | salvagePlan | sellPlan | scoutPlan | jobPlan',
            },
            orderId: { type: 'number', description: 'orderStatus only: the orderId from a fleet_order receipt (exact single order; omit to get the latest order of `ship`)' },
            ship: { type: 'string', description: 'ship name; required when what is ship/goal/dossier/predict/tradeRoutes/tradeEvaluate/shipQuote/blockQuote/blockUpgrade/shipUpgrade/renameShip (renameShip: the CURRENT name)/systemsFacts/any plan' },
            name: { type: 'string', description: 'renameShip only: the NEW ship name (a plain string, NOT a Format). Trimmed; must be non-empty, free of control characters and \'|\', valid UTF-8, and <= 32 characters (this mod\'s guard). No confirm needed -- it is a reversible one-field write.' },
            x: { type: 'number', description: 'sector x; required for what=sectorFacts/predict/tradeRoutes (box centre; for Travel = the DESTINATION sector)' },
            y: { type: 'number', description: 'sector y; required for what=sectorFacts/predict/tradeRoutes (box centre; for Travel = the DESTINATION sector)' },
            sizeX: { type: 'number', description: 'box WIDTH; required for what=predict/tradeRoutes (with sizeY); Travel: use 1; Refine: must be 31; tradeEvaluate: put it inside each boxes[] entry' },
            sizeY: { type: 'number', description: 'box HEIGHT; required for what=predict/tradeRoutes (with sizeX); Travel: use 1; Refine: must be 31; tradeEvaluate: put it inside each boxes[] entry' },
            goodName: { type: 'string', description: 'predict Trade only: WHICH route to evaluate (from tradeRoutes)' },
            deposit: { type: 'number', description: 'predict Trade only: upfront budget (must be > 0)' },
            deposits: { type: 'array', items: { type: 'number' }, description: 'tradeEvaluate only: 1..3 upfront-budget tiers (each > 0). The deposit changes BOTH the cargo carried and the ambush chance, so try several tiers.' },
            goodsFilter: { type: 'array', items: { type: 'string' }, description: 'tradeEvaluate only (optional): evaluate only these route names; default = EVERY route in each box (vanilla gives at most 4 per box).' },
            maxAttackChance: { type: 'number', description: 'tradeEvaluate: risk gate (default 0.10) used ONLY to classify rejected[] -- it never changes a number.' },
            duration: { type: 'number', description: 'predict Mine/Salvage only: task hours (optional)' },
            safeMode: { type: 'boolean', description: 'predict Mine/Salvage only: safe mode (optional)' },
            escorts: { type: 'array', items: { type: 'string' }, description: 'predict/tradeEvaluate/plan: escort ship names (optional)' },
            goodsToSell: { type: 'array', description: 'predict Sell only: goods to sell (optional; default = whole hold)' },
            boxes: { type: 'array', description: 'predict batch: array of {x,y,sizeX,sizeY,...per-action params} (N<=24). tradeEvaluate: array of 1..6 {x,y,sizeX,sizeY} work boxes (legal Trade shapes 17x17 / 29x11 / 11x29).' },
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
                description: 'ship/fleet: return the SHORT view (name/shipTitle/entityType/sector/captain/cargo/actions ' +
                    '+ current-sector numbers; no depth sampling, no long per-action prose). Answers "what can ' +
                    'it do now". The identity fields are copied verbatim from the full card (same source).',
            },
            action: { type: 'string', description: 'predict/jobPlan: Mine | Salvage | Trade | Sell | Scout | Travel | Refine (Travel predict: box = 1x1 destination, ship need NOT be inside; Refine: 31x31, box re-centred on the ship by the game)' },
            material: {
                type: 'string',
                description: 'mountQuote/mountUpgrade/shipQuote/blockQuote/blockUpgrade/shipUpgrade only: the TARGET ' +
                    'material -- iron|titanium|naonite|trinium|xanion|ogonite|avorion or 0-6. The mount atoms ' +
                    'upgrade every turret base below that tier; shipQuote/shipUpgrade cover every block on the ' +
                    'whole ship; blockQuote/blockUpgrade cover exactly the selected blockType.',
            },
            blockType: {
                type: 'string',
                description: 'blockQuote/blockUpgrade only: a VANILLA BlockType name (Enums.html: Hull, Armor, CargoBay, ' +
                    'Engine, TurretBase, ...) or its numeric id. Case-insensitive. It selects exactly one block ' +
                    'type; use shipQuote/shipUpgrade for the whole ship (a separate interface).',
            },
            confirm: {
                type: 'boolean',
                description: 'mountUpgrade/blockUpgrade/shipUpgrade only: MUST be true to actually spend resources/credits ' +
                    'and write the new plan. Omitted or false = quote-only preview that changes NOTHING. Always ' +
                    'call without confirm first and show the owner the cost.',
            },
        },
        output: {
            schema: { type: 'string' },
            render: (_args, value) => [{ type: 'text', text: String(value) }],
        },
        async execute(args) {
            // ★ sectorFacts 只需坐标 ✓；list 什么都不用 ✓；其余"针对某艘船"的 what 才需要 ship ✓（2026-10-17 ✓）
            //   ★ orderStatus 例外：给 orderId 就够（精确到某一单 ✓），不给才按 ship 取最近一单 ✓
            const orderStatusById = args.what === 'orderStatus' && args.orderId !== undefined;
            const needsShip = args.what !== 'fleet' && args.what !== 'sectorFacts' && args.what !== 'list'
                && !orderStatusById;
            if (needsShip && (args.ship === undefined || args.ship === '')) {
                return `what=${args.what} needs the ship parameter${args.what === 'orderStatus' ? ' (or an orderId)' : ''}`;
            }
            // ★ renameShip：`ship` = 旧名（needsShip 已覆盖 ✓）、`name` = 新名（必填 ✓ 且**不许**是空串 ——
            //   空串会被游戏侧当成 NAME_EMPTY 拒掉，但在这里先拦一次更省一次往返 ✓）。
            if (args.what === 'renameShip' && (args.name === undefined || args.name === '')) {
                return 'what=renameShip needs the name parameter (the NEW ship name; plain string)';
            }
            if (args.what === 'sectorFacts' && (args.x === undefined || args.y === undefined)) {
                return 'what=sectorFacts needs the x and y parameters';
            }
            if ((args.what === 'mountQuote' || args.what === 'mountUpgrade'
                || args.what === 'shipQuote' || args.what === 'blockQuote'
                || args.what === 'blockUpgrade' || args.what === 'shipUpgrade')
                && (args.material === undefined || args.material === '')) {
                return `what=${args.what} needs the material parameter ` +
                    '(iron|titanium|naonite|trinium|xanion|ogonite|avorion or 0-6)';
            }
            if ((args.what === 'blockQuote' || args.what === 'blockUpgrade')
                && (args.blockType === undefined || args.blockType === '')) {
                return `what=${args.what} needs the blockType parameter ` +
                    '(a vanilla BlockType name such as Hull/Armor/CargoBay/Engine/TurretBase, or a number)';
            }
            // ★ tradePlan runs a FULL area analysis in the game (PassageMap + flood fill),
            // which takes far longer than a plain query -- give it room (2026-10-16).
            // ★ tradeEvaluate = 每个框一次 run()（最多 6 框 ✓）+ 逐组合 predict（≤60 ✓）≈ 秒级；
            //   给 60 s 上限，避免"游戏算得完而 DSH 先超时"✗✓（2026-10-18 ✓）。
            // ★ mountQuote/mountUpgrade = 整船重建 plan（大船几千块）+ 快照，CLI 预览同一套代码 →
            //   同样给 60 s（RPC 是同步的，别让"游戏还在算"被 10 s 先掐断 ✗✓）。
            // ★ shipQuote/blockQuote 更重一点（重建整船 plan）→ 同样 60 s ✓；
            //   blockUpgrade/shipUpgrade 还要 pay + setMovePlan + 核验 → 也给 60 s ✓。
            const timeout = args.what === 'tradePlan' ? 120
                : (args.what === 'tradeEvaluate' || args.what === 'mountQuote'
                    || args.what === 'mountUpgrade' || args.what === 'shipQuote'
                    || args.what === 'blockQuote' || args.what === 'blockUpgrade'
                    || args.what === 'shipUpgrade') ? 60
                    : 10;
            // ★★ 计划查询的**体积旋钮**（2026-10-17 ✓✓）：原样透传给游戏侧 ✓。
            //   ★ **一个都不默认** ✗ —— 缺省由**游戏侧**定（compact=true / top=4 ✓），
            //     这样"工具说明"与"游戏行为"只有一个真相来源 ✓（不会各改各的 ✓）。
            //   ★ 但**必须**把参数名带过去（漏了它们 = 旋钮静默失效 ✓）。
            const r = await ask(peer, 'query', {
                what: args.what, ship: args.ship, x: args.x, y: args.y,
                sizeX: args.sizeX, sizeY: args.sizeY, goodName: args.goodName, deposit: args.deposit,
                deposits: args.deposits, goodsFilter: args.goodsFilter,
                maxAttackChance: args.maxAttackChance,
                duration: args.duration, safeMode: args.safeMode, escorts: args.escorts,
                goodsToSell: args.goodsToSell, boxes: args.boxes,
                compact: args.compact, top: args.top, full: args.full, brief: args.brief,
                action: args.action, material: args.material, confirm: args.confirm,
                blockType: args.blockType,
                orderId: args.orderId,
                name: args.name,
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
        description: 'Give ONE background command to ONE ship (atomic: one ship + one action + that action ' +
            'minimal params -- NO auto box, NO auto params, NO auto retreat). action is one of Mine, ' +
            'Salvage, Trade, Travel, Sell, Scout, Refine. You MUST provide the explicit box (x, y + size, or ' +
            'sizeX+sizeY for Trade) and, for Trade, an explicit goodName (a route name from ' +
            'fleet_query what=tradeRoutes) and deposit > 0. Travel needs NO size: x/y is the destination ' +
            'sector (the box is 1x1 and the ship does NOT have to be inside it). Refine needs size=31 ' +
            '(its box is FIXED at 31x31 and the game re-centres it on the ship) and ore in the hold ' +
            '(it has no duration/safeMode config). ★ For Sell you may pass goodsToSell to pick a subset ' +
            '(WHITELIST); omitting it means "every sellable good in the hold". The game filters the list ' +
            'BEFORE ordering (vanilla rejects the WHOLE command if any listed good has no buyer), so the ' +
            'receipt carries sellable:{kinds,units,goods} and skipped:[{goodName,amount,reason}] -- and if ' +
            'not one requested good has a buyer the order fails with NO_BUYER (nothing is queued). ★ The receipt carries ' +
            'risk:{known, attackChance, baseAttackChance, riskKind, ...} = the ambush assessment of THIS ' +
            'order, computed by the SAME code as fleet_query what=predict (so it matches what you predicted; ' +
            'for Travel it is the whole-trip ambush chance). known=false means the game could NOT compute it: ' +
            'attackChance is then null -- never read that as 0%. ★★ For Trade the box->route list is ' +
            'validated BEFORE ordering with the SAME implementation tradeEvaluate uses: if goodName is not ' +
            'one of that box\'s routes RIGHT NOW, the receipt is accepted:false with error starting ' +
            '"NO_ROUTE:" plus noRoute:{goodName, routeCount, candidates:[up to 8 route names], didYouMean, ' +
            'box} -- and NOTHING was queued (no area analysis, no startCommand). Read noRoute.candidates and ' +
            'order one of those instead: the vanilla route list is a live sample (top 4) and hides routes ' +
            'occupied for 120 s, so a route you saw a few seconds ago can be gone. Matching is EXACT ' +
            '(case/spacing/plural must match); didYouMean only suggests. ★★ The receipt now ALSO carries ' +
            'preflight:{ok, code, reason, checks, warnings, ...} (the game checked the vanilla ' +
            'preconditions BEFORE ordering -- preflight.ok=false means NOTHING was ordered: no area ' +
            'analysis, no startCommand) and verify:{ok, evidence, busy, moved, atDestination, cargoUsed, ' +
            'cargoUsedDelta, reason, ...} (the game RE-READ the ship state a few seconds after ' +
            'startCommand). `accepted:true, executed:true` alone only means the order entered the RPC ' +
            'queue -- verify is the honest "did it actually run" answer, and verify.ok=false means ' +
            'nothing observable happened after the order (the vanilla "accepted then silently refused" ' +
            'case). The command is ASYNCHRONOUS: the captain ' +
            'takes the ship out of the player sector and is unreachable while working.',
        parameters: {
            ship: { type: 'string', required: true, description: 'ship name (must be on the Copilot roster)' },
            action: { type: 'string', required: true, description: 'Mine | Salvage | Trade | Travel | Sell | Scout | Refine' },
            x: { type: 'number', description: 'target sector x (required; box centre for work actions; for Travel = destination)' },
            y: { type: 'number', description: 'target sector y (required; for Travel = destination)' },
            size: { type: 'number', description: 'area edge length (required for work actions; NOT needed for Travel -- its box is the 1x1 destination; Refine must be 31 -- its area is fixed)' },
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
                    'fleet_query what=tradeRoutes (e.g. "Drill", "Antigrav Unit"). Without it the ' +
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
                description: 'Trade/Travel/Mine/Salvage: escort ship names. The vanilla escort check is ' +
                    'SimulationUtility.isShipUsableAsEscort: available, and within the ESCORT\'s own ' +
                    'hyperspace reach (a same-sector escort is just the easy case) -- "too far away" makes ' +
                    'the game abort the whole order. Vanilla does NOT require the same sector: the only ' +
                    'distance gate is the escort\'s own reach (simulationutility.lua:156-163), so a ship ' +
                    'in another sector is perfectly usable. Vanilla never checks ' +
                    'armament; the receipt reports canFight as a warning.',
            },
            goodsToSell: {
                type: 'array',
                description: 'Sell only: WHICH goods to sell -- a WHITELIST. Either plain names ["Drill","Oxygen"] ' +
                    'or objects [{goodName:"Drill", amount:100}] (amount defaults to the whole stack). ' +
                    'Omit it = sell every SELLABLE good in the hold. ★ Names must match the cargo keys ' +
                    'exactly (see the ship card / sellPlan). Goods with no buyer in the box are dropped and ' +
                    'reported in the receipt (skipped[]); if none of them has a buyer the order fails with ' +
                    'NO_BUYER and nothing is queued.',
            },
        },
        output: {
            schema: { type: 'string' },
            render: (_args, value) => [{ type: 'text', text: String(value) }],
        },
        async execute(args) {
            // ★ 60s：order 现在**同时**为回执算一次风险预测（= predict 同口径 ✓）—— Travel 还要先算航线分析 ✓
            const r = await ask(peer, 'order', args, opts.orderTimeoutSec ?? 60);
            if (!r.ok)
                return `order failed: ${r.why ?? 'unknown'}`;
            const data = (r.data ?? {});
            const preflight = (data.preflight !== null && typeof data.preflight === 'object'
                && !Array.isArray(data.preflight)) ? data.preflight : undefined;
            const head = `ordered: ${args.ship} -> ${args.action}`;
            const lines = [head];
            const pt = preflightText(preflight);
            if (pt !== undefined) {
                // ★★ 预检不过 = **没有下单** ✗✓（游戏侧连区域分析都没发起 ✓）—— 别再说 ordered ✓
                lines[0] = `NOT ordered: ${args.ship} -> ${args.action}`;
                lines.push(pt);
                const body0 = text(r.data);
                lines.push(body0);
                return lines.join('\n');
            }
            const pw = preflightWarningText(preflight);
            if (pw !== undefined)
                lines.push(pw);
            // ★★ 实测（2026-10-17 ✓✓）：`accepted:true executed:true` 只代表"进了 RPC 队列" ✗ ——
            //   这里**再问一次游戏**（orderStatus ✓）拿实体状态的证据 ✓；拿不到就明说（不编 ✗）。
            //   ★ 有界：预算 30s（6s startCommand + 6s 采样 + 可能的重采 9s + 余量 ✓）。
            const orderId = (typeof data.orderId === 'number' || typeof data.orderId === 'string')
                ? data.orderId : undefined;
            if (orderId !== undefined) {
                const v = await waitForOrderVerify(peer, { orderId, ship: args.ship }, { budgetMs: 30_000 });
                if (v !== undefined) {
                    data.verify = v;
                    const vt = verifyText(v);
                    if (vt !== undefined)
                        lines.push(`实测：${vt}`);
                }
                else {
                    lines.push('实测：游戏侧没给结论（老版本 / 记录已过期）→ 回执保持 pending ✓（不编 ✗）');
                }
            }
            lines.push(text(data));
            return lines.join('\n');
        },
    }, 'fleet_order tool');
    // ---------------------------------------------------------------------
    // fleet_escort -- send an escort over to the target ship's sector
    //
    // The owner's feature (2026-10-17): when a job's ambush risk is too high and
    // the only way to lower it is an escort, but no escort is within the action
    // ship's reach, the escort has to TRAVEL there first. Vanilla rule (NOT a
    // same-sector rule): an escort is usable when the action ship is within the
    // ESCORT's own hyperspace reach -- simulationutility.lua:156-163; same sector
    // is only the distance-0 case. 2026-10-18 real-machine verified.
    //
    // This is the explicit, human-drivable version of the step the decide flow
    // does on its own (see index.ts: escortNeedOf / pickRendezvousEscort).
    // ---------------------------------------------------------------------
    addTool(ctx, {
        name: 'fleet_escort',
        description: 'Send an escort ship to the target ship sector with a Travel background command, so the ' +
            'target can later take a risky job with a nearby escort. FIRST judge whether the target ' +
            'actually needs it: predict the target job ambush risk (risk.baseAttackChance); at/below the ' +
            '10% gate it usually does NOT need an escort, and combat ships are allowed to idle, so do not ' +
            'send one just to give an idle ship work. Vanilla rule (no same-sector requirement): an ' +
            'escort is usable when the action ship is within the ESCORT\'s own hyperspace reach ' +
            '(simulationutility.lua:156-163) -- same sector is only the distance-0 case. A ship already ' +
            'inside that reach needs NO travel: pass escorts=[...] on the action instead. The target ' +
            'sector is resolved here from the target ship card. Travel needs a destination at least ' +
            '2 jumps away; if the game refuses for any reason, the refusal is returned verbatim (this ' +
            'tool never retries by itself).',
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
            // ★ 改了目标 → 清掉待命冷却（目标指纹本就变了会自恢复；这里再显式清一次 ✓）
            try {
                standby?.clear(args.ship);
            }
            catch { /* 清冷却失败不影响改目标 ✓ */ }
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
            // ★ 手动召回 = 主人想重新评估 → 清掉该船的待命冷却 ✓（绝不"永远不问" ✗）
            try {
                standby?.clear(args.ship);
            }
            catch { /* 清冷却失败不影响召回 ✓ */ }
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
                'displaces the previous one immediately. The session is never interrupted: in LIVE mode, ' +
                'if the commander session is online but busy or times out, the decision DEFERS ' +
                '(action=None) instead of letting the single-shot model order on its behalf. The ' +
                'single-shot path only decides when there is NO commander or the session is ' +
                'offline/unavailable. Call with no arguments to see the current commander. Pass ' +
                'session=<id> to designate it, or clear=true to stop delivering -- clearing restores ' +
                'the pure single-shot behaviour.',
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
                    lines.push('  NOTE: a BUSY session is never interrupted; in LIVE mode the decision then DEFERS ' +
                        '(action=None) instead of letting single-shot order. Only when there is no commander, or the ' +
                        'session is offline/unavailable, does the single-shot path decide. Fleet tasks are delimited ' +
                        'by <fleet_task> and require a task=<id> echo, so they never get confused with your own words.');
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
                // ★★ decider 来源（2026-10-17 主人要求 ✓）：一眼看出这单谁定的 ✓
                lines.push(`decider: ${rec.decider ?? deciderOf(rec.source) ?? '?'}${rec.source !== undefined ? ` (source=${rec.source})` : ''}`);
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
                // ★ 结构化回执（2026-10-17 ✓）：accepted/executed/error —— 一眼看清这单到底下没下成 ✓
                if (rec.receipt !== undefined) {
                    const r = rec.receipt;
                    const okText = r.accepted && r.executed ? 'OK' : 'FAILED';
                    lines.push(`receipt: ${okText} accepted=${String(r.accepted)} executed=${String(r.executed)}` +
                        (r.error !== undefined ? ` error=${r.error}` : '') +
                        (r.note !== undefined ? ` note=${String(r.note).slice(0, 80)}` : ''));
                }
                // ★ 失败回投记录（2026-10-17 ✓）
                if (rec.redeliveries !== undefined && rec.redeliveries.length > 0) {
                    lines.push(`redeliveries (${rec.redeliveries.length}):`);
                    for (const rd of rec.redeliveries) {
                        const how = rd.receipt !== undefined
                            ? (rd.receipt.accepted && rd.receipt.executed ? 'accepted ✓' : 'failed')
                            : (rd.action === 'None' ? 'decided None' : (rd.note ?? 'no decision'));
                        lines.push(`  - ${rd.reason} → ${rd.action ?? '(no action)'} [${how}]`);
                    }
                }
                if (rec.needsIntervention !== undefined) {
                    lines.push(`★ 需人工介入: ${rec.needsIntervention}`);
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