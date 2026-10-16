// ★ 提示词运行时读取的离线自测（2026-10-17 ✓）
//   验的是主人要求的那件事：「prompt 搞成单独文件，程序运行时读取」✓
//
// 用法: node test/prompt-file.mjs        （先在插件根跑一次 scripts/build.ps1 ✓）
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import assert from 'node:assert/strict'
import { loadPromptFrom, resetPromptCache, MECHANICS_PLACEHOLDER } from '../lib/promptfile.js'

let n = 0, bad = 0
const check = (name, fn) => {
  n++
  try { fn(); console.log('  ✓ ' + name) }
  catch (e) { bad++; console.log('  ✗ ' + name + '  →  ' + (e && e.message)) }
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-prompt-'))
const bundled = path.join(tmp, 'bundled.md')
const override = path.join(tmp, 'override.md')
const missingDir = path.join(tmp, 'nope')
const missing = path.join(missingDir, 'system.md')

const bundledText = '自带提示词\n\n机制：\n{{MECHANICS}}\n\n请从事实出发，自己判断。\n'
fs.writeFileSync(bundled, bundledText, 'utf8')

const load = () => loadPromptFrom({ override, bundled, defaultText: '【编译兜底】' })

console.log('=== 提示词文件运行时读取 ✓ ===')

// ① 只用自带文件：读得到，且占位符被机制段替换 ✓
resetPromptCache()
const r1 = load()
check('① 读得到自带文件', () => assert.ok(r1.text.includes('自带提示词')))
check('① 来源 = 自带文件路径', () => assert.equal(r1.source, bundled))
check('① {{MECHANICS}} 已被替换（含机制段特征词）', () => {
  assert.ok(!r1.text.includes(MECHANICS_PLACEHOLDER), '占位符还在 ✗')
  assert.ok(r1.text.includes('revealsOffgrid'), '机制段没进来 ✗')
})
check('① 没有 notes（一切正常 ✓）', () => assert.equal(r1.notes.length, 0))

// ② 有覆盖文件 → 覆盖优先 ✓✓
fs.writeFileSync(override, '覆盖提示词 A\n{{MECHANICS}}\n', 'utf8')
resetPromptCache()
const r2 = load()
check('② 覆盖文件优先', () => {
  assert.equal(r2.source, override)
  assert.ok(r2.text.includes('覆盖提示词 A'))
  assert.ok(!r2.text.includes('自带提示词'))
})

// ③ 改文件 → 下一次读**立刻拿到新内容**（不用重启 DSH ✓✓）
fs.writeFileSync(override, '覆盖提示词 B —— 改过了，而且长度不同\n{{MECHANICS}}\n', 'utf8')
const r3 = load()
check('③ 改完重新读就是新内容 ✓', () => assert.ok(r3.text.includes('覆盖提示词 B')))
check('③ 内容变了要报 changed=true（好让流水说一声 ✓）', () => assert.equal(r3.changed, true))

// ④ 同内容再读一次 → 不该反复报"已更新" ✓
const r4 = load()
check('④ 内容没变则 changed=false', () => assert.equal(r4.changed, false))

// ⑤ 两个文件都没有 → **不抛异常**，退回兜底 ✓✓
resetPromptCache()
const r5 = loadPromptFrom({ override: missing, bundled: path.join(missingDir, 'also-missing.md'), defaultText: '【编译兜底】' })
check('⑤ 文件全缺 → 用兜底且不抛异常', () => {
  assert.ok(r5.text.includes('【编译兜底】'))
  assert.equal(r5.source, '<built-in default>')
  assert.ok(r5.notes.length > 0, '应当记一条 note ✓')
})

// ⑥ 文件里没写占位符 → 只提醒，不擅自拼接 ✓
fs.writeFileSync(bundled, '没有占位符的提示词\n', 'utf8')
resetPromptCache()
const r6 = loadPromptFrom({ override: missing, bundled, defaultText: '【兜底】' })
check('⑥ 缺占位符 → 有 note、且不硬塞机制段', () => {
  assert.ok(r6.notes.some((s) => s.includes(MECHANICS_PLACEHOLDER)))
  assert.ok(!r6.text.includes('revealsOffgrid'))
})

// ⑦ 编译兜底确实是"prompt/system.md 的副本"（长度对得上 ✓）
import { SYSTEM_PROMPT_DEFAULT } from '../lib/prompt-default.js'
check('⑦ 编译兜底非空且含大目标 + 占位符（供替换 ✓）', () => {
  assert.ok(SYSTEM_PROMPT_DEFAULT.length > 500)
  assert.ok(SYSTEM_PROMPT_DEFAULT.includes('大目标'))
  assert.ok(SYSTEM_PROMPT_DEFAULT.includes(MECHANICS_PLACEHOLDER))
})

fs.rmSync(tmp, { recursive: true, force: true })

console.log('')
console.log(`== 共 ${n} 项断言，失败 ${bad} 项 ==`)
if (bad > 0) { console.log('promptFileSelfTest: FAILED'); process.exit(1) }
console.log('promptFileSelfTest: OK')
