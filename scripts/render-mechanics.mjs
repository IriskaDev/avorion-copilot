// 从 MECHANICS.md 的「浓缩版」段落重新生成 src/mechanics.ts ✓
// 用法: node scripts/render-mechanics.mjs [MECHANICS.md 路径]
// 默认路径可用环境变量 COPILOT_MECHANICS_MD 覆盖 ✓
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(here, '..')
const MD = process.argv[2]
  || process.env.COPILOT_MECHANICS_MD
  || 'D:/SteamLibrary/steamapps/common/Avorion/mods/copilot/MECHANICS.md'
const OUT = path.join(repoRoot, 'src/mechanics.ts')

export function extractBrief(mdText) {
  const begin = '<!-- BEGIN MECHANICS_BRIEF -->'
  const end = '<!-- END MECHANICS_BRIEF -->'
  const b = mdText.indexOf(begin)
  const e = mdText.indexOf(end)
  if (b < 0 || e < 0 || e < b) throw new Error('MECHANICS.md 里找不到 BRIEF 标记 ✗')
  return mdText.slice(b + begin.length, e).replace(/^\r?\n/, '').replace(/\s+$/, '')
}

export function renderTs(brief) {
  if (brief.includes('`') || brief.includes('${')) {
    throw new Error('BRIEF 里含反引号或 ${ —— 不能放进模板字符串 ✗')
  }
  return [
    '// ★ 本文件由 MECHANICS.md 的「浓缩版」段落生成 —— 不要手改 ✗',
    '//   单一来源: ' + MD.replace(/\\/g, '\\\\'),
    '//   重新生成: node scripts/render-mechanics.mjs ｜ 校验: node scripts/check-mechanics.mjs',
    'export const MECHANICS_BRIEF = `' + brief + '`',
    '',
  ].join('\n')
}

if (process.argv[1] && process.argv[1].endsWith('render-mechanics.mjs')) {
  if (!fs.existsSync(MD)) {
    console.error('✗ 找不到 MECHANICS.md: ' + MD)
    console.error('  （用参数或 COPILOT_MECHANICS_MD 指定路径 ✓）')
    process.exit(1)
  }
  const brief = extractBrief(fs.readFileSync(MD, 'utf8'))
  fs.writeFileSync(OUT, renderTs(brief), { encoding: 'utf8' })
  console.log('✓ 已生成 ' + path.relative(repoRoot, OUT) + '（' + brief.length + ' 字符 ✓）')
}
