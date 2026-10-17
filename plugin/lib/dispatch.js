/**
 * dispatch.ts —— 「把决策任务投递给主人正在用的那个会话」的**阶梯**与**硬期限**（Phase A/B ✓）
 *
 * 设计书：`AGENT-DESIGN.md` §2.2/§3.4；离线原型：`test/commander-dispatch-proto.mjs`（7/7 ✓）。
 * 本文件是原型的**生产版**：把桩换成真依赖（`ctx.agents` / `ctx.on('session/event')`），
 * 把原型抓到的两个坑**原样避开** ✓✓：
 *
 *   1. **`whenIdle()` 的解析值就是 `undefined`** ✗（原型第一版 7 项挂 2 项的真凶 ✓）——
 *      所以"跑完了"和"超时了"**必须显式区分** ✓：本文件的 `settled` 结果是
 *      `{settled:true}` / `{settled:false}`，**绝不**用返回值判 ✓✓。
 *   2. **失败绝不重投** ✗（同一艘船同一轮只投一次 ✓ —— 重投会让同一艘船收到两条矛盾命令，
 *      正是 TAKEOVER.md 那条铁律要防的 ✗✓）。
 *
 * ## 三级阶梯（**永不卡住舰队** ✓）
 *
 * ```
 * ① 投递目标会话（若主人指定且活着）
 *      空闲          → followup(任务块) → 等这一轮结束 → 校验 → 采纳 ✓
 *      忙（主人在聊天）→ steerWhenBusy=false（默认）→ 不插队 → 下①.9 ✓
 *      超时          → cancel({kind:'hook'}) → 下①.9 ✓
 *      答不上来/答错船 → 下①'（若允许重试一次，**同一批事实**、只要求答案行 ✓）→ 下①.9 ✓
 *      在问主人       → **显式延期**（ASKED_OWNER：不派单、写清原因 ✓）—— 不是失败 ✓
 * ①.9 ★★ 兜底不许下单（live 模式）：会话**在线**却没答成 → 直接 None（fallbackNone）✓
 *       （只有「没有指挥官」或「会话明确离线/不在 registry」才允许下②单发 ✗）
 * ② 今天的单发事实调用（**保留**：没有指挥官 / 会话离线时才走 ★ 有**硬期限** ✓）
 * ③ 都没有 → action=None + 原因写清 ✓
 * ```
 *
 * ## 两种模式（**Phase A 与 B 的差别只在这里** ✓）
 *
 * | 模式 | 会话级的答案 | 谁真的决定了这一单 |
 * |---|---|---|
 * | `live`   | **采纳** ✓（校验通过就直接下单 ✓） | 会话（否则单发 ✓） |
 * | `shadow` | **只并排记下来** ✗✓（**零风险** ✓ —— 不改任何实际下单行为 ✓） | **永远是单发** ✓ |
 *
 * `shadow` 就是设计书推荐的"最重要的第一步" ✓：主人能提前看到她会怎么答、
 * 能对比"会话答案 vs 单发答案"、能测延迟与成本，而**实际下单一个字节都没变** ✓✓。
 *
 * ★ 舰队级串行（设计书 §3.4）：一个会话同一时刻**只能有一个 turn** ✓。
 *   所以用一个跨决策共享的 `lock`：取不到就**根本不投递** ✗ → 直接下② ✓
 *   （不排队、不等待 ✓ —— 排队等 20 秒只会让游戏侧的 decide 白等 ✓，而单发本来就是对的答案 ✓）。
 */
import { field, makeTaskId, renderTaskBlock, validateAnswer } from './task.js';
export const BUDGETS = {
    sessionDeadlineMs: 20_000,
    queueReserveMs: 3_000,
    commitReserveMs: 1_000,
    singleShotTimeoutMs: 15_000,
    retryOnceMs: 8_000,
};
const nowMs = () => Date.now();
/** 合并默认预算与调用方覆盖 ✓（一处算法，三处用 ✓） */
function budgetOf(override) {
    return { ...BUDGETS, ...(override ?? {}) };
}
/**
 * ★ 原型抓到的坑 ①：`whenIdle()` **没有返回值** ✗ → "跑完了"与"超时了"必须**显式区分** ✓。
 * 返回 `{settled:true, value?}` / `{settled:false}`；**绝不**用 `value === undefined` 判超时 ✗✓。
 */
export function withTimeout(promise, ms) {
    return new Promise((resolve) => {
        let done = false;
        const timer = setTimeout(() => {
            if (done)
                return;
            done = true;
            resolve({ settled: false });
        }, Math.max(0, ms));
        promise.then((value) => { if (!done) {
            done = true;
            clearTimeout(timer);
            resolve({ settled: true, value });
        } }, (error) => { if (!done) {
            done = true;
            clearTimeout(timer);
            resolve({ settled: false, error });
        } });
    });
}
/** 两个答案的"实质是否一致"（只比 action + 关键参数 ✓ —— 不比理由文字 ✗） */
function sameDecision(a, b) {
    if (a === undefined || b === undefined)
        return undefined;
    if (a.action !== b.action)
        return false;
    const keys = new Set([...Object.keys(a.params), ...Object.keys(b.params)]);
    for (const k of keys) {
        const x = a.params[k];
        const y = b.params[k];
        if (typeof x === 'number' && typeof y === 'number') {
            if (Math.abs(x - y) > 1e-6)
                return false;
            continue;
        }
        if (JSON.stringify(x) !== JSON.stringify(y))
            return false;
    }
    return true;
}
/**
 * ★★ 主入口：为**一艘船**要一个决策 ✓。
 *
 * 保证（都在测试里断言过 ✓）：
 *   · **永不抛** ✓（任何异常都变成"下一级"或 `action=None` ✓）
 *   · **永不超总预算** ✓（会话硬闸 + 单发硬闸，各自独立 ✓）
 *   · 忙/挂死/在聊天的会话，**绝不会**让这一轮没有决策 ✓
 */
export async function dispatchDecision(deps, req) {
    const B = budgetOf(deps.budgets);
    const say = deps.log ?? (() => { });
    const mode = deps.mode ?? 'live';
    const started = nowMs();
    const elapsed = () => nowMs() - started;
    let sessionAttempt;
    // ---- 阶梯①：投递目标会话 --------------------------------------------------
    const agent = deps.commanderId !== undefined ? deps.registry.get(deps.commanderId) : undefined;
    if (deps.commanderId !== undefined && agent === undefined) {
        say(`  [ladder] 投递目标会话 ${deps.commanderId} **不在了** ✗（已关/已换）→ 下②单发 ✓`);
    }
    if (agent !== undefined) {
        const remaining = B.sessionDeadlineMs - elapsed();
        if (agent.status !== 'idle') {
            // 主人在聊天 / 这一轮在做别的事 ✓ —— 设计书的默认是**不插队** ✓（插队会把任务块插到
            // 别人的上下文里，正是"猜会话"那类风险的同源 ✓）。
            say(`  [ladder] 投递会话**正忙**（主人在聊 / 在别的任务上）`);
            if (deps.steerWhenBusy !== true) {
                say('  [ladder] steerWhenBusy=false（默认）→ 不插队，直接下②单发 ✓');
            }
            else if (remaining < B.queueReserveMs) {
                say(`  [ladder] 只剩 ${remaining}ms（< 保留 ${B.queueReserveMs}ms）→ 不投递，直接下②单发 ✓`);
            }
            else {
                sessionAttempt = await runSessionRung(deps, req, Math.max(0, remaining - B.commitReserveMs), say);
            }
        }
        else if (remaining < B.queueReserveMs) {
            say(`  [ladder] 剩余预算 ${remaining}ms < 保留 ${B.queueReserveMs}ms → 不投递，直接下②单发 ✓`);
        }
        else {
            sessionAttempt = await runSessionRung(deps, req, Math.max(0, remaining - B.commitReserveMs), say);
        }
    }
    else if (deps.commanderId === undefined) {
        say('  [ladder] 没有指定投递目标会话 → 直接走②单发（**与今天逐字相同** ✓）');
    }
    // 会话那一路的结论先落进结果里 ✓（影子模式也照样带着走 ✓）
    if (sessionAttempt !== undefined && mode === 'live') {
        if (sessionAttempt.answered && sessionAttempt.answer !== undefined) {
            say(`  [commit] 采用**投递目标会话**的答案：${sessionAttempt.answer.action} ${JSON.stringify(sessionAttempt.answer.params)}` +
                `（${sessionAttempt.steps} 步 / ${sessionAttempt.tookMs}ms ✓）`);
            return {
                action: sessionAttempt.answer.action,
                params: sessionAttempt.answer.params,
                reason: sessionAttempt.answer.reason,
                source: 'session',
                session: sessionAttempt,
            };
        }
        if (sessionAttempt.code === 'ASKED_OWNER') {
            // ★ 人在环里 = **显式延期** ✓（绝不是悬着的 promise ✗）
            const q = String(sessionAttempt.question ?? '').slice(0, 300);
            say(`  [commit] 投递会话**在问主人** ✓：${JSON.stringify(q.slice(0, 160))}`);
            say('  [commit] → 本轮**明确延期**（不派单 ✓）；主人回答后，下一轮投递自然带上新信息 ✓');
            return {
                action: 'None',
                params: {},
                reason: `投递会话在问主人：${q}（本轮明确延期，未派单 ✓）`,
                source: 'asked-owner',
                session: sessionAttempt,
            };
        }
        say(`  [ladder] 会话那一级没成：${sessionAttempt.code ?? '?'}（${sessionAttempt.message ?? ''}）`);
    }
    // ---- 阶梯①.9：★★ 兜底不许下单（2026-10-17 主人铁律）--------------------
    //   当投递目标会话**已指定且在线**（`agent` 还在 registry ✓）而这一轮它没给出可用
    //   答案（忙 / 超时 / 答错船 / 无动作行 / 锁被占 …）→ 本轮**绝不**让单发模型替它拍板 ✗
    //   → 直接 None（fallbackNone）。
    //
    //   ★ 判定"慢"与"不在"（这是唯一的判据，代码里就这一处 ✓）：
    //     · `deps.commanderId === undefined`          → **没有指挥官** → 允许单发 ✓；
    //     · `agent === undefined`（registry 里取不到） → 会话**明确离线/已关/不可用** → 允许单发 ✓；
    //     · 其余（agent 在、但忙/超时/没答成）          → **在线但慢** → 兜底 = None ✗（不许单发 ✓）。
    //   ★ shadow 模式不在这里 ✗：影子模式里单发**本来就是**决策者（会话只观测 ✓），
    //     不是"兜底替它拍板"，所以不受这条铁律约束 ✓（见下面阶梯②）。
    if (mode === 'live' && deps.commanderId !== undefined && agent !== undefined) {
        const why = sessionAttempt !== undefined
            ? (sessionAttempt.code ?? 'NO_ANSWER')
            : 'SESSION_BUSY';
        say(`  [ladder] ★ 指挥官会话在线但本轮没答成（${why}）→ 兜底 = None（fallbackNone），` +
            '**不许单发替它拍板** ✗');
        return {
            action: 'None',
            params: {},
            reason: `投递目标会话在线，但本轮没给出可用答案（${why}）—— 按主人规矩本轮**不下单**、` +
                '也不让单发模型替它决策 ✗；下一轮（状态变化或冷却到期）会再次征询',
            source: 'fallbackNone',
            session: sessionAttempt,
        };
    }
    // ---- 阶梯②：今天的单发事实调用（★ 现在有硬期限 ✓）-----------------------
    if (sessionAttempt !== undefined && mode === 'shadow') {
        if (sessionAttempt.answered && sessionAttempt.answer !== undefined) {
            say(`  [shadow] 投递目标会话答了：${sessionAttempt.answer.action} ${JSON.stringify(sessionAttempt.answer.params)}` +
                `（${sessionAttempt.steps} 步 / ${sessionAttempt.tookMs}ms ✓）—— ★ **本轮不采纳** ✓，仍由单发决定 ✓`);
        }
        else {
            say(`  [shadow] 投递目标会话没答成：${sessionAttempt.code ?? '?'}（${sessionAttempt.message ?? ''}）✓`);
        }
    }
    // ---- 阶梯①.5：单发路径的重数据预取（会话路径不预取 ✓）------------------
    //   ★ 2026-10-17：会话路径投递前只取 goal（毫秒级 ✓）—— 船卡/舰队/计划/记忆/rendezvous
    //     全在这里**惰性**预取，只在真正要跑单发时（没有会话 / 会话没答成 / 影子模式兜底）才跑 ✓。
    //   ★ 它**不受** singleShotTimeoutMs 限制（计划查询在游戏主线程同步算，tradePlan 20s+ ✓）。
    if (deps.prefetch !== undefined) {
        let early = null;
        try {
            early = await deps.prefetch();
        }
        catch (error) {
            say(`  [prefetch] 预取异常（${String(error)}）→ 继续走单发，档案可能缺计划 ✓`);
        }
        if (early !== null) {
            say(`  [prefetch] 预取期间已定这一单：${early.action}（${early.reason ?? ''}）→ 跳过单发模型调用 ✓`);
            return {
                action: early.action,
                params: early.params,
                reason: early.reason,
                source: 'rendezvous',
                session: sessionAttempt,
            };
        }
    }
    say(`  [ladder] → ② 单发模型调用（今天那条路 ✓；硬期限 ${B.singleShotTimeoutMs}ms ✓）`);
    const single = await runSingleShot(deps, B.retryOnceMs, say);
    if (!single.ok || single.action === undefined) {
        say(`  [ladder] 单发也没成：${single.why ?? 'unknown'} → ③ action=None ✓`);
        return {
            action: 'None',
            params: {},
            reason: `没有可用的决策（投递会话未指定/未答成；单发：${single.why ?? 'unknown'}）`,
            source: 'none',
            session: sessionAttempt,
        };
    }
    const sessionAnswer = sessionAttempt?.answer;
    const agreement = sameDecision(sessionAnswer, { action: single.action, params: single.params });
    const viaSession = sessionAttempt?.answered === true;
    return {
        action: single.action,
        params: single.params,
        reason: single.reason,
        // ★ 影子模式：会话答了**也不算它决定的** ✗ —— 这一单是单发定的 ✓（source 说真话 ✓）
        source: mode === 'shadow' && viaSession ? 'shadow' : 'single-shot',
        text: single.text,
        truncated: single.truncated,
        session: sessionAttempt,
        agreement,
    };
}
/**
 * 跑单发路径，**带硬期限** ✓。
 *
 * ★ 为什么期限是"不管它了"而不是"掐掉" ✗：`ctx.llm.stream` 没有取消参数 ✗
 *   （今天就没法掐 ✓）。所以超时后我们**不再等它**、直接返回 ✓ —— 那条流会自己在后台
 *   收完（最多多跑一轮输出 ✓），但这**不影响舰队** ✓✓。
 *
 * ★ 重试一次（可选）：与今天 `index.ts` 里的重试同源 ✓ —— 同一批事实、只要求答案行、
 *   **只此一次** ✓、不重取数据 ✓。`hint` 交给调用方拼进提示词 ✓。
 */
async function runSingleShot(deps, retryBudgetMs, say) {
    const B = budgetOf(deps.budgets);
    const attempt = async (hint) => withTimeout(deps.singleShot(hint), B.singleShotTimeoutMs);
    let first;
    try {
        first = await attempt();
    }
    catch (error) {
        return { ok: false, params: {}, why: `调用抛异常：${String(error)}` };
    }
    if (!first.settled) {
        return { ok: false, params: {}, why: `超过硬期限 ${B.singleShotTimeoutMs}ms 没返回（★ 今天没有这道闸 ✗）` };
    }
    if (first.value === undefined) {
        return { ok: false, params: {}, why: `调用抛异常：${String(first.error)}` };
    }
    if (first.value.failure !== undefined) {
        return { ok: false, params: {}, why: `模型失败 ${first.value.failure}` };
    }
    const parsed = parseSingleShotText(first.value.text);
    if (parsed.action !== undefined) {
        return { ok: true, ...parsed, text: first.value.text, truncated: first.value.truncated };
    }
    // ---- 只有"完全没有动作行"才重试 ✓（其它问题重试也救不回来 ✗）------------
    //   ★ 默认**允许**（= 今天 index.ts 里那条重试 ✓ —— 实机事故：正文一个动作行都没吐 ✓）；
    //     传 retrySingleShotOnce:false 可关掉 ✓。
    const allowed = deps.retrySingleShotOnce !== false;
    const canRetry = allowed && retryBudgetMs > 0 && parsed.why === 'no action line';
    if (!canRetry) {
        return { ok: false, params: {}, why: parsed.why ?? '解析不出动作', text: first.value.text };
    }
    say('  [ladder] 单发首轮没有动作行 → 重试一次（同一批事实、**只要求答案行** ✓、只此一次 ✗）');
    const second = await attempt('★ 你上一次没有输出任何 action 行 ✗。现在**只输出答案行** ✓：action 必须在**第一行** ✓；' +
        '不要写任何推理或解释 ✗；reason 可以留空 ✓。一行一个字段，从 action= 开始。');
    if (!second.settled || second.value === undefined || second.value.failure !== undefined) {
        return {
            ok: false, params: {},
            why: `重试也没成（${!second.settled ? '超时' : String(second.value?.failure ?? second.error)}）`,
            text: first.value.text,
        };
    }
    const again = parseSingleShotText(second.value.text);
    if (again.action === undefined) {
        return { ok: false, params: {}, why: `重试后仍解析不出（${again.why ?? '?'}）`, text: second.value.text };
    }
    say('  [ladder] ✔ 单发重试成功（拿到动作行 ✓）');
    return { ok: true, ...again, text: second.value.text, truncated: second.value.truncated };
}
/**
 * 单发回复的**极小**解析：`action=` 那一行 + 那几个**跨路径共用**的字段 ✓。
 *
 * ★ 分工（避免两份规则漂移 ✗✓ —— 本仓库反复吃过这个亏）：
 *   · **合法性**（动作在不在允许集合内、escort 候选过滤、goodsToSell 形状…）仍由**今天那套**
 *     `parseDecision`/`toAnswer` 判 ✓（调用方在拿到 `text` 之后照样跑它 ✓）。
 *   · 这里只把**两边都要看得懂**的那几个字段取出来 ✓（`x/y/shape/size/sizeX/sizeY/deposit/
 *     duration/safeMode/goodName` ✓），好让"会话答案 vs 单发答案并排比较"（`agreement` ✓）
 *     与 DecisionRecord 里的记录**有意义** ✓。字段口径与 `task.ts` 的校验器**逐字一致** ✓。
 */
function parseSingleShotText(text) {
    const raw = typeof text === 'string' ? text : '';
    const m = /^\s*[*-]?\s*\**\s*action\s*[:=：]\s*(.*)$/im.exec(raw);
    if (m === null)
        return { params: {}, why: 'no action line' };
    const word = m[1].replace(/[`*"'。，,]/g, '').trim();
    if (word === '')
        return { params: {}, why: 'no action line' };
    const v = validateAnswer(raw, field(raw, 'task') ?? '', [word, 'None']);
    const params = v.ok ? v.answer.params : {};
    const reason = v.ok ? v.answer.reason : field(raw, 'reason');
    return { action: word, params, reason, why: undefined };
}
// ---------------------------------------------------------------------------
// 阶梯①的内部：投递 → 等这一轮结束 → 校验
// ---------------------------------------------------------------------------
/**
 * 投一次任务并等它的结论 ✓。**本函数永不抛** ✓（所有失败都变成结果码 ✓）。
 *
 * ★ 舰队级串行：先用 `lock` 抢（拿不到 = 别的决策正占着这个会话 ✓ → 直接放弃这一级 ✓，
 *   **不排队** ✗ —— 排队只会让这一轮白等到超时 ✓）。
 */
async function runSessionRung(deps, req, budgetMs, say, allowRetry = true) {
    const t0 = nowMs();
    const fail = (code, message) => ({ answered: false, code, message, steps: 0, tookMs: nowMs() - t0 });
    if (budgetMs <= 0)
        return fail('NO_BUDGET', '剩余预算为 0，不投递 ✓');
    const release = deps.lock?.tryClaim();
    if (deps.lock !== undefined && release === undefined) {
        // ★ 设计书 §3.4「舰队级串行：1 艘/轮」✓ —— 一个会话同一刻只有一个 turn ✓。
        //   抢不到就**不投**（下②单发 ✓）—— 绝不排队 ✗、绝不并发投 ✗✓。
        return fail('SESSION_BUSY_ELSEWHERE', '同一时刻已经有一条决策在用这个会话 → 本轮不投递，直接落单发 ✓');
    }
    const agent = deps.registry.get(deps.commanderId ?? '');
    if (agent === undefined) {
        release?.();
        return fail('SESSION_GONE', '投递目标会话不在了 ✓');
    }
    const texts = [];
    let usage;
    let endReason;
    let resolveTurn;
    const turnPromise = new Promise((resolve) => { resolveTurn = resolve; });
    const stop = deps.subscribe?.(deps.commanderId ?? '', (event) => {
        // ★★ 宿主派发的 `session/event` 把载荷放在 `event.data` 里 ✓（同宿主的
        //    `dsh-mode-boost` 读的正是 `event.data.source` / `extractText(event.data)` ✓）。
        //
        //    ★ 2026-10-17 实机事故（铁证）：这里原先读的是**顶层** `event.message` ✗ ——
        //    它永远是 `undefined`，于是"她答的每一个字"都没被收进来 ✗：
        //    会话那边明明已经吐出 assistant 文本（会话日志里看得见 ✓），
        //    这里 `texts` 依然是空 → 一轮结束就判 `EMPTY_REPLY`（"这一轮没有任何文本"）✗✗，
        //    整条"投递进会话"的路**从来没有成功过一次**（`decisions.live.log` 里
        //    "她的第 N 条输出" / "校验通过" 一次都没出现过 ✓）。
        //    顶层形态同时保留，两种派发形状都能吃 ✓。
        const payload = (event?.data ?? {});
        if (event.type === 'assistant/message') {
            const message = payload.message ?? event.message;
            const blocks = message?.content;
            const text = Array.isArray(blocks)
                ? blocks.filter((b) => b?.type === 'text').map((b) => b?.text ?? '').join('')
                : '';
            if (text.trim() !== '') {
                texts.push(text);
                say(`  [session] 她的第 ${texts.length} 条输出（${text.length} 字 ✓）`);
                try {
                    deps.onAssistantText?.(texts.length, text);
                }
                catch { /* 旁路失败不影响决策 ✓ */ }
            }
            if (payload.usage !== undefined)
                usage = payload.usage;
            else if (event.usage !== undefined)
                usage = event.usage;
            return;
        }
        if (event.type === 'turn/end') {
            // ★ 只认"我们发出去之后"这一轮的结束 ✓：本订阅是在**投递之前**建好的 ✓，
            //   所以此前那一轮（主人自己的聊天）的 turn/end 不可能走到这里 ✓✓。
            //
            // ★★ 但**宿主自己把这一轮判死**是另一回事 ✗：那种情况下它同样会发一个
            //    turn/end（reason 不是 completed），于是一个字都没有就"结束"了 ✓。
            //    把它的原话留下来 ✓ —— 否则错误会被吞成 EMPTY_REPLY，排查只能从
            //    "没有文本"倒推（2026-10-17 的 v4 source kind 事故就是这么被吞掉的 ✗）。
            const reason = payload.reason ?? event.reason;
            if (reason !== undefined && reason !== null) {
                const kind = typeof reason === 'object' ? reason.kind : reason;
                if (kind !== undefined && kind !== 'completed' && kind !== 'user') {
                    endReason = typeof reason === 'string' ? reason : JSON.stringify(reason);
                }
            }
            resolveTurn?.();
            return;
        }
    });
    try {
        const block = renderTaskBlock(req);
        if (deps.subscribe === undefined) {
            // 没有事件通道 = 收不到答案 ✗ → 别投（投了也是白投，还会污染那个会话 ✓）
            return fail('NO_EVENT_CHANNEL', '拿不到 session/event 通道 → 不敢投递（会污染会话且收不到答案 ✓）');
        }
        say(`  [session] 投递任务 ${req.taskId} → 会话（预算 ${budgetMs}ms ✓）；她会在会话里留下一条可见的 user 消息 ✓`);
        // ★ 真实现用 createUserMessage({content:[{type:'text',text}], source:{kind:'plugin',plugin:'dsh-avorion-copilot'}})
        //   —— 由 index.ts 注入（本模块不 import dsh-llm，好让测试完全离线 ✓）。
        deps.followup(agent, block, req);
        // ★ 续期由调用方做（index.ts 确认这次真的投出去了之后 renewLease ✓）。
        const waited = await withTimeout(turnPromise, budgetMs);
        const tookMs = nowMs() - t0;
        if (!waited.settled) {
            // ★ 硬闸到 → **掐掉这一轮** ✓（否则失控的一轮会一直占着会话 ✓）；
            //   ★ 失败**绝不重投** ✗（重投 = 同一艘船两条矛盾命令 ✓ —— TAKEOVER.md 铁律 ✓）。
            // ★★ cancel 的 cause 必须是宿主认得的 kind（user | parent | disposed | hook ✓）。
            //    乱传 kind（原先传的是 'timeout' ✗）会让宿主的 abortedCancelCause 落到
            //    assertNever 抛错 → 那一轮的 turn/end 被写成 **reason: null** ✗ →
            //    客户端回放轨迹时 `reason.kind` 直接 TypeError → 整个会话界面空白 ✗✗
            //    （2026-10-17 实测事故 ✓）。官方支持的语义里，"插件/钩子让这一轮停下"
            //    就是 hook ✓，所以带上 reason 走 hook ✓。
            try {
                agent.cancel({ kind: 'hook', reason: 'avorion-copilot: decision budget expired (timeout)' });
            }
            catch { /* 取消失败也不能让它抛上去 ✓ */ }
            say(`  [session] ${budgetMs}ms 内没结束 → 已 cancel({kind:'hook'}) ✓ 并放弃这一级（**不重投** ✗）`);
            return { answered: false, code: 'TIMEOUT', message: `会话在 ${budgetMs}ms 内没有给出结论`, steps: texts.length, tookMs, usage };
        }
        const last = texts.length > 0 ? texts[texts.length - 1] : '';
        // ★ 一个字都没收到、而宿主又**不是**正常收起这一轮 → 把宿主的原因原样报出来 ✓
        //   （这样 decisions.live.log 里出现的是真因，而不是含糊的"这一轮没有任何文本" ✓；
        //    2026-10-17 的 v4 source kind 事故就是被 EMPTY_REPLY 吞掉、白查了一小时的 ✓）
        if (last.trim() === '' && endReason !== undefined) {
            say(`  [session] ✘ 宿主结束了这一轮且没有 assistant 文本：${endReason}`);
            return {
                answered: false,
                code: 'HOST_TURN_FAILED',
                message: `宿主结束了这一轮（无 assistant 文本）：${endReason}`,
                steps: 0,
                tookMs,
                usage,
            };
        }
        const verdict = validateAnswer(last, req.taskId, deps.allowedActions);
        if (verdict.ok) {
            say(`  [session] ✔ 校验通过${verdict.echoed ? '（回显 task 对上了 ✓）' : '（她没回显 task，但内容合格 ✓）'}`);
            return { answered: true, answer: verdict.answer, steps: texts.length, tookMs, usage, raw: last };
        }
        const code = verdict.code;
        if (code === 'ASKED_OWNER') {
            return { answered: false, code, question: verdict.question, steps: texts.length, tookMs, usage, raw: last };
        }
        say(`  [session] ✘ 校验没过：${code}（${verdict.message ?? ''}）`);
        // ---- 只对"完全没有动作行"再给一次机会 ✓（同 today 的重试 ✓，只此一次 ✓）----
        const retryable = code === 'NO_ACTION_LINE' || code === 'EMPTY_REPLY';
        if (allowRetry && deps.retrySessionOnce === true && retryable) {
            const left = budgetMs - (nowMs() - t0);
            const retryBudget = Math.min(left, deps.budgets?.retryOnceMs ?? BUDGETS.retryOnceMs ?? 0);
            if (retryBudget > 500) {
                // ★ 新任务 id：她上一轮可能已经在**同一轮里**回了一句别的（回显旧 id ✓）——
                //   沿用旧 id 会让她"回显旧 id 而被判 TASK_MISMATCH"✗。换新 id 最干净 ✓。
                const retryTaskId = makeTaskId();
                say(`  [session] 再投一次（同一批事实、只要求答案行 ✓；新任务号 ${retryTaskId}；` +
                    `预算 ${Math.round(retryBudget)}ms，**只此一次** ✗）`);
                const second = await runSessionRung(deps, { ...req, taskId: retryTaskId }, retryBudget, say, false);
                return {
                    ...second,
                    steps: texts.length + second.steps,
                    tookMs: nowMs() - t0,
                    code: second.answered ? undefined : (second.code ?? code),
                    message: second.answered
                        ? undefined
                        : `第一次：${code}（${verdict.message ?? ''}）；重试：${second.message ?? second.code ?? ''}`,
                };
            }
        }
        return { answered: false, code, message: verdict.message, steps: texts.length, tookMs, usage, raw: last };
    }
    catch (error) {
        return fail('SESSION_ERROR', `投递/等待时异常：${String(error)}`);
    }
    finally {
        try {
            stop?.();
        }
        catch { /* 退订失败不影响结果 ✓ */ }
        release?.();
    }
}
export { makeTaskId, renderTaskBlock, validateAnswer };
//# sourceMappingURL=dispatch.js.map