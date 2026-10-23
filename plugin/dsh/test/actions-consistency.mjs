#!/usr/bin/env node
// ★ 跨仓库一致性测试（2026-10-17 新增 ✓）
//
// 为什么要有它 ✗→✓：pro 审查抓到 `Scout` / `Sell` 在**提示词里能选**，
// 却在解析器与默认白名单之外 ✗ —— 于是"计划算得出来、永远下不了单" ✓✓。
// 同类：tradePlan 算好了 deposit ✓ 却没人转发 ✗。
//
// 这个测试**不跑游戏、不跑构建** ✓，只做静态交叉核对 ✓，
// 让"三处列表必须一致"和"字段必须真的被转发"变成**可执行的断言** ✓✓。
//
// 跑法：node test/actions-consistency.mjs   → 失败时 exit 1 ✓

import { readFileSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const plg = join(here, '..')
const mod = 'D:/SteamLibrary/steamapps/common/Avorion/mods/copilot'

const failures = []
const checks = []
function check(name, ok, detail) {
  checks.push({ name, ok, detail })
  if (!ok) failures.push(`${name}${detail ? ' — ' + detail : ''}`)
}

// ── ① 单一来源：src/index.ts 的 ALL_ACTIONS ✓
const idx = readFileSync(join(plg, 'src', 'index.ts'), 'utf8')
const dossier = readFileSync(join(plg, 'src', 'dossier.ts'), 'utf8')
const m = /export const ALL_ACTIONS = \[([^\]]+)\]/.exec(idx)
check('src/index.ts 定义了 ALL_ACTIONS', m !== null)
const allActions = m ? m[1].split(',').map((s) => s.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean) : []
check('ALL_ACTIONS 非空', allActions.length > 0, allActions.join(','))

// ── ② 提示词广告的动作集合 == ALL_ACTIONS + None ✓✓（缺陷 #9/#10 的核心）
//   ★ 提示词瘦身后动作清单不再是独立行，而是 action=（Mine / … / None 之一）✓
const promptPath = join(plg, 'prompt', 'system.md')
const prompt = existsSync(promptPath) ? readFileSync(promptPath, 'utf8') : ''
const pm = /action=（([^）]+)）/u.exec(prompt)
check('prompt/system.md 有 action=（...）动作清单', pm !== null)
const advertised = pm
  ? pm[1]
      .replace(/之一.*$/, '')       // 去掉"之一"这类说明 ✓
      .split('/')
      .map((s) => s.trim())
      .filter(Boolean)
  : []
const setEq = (a, b) => a.length === b.length && [...a].sort().join(',') === [...b].sort().join(',')
const allWithNone = [...allActions, 'None']
check(
  '提示词广告的动作 == ALL_ACTIONS + None',
  setEq(advertised, allWithNone),
  `prompt=[${advertised.join(',')}] ALL_ACTIONS+None=[${allWithNone.join(',')}]`,
)

// ── ③ 解析器与白名单都从 ALL_ACTIONS 派生（不许再出现写死的字面量 ✗）✓
check(
  '解析器的 known 由 ALL_ACTIONS 派生',
  /const known = \[\.\.\.ALL_ACTIONS, 'None'\]/.test(idx),
)
check(
  "toAnswer 的默认白名单由 ALL_ACTIONS 派生",
  /f\.goalOptions\.length > 0 \? f\.goalOptions : \[\.\.\.ALL_ACTIONS\]/.test(idx),
)
check(
  'src/index.ts 里没有残留的写死四动作列表 ✗',
  !/\['Mine', 'Salvage', 'Trade', 'Travel'\]/.test(idx),
)

// ── ④ 游戏侧 onOrder 真的接受这些动作 ✓✓（否则提示词再对也下不了单 ✗）
const linkIn = join(mod, 'data', 'scripts', 'net', 'link_in.lua')
check('找得到游戏侧 link_in.lua', existsSync(linkIn))
const lua = existsSync(linkIn) ? readFileSync(linkIn, 'utf8') : ''
for (const a of allActions) {
  // COMMAND_TYPES 里以 `Name = "<uuid>"` 形式登记 ✓
  const re = new RegExp(`\\b${a}\\s*=\\s*"[0-9a-f-]{36}"`)
  check(`游戏侧 COMMAND_TYPES 认识 ${a}`, re.test(lua))
}

// ── ⑤ deposit 必须真的被转发（缺陷 #11 ✓）
check('Decision 有 deposit 字段', /deposit\?: number/.test(idx))
check('解析器读 deposit', /const deposit = field\(text, 'deposit'\)/.test(idx))
check('toAnswer 转发 deposit', /params\.deposit = decision\.deposit/.test(idx))
// ★ 提示词瘦身后字段不再是逐行 deposit=，而是一行列出全部字段名 ✓ → 断言"清单完整"
const fieldLine = /写字段：([^；]*)/.exec(prompt)?.[1] ?? ''
const fieldNames = fieldLine.split('/').map((s) => s.trim().replace(/=$/, '')).filter(Boolean)
const WANT_FIELDS = ['x', 'y', 'sizeX', 'sizeY', 'duration', 'goodName', 'deposit', 'safeMode', 'escorts', 'goodsToSell', 'reason']
check(
  '提示词广告的字段名清单完整（含 deposit/escorts/goodsToSell）',
  setEq(fieldNames, WANT_FIELDS),
  `prompt=[${fieldNames.join(',')}] want=[${WANT_FIELDS.join(',')}]`,
)

// ── ⑥ 风险判定必须活到模型眼前（缺陷 #6 ✓）
//   ★★ 2026-10-24：`compactJobPlan` **已删除** ✗✓（legacy jobPlan 预取不再存在 ✓ ——
//     主人原话：「去掉吧，是旧的那套 JOB 之前直接扫区域，而非你去决策扫是吧」）。
//     所以这条断言换成**现在还活着的两个出口** ✓：
//       (a) 游戏侧**原子** `predict` 的回包仍带闸门三件套 ✓（≤24 框、调用方点名 ✓）；
//       (b) 单发档案的候选行仍印「基准风险 / 本次概率」✓（两条概率都要看得见 ✓）。
check('原子 predict 回包仍带 riskLimit', /resp\.riskLimit = gate/.test(lua))
check(
  '原子 predict 的候选行仍带 exceedsRiskLimit 说明',
  /exceedsRiskLimit=true 的候选/.test(lua),
)
check('单发档案的候选行仍印「基准风险」', /基准风险\$\{pct\(r\.baseAttackChance\)\}/.test(dossier))
check('单发档案的候选行仍印「本次概率」', /本次概率\$\{pct\(r\.attackChance\)\}/.test(dossier))

// ── ⑦ 我们自造的经验系数必须被标注为估计，且原版数字优先 ✓
check('ESCORT_RISK_FACTOR 有"估计"标注', /我们自己的估计/.test(idx))
check('优先用原版 attackChanceWithEscorts', /best\.withEscorts \?\?/.test(idx))

// ── ⑧ ★★ RPC 返回值契约（2026-10-17 实测血案 ✓✓）
//   游戏侧 query 分支必须写成 `return true, <payload>` ✓ —— RPC 契约是 (ok, payload, why) ✓。
//   六个计划分支曾是 `return CopilotLinkIn.informOnly(...)` ✗（只有一个返回值 ✓）
//   → ok=那个表（真值）而 payload=nil ✗ → DSH 收到空载荷 {} ✗✓ → 模型**完全没计划数据**
//   却以为「没有候选」✗✓ 并开始瞎猜 ✓✓。这条断言让那种写法**再也进不了仓库** ✓。
//
//   ★★ 2026-10-17 重构后（体积改动 ✓）：六个计划分支**收成一个出口** `planQuery` ✓
//      —— 契约断言跟着换成"那个出口仍然显式接三个返回值" ✓（语义一模一样 ✓，
//      只是不再有六份重复 ✓；而"六个分支各自写对"这件事**再也不需要人来守** ✗✓）。
{
  // (a) 任何地方都不许出现 `return informOnly(...)` 这种**单返回值**写法 ✗
  //     （`return true, informOnly(...)` 是合法的 ✓ —— 所以只禁"直接 return 它" ✓）
  const bare = [...lua.matchAll(/return\s+(CopilotLinkIn\.informOnly\s*\()/g)].length
  check('没有任何"单返回值 informOnly"写法 ✓', bare === 0, `仍单返回值 ${bare} 处 ✗`)

  // (b) 计划出口必须**显式接三个返回值**（血案的写法就是漏了这个 ✓）。
  //     ★ 写法是"先声明、再在分支里赋 (ok, payload, why)"✓ —— 所以要断言
  //       **三返回值赋法真的存在** ✓，别去猜某个具体的 `local a, b, c =` 形状 ✗。
  const takes3 = /\bok,\s*payload,\s*why\s*=\s*CopilotLinkIn\.(tradePlan|jobPlan|sellPlan|scoutPlan)\s*\(/.test(lua)
  check('计划出口显式接 (ok, payload, why) ✓', takes3, 'planQuery 里没找到三返回值接法 ✗')
  const wraps = /payload\s*=\s*CopilotLinkIn\.informOnly\s*\(\s*payload,\s*data\s*\)/.test(lua)
  check('计划出口仍然调用 informOnly 包装（不是把它删了 ✓）', wraps, '没找到 informOnly 包装 ✗')

  // (c) ★ 六个计划**都**走同一个出口 ✓（"加一层处理要改六处"这个坑不可能再出现 ✓）
  const dispatch = [...lua.matchAll(/return\s+CopilotLinkIn\.planQuery\s*\(/g)].length
  check('六个计划分支都走同一个出口 planQuery ✓', dispatch >= 6, `只找到 ${dispatch} 处 ✓`)
  // (d) 六个 what 名一个都没少 ✓
  for (const w of ['tradePlan', 'minePlan', 'salvagePlan', 'jobPlan', 'sellPlan', 'scoutPlan']) {
    check(`query 分支仍在：${w} ✓`, new RegExp(`what\\s*==\\s*"${w}"`).test(lua), '')
  }
}

// ── ⑨ 零候选必须自带机器可读的原因（否则模型自己编 ✗✓）
check('informOnly 提供 noCandidatesReason', /noCandidatesReason\s*=/.test(lua))
check(
  '零候选原因区分"没设备"/"不知道"/"真没有"',
  /NO_TOOL_FOR_THIS_JOB/.test(lua) && /UNKNOWN_NO_CAPABILITY/.test(lua) && /NO_ACCEPTABLE_CANDIDATE/.test(lua),
)

// ── ⑩ 插件侧：「没取到」必须与「没有候选」分开 ✓✓
check('DecideFacts 有 planFetchFailures', /planFetchFailures\?/.test(idx))
//   ★★ 2026-10-24：`emptyPayload` 那段随 legacy 计划预取一起删了 ✗✓ ——
//     换成这次主人点名的新不变量 ✓✓：**插件侧一个 legacy 计划都不许再向游戏要** ✗
//     （它们全在游戏主循环里同步扫 67~71 个区域并自排序 ✓；要数据请用原子接口 ✓）。
{
  const LEGACY = ['tradePlan', 'minePlan', 'salvagePlan', 'sellPlan', 'scoutPlan', 'jobPlan']
  const asked = LEGACY.filter((w) => new RegExp(`what:\\s*'${w}'`).test(idx))
  check('插件侧不再请求任何 legacy 计划（★ 2026-10-24 ✓）', asked.length === 0, `仍在请求: ${asked.join(',')}`)
  // 单发兜底的档案里 plans 必须是**空数组** ✓（不是"没写"、更不是偷偷翻旧计划 ✗）
  check('dossierInputOf 的 plans 是空数组', /plans:\s*\[\]\s*as\s*unknown\[\]/.test(idx))
  // 那句"没有计划"必须**明说**给模型 ✓（沉默会被读成"没有候选" ✗✓）
  check('单发档案明说「无计划（已移除预扫描）」', /无计划（已移除预扫描）/.test(dossier))
}
check('提示词里明说"没取到 ≠ 没有候选"', /并不代表那里没有候选/.test(dossier))
check('取失败会重试一次', /重试一次/.test(idx))

// 输出
for (const c of checks) {
  console.log(`${c.ok ? '  ✓' : '  ✗'} ${c.name}${c.ok || !c.detail ? '' : '  → ' + c.detail}`)
}
console.log('')
if (failures.length === 0) {
  console.log(`actionsConsistency: OK（${checks.length} 项断言，失败 0 项）`)
  process.exit(0)
}
console.log(`actionsConsistency: FAILED（${checks.length} 项断言，失败 ${failures.length} 项）`)
for (const f of failures) console.log('  ✗ ' + f)
process.exit(1)
