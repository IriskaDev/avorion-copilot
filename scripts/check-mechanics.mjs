// 校验「文档 ↔ 提示词」没有漂移 ✓✓
//   · MECHANICS.md 的 BRIEF 段落  vs  src/mechanics.ts 的 MECHANICS_BRIEF
//   · 以及 SYSTEM_PROMPT 是否真的**引用了**它（而不是又抄了一份 ✗）
// 用法: node scripts/check-mechanics.mjs [MECHANICS.md 路径]
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { extractBrief } from './render-mechanics.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(here, '..')
const MD = process.argv[2]
  || process.env.COPILOT_MECHANICS_MD
  || 'D:/SteamLibrary/steamapps/common/Avorion/mods/copilot/MECHANICS.md'
const TS = path.join(repoRoot, 'src/mechanics.ts')
const INDEX = path.join(repoRoot, 'src/index.ts')

const fail = (m) => { console.error('✗ ' + m); process.exitCode = 1 }

if (!fs.existsSync(MD)) {
  console.error('✗ 找不到 MECHANICS.md: ' + MD)
  console.error('  （这是**权威来源**；用参数或 COPILOT_MECHANICS_MD 指定路径 ✓）')
  process.exit(1)
}
if (!fs.existsSync(TS)) fail('找不到 src/mechanics.ts（先跑 render-mechanics.mjs ✓）')

const want = extractBrief(fs.readFileSync(MD, 'utf8'))
const tsText = fs.readFileSync(TS, 'utf8')
const m = tsText.match(/export const MECHANICS_BRIEF = `([\s\S]*?)`\s*$/m)
if (!m) fail('src/mechanics.ts 里读不出一条 export const MECHANICS_BRIEF = `...`')
const got = (m ? m[1] : '').replace(/\s+$/, '')

const norm = (s) => s.replace(/\r\n/g, '\n').replace(/[ \t]+$/gm, '').replace(/\n{3,}/g, '\n\n').trim()
if (norm(want) !== norm(got)) {
  fail('文档与提示词**不一致** ✗（跑 node scripts/render-mechanics.mjs 重新生成 ✓）')
  console.error('  文档: ' + want.length + ' 字符 / mechanics.ts: ' + got.length + ' 字符')
} else {
  console.log('✓ MECHANICS.md ↔ src/mechanics.ts 一致（' + want.length + ' 字符 ✓）')
}

// SYSTEM_PROMPT 必须引用 MECHANICS_BRIEF（单一来源），而不是自己再抄一遍机制 ✗
const idx = fs.readFileSync(INDEX, 'utf8')
if (!idx.includes('MECHANICS_BRIEF')) fail('src/index.ts 没有引用 MECHANICS_BRIEF ✗')
else console.log('✓ src/index.ts 引用了 MECHANICS_BRIEF ✓')

// 提示词里不应再出现"叫模型照抄"的指令 ✗
const bad = []
const lines = idx.split(/\r?\n/)
lines.forEach((l, i) => {
  if (!/lines\.push\(|const SYSTEM_PROMPT|\+=|\+ `/.test(l)) return   // 只看会进提示词的行 ✓
  // ★ 只抓"叫模型照办"的指令 ✓ —— 显式排除否定说法（"不是必须照抄" ✓ 是我们要的）
  if (/(?<!不是)必须照抄|照抄成|直接照抄|照它的 orderHint 下单|照 orderHint 抄/.test(l)) bad.push((i + 1) + ': ' + l.trim())
})
if (bad.length > 0) { fail('提示词里仍有"照抄"指令 ✗'); bad.forEach((b) => console.error('  ' + b)) }
else console.log('✓ 提示词里没有"叫模型照抄"的指令 ✓')

process.exit(process.exitCode ?? 0)
