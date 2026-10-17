/**
 * ★ 回归：**回单（会话路径）→ 解析 → order 载荷** 与 **fleet_order 工具路径** 必须**同指令同载荷** ✓✓
 *
 * 现场对照实验（2026-10-17 主人铁证 ✓）：
 *   同一条指令 `Sell @(-381,57) 15x15 goodsToSell=all`：
 *     ① 走**会话回单**（指挥官在 <fleet_task> 里答 `action=Sell x=-381 y=57 …`）→ 连试三次没执行 ✗；
 *     ② 走**工具** fleet_order{action:"Sell", x:-381, y:57, size:15} → 一次成功 ✓。
 *   → 断点在「回单 → 解析 → 下单」这条链 ✗，不在游戏、不在决策者 ✓。
 *
 * 所以本文件驱动**真解析器**（lib/task.js 的 validateAnswer = 会话回单那一条路的解析器），
 * 逐字段断言三种形态（size=15 / sizeX+sizeY / shape=15x15）+ goodsToSell=all，并断言：
 *   · 会话回单路径产出的 order 载荷 == fleet_order 工具路径产出的载荷（同一指令 ✓✓ 核心断言）；
 *   · goodsToSell=all **不是被当成空表** ✗，而是**根本不回传**（交给游戏"默认全卖" ✓）；
 *   · "no response" 超时 → 回执标 `unconfirmed`（已发送未确认 ✓），**不算失败、不回投** ✗✓。
 *
 * 跑法: node test/session-order-payload.mjs      （退出码 0 = 全过 ✓）
 */

import { registerHooks } from 'node:module'

// 与兄弟测试同款：DSH 两个包在 npm 里解析不了，指到本地桩 ✓（renderPrevResult 走 lib/index.js ✓）
registerHooks({
  resolve(spec, _ctx, next) {
    if (spec === '@deepseek-ai/dsh-llm') {
      return { url: new URL('./llm-stub.mjs', import.meta.url).href, shortCircuit: true }
    }
    if (spec === '@deepseek-ai/dsh-tools') {
      return { url: new URL('./tools-stub.mjs', import.meta.url).href, shortCircuit: true }
    }
    return next(spec, _ctx)
  },
})

// 让插件把日志写到临时位置，别碰真实玩家目录 ✓
process.env.HOMEPATH = ''
process.env.USERPROFILE = process.env.TEMP ?? ''

const { validateAnswer } = await import('../lib/task.js')
const { renderPrevResult, ALL_ACTIONS } = await import('../lib/index.js')

const SHIP = 'Trader-00001'
const ALL = ['Mine', 'Salvage', 'Trade', 'Travel', 'Sell', 'Scout']
const TASK = 't-0001'

// ---------------------------------------------------------------------------
// 断言工具
// ---------------------------------------------------------------------------
const checks = []
function check(label, cond, actual) {
  checks.push({ label, pass: cond === true, actual })
}
function show(v) {
  return JSON.stringify(v)
}

/** 会话回单 → order 载荷（= orderShip 里 `{ship, action, ...a.params}` 的形态 ✓） */
function sessionPayload(text, ship = SHIP) {
  const v = validateAnswer(text, TASK, ALL)
  if (!v.ok) throw new Error(`validateAnswer 没通过：${v.code} ${v.message ?? ''}`)
  return { ship, action: v.answer.action, ...v.answer.params }
}

/** 工具路径对同一条指令会发出的载荷（fleet_order 的 execute 就是 `ask(peer,'order', args)` ✓） */
function toolPayload(args) {
  return { ship: SHIP, ...args }
}

try {
  // ---- ① 三种形态逐字段断言 ------------------------------------------------
  {
    // size=15（正方形边长）→ 载荷带 size ✓（此前单发路径会漏掉它 ✗）
    const p = sessionPayload(`action=Sell\nx=-381\ny=57\nsize=15\ngoodsToSell=all\ntask=${TASK}\nreason=卖货\n`)
    console.log(`\n[size=15] 载荷: ${show(p)}`)
    check('size=15: action=Sell', p.action === 'Sell', p.action)
    check('size=15: x/y 原样', p.x === -381 && p.y === 57, `${p.x},${p.y}`)
    check('size=15: ★ 载荷带 size=15（不是被丢 ✗）', p.size === 15, p.size)
    check('size=15: goodsToSell=all 不回传', p.goodsToSell === undefined, p.goodsToSell)
  }
  {
    const p = sessionPayload(`action=Sell\nx=-381\ny=57\nsizeX=15\nsizeY=15\ngoodsToSell=all\ntask=${TASK}\n`)
    console.log(`\n[sizeX/Y] 载荷: ${show(p)}`)
    check('sizeX/Y: ★ 载荷带 sizeX/sizeY', p.sizeX === 15 && p.sizeY === 15, `${p.sizeX}x${p.sizeY}`)
    check('sizeX/Y: goodsToSell=all 不回传', p.goodsToSell === undefined, p.goodsToSell)
  }
  {
    const p = sessionPayload(`action=Sell\nx=-381\ny=57\nshape=15x15\ngoodsToSell=all\ntask=${TASK}\n`)
    console.log(`\n[shape] 载荷: ${show(p)}`)
    check('shape=15x15: ★ 拆成 sizeX/sizeY', p.sizeX === 15 && p.sizeY === 15, `${p.sizeX}x${p.sizeY}`)
  }
  {
    // goodsToSell 显式列表 → 数组逐字段 ✓
    const p = sessionPayload(`action=Sell\nx=-381\ny=57\nsize=15\ngoodsToSell=Platinum:1460,Oxygen:50\ntask=${TASK}\n`)
    console.log(`\n[list] 载荷: ${show(p)}`)
    check('list: goodsToSell 是数组且 2 项',
      Array.isArray(p.goodsToSell) && p.goodsToSell.length === 2, show(p.goodsToSell))
    check('list: 货名/数量正确',
      p.goodsToSell?.[0]?.goodName === 'Platinum' && p.goodsToSell?.[0]?.amount === 1460
      && p.goodsToSell?.[1]?.goodName === 'Oxygen' && p.goodsToSell?.[1]?.amount === 50,
      show(p.goodsToSell))
  }
  {
    // 其它字段：goodName/deposit/duration/safeMode/escorts ✓
    const p = sessionPayload(
      `action=Trade\ngoodName=Antigrav Unit\nx=-381\ny=57\nsize=17\ndeposit=752000\nduration=1\nsafeMode=false\nescorts=Combat-00001\ntask=${TASK}\n`)
    console.log(`\n[trade] 载荷: ${show(p)}`)
    check('trade: action/goodName/deposit', p.action === 'Trade' && p.goodName === 'Antigrav Unit' && p.deposit === 752000, show(p))
    check('trade: size/duration/safeMode', p.size === 17 && p.duration === 1 && p.safeMode === false, `${p.size}/${p.duration}/${p.safeMode}`)
    check('trade: escorts 数组', JSON.stringify(p.escorts) === JSON.stringify(['Combat-00001']), show(p.escorts))
  }

  // ---- ② 核心断言：同一指令，回单路径 == 工具路径 --------------------------
  //   现场实验的那条指令：Sell @(-381,57) 15x15 goodsToSell=all
  {
    const receipt = sessionPayload(`action=Sell\nx=-381\ny=57\nsize=15\ngoodsToSell=all\ntask=${TASK}\n`)
    const tool = toolPayload({ action: 'Sell', x: -381, y: 57, size: 15 })
    console.log(`\n[等价] 回单: ${show(receipt)}`)
    console.log(`[等价] 工具: ${show(tool)}`)
    check('★ 核心断言：Sell size=15 两条路径载荷**完全一致**',
      JSON.stringify(receipt) === JSON.stringify(tool), `${show(receipt)} vs ${show(tool)}`)
  }
  {
    const receipt = sessionPayload(`action=Trade\ngoodName=Drill\nx=-381\ny=57\nsizeX=17\nsizeY=17\ndeposit=100000\ntask=${TASK}\n`)
    const tool = toolPayload({ action: 'Trade', goodName: 'Drill', x: -381, y: 57, sizeX: 17, sizeY: 17, deposit: 100000 })
    check('★ 核心断言：Trade sizeX/Y 两条路径载荷**完全一致**',
      JSON.stringify(receipt) === JSON.stringify(tool), `${show(receipt)} vs ${show(tool)}`)
  }

  // ---- ③ goodsToSell=all 的各种写法都**不回传**（不是空表 ✗）---------------
  {
    for (const w of ['all', '全部', '全卖']) {
      const p = sessionPayload(`action=Sell\nx=-381\ny=57\nsize=15\ngoodsToSell=${w}\ntask=${TASK}\n`)
      check(`goodsToSell=${w}: 不回传（undefined，不是 [] ✗）`,
        p.goodsToSell === undefined, show(p.goodsToSell))
    }
  }

  // ---- ④ 坐标不被改写：负坐标 / 括号内坐标只取第一段 ✓ --------------------
  {
    const p = sessionPayload(`action=Sell\nx=(-381,57)\ny=57\nsize=15\ntask=${TASK}\n`)
    check('④ 括号坐标只取第一段：x=-381 不被改写', p.x === -381 && p.y === 57, `${p.x},${p.y}`)
  }

  // ---- ⑤ "no response" → 未确认（不算失败、不回投 ✓）---------------------
  {
    const rec = {
      ship: SHIP, answer: { action: 'Sell', params: { x: -381, y: 57, size: 15 } },
      source: 'session', decider: 'session',
      receipt: { at: 'now', accepted: false, executed: false, unconfirmed: true, note: 'order sent, no ack (no response) — verify next round via list/ship busy+cargo' },
    }
    const line = renderPrevResult(rec)
    console.log(`\n[no response] 上一单结果: ${line}`)
    check('⑤ no response: 渲染成"已发送，未确认"（不是"被拒/失败" ✗）',
      line !== undefined && line.includes('已发送，未确认') && !line.includes('被拒'), line)
  }
  {
    const rec = {
      ship: SHIP, answer: { action: 'Sell', params: { x: -381, y: 57, size: 15 } },
      source: 'session', decider: 'session',
      receipt: { at: 'now', accepted: false, executed: false, error: 'the hold still holds 1460 units — run action=Sell first' },
    }
    const line = renderPrevResult(rec)
    check('⑤ 真被拒: 仍渲染成"被拒/未执行"（不误伤 ✓）',
      line !== undefined && /被拒|未执行/.test(line), line)
  }

  // ---- ⑥ ALL_ACTIONS 白名单自检（Sell/Scout 都必须在 ✓）------------------
  check('⑥ ALL_ACTIONS 含 Sell 与 Scout', ALL_ACTIONS.includes('Sell') && ALL_ACTIONS.includes('Scout'), ALL_ACTIONS.join(','))
} catch (err) {
  console.log(`\n✗ 测试抛异常: ${err?.stack ?? err}`)
  process.exit(1)
}

const failed = checks.filter((c) => !c.pass)
console.log(`\n== 共 ${checks.length} 项断言，失败 ${failed.length} 项 ==`)
for (const f of failed) console.log(`  ✗ ${f.label}  → 实际: ${JSON.stringify(f.actual)}`)
console.log(failed.length === 0 ? 'sessionOrderPayloadSelfTest: OK' : 'sessionOrderPayloadSelfTest: FAILED')
process.exit(failed.length === 0 ? 0 : 1)
