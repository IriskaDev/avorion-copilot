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
const m = /export const ALL_ACTIONS = \[([^\]]+)\]/.exec(idx)
check('src/index.ts 定义了 ALL_ACTIONS', m !== null)
const allActions = m ? m[1].split(',').map((s) => s.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean) : []
check('ALL_ACTIONS 非空', allActions.length > 0, allActions.join(','))

// ── ② 提示词广告的动作集合 == ALL_ACTIONS ✓✓（缺陷 #9/#10 的核心）
const promptPath = join(plg, 'prompt', 'system.md')
const prompt = existsSync(promptPath) ? readFileSync(promptPath, 'utf8') : ''
const pm = /^action=<([^>]+)>/m.exec(prompt)
check('prompt/system.md 有 action=<...> 行', pm !== null)
const advertised = pm
  ? pm[1]
      .replace(/[，,。].*$/, '')       // 去掉"只写这一个词"这类说明 ✓
      .split('|')
      .map((s) => s.trim())
      .filter((s) => s !== '' && s !== 'None')
  : []
const setEq = (a, b) => a.length === b.length && [...a].sort().join(',') === [...b].sort().join(',')
check(
  '提示词广告的动作 == ALL_ACTIONS',
  setEq(advertised, allActions),
  `prompt=[${advertised.join(',')}] ALL_ACTIONS=[${allActions.join(',')}]`,
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
check('提示词广告 deposit= 行', /^deposit=/m.test(prompt))

// ── ⑥ 风险判定必须活到模型眼前（缺陷 #6 ✓）
check(
  'compactJobPlan 保留 exceedsRiskLimit',
  /exceedsRiskLimit: e\.exceedsRiskLimit/.test(idx),
)
check('compactJobPlan 保留 riskLimit', /riskLimit: e\.riskLimit/.test(idx))

// ── ⑦ 我们自造的经验系数必须被标注为估计，且原版数字优先 ✓
check('ESCORT_RISK_FACTOR 有"估计"标注', /我们自己的估计/.test(idx))
check('优先用原版 attackChanceWithEscorts', /best\.withEscorts \?\?/.test(idx))

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
