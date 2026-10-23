/**
 * what-whitelist.mjs —— ★ 接口白名单的**静态断言**（2026-10-24 加 ✓✓）
 *
 * 起因（主人原话，逐字）：「注意不要再加之前那种超高消耗的操作了」✓✓
 * 这条要求**不许只兑现一次** ✗ —— 于是把它变成会自己红的机制 ✓：
 *
 *   唯一真相 = `docs/dev/interface-whitelist.txt`（`[atomic]` / `[legacy]` / `[deprecated]`）
 *   本文件扫 `plugin/dsh/src/*.ts` 里**所有** `what:` 字面量（代码与注释都算 ✓）：
 *
 *     ① 每个字面量必须在 `[atomic]` 里 ✓
 *     ② 出现 `[legacy]` / `[deprecated]` 名 → **红** ✗（插件不许再点名那批自扫描接口）
 *     ③ 任何名字含 `plan`（不分大小写）→ **红** ✗（名单外的 Plan 也不许 ✗✓）
 *     ④ 名单三节都非空 + 至少扫到 MIN_LITERALS 个字面量（防正则失效变成永远绿 ✗）
 *     ⑤ 三节之间不许有交集（一份名字只能有一个身份 ✓）
 *
 * ★ 游戏侧的对应断言在 `native/harness/_what_whitelist_selftest.lua`（扫 link_in.lua 的分支 ✓）。
 * ★ 规矩文档：`docs/dev/interface-atomicity.md` §★★★ 性能硬闸 ✓。
 *
 * 跑法（在 plugin/dsh 下）：node test/what-whitelist.mjs
 * 退出码：0 = 全绿；1 = 有违例。
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '../../..')            // plugin/dsh/test -> 仓库根 ✓
const WHITELIST_PATH = path.join(ROOT, 'docs/dev/interface-whitelist.txt')
const SRC_DIR = path.join(ROOT, 'plugin/dsh/src')

/** 至少该扫到这么多个 what 字面量（现在 ≈ 16 处；小于这个数 = 正则/路径失效 ✗） */
const MIN_LITERALS = 8

const checks = []
function check(label, pass, actual) {
  checks.push({ label, pass: pass === true, actual })
}

// ---------------------------------------------------------------------------
// ① 名单（唯一真相）
// ---------------------------------------------------------------------------

function parseWhitelist(text) {
  const sets = { atomic: new Set(), legacy: new Set(), deprecated: new Set() }
  let section = null
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, '').trim()
    if (line === '') continue
    const header = line.match(/^\[(\w+)\]$/)
    if (header !== null) {
      section = header[1]
      continue
    }
    if (section === null || sets[section] === undefined) continue
    sets[section].add(line)
  }
  return sets
}

check('名单文件存在（docs/dev/interface-whitelist.txt ✓）', fs.existsSync(WHITELIST_PATH), WHITELIST_PATH)
if (!fs.existsSync(WHITELIST_PATH)) {
  report()
  process.exit(1)
}

const white = parseWhitelist(fs.readFileSync(WHITELIST_PATH, 'utf8'))
check('① [atomic] 非空（≥15 个原子 ✓）', white.atomic.size >= 15, white.atomic.size)
check('① [legacy] 非空（声明了 legacy 集合 ✓）', white.legacy.size > 0, white.legacy.size)
check('① [deprecated] 非空（orderSchema ✓）', white.deprecated.size > 0, white.deprecated.size)

// ⑤ 三节不许有交集
const overlap = []
for (const name of white.atomic) {
  if (white.legacy.has(name) || white.deprecated.has(name)) overlap.push(name)
}
for (const name of white.legacy) {
  if (white.deprecated.has(name)) overlap.push(name)
}
check('⑤ 三节没有交集（一个名字只能有一个身份 ✓）', overlap.length === 0, overlap.join(','))

// ---------------------------------------------------------------------------
// ② 扫 src/*.ts 的 what: 字面量
// ---------------------------------------------------------------------------

function lineAt(text, index) {
  let line = 1
  for (let i = 0; i < index; i++) if (text.charCodeAt(i) === 10) line++
  return line
}

const LITERAL = /what\s*:\s*(['"`])([A-Za-z0-9_]+)\1/g
const hits = []
if (fs.existsSync(SRC_DIR)) {
  for (const entry of fs.readdirSync(SRC_DIR, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith('.ts')) continue
    const file = path.join(SRC_DIR, entry.name)
    const text = fs.readFileSync(file, 'utf8')
    let m
    while ((m = LITERAL.exec(text)) !== null) {
      hits.push({ name: m[2], where: `${entry.name}:${lineAt(text, m.index)}` })
    }
  }
}

check(`② 扫到 ≥${MIN_LITERALS} 个 what 字面量（防正则失效 ✓）`, hits.length >= MIN_LITERALS, hits.length)

const unknown = hits.filter((h) => !white.atomic.has(h.name))
check('② ★ src 里每个 what 字面量都在 [atomic] 白名单里 ✓',
  unknown.length === 0, unknown.map((h) => `${h.where} what:${h.name}`).join(' | '))

const legacyHit = hits.filter((h) => white.legacy.has(h.name) || white.deprecated.has(h.name))
check('③ ★ src 里没有 legacy / deprecated 的 what（出现即红 ✗）',
  legacyHit.length === 0, legacyHit.map((h) => `${h.where} what:${h.name}`).join(' | '))

const planHit = hits.filter((h) => /plan/i.test(h.name))
check('③ ★ src 里没有任何名字含 plan 的 what（比名单更硬 ✓）',
  planHit.length === 0, planHit.map((h) => `${h.where} what:${h.name}`).join(' | '))

// ---------------------------------------------------------------------------

function report() {
  let failed = 0
  for (const c of checks) {
    if (!c.pass) failed++
    console.log(`${c.pass ? '  ✓' : '  ✗'} ${c.label}` + (c.pass ? '' : `   ← 实际 ${JSON.stringify(c.actual)}`))
  }
  console.log(`\n${checks.length - failed}/${checks.length} 通过`)
  if (failed > 0) process.exitCode = 1
}

// 扫到的名字（诊断用，不让它把输出顶爆 ✓）
const names = [...new Set(hits.map((h) => h.name))].sort()
console.log(`\n扫到 ${hits.length} 处 what 字面量：${names.join(', ')}`)
report()
