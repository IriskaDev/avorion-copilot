# escorts —— 护航：四前提 / `fleet_escort` 只 Travel / 先判需不需要

> 上一级：[`README.md`](README.md) · 机制出处：[`../mechanics/escorts.md`](../mechanics/escorts.md) ·
> 工具：[`../ops/tools-cheatsheet.md`](../ops/tools-cheatsheet.md) §1、§5

## L2 · ★ 护航生效有**四个前提**（缺一不可）

- **症状**：以为「派了护航 / 名单里有它」护航就生效，实际被拒或根本没进护航。
- **当时的错误判断**：看到某船 `turretCount` 数字 > 0 就当成「有炮塔的战斗舰」可用作护航；或以为调过去就完事。
- **错因**：护航是**四个前提的合取**，只满足一两个不够。
- **正确判据**（四条全要）：
  1. **真需要**——行动船任务风险超闸门（`predict` 的 `risk.baseAttackChance` 超/逼近 0.10）才考虑；
  2. **护航舰在行动船「自己的一跳航程（hyperspace reach）」之内**（**不必**同星区；同星区只是距离 0 的特例）；
  3. **有炮塔**——★ `turretCount` 是**槽位不是已装炮塔** ✗（实测被拒「没有炮塔」）；
  4. **行动船的订单里带 `escorts:[…]`**——护航是主命令的 `config.escorts`，不是单独一条 Escort 单。
- **证据出处**：
  - 资格判据原版 `simulationutility.lua:145-176`（`isShipUsableAsEscort`）✓，转引 `docs/game/mechanics/escorts.md:9-61`。
  - ★ 距离判据是 `distance2(护航坐标, 行动船坐标) > reach² → TooFarAway`（`:156-163`）——
    **只有** `TooFarAway` 这一条距离失败；源码里**没有**同星区判断 ✗。2026-10-18 真机回执：
    `sameSector:false, distance:2.236, reach:4.1` 仍然 `ESCORT_OK`（见 `mechanics/escorts.md` §1.1）。
  - `turretCount` 来自 `entry:getTurrets()` 数对象个数：`data/scripts/lib/copilot/card.lua:168-170` ✓、`data/scripts/player/ai/ops.lua:127-131` ✓；它**不代表「有武装炮塔」**——真正判「能不能打」的是 `entity:getNumArmedTurrets()`（`data/scripts/lib/entity.lua:58` ✓，`checkArmed` 里 =0 时报 `Your craft %s has no turrets or combat fighters!` `:81` ✓）。实测被拒「没有炮塔」✓。
  - 主命令带 `escorts` → 游戏自动建 Escort 副命令：`simulation.lua:612-618` ✓，转引 `escorts.md:103`。

## L3 · ★ `fleet_escort` 只把护航舰 Travel 过去 ≠ 护航生效

- **症状**：以为 `fleet_escort` 一调，护航就到位并参与护航了。
- **当时的错误判断**：把「派护航船过去」当成「护航生效」。
- **错因**：`fleet_escort` 的**唯一动作**是给护航舰下一单 `Travel` 到目标船星区（receipt 里只有 `action:Travel`）——它不把护航挂到任何订单上。
- **正确判据**：护航真正生效靠的是**行动船的订单里带 `escorts:[…]`**（= L2 ④）。`fleet_escort` 只是「把人送进行动船的一跳航程（reach）内」这个前置步骤（最稳当然是送到同星区，但**不是必须** ✗）；到没到位、进没进订单，还要再查、再在 `fleet_order` 的 `escorts` 里显式带上。
- **证据出处**：`fleet_escort` 执行体只发 `{ship:escort, action:'Travel', x, y}` `plugin/dsh/src/tools.ts:654` ✓（receipt 只有 Travel）；工具描述「Send an escort ship … with a Travel background command」`:550` ✓；护航生效靠 `config.escorts`：`link_in.lua:537`（`if type(data.escorts) == "table" then config.escorts = data.escorts`）✓ + 副命令 `simulation.lua:612-618` ✓。

## L4 · ★ 先判需不需要护航，再决定派不派（战斗舰允许闲置）

- **症状**：见到有艘空闲战斗舰，就顺手给它「派护航」之类的活。
- **当时的错误判断**：把「有一艘闲船」当成「该给它派护航」。
- **错因**：没先量化行动船的任务风险，就跳去「派护航」。
- **正确判据**：先 `predict` 拿 `risk.baseAttackChance`——**≤ 10% 通常不需要护航，不派** ✓；只有**超/逼近闸门**才考虑护航（或换框/换位置做同一动作）。战斗舰**允许闲置**，没被需要就不派；已派出发现不需要就 `fleet_recall`。
- **证据出处**：`risk.baseAttackChance` 出参 `link_in.lua:4739`（Trade）/`:4838`（Salvage）/`:4884`（Sell）✓；闸门 0.10 `docs/game/README.md:20` ✓；`fleet_escort` 工具描述自带判据「at/below the 10% gate it usually does NOT need an escort … combat ships are allowed to idle」`plugin/dsh/src/tools.ts:552-557` ✓；SKILL 既有判据 `.dsh/skills/fleet-decision/SKILL.md` §6 ✓。

## L21 · ★ 我们曾把 vanilla 的「一跳航程」规则误记成「必须同星区」

- **症状**：派护航前先要求「护航舰与行动船同星区」，否则不敢下单；文档、SKILL、工具描述里都写着「**HARD RULE: 必须同星区**」✗。
- **当时的错误判断**：把"我们在风险模型里只相信同星区护航"这个**自己的保守策略**，当成了**原版规则** ✗。
- **错因**：没读 `isShipUsableAsEscort` 的函数体，只凭"护航要跟着行动船"的直觉；而真正唯一的距离判据是
  `distance2(护航坐标, 行动船坐标) > reach² → TooFarAway`（`simulationutility.lua:156-163`）——
  `reach` 来自**护航自己**的 `getHyperspaceProperties()`，判据是一个**圆盘**，同星区只是距离 0 的特例 ✓。
- **正确判据**：原版接受「与行动船距离 ≤ 护航自己 reach」的任何护航（不同星区也行）✓；**只有**超出 reach 才
  `TooFarAway` ✓；另外还有环侧（`:165-169`）与 `isShipUsable`（`:171-174`）两条，但**没有**同星区、**没有**武装检查。
  2026-10-18 真机：`sameSector:false, distance:2.236, reach:4.1` 的单子，原版流程走过了护航闸门
  （随后被 `salvagecommand.lua:566-567` 的炮塔栏位拦下，那条 `getErrors` 在闸门**之后**才调用 ✓）。
  所以「调护航」只在该船**确实超出 reach**时才必要 ✓。
- **证据出处**：`simulationutility.lua:145-176`（全文）、`:156-163`（距离）、`:165-169`（环侧）、`:171-174`（可用性）；
  `simulation.lua:490-522`（闸门在 `:520` 就 `return`）、`:557`（`getErrors` 在闸门之后）；
  真机回执见 `docs/game/mechanics/escorts.md` §1.1；聊天原文「炮塔栏位不足，无法放置所有炮塔！」
  （客户端日志 2026-10-18 15:40:20 ✓）。
