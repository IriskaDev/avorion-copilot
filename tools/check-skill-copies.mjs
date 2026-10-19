// check-skill-copies.mjs —— 守住「技能副本」不漂移 ✓
//   .dsh/skills/<name>/SKILL.md          ← 运行时唯一被 DSH 扫描的那份（权威）
//   docs/game/ops/<name>-skill.md        ← 文档副本（夹在 BEGIN/END SKILL-COPY 标记之间）
//
// 用法:
//   node tools/check-skill-copies.mjs          校验；不一致 → exit 1 并指出首个差异行
//   node tools/check-skill-copies.mjs --sync   以 .dsh 那份为准，重写文档副本
import fs from 'node:fs'
import path from 'node:path'

const ROOT = path.resolve(process.argv[1], '../..')
const sync = process.argv.includes('--sync')
const BEGIN = '<!-- BEGIN SKILL-COPY -->'
const END = '<!-- END SKILL-COPY -->'

/** 技能名 → 文档副本（仓库相对，正斜杠） */
const PAIRS = [
  { skill: 'fleet-decision', copy: 'docs/game/ops/fleet-decision-skill.md' },
]

// ★ 两侧都做**整体 trim** ✓：BEGIN/END 标记必然带来一个换行（标记独占一行 ✓），
//   只 trim 尾部会让「标记独占一行」的排版永远判成不一致 ✗（--sync 写完立刻又报漂移 ✓）。
const norm = (s) => s.replace(/\r\n/g, '\n').replace(/^\s+/, '').replace(/\s+$/, '')
let bad = 0

for (const { skill, copy } of PAIRS) {
  const src = path.join(ROOT, '.dsh/skills', skill, 'SKILL.md')
  const dst = path.join(ROOT, copy)
  if (!fs.existsSync(src)) { console.error(`✗ 找不到技能源: .dsh/skills/${skill}/SKILL.md`); bad++; continue }
  if (!fs.existsSync(dst)) { console.error(`✗ 找不到文档副本: ${copy}`); bad++; continue }

  const skillText = norm(fs.readFileSync(src, 'utf8'))
  const copyText = fs.readFileSync(dst, 'utf8')
  const b = copyText.indexOf(BEGIN)
  const e = copyText.indexOf(END)
  if (b < 0 || e < 0 || e < b) {
    console.error(`✗ ${copy} 里找不到 ${BEGIN} / ${END} 标记`)
    bad++
    continue
  }
  const inner = norm(copyText.slice(b + BEGIN.length, e))

  if (inner === skillText) {
    console.log(`✓ ${skill}: ${copy} 与 .dsh 那份一致（${skillText.length} 字符）`)
    continue
  }

  if (sync) {
    const rebuilt = copyText.slice(0, b + BEGIN.length) + '\n' + skillText + '\n' + copyText.slice(e)
    fs.writeFileSync(dst, rebuilt, 'utf8')
    console.log(`✓ ${skill}: 已按 .dsh 那份重写副本（${skillText.length} 字符）`)
    continue
  }

  // 首个差异行（便于定位）
  const a = inner.split('\n')
  const c = skillText.split('\n')
  let i = 0
  while (i < Math.min(a.length, c.length) && a[i] === c[i]) i++
  console.error(`✗ ${skill}: 副本与 .dsh 那份**不一致** ✗（首个差异在第 ${i + 1} 行）`)
  console.error(`    .dsh : ${(c[i] ?? '<缺行>').trim()}`)
  console.error(`    副本 : ${(a[i] ?? '<缺行>').trim()}`)
  console.error('    修法: node tools/check-skill-copies.mjs --sync（以 .dsh 为准）')
  bad++
}

if (bad === 0) console.log('ALL SKILL COPIES IN SYNC ✓')
else process.exitCode = 1
