/**
 * standby.ts —— 「待命裁定」（2026-10-17 主人要求 ✓）
 *
 * 决策者判某船"待命（None）"后，同一艘船在冷却期内**不再征询** ✗✓：
 *   · 否则游戏每 5 分钟重问一次（见 data/scripts/net/fleet.lua 的 REDECIDE_COOLDOWN ✓），
 *     模型/会话被反复打扰，甚至被兜底改判 ✗（"Combat-00001 怎么又派出去侦察了"的根之一 ✓）。
 *   · 这里用**冷却 + 目标指纹**两条判据：冷却到期或目标改变就恢复征询 ✓；
 *     手动召回/改目标也会清掉裁定 ✓（上限 = 冷却到期，绝不"永远不问" ✗）。
 *
 * ★ 为什么"状态变化"只认**目标指纹**、不读船卡（换星区/船长/货舱）✗→✓：
 *   读船卡就要在会话路径里多发一次 `query{what:"ship"}` ✗ —— 而主人定的硬不变量是
 *   "会话路径投递前只取 goal"（test/session-no-prefetch.mjs 钉住 ✓）。所以这里只比对
 *   **已经免费拿到**的 goal；换星区/船长/货舱这类变化，由冷却上限 + 手动召回兜住 ✓
 *   （绝不"永远不问" ✗）。
 *
 * 纯内存（与 rendezvousMemo / redeliverMemo 同一档 ✓）；DSH 重启后自然清空 ✓。
 */

export interface StandbyEntry {
  ship: string
  /** 裁定时刻（毫秒） */
  atMs: number
  /** 原始 source（session / single-shot / fallbackNone / …） */
  source: string
  reason: string
  /** 目标指纹（goal text + options）—— 变了就恢复征询 ✓ */
  goalFingerprint: string
}

/** 默认冷却：20 分钟（主人建议 15~30 分钟 ✓，可配置 ✓） */
export const DEFAULT_NONE_COOLDOWN_MS = 20 * 60 * 1000

const memo = new Map<string, StandbyEntry>()

/** 目标指纹：goal 文本 + 动作边界（玩家改动目标 → 指纹变 → 恢复征询 ✓） */
export function goalFingerprintOf(goalText: string, goalOptions: string[]): string {
  return `${goalText}|${(goalOptions ?? []).join(',')}`
}

export function recordStandby(
  ship: string,
  source: string,
  reason: string,
  fingerprint: string,
  now: number = Date.now(),
): StandbyEntry {
  const entry: StandbyEntry = { ship, atMs: now, source, reason, goalFingerprint: fingerprint }
  memo.set(ship, entry)
  return entry
}

export function getStandby(ship: string): StandbyEntry | undefined {
  return memo.get(ship)
}

export function clearStandby(ship: string): void {
  memo.delete(ship)
}

/** 测试用：清空全部裁定 ✓ */
export function resetStandbyCache(): void {
  memo.clear()
}

export type StandbyVerdict =
  | { kind: 'standby'; entry: StandbyEntry; minsLeft: number }
  | { kind: 'consult' }

/**
 * 给一艘船要一个"要不要继续征询"的裁定 ✓。
 *   · 没有记录 / 冷却到期 / 目标指纹变了 → consult（照常征询）✓；
 *   · 否则 → standby（直接 None，不投递、不跑模型）✓。
 */
export function standbyVerdict(
  ship: string,
  goalText: string,
  goalOptions: string[],
  cooldownMs: number,
  now: number = Date.now(),
): StandbyVerdict {
  const entry = memo.get(ship)
  if (entry === undefined) return { kind: 'consult' }
  const elapsed = now - entry.atMs
  if (elapsed >= cooldownMs) {
    memo.delete(ship)
    return { kind: 'consult' }
  }
  if (goalFingerprintOf(goalText, goalOptions) !== entry.goalFingerprint) {
    memo.delete(ship)
    return { kind: 'consult' }
  }
  return { kind: 'standby', entry, minsLeft: Math.max(0, Math.round((cooldownMs - elapsed) / 60000)) }
}
