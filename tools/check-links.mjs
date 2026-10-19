// check-links.mjs —— 扫全部 markdown 的相对链接，报出目标不存在的（一次性校验工具，常驻可复用）
// 用法: node tools/check-links.mjs [--verbose]
//   退出码 0 = 全部可解析；1 = 有坏链（会逐条打印 文件:行 → 目标）
import fs from 'node:fs'
import path from 'node:path'

const ROOT = path.resolve(process.argv[1], '../..')
const verbose = process.argv.includes('--verbose')
const SKIP = /(^|[\\/])(node_modules|build|\.git|_evidence)([\\/]|$)/

const mds = []
function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (SKIP.test(p)) continue
    if (e.isDirectory()) walk(p)
    else if (e.name.endsWith('.md')) mds.push(p)
  }
}
walk(ROOT)

let total = 0
const broken = []
const LINK = /\[[^\]]*\]\(([^)]+)\)/g

for (const file of mds) {
  const rel = path.relative(ROOT, file).replace(/\\/g, '/')
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/)
  lines.forEach((line, i) => {
    let m
    while ((m = LINK.exec(line)) !== null) {
      let target = m[1].trim()
      if (/^(?:[a-z]+:)?\/\//i.test(target) || target.startsWith('#')) continue
      target = target.replace(/#.*$/, '').replace(/:\d+(?:-\d+)?$/, '')
      if (target === '') continue
      total++
      const rel1 = path.resolve(path.dirname(file), decodeURI(target))
      // 两种约定都接受：①相对本文件 ②相对仓库根（.dsh/skills 等卡片明说了用根相对 ✓）
      const rel2 = path.resolve(ROOT, decodeURI(target))
      if (!fs.existsSync(rel1) && !fs.existsSync(rel2)) broken.push(`${rel}:${i + 1}  ->  ${m[1]}`)
    }
  })
}

console.log(`检查 ${mds.length} 个 markdown 文件 / ${total} 条相对链接`)
if (verbose) for (const md of mds) console.log('  ' + path.relative(ROOT, md).replace(/\\/g, '/'))
if (broken.length === 0) {
  console.log('ALL LINKS OK ✓')
} else {
  console.log(`BROKEN ${broken.length} 条:`)
  for (const b of broken) console.log('  ✗ ' + b)
  process.exitCode = 1
}
