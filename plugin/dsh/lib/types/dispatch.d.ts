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
 *    ★★ A（2026-10-18）：先进**合并队列**（`pumpRungQueue` ✓）—— 等 mergeWindowMs 把同一批收齐，
 *       1 条 → 老的单船路径（逐字不变 ✓）；N 条 → **一个块** + 一次投递 + 多组答案解析 ✓✓
 *       （病根：多艘船同时空闲时各投一个块 ✗，而一轮只答得了一个 → 其余的静默 None ✗）
 *      空闲          → followup(任务块) → 等这一轮结束 → 校验 → 采纳 ✓
 *      忙（主人在聊天）→ steerWhenBusy=false（默认）→ 不插队 → 下①.9 ✓
 *      超时          → cancel({kind:'hook'}) → 下①.9 ✓
 *      答不上来/答错船 → 下①'（若允许重试一次，**同一批事实**、只要求答案行 ✓）→ 下①.9 ✓
 *      在问主人       → **显式延期**（ASKED_OWNER：不派单、写清原因 ✓）—— 不是失败 ✓
 *      没答到这艘船   → `UNANSWERED`（★ 合并块的常见情形 ✓）→ 下①.9 ✓，并由 index.ts 的
 *                       B 项**短间隔重投** ✓（绝不 20 分钟静默 ✗）
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
import type { TaskAnswer, TaskRequest } from './task.js';
import { makeTaskId, renderTaskBlock, validateAnswer } from './task.js';
export interface Budgets {
    /** 等投递目标会话的**硬闸**：超了就 `cancel()` 并放弃这一级 ✓ */
    sessionDeadlineMs: number;
    /** 剩余预算不够这个数，就**不要开始投递** ✓（避免"刚投完就超时" ✓） */
    queueReserveMs: number;
    /** 拿到答案后还要校验 + 发 order RPC，留一点余量 ✓ */
    commitReserveMs: number;
    /** ★ 单发路径的**硬期限**（今天完全没有 ✗ —— 设计书点名的薄弱点 ✓） */
    singleShotTimeoutMs: number;
    /** 会话第一次答不上来时，允许**再**投一次（同一批事实、只要求答案行 ✓）；0 = 不许重试 ✓ */
    retryOnceMs: number;
    /**
     * ★★ A：**合并收集窗口**（毫秒 ✓，2026-10-18）。
     *
     * 游戏侧是**每艘船一条 decide**（`data/scripts/net/fleet.lua:119` ✓），
     * 同一个扫描里同时空闲的船会在**同一瞬间**各发一条 ✓。所以先等这么一小会儿
     * 把同一批的决定收进**一个块** ✓，再投递一次（否则就是"各投一个、她只答得了一个" ✗✓）。
     * `0` = 不合并（逐条投 ✓ —— 测试与旧行为都用它 ✓）。
     */
    mergeWindowMs: number;
}
export declare const BUDGETS: Budgets;
/** 会话事件的**最小**结构（真事件比这富 ✓；我们只读这两个字段 ✓） */
export interface SessionEventLike {
    type: string;
    turn?: number;
    step?: number;
    reason?: {
        kind?: string;
    };
    message?: {
        role?: string;
        content?: Array<{
            type?: string;
            text?: string;
        }>;
    };
    usage?: unknown;
}
/**
 * 一个**活着的** Agent 的**最小**面（真面见 `dsh-agent/lib/types/runtime-types.d.ts` ✓）。
 * ★ 只声明我们真的用的方法 ✓（`status` / `followup` / `whenIdle` / `cancel` ✓），
 *   这样测试桩只需要实现这几个 ✓，而真 Agent 天然满足 ✓（结构类型 ✓）。
 */
export interface AgentLike {
    id?: string;
    /** 'idle' | 'running' */
    status?: string;
    followup(message: unknown): void;
    whenIdle(): Promise<void>;
    cancel(cause: unknown, options?: unknown): void;
}
/** `ctx.agents` 的最小面 ✓ */
export interface RegistryLike {
    get(id: string): AgentLike | undefined;
    list(): AgentLike[];
}
/** 订阅某个会话的事件；返回退订函数 ✓ */
export type Subscribe = (sessionId: string, fn: (event: SessionEventLike) => void) => () => void;
/** 单发路径的一次调用（真实现 = `ctx.llm.stream` + 今天的解析/重试 ✓） */
export interface SingleShotResult {
    text: string;
    failure?: string;
    truncated?: boolean;
    /** 'first' | 'retry' —— 让流水能说清"这是重试那次" ✓ */
    attempt?: string;
    /**
     * ★★ 调用方要求**再问一次**（2026-10-17 修 ✓✓）。
     *
     * 为什么必须是它 ✗：单发那一级"该不该重试"只有**调用方**知道 ✓ ——
     *   提示词、事实、解析器都在 index.ts 里 ✓，dispatch 只看得到一段文本 ✓。
     *   原来的实现是 dispatch 自己拿正则找 `action=` ✓，可**"没有动作行"必须由真解析器判** ✓
     *   （`parseDecision` 容忍 `choice=`/加粗/全角冒号 ✓，一个正则判不准 ✗）。
     *   → 于是真正该重试的那种回复**永远重试不了** ✓（order-payload 的 g 用例就是这个 ✓）。
     * ★ 今天它是**必填**的：类型上漏了它 = 静默丢掉整条重试路径 ✗✓（这次就是这么被抓到的 ✓）。
     */
    retryHint?: string;
}
/** 阶梯的结论来源（**进 DecisionRecord.source ✓**） */
export type DecisionSource = 'session' | 'single-shot' | 'shadow' | 'asked-owner' | 'rendezvous' | 'fallbackNone' | 'none';
/** 会话这一级的结果（**影子模式也要报出来** ✓ —— 主人要看她答了什么 ✓） */
export interface SessionAttempt {
    /** 会话到底有没有给出可用答案 ✓ */
    answered: boolean;
    /** 会话的答案（答了才有 ✓） */
    answer?: TaskAnswer;
    /** 没用上/没用成的**原因码** ✓（TASK_MISMATCH / TIMEOUT / …） */
    code?: string;
    message?: string;
    /** 她问主人的问题（ASKED_OWNER ✓） */
    question?: string;
    /** 这一轮她吐了几条 assistant 文本 ✓（>1 说明她用了工具 ✓） */
    steps: number;
    /** 从投递到结束的真实耗时（ms ✓ —— 成本/延迟**实测**就靠它 ✓） */
    tookMs: number;
    /** token 用量（事件带就给 ✓，没有就 undefined ✓ —— **不假造** ✗） */
    usage?: unknown;
    /** 会话答案的原文（审计 ✓） */
    raw?: string;
    /**
     * ★★ 这一轮**合并投递**里一共塞了几艘船 ✓（2026-10-18）。
     *   `1` = 单船（与以前逐字相同 ✓）；`>1` = 一个块里 N 艘 ✓（这是"合并"的**证据** ✓）。
     */
    batchSize?: number;
}
export interface DispatchDeps {
    registry: RegistryLike;
    /** 投递目标会话 id；undefined = 没指定 ✓（阶梯直接从②开始 ✓） */
    commanderId?: string;
    /** 订阅会话事件（真实现 = `ctx.on('session/event', …)` 再按 sessionId 筛 ✓） */
    subscribe?: Subscribe;
    /** 单发路径（**必给** ✓ —— 没有它阶梯就没有第二级 ✓）。`hint` 非空 = 那次"只要答案行"的重试 ✓ */
    singleShot: (hint?: string) => Promise<SingleShotResult>;
    /**
     * ★ 单发路径的**重数据预取**（2026-10-17：会话路径不再预取计划 ✓✓）。
     *   它在阶梯①（会话）之后、阶梯②（单发）之前跑一次，**不受** singleShotTimeoutMs 限制
     *   （计划查询在游戏主线程同步算，tradePlan 实测 20s+ ✓）。返回非 null = 预取期间
     *   **已经定了这一单**（例如护航 rendezvous 派了 Travel ✓）→ 直接采纳并跳过单发模型 ✓。
     */
    prefetch?: () => Promise<PrefetchDecision | null>;
    /**
     * ★ 真正把任务块**投进会话** ✓（真实现 = `agent.followup(createUserMessage({...}))` ✓）。
     *   单列成一个注入点，是为了让本模块**不 import `dsh-llm`** ✓ ——
     *   于是整个阶梯可以在 Node 里**完全离线**测（`test/commander-dispatch.mjs` ✓✓）。
     */
    followup: (agent: AgentLike, block: string, req: TaskRequest) => void;
    /** 每艘船此刻允许的动作 ✓（校验用 ✓）—— ★ 但它是**投递时**的快照 ✗（见 `allowedActionsFor` ✓） */
    allowedActions: string[];
    /**
     * ★★ 2026-10-20 真机丢单的修：**校验前当场重查**这艘船的动作边界 ✓✓。
     *
     * 病根（`decisions.live.log` 2026-10-20 14:32:19 逐字 ✓）：
     *   `[session] ✘ 校验没过：BAD_ACTION（action Mine 不在允许集合内（Travel, Sell, Scout，以及 None））`
     *   —— 船刚加载完、**炮塔还没恢复**时取的 `facts.goalOptions` 快照 = [Travel, Sell, Scout] ✗；
     *   十几秒后她答 `action=Mine`（那时 `fleet_query{what:'ship'}` 已显示 Mining:4 ✓）→
     *   被**过期快照**当非法动作**整组丢掉** → `fallbackNone` → 船空转 ✗✗。
     *
     * → 校验**以当前事实为准** ✓；块里的清单只当提示 ✓。
     *   返回 `undefined`（或空数组）= 拿不到当前事实 → **退回快照** ✓（绝不因为查不到就丢单 ✗）。
     */
    allowedActionsFor?: (ship: string) => Promise<string[] | undefined>;
    /** 'live' = 会话答案算数 ✓；'shadow' = 只观察、单发算数 ✓（默认 'live' ✓） */
    mode?: 'live' | 'shadow';
    /** 忙会话要不要插队（默认 **false** ✓ —— 设计书：不插队，直接落单发 ✓） */
    steerWhenBusy?: boolean;
    /** 舰队级串行：取不到就直接下② ✓（**不排队** ✗ —— 见文件头注释 ✓） */
    lock?: {
        tryClaim(): (() => void) | undefined;
    };
    /** 会话那一级**答不上来时**要不要再投一次（同一批事实、只要求答案行 ✓）；默认 false = 只投一次 ✓ */
    retrySessionOnce?: boolean;
    /** ★ 单发那一级**没有动作行**时要不要重试一次（与今天 index.ts 的重试同源 ✓）；默认 true ✓ */
    retrySingleShotOnce?: boolean;
    budgets?: Partial<Budgets>;
    log?: (line: string) => void;
    /** 收答案时的**旁路**：每收到一条 assistant 文本就回调一次 ✓（主人能边看边说 ✓） */
    onAssistantText?: (step: number, text: string) => void;
}
/** 阶梯的完整结论 ✓ */
export interface DispatchOutcome {
    /** 最终要执行的动作（'None' = 不下单 ✓） */
    action: string;
    params: Record<string, unknown>;
    reason?: string;
    /** ★ 这一单是**谁**定的 ✓（进 DecisionRecord.source ✓） */
    source: DecisionSource;
    /** 单发那一路的原文（审计/落盘 ✓） */
    text?: string;
    truncated?: boolean;
    /** 会话那一路的观察结果（影子模式也有 ✓） */
    session?: SessionAttempt;
    /** 会话答案 vs 单发答案**是否一致**（影子模式下最有用的一个数 ✓；会话没答 = undefined ✓） */
    agreement?: boolean;
}
/**
 * ★ 单发预取阶段**直接定下**的一单（2026-10-17 ✓）：
 *   例如护航 rendezvous —— 预取时发现缺护航、本星系又没有候选，就派一艘 Travel 过去、
 *   本轮 action=None（**不跑模型** ✓）。它跳过单发模型调用，但**不**跳过记录/审计 ✓。
 */
export interface PrefetchDecision {
    action: string;
    params: Record<string, unknown>;
    reason?: string;
}
/**
 * ★ 原型抓到的坑 ①：`whenIdle()` **没有返回值** ✗ → "跑完了"与"超时了"必须**显式区分** ✓。
 * 返回 `{settled:true, value?}` / `{settled:false}`；**绝不**用 `value === undefined` 判超时 ✗✓。
 */
export declare function withTimeout<T>(promise: Promise<T>, ms: number): Promise<{
    settled: boolean;
    value?: T;
    error?: unknown;
}>;
/**
 * ★★ 主入口：为**一艘船**要一个决策 ✓。
 *
 * 保证（都在测试里断言过 ✓）：
 *   · **永不抛** ✓（任何异常都变成"下一级"或 `action=None` ✓）
 *   · **永不超总预算** ✓（会话硬闸 + 单发硬闸，各自独立 ✓）
 *   · 忙/挂死/在聊天的会话，**绝不会**让这一轮没有决策 ✓
 */
export declare function dispatchDecision(deps: DispatchDeps, req: TaskRequest): Promise<DispatchOutcome>;
/** 测试用：清空合并队列 ✓（一个进程里多次 apply 必须互不串味 ✓） */
export declare function resetBatchQueue(): void;
export { makeTaskId, renderTaskBlock, validateAnswer };
export type { TaskAnswer, TaskRequest };
