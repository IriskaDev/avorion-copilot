/**
 * @dsh-external/dsh-avorion-copilot —— Avorion `copilot` mod ⇄ DSH 的桥接插件。
 *
 * ## 本版（RPC 版）
 *
 * 传输从「文件桥」换成「**TCP + 对称 RPC**」✓（协议见 mod 仓库的 PROTOCOL.md v2）。
 * 本质就是主人点透的那句话：
 *   **让 DSH 能调游戏的功能，也让游戏能调 DSH 的功能。** ✓
 *
 * ```
 *   游戏（Lua rpc.lua）  ⇄  TCP 127.0.0.1:8765  ⇄  本插件（rpc.ts）
 *        handle: hello/query/order/decide/reload/ping      ← 游戏提供的功能
 *        call:   hello/state/decide                        ← 游戏发起的请求
 * ```
 *
 * 本插件**监听** 8765（游戏主动连过来 ✓ —— 这样不触发 Windows 防火墙弹窗 ✓）。
 *
 * ## 文件桥时代的东西去哪了
 *
 * `watch`/`atomicWrite`/`writeDiagnostics` 全部删掉 ✓ —— 不再需要 ✓。
 * **`SYSTEM_PROMPT` 与 `parseDecision` 那一套一字未改** ✓ —— 它们是调研出来的领域知识
 * 和踩过坑的鲁棒解析 ✓，与传输无关 ✓。
 */
import type { GenerateOptions, StreamChunk } from '@deepseek-ai/dsh-llm/types';
import { RpcPeer } from './rpc.js';
import { type SessionAttempt } from './dispatch.js';
export declare const name = "@dsh-external/dsh-avorion-copilot";
/** 需要 LLM 服务；没有它插件不启动。 */
export declare const inject: string[];
/** ctx 的最小结构化描述，避免依赖拿不到的 cordis 类型。 */
interface CopilotCtx {
    logger?: {
        info?: (message: string) => void;
        warn?: (message: string) => void;
    };
    llm: {
        stream(options: GenerateOptions): AsyncIterable<StreamChunk>;
        listProviders?(): unknown;
    };
    effect(fn: () => (() => void) | void, label?: string): void;
    /** ★ 工具注册（inject 里已声明 'tools' ✓） */
    tools: {
        register(tool: unknown): unknown;
    };
    /** ★ `ctx.agents`（不经 inject：拿不到也不影响单发路径 ✓ —— 见 resolveAgents ✓） */
    agents?: unknown;
    /**
     * ★ `ctx.on('session/event', …)` ✓ —— 收会话答案靠它 ✓。
     *   作用域规则（`dsh-scope`）：**未打 scope 标记的监听者收到所有会话的事件** ✓，
     *   所以我们按 sessionId 自己筛 ✓（与 dsh-goal-round-driver 同一套做法 ✓）。
     */
    on?: (event: string, listener: (...args: any[]) => void) => unknown;
    get?(name: string): unknown;
    /**
     * ★ **等一个可选服务**（cordis 自带 ✓）。
     *
     * `ctx.get(name)` 是**当场**查 ✗ —— 服务还没就绪就是 undefined ✓；
     * `ctx.inject([name], cb)` 则是**等它就绪再回调** ✓✓，回调收到的是能直接
     * `.name` 取到该服务的子 ctx ✓（原版 `dsh-client-modules` 就是这么拿 webServer 的 ✓）。
     * 注意：用它 ★ 不等于 ★ 把服务写进 `export const inject` ✗ ——
     * 后者是"没有它插件就别启动" ✓，而我们要的是"没有它照样跑，只是少个开关" ✓。
     */
    inject?(names: string[], fn: (ctx: any) => void): unknown;
}
interface CopilotConfig {
    /** 监听端口；默认 8765（与游戏侧一致） */
    port?: number;
    provider?: string;
    model?: string;
    maxTokens?: number;
    temperature?: number;
    /**
     * ★ 决策任务投递到**哪个会话**（主人自己的会话 id ✓）。
     *   缺省 → 用落盘的选择（`fleet_commander` 指定过的 ✓）；都没有 = 不投递 ✓
     *   （= 今天的单发路径，逐字不变 ✓）。
     */
    commanderSession?: string;
    /**
     * ★ 怎么用那个会话的答案（主人 2026-10-17 定的两阶段 ✓）：
     *   · `shadow`（**默认**）= 只投递 + 只观测：她的答案被记下来并跟单发的答案并排比较，
     *     但**实际下单仍然是单发** ✓✓ —— 零风险地量延迟/成本/质量 ✓（设计书推荐的第一步 ✓）。
     *   · `live` = 她的答案**算数** ✓（校验通过就直接下单 ✓）；她没答成才落单发 ✓。
     *     ★ 需要主人显式打开（这也是"回滚开关"：改回 shadow 即恢复零风险 ✓，不用重启游戏 ✓）。
     */
    decideMode?: 'shadow' | 'live';
    /** 主人在那个会话里聊天时要不要插队投递（**默认 false** ✓ —— 主人的对话优先 ✓） */
    steerWhenBusy?: boolean;
    /** 会话第一次答不上来时要不要再投一次（默认 false ✓）；单发那次重试默认开 ✓ */
    retrySessionOnce?: boolean;
    /**
     * ★★ 待命裁定冷却（毫秒）：决策者判某船 None 后，同船这段时间内不再征询 ✓
     *   （默认 20 分钟；主人建议 15~30 分钟 ✓）。目标改变 / 手动召回会提前恢复 ✓。
     */
    noneCooldownMs?: number;
}
/**
 * ★★ 一次决策的完整记录（主人在 DSH 里要看得见的东西 ✓✓）。
 *
 * 分五段，正好对应主人的问法 "决策过程" ✓：
 *   ① 触发  ship / at / goalText
 *   ② 输入  card（星区·船长·忙闲）+ routes（候选路线表 ✓）
 *   ③ 推理  modelText + **reasoning**（思维链 ✓✓）
 *   ④ 结论  answer（action / params / reason）
 *   ⑤ 结果  orderResult（下单回执 ✓）/ code + message（失败时 ✓）
 */
/**
 * ★★ 决策的**粗粒度来源**标签（2026-10-17 主人要求 ✓✓）——
 *   进「上一单的结果」块文案与 fleet_decisions，让主人一眼看出"这单谁定的" ✓。
 *   `source` 更细（区分 shadow / asked-owner / none），`decider` 只回答"谁拍板/谁不下单" ✓。
 */
export type Decider = 'session' | 'single-shot' | 'rendezvous' | 'fallbackNone';
/**
 * ★ source → decider 的**单一映射**（只有一个真相来源 ✓）：
 *   · 会话定的（含她在问主人）→ session；单发定的（含影子采纳）→ single-shot；
 *   · rendezvous → rendezvous；「都没有」与「兜底不下单」→ fallbackNone ✓。
 */
export declare function deciderOf(source: string | undefined): Decider | undefined;
export interface DecisionRecord {
    at: string;
    ship: string;
    goalText: string;
    goalOptions: string[];
    /**
     * ★★ 这一单是**谁**定的（2026-10-17 补 ✓）—— 主人一眼看出决策来自哪条路 ✓：
     *   `session`      = 投进主人会话、由她定的 ✓
     *   `single-shot`  = 插件自己那一次单发调用定的 ✓（今天的行为 ✓）
     *   `shadow`       = ★ 影子模式：她答了，但这一单**采纳的是单发** ✓（Phase B ✓）
     *   `asked-owner`  = 她在问主人 → 本轮**明确延期**、未派单 ✓（人在环里 ✓）
     *   `none`         = 两条路都没有可用答案 ✓
     *   `rendezvous`   = 插件自己先派护航、本轮不下单 ✓（既有逻辑 ✓）
     *   `fallbackNone` = ★ 指挥官会话在线但本轮没答成 → 兜底 = None（不许单发拍板 ✓）
     */
    source?: 'session' | 'single-shot' | 'shadow' | 'asked-owner' | 'none' | 'rendezvous' | 'fallbackNone';
    /**
     * ★★ 这一单**谁定的**（2026-10-17 主人要求 ✓✓）—— 与 `source` 互补的**粗粒度**标签，
     *   贯通到「上一单的结果」块文案与 fleet_decisions ✓：
     *   · `session`      = 会话定的（含 `asked-owner`：是她在问主人，也算她这一级 ✓）；
     *   · `single-shot`  = 单发定的（含 `shadow`：影子模式下采纳的也是单发 ✓）；
     *   · `rendezvous`   = 护航 rendezvous 定的 ✓；
     *   · `fallbackNone` = 兜底说"不下单"（会话在线但没答成 / 待命裁定冷却期内 ✓）。
     *   ★ 由 `deciderOf(source)` 单一映射 ✓ —— 旧记录没有它就按 source 反推 ✓。
     */
    decider?: Decider;
    card?: unknown;
    routes?: unknown;
    ok: boolean;
    code?: string;
    message?: string;
    modelText?: string;
    reasoning?: string;
    truncated?: boolean;
    answer?: {
        action: string;
        params: Record<string, unknown>;
        reason?: string;
    };
    orderResult?: unknown;
    /** ★ 会话那一路的观察结果（她答了什么 / 几步 / 多久 / 为什么没答成 ✓ —— 影子模式最有价值的一栏 ✓） */
    session?: SessionAttempt;
    /** ★ 她的答案与单发的答案**是否一致**（影子模式下用来量"她靠不靠谱" ✓） */
    agreement?: boolean;
    /**
     * ★★ 两条路的**体积实测**（2026-10-17 加 ✓✓ —— 体积问题必须有可回看的数字 ✓）：
     *   · `blockBytes`   = 投进会话那个块的真实字节数 ✓（agent 路径；目标远小于 2 KB ✓）
     *   · `cardCopies`   = 那次块里出现了几遍船卡 ✓（**必须是 0** ✗ —— 以前是 2 ✓）
     *   · `dossierBytes` = 单发那份有界档案的字节数与裁剪记录 ✓（`dossier.ts` 的 stats ✓）
     */
    delivered?: {
        blockBytes: number;
        cardCopies: number;
        targetBytes: number;
    };
    dossierBytes?: unknown;
    /**
     * ★★ 下单回执（结构化，2026-10-17 补 ✓✓）：把游戏 order 的 accepted/executed/error 落盘 ✓。
     *   · `accepted` = 游戏收下了这单（没被拒 ✓）；
     *   · `executed` = 真的排进了 startCommand（两段式第二阶段 ✓）；
     *   · `error`   = 失败/被拒/未执行时的原因（游戏原话 or "not connected to the game" ✓）。
     */
    receipt?: OrderReceipt;
    /**
     * ★★ 失败回投的完整记录（2026-10-17 补 ✓✓）：每回投一次就记一行 ✓，
     *   `reason` = 上一单为什么失败 / `action` = 回投后重新选了啥 / `receipt` = 那次下单的回执 ✓。
     */
    redeliveries?: Array<{
        at: string;
        reason: string;
        action?: string;
        params?: Record<string, unknown>;
        receipt?: OrderReceipt;
        note?: string;
    }>;
    /** ★★ 回投达到上限/退避而停止时，写明"需人工介入"的原因 ✓ */
    needsIntervention?: string;
}
/** ★ 下单回执（2026-10-17 补 ✓）：`accepted` + `executed` + `error`，跨重启可审计 ✓ */
/**
 * ★★ 游戏侧给的「这次下单的伏击风险评估」（2026-10-17 加 ✓✓）。
 *   口径 = 游戏 `predict` 的**同一份代码**（`link_in.lua` 的 `orderRiskOf` 直接调 predict ✓），
 *   所以数值与决策前用 `fleet_query what=predict` 查到的一模一样 ✓✓。
 *   · `known=false` → `attackChance` 是 **null/undefined**（**绝不是 0** ✗✓：0 = 游戏说不会遇伏击）；
 *   · Travel 的数是**整段航程**被伏击的概率 ✓（原版 Travel 命令自带评估 ✓）；
 *   · `baseAttackChance` 是基准（判断「<10% 吗」只看它 ✓）；Travel 没有 base →
 *     `baseAttackChanceKnown=false` + `baseAttackChanceUnknownReason` ✓。
 */
export interface OrderRisk {
    known: boolean;
    attackChance?: number | null;
    baseAttackChance?: number | null;
    baseAttackChanceKnown?: boolean;
    baseAttackChanceUnknownReason?: string;
    riskKind?: string | null;
    unknownReason?: string;
    attackChanceWithEscorts?: number | null;
}
/**
 * ★★ 预检（preflight）—— 游戏侧在**下单前**按动作核对前置条件的结论 ✓✓（2026-10-17）
 *
 * 主人的原话（这套结构的由来）：「你下的指令似乎你都不知道是有没有正常执行啊，回执没法带结果吗？」
 * 今晚四种「接了却没做」（回执都是 accepted:true executed:true ✗）：
 *   ① Sell 清单里混了没人收的货 → 一件没卖；② Sell 在没买家的框 → 空转；
 *   ③ `startCommand -> ok=true` 只是"进队列"；④ Travel 只有 1 跳 → 接单不动。
 * 根因 = 回执只反映 RPC 队列那一步 ✗ —— 所以游戏侧加了这一层：
 *   `preflight.ok=false` → **压根没下单**（没发起区域分析、没排 startCommand ✓）。
 * ★ `ok=false` 时字段是 `{ok:false, code, reason, detail}` ✓；通过时还会有 checks / warnings。
 */
export interface OrderPreflightCheck {
    name?: string;
    ok?: boolean;
    reason?: string;
    detail?: string;
}
export interface OrderPreflightWarning {
    code?: string;
    detail?: string;
}
export interface OrderPreflight {
    ok: boolean;
    /** 失败码：MIN_DISTANCE / ALREADY_THERE / SHIP_NOT_IN_AREA / CAPTAIN_NOT_MERCHANT / ... */
    code?: string;
    /** 人话原因（游戏侧原文，**不翻译** ✓） */
    reason?: string;
    detail?: string;
    /** 逐项结论（ok=true 的那些也在这里 ✓） */
    checks?: OrderPreflightCheck[];
    /**
     * ★ 提示（**不是失败** ✓）：原版**不会**拒绝、但按主人的规矩/机制值得知道的事。
     *   例：`DURATION_CLAMPED`（被原版夹紧）、`SELL_SKIPPED`（卖不掉的货被剔掉）、
     *       `ESCORT_UNARMED`（原版不查武装 ✗）、`ESCORT_NOT_SAME_SECTOR`（原版允许一跳之内 ✓）
     */
    warnings?: OrderPreflightWarning[];
    /** 预检时真的改过的参数（如 duration 被夹紧 ✓） */
    applied?: Record<string, unknown>;
    /** 预检时读到的船状态（位置 / busy / 货舱 ✓ —— 与实测同一个读取函数 ✓） */
    state?: Record<string, unknown>;
    /** Sell 专用：有买家 / 卖不掉 的逐货结论（判据 = 原版 getErrors ✓） */
    sell?: {
        sellableKinds?: number;
        sellableUnits?: number;
        skippedKinds?: number;
        skippedUnits?: number;
        skipped?: Array<{
            goodName?: string;
            amount?: number;
            reason?: string;
        }>;
    };
    /** 护航逐条事实（available / sameSector / distance / reach / canFight ✓） */
    escorts?: Array<Record<string, unknown>>;
    /** Travel 专用：距离 / route 段数 / 时长 ✓（与 predict 同一份分析 ✓） */
    travel?: Record<string, unknown>;
}
/**
 * ★★ 实测（verify）—— startCommand 之后**延迟重读实体状态**的结论 ✓✓（2026-10-17）
 *
 * ★ 判定口径（游戏侧 verifyVerdict ✓，都来自原版实读）：
 *   · **主证据 = `busy:true`**（= `InBackground`，simulation.lua:584 —— 这一行在**所有**闸门之后 ✓）；
 *   · Travel：位置/终点（但原版**只在 onFinish/onRecall 才写坐标** → 航程中间不动是正常的 ✓）；
 *   · Sell/Refine：`cargoUsed` 下降（★ 只在**跑完**才结算 ✓ —— 短窗口里 `busy` 才是证据 ✓）；
 *   · Mine/Salvage/Trade/Scout：`busy:true`（产出进派系资源池 / 货舱在结束时才变 ✓）。
 *   · `ok=false` + `reason` = "**接了却什么都没发生**"（原版静默拒绝的样子 ✓）。
 * ★ `pending:true` = 还没到采样点（RPC 是一次问答，实测只能**稍后**取 ✓）。
 */
export interface OrderVerify {
    pending?: boolean;
    /** 还要等几秒（pending 时有 ✓） */
    etaSeconds?: number;
    at?: string;
    ok?: boolean;
    reason?: string;
    note?: string;
    /** atDestination / moved / busy / cargoUsedDecreased / cargoUsedIncreased / cargoChanged */
    evidence?: string;
    started?: boolean;
    startCommandQueued?: boolean;
    afterStartSec?: number;
    busy?: boolean;
    busyKnown?: boolean;
    availability?: unknown;
    moved?: boolean | null;
    atDestination?: boolean;
    position?: {
        x: number;
        y: number;
    };
    positionBefore?: {
        x: number;
        y: number;
    };
    cargoUsed?: number;
    cargoUsedBefore?: number;
    cargoUsedDelta?: number;
    cargoKinds?: number;
    cargoKindsBefore?: number;
    holdHasGoods?: boolean;
    destination?: {
        x: number;
        y: number;
    };
    stage?: number;
    hint?: string;
}
export interface OrderReceipt {
    at: string;
    accepted: boolean;
    executed: boolean;
    /**
     * ★★ 已发送但没收到确认（order RPC 超时回 `no response` / 断连回 `connection lost`）✓✓。
     *   这是**假阴性** ✗：order 是 fire-and-forget，游戏可能已经在跑了 ✓（实机铁证：
     *   下单 RPC 超时回 no response，船其实已经从 (-381,57) 挪到 (-373,60) ✓✓）。
     *   → **绝不据此判失败、绝不回投** ✗（回投 = 同一艘船两条矛盾命令 ✗）；
     *   下一轮用 list/ship 的 busy/舱量来核实真实结果 ✓。
     */
    unconfirmed?: boolean;
    /** ★ 游戏侧对**这一单**的伏击风险评估（2026-10-17 ✓）；缺省 = 老游戏侧没这个字段 ✓ */
    risk?: OrderRisk;
    /** ★★ 下单**之前**的前置条件核对（2026-10-17 ✓✓）；`ok=false` = 这单**根本没下** ✗✓ */
    preflight?: OrderPreflight;
    /** ★★ 下单**之后**的实测结论（2026-10-17 ✓✓）；`pending:true` = 还没到采样点 ✓ */
    verify?: OrderVerify;
    /** ★★ 下单号（取实测结论用 ✓）：`fleet_query{what:'orderStatus', orderId}` 或按 ship ✓ */
    orderId?: number | string;
    error?: string;
    note?: string;
}
/**
 * 决策记录（环形，最多 50 条 ✓）。放在模块级，工具与 decide 处理器共用 ✓。
 * 只在内存里 —— 够主人现场回看 ✓；要长期留档再落文件 ✓。
 */
export declare const decisionLog: DecisionRecord[];
export declare const DECISION_LOG_LIMIT = 50;
export declare function live(msg: string): void;
/** 收到一个 delta → 立刻追加（不做任何组织/截断 ✓✓） */
export declare function liveRaw(kind: 'reasoning' | 'text', delta: string): void;
/** 读回落盘的记录（DSH 重启后仍能看到历史 ✓） */
export declare function readDecisionFile(limit: number): DecisionRecord[];
export interface VerifyWaitOptions {
    /** 总共最多等多久（ms ✓；缺省 25s —— 够 startCommand 6s + 采样 6s + 一次重采 9s ✓） */
    budgetMs?: number;
    /** 两次查询之间至少隔多久（ms ✓） */
    pollMs?: number;
}
/**
 * ★★ 轮询 `orderStatus` 直到拿到**定稿**的实测结论 ✓✓（2026-10-17）
 *   返回 `undefined` = 老游戏侧 / 没有这单的记录 / 断连（**不编** ✓）；
 *   返回 `{pending:true,…}` = 预算到了还没定稿（**也不编成功** ✓）。
 */
export declare function waitForOrderVerify(peer: Pick<RpcPeer, 'call'>, target: {
    orderId?: number | string;
    ship?: string;
}, opts?: VerifyWaitOptions): Promise<OrderVerify | undefined>;
/**
 * ★★ 游戏侧风险 → 一行短文案（2026-10-17 ✓✓）：`伏击 3%（基准 3%）`。
 *   · `known=false` → 明说「伏击未知 + 原因」✓ —— **绝不写 0%** ✗✓（0% 是"游戏说不会遇伏击"，两回事 ✓）；
 *   · Travel 的数是**整段航程**的（`riskKind` 里写着 ✓），这里不重复解释 ✓。
 */
export declare function riskText(r: OrderRisk | undefined | null): string | undefined;
/**
 * ★★ 预检结论 → 人话（2026-10-17 ✓✓）
 *   `预检 ✗ MIN_DISTANCE — This route is too short. …`（`ok=false` = **没下单** ✓）
 *   `ok=true` 返回 undefined（成功不需要废话 ✓；要看细节直接读 JSON ✓）。
 */
export declare function preflightText(pf: OrderPreflight | undefined | null): string | undefined;
/** 预检里"值得知道但不拦"的提示（卖不掉的货 / 被夹紧的时长 / 护航事实 ✓） */
export declare function preflightWarningText(pf: OrderPreflight | undefined | null): string | undefined;
/**
 * ★★ 实测结论 → 人话（2026-10-17 ✓✓）
 *
 *   `已到 ✓` / `在跑 ✓（货舱要跑完才结算）` / `货舱 -120 ✓` /
 *   `实测 ✗ 货舱没少、也不在后台运行 —— …`（**这就是"接了就完"的样子** ✓）
 *   `实测待回（~8s）` = 还没到采样点（**不是成功** ✗✓）
 */
export declare function verifyText(v: OrderVerify | undefined | null): string | undefined;
/**
 * ★ 把一条决策记录渲染成「上一单的结果」一行（**带 decider 来源标签** ✓✓）。
 *   2026-10-17 主人要求：不许把单发/兜底的结论写成"你（会话）上一单" ✗ ——
 *   所以每一行都带 `[session]` / `[single-shot]` / `[rendezvous]` / `[fallbackNone]` ✓。
 *   ★ 2026-10-17 第二轮追加：**预检 / 实测**也要在这行里（这是主人"回执带结果"的落点 ✓✓）。
 *   导出给测试 ✓。
 */
export declare function renderPrevResult(rec: DecisionRecord): string | undefined;
/** ★ 单一来源：模型可以选的**全部**行动 ✓
 *  提示词（prompt/system.md 的输出格式）、这里（解析器）、以及 toAnswer 的默认白名单
 *  三处**必须一致** ✗ —— 2026-10-17 的 pro 审查抓到 `Scout` / `Sell` 漏在解析器与白名单之外 ✓，
 *  于是"计划里算得出来、却永远下不了单" ✗✓。test/actions-consistency.mjs 会守住这条 ✓。 */
export declare const ALL_ACTIONS: readonly ["Mine", "Salvage", "Trade", "Travel", "Sell", "Scout", "Refine"];
/** `escortNeedOf` 的结论 ✓ */
export interface EscortNeed {
    needed: boolean;
    why: string;
    route?: string;
    risk?: number;
    riskWithEscort?: number;
    gate?: number;
}
/**
 * ★ 判断"这一轮的 tradePlan 是不是**真的缺一艘护航**" ✓
 *
 * 只**读**游戏给的字段，不改扫描逻辑 ✓：
 *   recommendation 非空        → 已经有能出海的推荐 → 不需要 ✓
 *   本星系已有护航候选          → 现有流程会处理 → 不需要 ✓
 *   一条路线都没有              → 护航只降伏击概率，救不了"没货可运" ✗ → 不需要 ✓
 *   最好候选 ×0.75 仍超门槛     → 派过去也压不下来 ✗ → 不派（诚实说明 ✓，别白跑一趟 ✓）
 *
 * 兼容两种形状：新的多区域 areaRanking ✓、老的 candidates ✓。
 */
export declare function escortNeedOf(plan: unknown, sameSectorEscorts: string[]): EscortNeed;
/** 挑出来的护航船 ✓ */
export interface EscortPick {
    name: string;
    sector: {
        x: number;
        y: number;
    };
    turretCount?: number;
    basis: string;
}
/**
 * ★ 从舰队快照里挑一艘**别的星系**的护航 ✓
 *
 * 硬规矩（一条都不能松 ✗）：
 *   · 绝不挑玩家正在开的那条（`fd.piloted` ✓ —— 本项目的老规矩 ✓）
 *   · 绝不挑行动船自己 ✓
 *   · 跳过忙船 ✓（后台命令是异步的，忙船派不动 ✓）
 *   · 必须有船长 ✓（没船长接不了后台命令 ✓）
 *   · 必须在**别的**星系 ✓（同星系就直接当候选了，不用旅行 ✓）
 *   · "像战斗舰"：**名字命中战斗词** 或 **有炮塔** ✓ —— 只看名字太窄 ✗
 *     （实测有些船 turretCount 探针读不到 ✗，只认名字会把能用的船全漏掉 ✓）
 *
 * 打分：名字命中数 ×10 + 炮塔数（封顶 10）✓ —— 名字最重（主人点名 Combat/Raven ✓）。
 * 并列时按船名排序 → **确定性** ✓（同一局不会一会儿挑 A 一会儿挑 B ✓）。
 */
export declare function pickRendezvousEscort(ships: Record<string, unknown>[], actionShip: string, pilotedName: string, targetSector: {
    x?: number;
    y?: number;
}): EscortPick | null;
export declare function apply(ctx: CopilotCtx, config?: CopilotConfig): void;
export {};
