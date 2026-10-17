// 从 prompt/system.md 生成 src/prompt-default.ts（编译内置的兜底提示词）✓
//
// 为什么要生成 ✗：兜底提示词必须是**编译进 lib/** 的 ✓，否则文件全丢了就没得用 ✗。
// ★ 用 JSON 字符串而不是模板字符串 ✓✓ —— 这样**再也不会踩反引号/TEMPLATE 的坑** ✗
//   （历史教训：反引号两次把 SYSTEM_PROMPT 模板提前结束，TS 报 TS1005 ✗）。
//
// 用法: node scripts/render-prompt.mjs [prompt/system.md 路径]
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
export const repoRoot = path.resolve(here, '..')
export const SRC_MD = process.argv[2] || path.join(repoRoot, 'prompt', 'system.md')
export const OUT_TS = path.join(repoRoot, 'src', 'prompt-default.ts')

/** 统一行尾并去掉尾部空白 —— 校验与生成都用它，免得 CRLF 造成假阳性 ✓ */
export function normalise(s) {
  return s.replace(/\r\n/g, '\n').replace(/[ \t]+$/gm, '').replace(/\n{3,}/g, '\n\n')
}

export function renderTs(raw) {
  const body = normalise(raw)
  return [
    '// ★ 本文件由 prompt/system.md 生成 —— 不要手改 ✗',
    '//   它是**兜底**提示词：prompt/system.md（自带）与用户覆盖文件都读不到时才会用到 ✓。',
    '//   重新生成: node scripts/render-prompt.mjs ｜ 校验: node scripts/check-mechanics.mjs',
    '//   ★ 用 JSON 字符串（不用模板字符串）→ 正文里出现反引号也不会破坏编译 ✓✓',
    `export const SYSTEM_PROMPT_DEFAULT = ${JSON.stringify(body)}`,
    '',
  ].join('\n')
}

if (process.argv[1] && process.argv[1].endsWith('render-prompt.mjs')) {
  if (!fs.existsSync(SRC_MD)) {
    console.error('✗ 找不到提示词文件: ' + SRC_MD)
    process.exit(1)
  }
  const ts = renderTs(fs.readFileSync(SRC_MD, 'utf8'))
  fs.writeFileSync(OUT_TS, ts, { encoding: 'utf8' })
  console.log('✓ 已生成 ' + path.relative(repoRoot, OUT_TS) + '（' + fs.readFileSync(SRC_MD, 'utf8').length + ' 字符 ✓）')
}
