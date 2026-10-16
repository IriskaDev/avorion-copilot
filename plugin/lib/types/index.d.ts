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
    get?(name: string): unknown;
}
interface CopilotConfig {
    /** 监听端口；默认 8765（与游戏侧一致） */
    port?: number;
    provider?: string;
    model?: string;
    maxTokens?: number;
    temperature?: number;
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
export interface DecisionRecord {
    at: string;
    ship: string;
    goalText: string;
    goalOptions: string[];
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
/** ★ 单一来源：模型可以选的**全部**行动 ✓
 *  提示词（prompt/system.md 的输出格式）、这里（解析器）、以及 toAnswer 的默认白名单
 *  三处**必须一致** ✗ —— 2026-10-17 的 pro 审查抓到 `Scout` / `Sell` 漏在解析器与白名单之外 ✓，
 *  于是"计划里算得出来、却永远下不了单" ✗✓。test/actions-consistency.mjs 会守住这条 ✓。 */
export declare const ALL_ACTIONS: readonly ["Mine", "Salvage", "Trade", "Travel", "Sell", "Scout"];
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
