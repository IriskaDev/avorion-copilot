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
    /** 注册需要在卸载/热重载时自动清理的资源。 */
    effect(fn: () => (() => void) | void, label?: string): void;
    /** cordis 的服务查找；用来探测 credentials 服务在不在。 */
    get?(name: string): unknown;
}
interface BridgeConfig {
    /** 桥接目录；留空则用 %APPDATA%/Avorion/moddata/copilot。 */
    dir: string;
    /** 轮询间隔（毫秒）。 */
    intervalMs: number;
    provider: string;
    model: string;
    maxTokens: number;
    temperature: number;
}
export declare function apply(ctx: CopilotCtx, rawConfig?: Partial<BridgeConfig>): Promise<void>;
export {};
