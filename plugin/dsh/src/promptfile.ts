/**
 * ★ 提示词的**运行时读取器**（2026-10-17 主人要求 ✓）
 *
 * 主人原话：「prompt 能搞成单独的文件 prompt 文件吗，让程序运行时读取」
 *
 * 为什么要这样 ✗→✓：
 *   · 提示词以前是 src/index.ts 里的**模板字符串** ✗ —— 每次改一个字都要**重新编译 + 重启 DSH** ✗✓；
 *     而且它踩过**两次**反引号把模板提前结束的坑（TS1005 ✗）。
 *   · 现在提示词是普通 Markdown 文件 ✓：
 *       ① 用户覆盖（可随时手改 ✓ 不会被插件更新冲掉 ✓）
 *       ② 插件自带（随仓库走 ✓ 默认值 ✓）
 *       ③ 编译内置的兜底常量（文件读不到时用 ✓ —— **绝不因为文件问题拖垮决策** ✓✓）
 *   · ★ 每次决策前**重新读**（带 mtime+size 缓存 ✓）→ **改完立刻生效，不用重启 DSH** ✓✓
 *
 * ★ 注意：机制段（`{{MECHANICS}}`）仍然只有一份来源 —— mod 仓库的 docs/game/mechanics-source.md ✓，
 *   由 scripts/render-mechanics.mjs 生成 src/mechanics.ts，再在这里**替换进占位符** ✓。
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { MECHANICS_BRIEF } from './mechanics.js'
import { SYSTEM_PROMPT_DEFAULT } from './prompt-default.js'

/** 提示词文件名（用户覆盖目录里同名文件即可 ✓） */
export const PROMPT_FILE_NAME = 'system.md'

/** 机制段的占位符（提示词文件里写这一行，加载时被替换 ✓） */
export const MECHANICS_PLACEHOLDER = '{{MECHANICS}}'

const here = path.dirname(fileURLToPath(import.meta.url))

/** ② 插件自带（lib/../prompt/system.md ✓） */
export const bundledPromptPath = path.resolve(here, '..', 'prompt', PROMPT_FILE_NAME)

/** ① 用户覆盖（主人放这儿就优先用它 ✓✓） */
export const overridePromptPath = path.join(
  os.homedir(), 'AppData', 'Roaming', 'Avorion', 'moddata', 'copilot', 'prompt', PROMPT_FILE_NAME,
)

/** 加载结果 */
export interface LoadedPrompt {
  /** 真正送给模型的提示词（占位符已替换 ✓） */
  text: string
  /** 实际来源：文件路径，或 '<built-in default>' */
  source: string
  /** 与上一次相比内容是否变了 ✓（变了就值得在流水里说一声 ✓） */
  changed: boolean
  /** 解析顺序里的两个候选路径（供文档/日志用 ✓） */
  paths: { override: string; bundled: string }
  /** 非致命问题（文件缺失/不可读/没写占位符 ✓）—— 调用方可以报一行 ✓ */
  notes: string[]
}

/** 让调用方（index.ts 的 live()）收到提示词相关的通知 ✓ —— 用回调避免循环 import ✓ */
let notifier: ((line: string) => void) | undefined
export function setPromptNotifier(fn: ((line: string) => void) | undefined): void {
  notifier = fn
}
function note(line: string): void {
  try { notifier?.(line) } catch { /* 通知失败绝不能影响决策 ✓ */ }
}

/** 每个路径一条缓存，键 = mtimeMs:size ✓（很便宜 ✓） */
const fileCache = new Map<string, { key: string; text: string }>()
/** 上一次"对模型生效"的内容指纹（变了才播报 ✓） */
let lastFingerprint: string | undefined

/** 内容指纹：长度 + 一个便宜的滚动哈希 ✓（只为判断"变了没" ✓） */
function fingerprint(s: string): string {
  let h = 0
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0
  return `${s.length}:${(h >>> 0).toString(16)}`
}

/** 把一个文件读成文本；读不到返回 undefined（**不抛异常** ✓） */
function readCached(file: string): { text: string; key: string } | undefined {
  try {
    const st = fs.statSync(file)
    if (!st.isFile()) return undefined
    const key = `${st.mtimeMs}:${st.size}`
    const hit = fileCache.get(file)
    if (hit !== undefined && hit.key === key) return hit
    const text = fs.readFileSync(file, 'utf8')
    fileCache.set(file, { key, text })
    return { key, text }
  } catch {
    return undefined
  }
}

/** 把机制段替换进占位符 ✓（没写占位符就只在 notes 里说一声 ✓ 不擅自拼接 ✗） */
export function applyMechanics(raw: string, notes: string[]): string {
  if (!raw.includes(MECHANICS_PLACEHOLDER)) {
    notes.push(`提示词里没有 ${MECHANICS_PLACEHOLDER} 占位符 —— 机制段不会被注入（副本会漂移 ✗）`)
    return raw
  }
  return raw.split(MECHANICS_PLACEHOLDER).join(MECHANICS_BRIEF)
}

/**
 * ★ 读提示词。顺序：用户覆盖 → 插件自带 → 内置兜底 ✓。
 * **任何失败都只会落到兜底**，绝不抛异常 ✓✓（提示词问题不许拖垮决策 ✗）。
 */
export function loadSystemPrompt(): LoadedPrompt {
  return loadPromptFrom({ override: overridePromptPath, bundled: bundledPromptPath })
}

/**
 * ★ 可测的核心：给定两个候选路径与兜底文本，按顺序解析 ✓
 * （测试就是靠它用临时目录验"覆盖优先 / 兜底不抛异常" ✓✓）
 */
export function loadPromptFrom(opts: {
  override: string
  bundled: string
  defaultText?: string
}): LoadedPrompt {
  const notes: string[] = []
  const paths = { override: opts.override, bundled: opts.bundled }
  let raw: string | undefined
  let source = '<built-in default>'

  const over = readCached(opts.override)
  if (over !== undefined) {
    raw = over.text
    source = opts.override
  } else {
    const bund = readCached(opts.bundled)
    if (bund !== undefined) {
      raw = bund.text
      source = opts.bundled
    }
  }
  if (raw === undefined) {
    notes.push(`提示词文件都读不到（找了 ${opts.override} 与 ${opts.bundled}）→ 用内置兜底 ✓`)
    raw = opts.defaultText ?? SYSTEM_PROMPT_DEFAULT
  }

  // 统一行尾 ✓（文件可能是 CRLF；判断"变了没"时才不会假阳性 ✓）
  const normalized = raw.replace(/\r\n/g, '\n')
  const text = applyMechanics(normalized, notes)

  const fp = fingerprint(text)
  const changed = lastFingerprint !== undefined && lastFingerprint !== fp
  if (changed) note(`  ├ 提示词已更新（${source === '<built-in default>' ? '内置兜底' : '文件'}）→ 本轮起生效（${text.length} 字符 ✓）`)
  lastFingerprint = fp

  for (const n of notes) note(`  ⚠ 提示词：${n}`)
  return { text, source, changed, paths, notes }
}

/** 首次加载时打印一次解析路径（人要知道改哪个文件 ✓） */
export function describePromptPaths(): string[] {
  return [
    `提示词解析顺序：① ${overridePromptPath}（用户覆盖，改它不用重启 ✓）`,
    `                 ② ${bundledPromptPath}（插件自带）`,
    '                 ③ 内置兜底常量（前两个都读不到时用 ✓）',
  ]
}

/** 给测试用：清掉缓存与"已播报"状态 ✓ */
export function resetPromptCache(): void {
  fileCache.clear()
  lastFingerprint = undefined
}
