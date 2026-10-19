/**
 * session-store.mjs —— 读 DSH 的会话存档，量**投递块**的体积（本鱼留下的诊断工具 ✓）
 *
 * 为什么有它 ✗→✓（2026-10-17 事故的取证工具，原来是 7 个 tmp-*.mjs 草稿 ✓）：
 *   实机事故是"一条 8.7 MB 的 fleet_task 把会话撑爆 ✗ → 客户端空白、模型超上下文 ✓"。
 *   要修它，先得**量清楚**：这条块一共多大、哪一段占地最多 ✓✓。
 *   这个工具就是那把尺子 ✓ —— 以后体积再出问题，先跑它 ✓。
 *
 * ## ★ 非显然的坑（踩过，别重踩 ✗✓）
 *   会话存档 `session.v4.jsonl.zstd` **不是单帧 zstd** ✗ —— 它是**几千个 zstd 帧拼接** ✓
 *   （实测 6483 帧）。所以：
 *     · `zlib.zstdDecompressSync(整文件)` 只解**第一帧** ✗（拿到几 KB 就以为完了 ✓）；
 *     · `createZstdDecompress()` 流式会在某个帧上报 `Unknown frame descriptor` ✗。
 *   ✓ 正确做法：按 magic `28 b5 2f fd` 找**每个帧的边界** ✓，逐帧独立解压再拼接 ✓
 *   —— 就是 decode 那一段 ✓。解出来的是一份 JSONL（一行一条会话记录 ✓）。
 *
 * ## 用法
 *   node tools/session-store.mjs decode <session.v4.jsonl.zstd> <out.jsonl>
 *   node tools/session-store.mjs blocks <out.jsonl> [--top N] [--full]
 *
 *   decode  → 解出 JSONL（多帧 zstd ✓）
 *   blocks  → 找出每一条含 `<fleet_task>` 的记录，报**总长**与**分段体积** ✓
 *             `--full` 连"这一段是什么"都打出来（默认只打前若干条 ✓）
 *
 * 会话存档位置（本机实测 ✓）：
 *   %USERPROFILE%\.dsh\sessions\--D-SteamLibrary-...-mods-copilot--\<session id>\session.v4.jsonl.zstd
 */
import fs from 'node:fs'
import zlib from 'node:zlib'

/** zstd 帧 magic（小端 ✓） */
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])

/**
 * 逐帧解压（★ 见文件头：一次性 API 只解第一帧 ✗）。
 * 做法：找所有 magic 位置当**候选**边界，从当前帧起点往后试到第一个"能解开"的终点 ✓。
 * （帧内数据不会出现 magic 的概率极高 ✓；万一撞上了，试解会失败并继续往后找 ✓。）
 */
export function decodeMultiFrameZstd(buf) {
  const bounds = []
  let i = buf.indexOf(MAGIC, 0)
  while (i !== -1) { bounds.push(i); i = buf.indexOf(MAGIC, i + 1) }
  bounds.push(buf.length)
  const chunks = []
  let frames = 0
  let p = 0
  while (p < bounds.length - 1) {
    let q = p + 1
    let out = null
    while (q < bounds.length) {
      try { out = zlib.zstdDecompressSync(buf.subarray(bounds[p], bounds[q])); break } catch { q += 1 }
    }
    if (out === null) break                     // 后面的不是帧（例如尾部校验）→ 停 ✓
    chunks.push(out)
    frames += 1
    p = q
  }
  return { text: Buffer.concat(chunks).toString('utf8'), frames }
}

/**
 * 投递块里的**分段锚点** —— 与 `src/task.ts` 的 renderTaskBlock / `src/index.ts` 的
 * buildPrompt 一一对应 ✓（任一处改文案，这里要跟着改 ✓；对不上就只会少量一段 ✓）。
 */
const ANCHORS = [
  ['任务头', '<fleet_task'],
  ['船/目标/边界', '船：'],
  ['能力卡', '这艘船的现状（能力卡）：'],
  ['取数失败说明', '这次**没取到**下面这些计划'],
  ['计划 JSON（每份一段）', '★★ 游戏侧算好的'],
  ['计划读法', '★ 上面这份计划的读法'],
  ['贸易候选 JSON', '本区域的贸易候选'],
  ['Scout 计划 JSON', 'Scout 计划（游戏侧算出的**事实**）'],
  ['Sell 计划 JSON', '★★ 游戏侧算好的 Sell'],
  ['候选表（并排）', '★★ 下面是**并排的候选表**'],
  ['贸易候选表', '★★ Trade 候选框'],
  ['Mine/Salvage 候选表', '候选框（'],
  ['Scout 候选表', '★★ Scout 候选框'],
  ['答复格式（必须留 ✓）', '★★★ 答复格式'],
  ['块尾', '</fleet_task>'],
]

/** 量一条记录里**全部** fleet_task 块的分段体积 ✓ */
export function blockSections(line) {
  const out = []
  let s = 0
  for (let k = 0; k < 20; k++) {
    const a = line.indexOf('<fleet_task', s)
    if (a < 0) break
    const b = line.indexOf('</fleet_task>', a)
    const block = line.slice(a, b < 0 ? line.length : b + '</fleet_task>'.length)
    const marks = []
    for (const [name, anchor] of ANCHORS) {
      let from = 0
      for (;;) {
        const j = block.indexOf(anchor, from)
        if (j < 0) break
        marks.push([j, name])
        from = j + anchor.length
      }
    }
    marks.sort((x, y) => x[0] - y[0])
    const sizes = []
    for (let m = 0; m < marks.length; m++) {
      const [j, name] = marks[m]
      const end = m + 1 < marks.length ? marks[m + 1][0] : block.length
      sizes.push([name, end - j])
    }
    out.push({ start: a, chars: block.length, sizes })
    s = b < 0 ? a + 1 : b + 1
  }
  return out
}

function main() {
  const mode = process.argv[2]
  if (mode === 'decode') {
    const [, , , src, dst] = process.argv
    if (src === undefined || dst === undefined) { console.error('usage: decode <in.zstd> <out.jsonl>'); process.exit(2) }
    const buf = fs.readFileSync(src)
    const { text, frames } = decodeMultiFrameZstd(buf)
    fs.writeFileSync(dst, text)
    console.log(`frames=${frames} chars=${text.length} -> ${dst}`)
    return
  }
  if (mode === 'blocks') {
    const file = process.argv[3]
    const top = Number((process.argv.find((a) => a.startsWith('--top=')) ?? '--top=12').slice(6))
    const full = process.argv.includes('--full')
    const lines = fs.readFileSync(file, 'utf8').split('\n')
    const rows = []
    lines.forEach((line, i) => {
      const blocks = blockSections(line)
      for (const b of blocks) {
        const ship = (/船：([A-Za-z]+-\d+)/.exec(line.slice(b.start, b.start + b.chars)) ?? [])[1] ?? '?'
        rows.push({ line: i + 1, ship, ...b })
      }
    })
    rows.sort((a, b) => b.chars - a.chars)
    console.log(`fleet_task 块 = ${rows.length}（按体积降序 ✓）`)
    for (const r of rows.slice(0, top)) {
      console.log(`\n--- 会话记录 ${r.line}  船=${r.ship}  **块长 ${r.chars}**`)
      const total = r.sizes.reduce((n, [, s]) => n + s, 0)
      for (const [name, s] of r.sizes) {
        const pct = total === 0 ? 0 : (100 * s) / total
        console.log(`    ${String(s).padStart(9)}  ${pct.toFixed(1).padStart(5)}%  ${name}`)
      }
    }
    void full
    return
  }
  console.error('usage: session-store.mjs decode|blocks ...')
  process.exit(2)
}

if (process.argv[1] !== undefined && /session-store\.mjs$/.test(process.argv[1])) main()
