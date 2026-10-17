// 校验「文档 ↔ 提示词」没有漂移 ✓✓，并且**主人的原则没有被违反** ✓
//   · MECHANICS.md 的 BRIEF 段落  vs  src/mechanics.ts 的 MECHANICS_BRIEF
//   · prompt/system.md（提示词本体）vs  src/prompt-default.ts（编译兜底）
//   · 提示词里**不许有"叫模型照抄"的指令** ✗
//   · ★ 提示词里**不许有策略/时机建议** ✗✓ —— 主人原话：
//       「你只给她一个大目标，以及游戏当前的机制，让她自己判断」
//       「不要直接把这种具体的策略写出来」
// 用法: node scripts/check-mechanics.mjs [MECHANICS.md 路径]
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { extractBrief } from './render-mechanics.mjs'
import { normalise, repoRoot } from './render-prompt.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const MD = process.argv[2]
  || process.env.COPILOT_MECHANICS_MD
  || 'D:/SteamLibrary/steamapps/common/Avorion/mods/copilot/MECHANICS.md'
const TS = path.join(repoRoot, 'src/mechanics.ts')
const PROMPT_MD = path.join(repoRoot, 'prompt/system.md')
const PROMPT_TS = path.join(repoRoot, 'src/prompt-default.ts')
const SRC = path.join(repoRoot, 'src')

const fail = (m) => { console.error('✗ ' + m); process.exitCode = 1 }
const ok = (m) => console.log('✓ ' + m)

// ── ① 机制：MECHANICS.md ↔ src/mechanics.ts ────────────────────────────────
if (!fs.existsSync(MD)) {
  console.error('✗ 找不到 MECHANICS.md: ' + MD)
  console.error('  （这是**权威来源**；用参数或 COPILOT_MECHANICS_MD 指定路径 ✓）')
  process.exit(1)
}
const want = extractBrief(fs.readFileSync(MD, 'utf8'))
if (!fs.existsSync(TS)) fail('找不到 src/mechanics.ts（先跑 render-mechanics.mjs ✓）')
const tsText = fs.readFileSync(TS, 'utf8')
const m = tsText.match(/export const MECHANICS_BRIEF = `([\s\S]*?)`\s*$/m)
if (!m) fail('src/mechanics.ts 里读不出一条 export const MECHANICS_BRIEF = `...`')
const got = (m ? m[1] : '').replace(/\s+$/, '')
if (normalise(want) !== normalise(got)) {
  fail('机制文档与 mechanics.ts **不一致** ✗（跑 node scripts/render-mechanics.mjs ✓）')
  console.error('  文档: ' + want.length + ' 字符 / mechanics.ts: ' + got.length + ' 字符')
} else ok('MECHANICS.md ↔ src/mechanics.ts 一致（' + want.length + ' 字符）')

// ── ② 提示词文件 ↔ 编译兜底 ───────────────────────────────────────────────
if (!fs.existsSync(PROMPT_MD)) {
  fail('找不到 prompt/system.md ✗（提示词本体 ✓）')
} else {
  const md = fs.readFileSync(PROMPT_MD, 'utf8')
  if (!md.includes('{{MECHANICS}}')) fail('prompt/system.md 里没有 {{MECHANICS}} 占位符 ✗（机制段会漂移 ✗）')
  else ok('prompt/system.md 含 {{MECHANICS}} 占位符 ✓')

  if (!md.includes('大目标')) fail('prompt/system.md 里看不到「大目标」段 ✗（主人要求只给大目标+机制 ✓）')
  else ok('prompt/system.md 含「大目标」段 ✓')

  if (!fs.existsSync(PROMPT_TS)) fail('找不到 src/prompt-default.ts（先跑 render-prompt.mjs ✓）')
  else {
    const ts = fs.readFileSync(PROMPT_TS, 'utf8')
    const mm = ts.match(/export const SYSTEM_PROMPT_DEFAULT = ("(?:[^"\\]|\\.)*")\s*$/m)
    if (!mm) fail('src/prompt-default.ts 里读不出一条 export const SYSTEM_PROMPT_DEFAULT = "..."')
    else {
      const fallback = JSON.parse(mm[1])
      if (normalise(fallback) !== normalise(md)) {
        fail('prompt/system.md 与 src/prompt-default.ts **不一致** ✗（跑 node scripts/render-prompt.mjs ✓）')
        console.error('  文件: ' + md.length + ' 字符 / 兜底: ' + fallback.length + ' 字符')
      } else ok('prompt/system.md ↔ src/prompt-default.ts 一致（' + md.length + ' 字符）')
    }
  }

  // ── ③ 不许"叫模型照抄" ✗ ──────────────────────────────────────────────
  const indexTs = fs.existsSync(path.join(SRC, 'index.ts')) ? fs.readFileSync(path.join(SRC, 'index.ts'), 'utf8') : ''
  const copyOffenders = []
  for (const [label, text] of [['prompt/system.md', md], ['src/index.ts', indexTs]]) {
    text.split(/\r?\n/).forEach((l, i) => {
      // 显式排除否定说法（"不是必须照抄" ✓ 是我们要的 ✓）
      if (/(?<!不是)必须照抄|照抄成|直接照抄|照它的 orderHint 下单|照 orderHint 抄/.test(l)) {
        copyOffenders.push(`${label}:${i + 1}: ${l.trim()}`)
      }
    })
  }
  if (copyOffenders.length > 0) { fail('提示词里仍有"照抄"指令 ✗'); copyOffenders.forEach((b) => console.error('  ' + b)) }
  else ok('提示词里没有"叫模型照抄"的指令 ✓')

  // ── ④ ★ 策略措辞：**只有标了「参考策略」的段落里才允许** ✓✓ ─────────────────
  //   2026-10-17 主人把口径**细化**（不是放弃 ✗）：
  //     · 「硬约束」= 玩家下的规矩（风险闸门、safeMode 规矩 ✓）—— 不是建议 ✓；
  //     · 「参考策略」= 主人自己的偏好/经验（例如 Scout 的"尽量侦察未发现的地方"✓）——
  //       **只允许**出现在**明确标注**的段里，而且那段必须写明
  //       「供参考 / 不是硬规则 / 具体由你自己判断」✓✓；
  //     · **别处**出现策略措辞 → 一律**大声失败** ✗（防止有人偷偷把建议塞进事实段 ✓）。
  //   → 本检查就是干这三件事 ✓（删规则、或改措辞躲检查 ✗ 都不允许 ✓）。
  const STRATEGY_PATTERNS = [
    /原地继续干活/,
    /往往更好/,
    /不要硬下单/,
    /通常是 action=None/,
    /正确的回答/,
    /建议你先/,
    /你应该先/,
    /最好先/,
    /优先(?:考虑)?往里/,
    /应该转移/,
    /先转移位置/,
  ]
  const REF_HEAD = /^\s*(?:>\s*)?\**\s*(?:★+\s*)?\**参考策略\**/
  const REF_END = /^\s*(?:>\s*)?\**\s*(?:★+\s*)?\**(?:每次都值得|先输出|判断依据|游戏机制|大目标)/
  const NOT_BINDING = /不是硬规则|不是必须遵守|不是指令|由你自己判断|由你判断|供.?参考|参考策略/
  const lines = md.split(/\r?\n/)
  let refStart = -1, refEnd = -1
  for (let i = 0; i < lines.length; i++) {
    if (refStart < 0 && REF_HEAD.test(lines[i])) refStart = i
    else if (refStart >= 0 && refEnd < 0 && REF_END.test(lines[i])) refEnd = i
  }
  if (refStart < 0) {
    // ★ 缺失也要**明说** ✓ —— 主人点名要这一段（参考策略块）✓；
    //   没有它并不算"漂移"，但会在输出里标出来 ✓（下面 ④ 的宽松豁免也就不生效 ✓）。
    console.log('· 提示词里没有「参考策略」段落（主人给的参考偏好无处安放 ✓ —— 现在没有也不算错 ✓）')
  } else {
    const endIdx = refEnd >= 0 ? refEnd : lines.length
    const body = lines.slice(refStart, endIdx).join('\n')
    if (!NOT_BINDING.test(body)) {
      fail('「参考策略」段落里**没有**"不具约束力 / 由你自己判断 / 供参考"的说明 ✗✓ ' +
        `（第 ${refStart + 1}-${endIdx} 行）—— 主人要求：参考策略必须**明说**它不是硬规则 ✓`)
    } else {
      ok(`「参考策略」段落存在且写明了"不具约束力、由你自己判断" ✓（第 ${refStart + 1}-${endIdx} 行，` +
        `${endIdx - refStart} 行）`)
    }
  }

  const inRef = (lineNo) => refStart >= 0 && lineNo > refStart && (refEnd < 0 || lineNo <= refEnd)
  const strategyOffenders = []
  md.split(/\r?\n/).forEach((l, i) => {
    // ★★ 玩家约束豁免（2026-10-17 ✓）：
    //   主人亲口下的规矩（「安全」的定义 = 伏击概率 <10% ✓、safeMode 一般不要开 ✓、
    //   禁止"缺数据就先开 safeMode"这条推理 ✗）在**形状上**是 when→then ✗✓，
    //   但它们是**玩家下发的约束** ✓，与风险闸门同级 ✓ —— 不是模型该自己判断的策略 ✗。
    //   → 带「玩家 / 主人」字样的行视为**约束** ✓，跳过策略措辞检查 ✓。
    //   ★ 这是**豁免约束**，不是放宽原则 ✗：删规则、或把规则改写成不被识别的措辞，都不允许 ✗。
    if (/玩家|主人/.test(l)) return
    // ★★ 参考策略段落**整体豁免** ✓✓（主人 2026-10-17 明确要求 ✓）——
    //   但**只有**那一段豁免 ✗：别处一律照查 ✓（见上 ✓）。
    if (inRef(i + 1)) return
    for (const re of STRATEGY_PATTERNS) {
      if (re.test(l)) { strategyOffenders.push(`${i + 1}: ${l.trim()}  ← 命中 ${String(re)}`); break }
    }
  })
  if (strategyOffenders.length > 0) {
    fail('提示词里出现了**未标注来源的策略/时机建议** ✗（主人要求：只给大目标 + 机制 + 事实；' +
      '真要写参考策略，就必须放进标了「参考策略」并写明"不具约束力、由你自己判断"的段落里 ✓）')
    strategyOffenders.forEach((b) => console.error('  ' + b))
  } else ok('提示词里没有**未标注**的策略/时机建议 ✓（事实段干净 ✓）')
}

// ── ⑤ 机制段仍然只有一处来源 ✓ ───────────────────────────────────────────
let referenced = false
const walk = (dir) => {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) walk(p)
    else if (e.name.endsWith('.ts') && fs.readFileSync(p, 'utf8').includes('MECHANICS_BRIEF')) referenced = true
  }
}
if (fs.existsSync(SRC)) walk(SRC)
if (!referenced) fail('src/ 里没有任何文件引用 MECHANICS_BRIEF ✗（机制段必须来自单一来源 ✓）')
else ok('src/ 里有文件引用 MECHANICS_BRIEF ✓（机制段单一来源 ✓）')

process.exit(process.exitCode ?? 0)
