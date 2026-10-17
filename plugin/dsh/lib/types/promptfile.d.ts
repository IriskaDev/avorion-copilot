/** 提示词文件名（用户覆盖目录里同名文件即可 ✓） */
export declare const PROMPT_FILE_NAME = "system.md";
/** 机制段的占位符（提示词文件里写这一行，加载时被替换 ✓） */
export declare const MECHANICS_PLACEHOLDER = "{{MECHANICS}}";
/** ② 插件自带（lib/../prompt/system.md ✓） */
export declare const bundledPromptPath: string;
/** ① 用户覆盖（主人放这儿就优先用它 ✓✓） */
export declare const overridePromptPath: string;
/** 加载结果 */
export interface LoadedPrompt {
    /** 真正送给模型的提示词（占位符已替换 ✓） */
    text: string;
    /** 实际来源：文件路径，或 '<built-in default>' */
    source: string;
    /** 与上一次相比内容是否变了 ✓（变了就值得在流水里说一声 ✓） */
    changed: boolean;
    /** 解析顺序里的两个候选路径（供文档/日志用 ✓） */
    paths: {
        override: string;
        bundled: string;
    };
    /** 非致命问题（文件缺失/不可读/没写占位符 ✓）—— 调用方可以报一行 ✓ */
    notes: string[];
}
export declare function setPromptNotifier(fn: ((line: string) => void) | undefined): void;
/** 把机制段替换进占位符 ✓（没写占位符就只在 notes 里说一声 ✓ 不擅自拼接 ✗） */
export declare function applyMechanics(raw: string, notes: string[]): string;
/**
 * ★ 读提示词。顺序：用户覆盖 → 插件自带 → 内置兜底 ✓。
 * **任何失败都只会落到兜底**，绝不抛异常 ✓✓（提示词问题不许拖垮决策 ✗）。
 */
export declare function loadSystemPrompt(): LoadedPrompt;
/**
 * ★ 可测的核心：给定两个候选路径与兜底文本，按顺序解析 ✓
 * （测试就是靠它用临时目录验"覆盖优先 / 兜底不抛异常" ✓✓）
 */
export declare function loadPromptFrom(opts: {
    override: string;
    bundled: string;
    defaultText?: string;
}): LoadedPrompt;
/** 首次加载时打印一次解析路径（人要知道改哪个文件 ✓） */
export declare function describePromptPaths(): string[];
/** 给测试用：清掉缓存与"已播报"状态 ✓ */
export declare function resetPromptCache(): void;
