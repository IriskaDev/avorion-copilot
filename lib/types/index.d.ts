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
/** 读回落盘的记录（DSH 重启后仍能看到历史 ✓） */
export declare function readDecisionFile(limit: number): DecisionRecord[];
export declare function apply(ctx: CopilotCtx, config?: CopilotConfig): void;
export {};
