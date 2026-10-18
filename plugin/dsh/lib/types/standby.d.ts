/**
 * standby.ts —— 「待命裁定」+ ★★ 「漏答不静默」（2026-10-17 / 2026-10-18 ✓）
 *
 * 决策者判某船"待命（None）"后，同一艘船在冷却期内**不再征询** ✗✓：
 *   · 否则游戏每 5 分钟重问一次（见 data/scripts/net/fleet.lua 的 REDECIDE_COOLDOWN ✓），
 *     模型/会话被反复打扰，甚至被兜底改判 ✗（"Combat-00001 怎么又派出去侦察了"的根之一 ✓）。
 *   · 这里用**冷却 + 目标指纹**两条判据：冷却到期或目标改变就恢复征询 ✓；
 *     手动召回/改目标也会清掉裁定 ✓（上限 = 冷却到期，绝不"永远不问" ✗）。
 *
 * ★★ 2026-10-18 主人原话：「我感觉你总是会漏，尤其是多个决策同时来的时候」✓✓
 *
 * 于是这里把「None」分成**两种**（以前一律 20 分钟 ✗✓ —— 那就是"静默 20 分钟"的病根 ✓）：
 *
 * | kind | 什么时候 | 冷却 |
 * |---|---|---|
 * | `none`（★ 真的判了 None） | 决策者**明确写了** `action=None`（会话/单发都算 ✓） | 长冷却（默认 20 分钟 ✓） |
 * | `unanswered`（★ 漏答，不是决策 ✗） | `fallbackNone`：会话**忙/超时/没答到这艘船/答错格式** | **短重试**（默认 3 分钟 ✓）+ 连续 N 次才落 None |
 *
 * ★ 为什么必须分 ✗→✓：`fallbackNone` 里**没有任何决策** ✓ —— 它只是"这一轮没答到" ✓
 *   （真机日志 2026-10-18 08:50:58：两艘船同一秒各发一条 decide，第二条被 `SESSION_BUSY`
 *   挡掉 → `fallbackNone` → **20 分钟**冷却 → 那艘船凭空消失 20 分钟 ✗✗）。
 *   把"漏"当成"判"来罚 20 分钟，等于**用惩罚静默掩盖了漏答** ✗✓。
 *
 * ★ 为什么"状态变化"只认**目标指纹**、不读船卡（换星区/船长/货舱）✗→✓：
 *   读船卡就要在会话路径里多发一次 `query{what:"ship"}` ✗ —— 而主人定的硬不变量是
 *   "会话路径投递前只取 goal"（test/session-no-prefetch.mjs 钉住 ✓）。所以这里只比对
 *   **已经免费拿到**的 goal；换星区/船长/货舱这类变化，由冷却上限 + 手动召回兜住 ✓
 *   （绝不"永远不问" ✗）。
 *
 * 纯内存（与 rendezvousMemo / redeliverMemo 同一档 ✓）；DSH 重启后自然清空 ✓。
 */
/** ★ 判定的**两种**来源（决定用哪条冷却 ✓） */
export type StandbyKind = 'none' | 'unanswered';
export interface StandbyEntry {
    ship: string;
    /** 裁定时刻（毫秒） */
    atMs: number;
    /** 原始 source（session / single-shot / fallbackNone / asked-owner / …） */
    source: string;
    reason: string;
    /** 目标指纹（goal text + options）—— 变了就恢复征询 ✓ */
    goalFingerprint: string;
    /** ★ 这条是"真的判了 None"还是"漏答" ✓（2026-10-18） */
    kind: StandbyKind;
    /** ★ 连续没答到的次数（`kind='unanswered'` 时才有意义 ✓；1 = 第一次 ✓） */
    misses: number;
}
/** 默认冷却：20 分钟（主人建议 15~30 分钟 ✓，可配置 ✓）—— **只**给"真的判了 None" ✓ */
export declare const DEFAULT_NONE_COOLDOWN_MS: number;
/**
 * ★★ 漏答的**短重试间隔**：3 分钟（主人建议 2~3 分钟 ✓，可配置 ✓）。
 *   ★ 它必须**远短于**游戏侧的 REDECIDE_COOLDOWN（300 秒 ✓，
 *     `data/scripts/net/fleet.lua:31`）—— 否则"重投"实际上永远等不到下一轮 ✓。
 */
export declare const DEFAULT_UNANSWERED_RETRY_MS: number;
/**
 * ★★ 连续漏答**几次**才落到 None + 长冷却（默认 3 ✓，可配置 ✓）。
 *   为什么不无限重试 ✗：会话一直答不上来时，无限重投 = 无限打扰主人 ✗✓。
 */
export declare const DEFAULT_UNANSWERED_MAX_MISSES = 3;
/** 目标指纹：goal 文本 + 动作边界（玩家改动目标 → 指纹变 → 恢复征询 ✓） */
export declare function goalFingerprintOf(goalText: string, goalOptions: string[]): string;
export interface RecordStandbyOptions {
    /** 缺省 `'none'`（= 决策者真的判了 None ✓；旧调用方的语义逐字不变 ✓） */
    kind?: StandbyKind;
    /** 这是第几次连续漏答（`kind='unanswered'` ✓） */
    misses?: number;
    /** 连续漏答到这个次数就**落成** `none`（长冷却 ✓）；缺省 3 ✓ */
    maxMisses?: number;
}
export declare function recordStandby(ship: string, source: string, reason: string, fingerprint: string, now?: number, opts?: RecordStandbyOptions): StandbyEntry;
export declare function getStandby(ship: string): StandbyEntry | undefined;
export declare function clearStandby(ship: string): void;
/** 测试用：清空全部裁定 ✓ */
export declare function resetStandbyCache(): void;
export type StandbyVerdict = {
    kind: 'standby';
    entry: StandbyEntry;
    minsLeft: number;
    cooldownMs: number;
} | {
    kind: 'consult';
};
/** 两种冷却（★ 分级 ✓；传一个数字时两种都用它 —— 旧调用方语义不变 ✓） */
export interface Cooldowns {
    noneMs: number;
    unansweredMs: number;
}
export declare function cooldownsOf(cooldown: number | Cooldowns, unansweredMs?: number): Cooldowns;
/**
 * 给一艘船要一个"要不要继续征询"的裁定 ✓。
 *   · 没有记录 / 冷却到期 / 目标指纹变了 → consult（照常征询）✓；
 *   · 否则 → standby（直接 None，不投递、不跑模型）✓ ——
 *     ★ 冷却按 `entry.kind` **分级** ✓：漏答用短冷却 ✓，明确的 None 用长冷却 ✓。
 */
export declare function standbyVerdict(ship: string, goalText: string, goalOptions: string[], cooldownMs: number | Cooldowns, now?: number, unansweredMs?: number): StandbyVerdict;
