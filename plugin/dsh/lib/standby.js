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
/** 默认冷却：20 分钟（主人建议 15~30 分钟 ✓，可配置 ✓）—— **只**给"真的判了 None" ✓ */
export const DEFAULT_NONE_COOLDOWN_MS = 20 * 60 * 1000;
/**
 * ★★ 漏答的**短重试间隔**：3 分钟（主人建议 2~3 分钟 ✓，可配置 ✓）。
 *   ★ 它必须**远短于**游戏侧的 REDECIDE_COOLDOWN（300 秒 ✓，
 *     `data/scripts/net/fleet.lua:31`）—— 否则"重投"实际上永远等不到下一轮 ✓。
 */
export const DEFAULT_UNANSWERED_RETRY_MS = 3 * 60 * 1000;
/**
 * ★★ 连续漏答**几次**才落到 None + 长冷却（默认 3 ✓，可配置 ✓）。
 *   为什么不无限重试 ✗：会话一直答不上来时，无限重投 = 无限打扰主人 ✗✓。
 */
export const DEFAULT_UNANSWERED_MAX_MISSES = 3;
const memo = new Map();
/** 目标指纹：goal 文本 + 动作边界（玩家改动目标 → 指纹变 → 恢复征询 ✓） */
export function goalFingerprintOf(goalText, goalOptions) {
    return `${goalText}|${(goalOptions ?? []).join(',')}`;
}
export function recordStandby(ship, source, reason, fingerprint, now = Date.now(), opts = {}) {
    let kind = opts.kind ?? 'none';
    const maxMisses = typeof opts.maxMisses === 'number' && opts.maxMisses > 0
        ? opts.maxMisses
        : DEFAULT_UNANSWERED_MAX_MISSES;
    // ★ 连续漏答满 N 次 → **落成** None（长冷却 ✓，避免无限刷 ✓）
    let misses = Math.max(0, Math.floor(opts.misses ?? (kind === 'unanswered' ? 1 : 0)));
    if (kind === 'unanswered' && misses >= maxMisses) {
        kind = 'none';
        reason = `${reason}（连续 ${misses} 次没答到 → 已落到 None + 长冷却 ✓）`;
    }
    const entry = {
        ship, atMs: now, source, reason, goalFingerprint: fingerprint, kind, misses,
    };
    memo.set(ship, entry);
    return entry;
}
export function getStandby(ship) {
    return memo.get(ship);
}
export function clearStandby(ship) {
    memo.delete(ship);
}
/** 测试用：清空全部裁定 ✓ */
export function resetStandbyCache() {
    memo.clear();
}
export function cooldownsOf(cooldown, unansweredMs) {
    if (typeof cooldown === 'number') {
        return { noneMs: cooldown, unansweredMs: unansweredMs ?? cooldown };
    }
    return { noneMs: cooldown.noneMs, unansweredMs: cooldown.unansweredMs };
}
/**
 * 给一艘船要一个"要不要继续征询"的裁定 ✓。
 *   · 没有记录 / 冷却到期 / 目标指纹变了 → consult（照常征询）✓；
 *   · 否则 → standby（直接 None，不投递、不跑模型）✓ ——
 *     ★ 冷却按 `entry.kind` **分级** ✓：漏答用短冷却 ✓，明确的 None 用长冷却 ✓。
 */
export function standbyVerdict(ship, goalText, goalOptions, cooldownMs, now = Date.now(), unansweredMs) {
    const entry = memo.get(ship);
    if (entry === undefined)
        return { kind: 'consult' };
    const cds = cooldownsOf(cooldownMs, unansweredMs);
    const cooldown = entry.kind === 'unanswered' ? cds.unansweredMs : cds.noneMs;
    const elapsed = now - entry.atMs;
    if (elapsed >= cooldown) {
        memo.delete(ship);
        return { kind: 'consult' };
    }
    if (goalFingerprintOf(goalText, goalOptions) !== entry.goalFingerprint) {
        memo.delete(ship);
        return { kind: 'consult' };
    }
    return {
        kind: 'standby',
        entry,
        minsLeft: Math.max(0, Math.round((cooldown - elapsed) / 60000)),
        cooldownMs: cooldown,
    };
}
//# sourceMappingURL=standby.js.map