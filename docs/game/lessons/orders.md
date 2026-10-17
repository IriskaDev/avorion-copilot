# orders —— 下单：别编活 / busy 落定 / 读回执 / 单一决策者 / 别强杀游戏

> 上一级：[`README.md`](README.md) · 工具 [`../ops/tools-cheatsheet.md`](../ops/tools-cheatsheet.md) §1、§3、§5

## L5 · ★ 不许给闲船编活（「不派也是决策」）

- **症状**：本会话**三次**给闲船编活——给战斗船派侦察 / 先派护航 / 为堵嘴给它编 Travel。
- **当时的错误判断**：见到「船空闲来问」就想给它找点事做，怕「空着浪费」。
- **错因**：把「船反复来问」当成「该给船派活」；其实反复来问是**循环没修好**，不是船缺活。
- **正确判据**：「不派」也是决策 ✓（`action=None`）。战斗舰允许闲置；别为了堵嘴编活。该修的是「反复来问」这个循环 ✗，不是船。
- **证据出处**：`action=None` 是合法答复 `docs/game/README.md:13` ✓；战斗舰允许闲置 `.dsh/skills/fleet-decision/SKILL.md:51` ✓；`fleet_escort` 工具描述「combat ships are allowed to idle, so do not send one just to give an idle ship work」`plugin/src/tools.ts:333-334` ✓；本会话三次错误 ✓（会话记录）。

## L9 · ★ 派单前确认目标船/护航舰 `busy=false` 且状态已落定

- **症状**：刚 recall 就派 → 被拒 `ship is not available (probably busy with another command)`。
- **当时的错误判断**：召回（recall）一发出就以为船已空闲、马上可派。
- **错因**：recall 是异步的，状态没落定；`busy` 还没翻回 false 就下单。
- **正确判据**：派单前 `fleet_query {what:"list"}`（或 `what:"ship"`）确认目标船**和每艘护航**都 `busy=false`、状态已落定，再 `fleet_order`。
- **证据出处**：拒串 `data/scripts/net/link_in.lua:430-431`（`SHIP_NOT_AVAILABLE`）✓；`busy` 来自 list 快照 `link_in.lua:54-58`（转引 `tools-cheatsheet.md:27`）✓；recall 异步 `plugin/src/tools.ts:411-434`（转引 `tools-cheatsheet.md:94`）✓；实测刚 recall 就派被拒 ✓（会话记录）。

## L10 · ★ 回执要读；失败要能重投重新决策

- **症状**：下单后不看回执，以为「发出去了 = 成功」。
- **当时的错误判断**：忽略块末尾「你上一单的结果」；失败就停在原地。
- **错因**：下单是异步的，成不成在 receipt 里；像 Scout 被拒 `order needs explicit data.x and data.y` 这类明确报错，不读就重投同一个错。
- **正确判据**：★ 读回执——现在的块里有「你上一单的结果」（如 Scout 被拒 `order needs explicit data.x and data.y`）✓；失败要能**重投重新决策**（带上失败原因），不是原样重试同一个错。
- **证据出处**：「你上一单的结果」行 `plugin/src/task.ts:196-197` ✓（预算 200B `:131`）+ `plugin/src/index.ts:2058-2059` ✓；失败回投带原因 `index.ts:2183-2193` ✓；拒串 `order needs explicit data.x and data.y (no auto box selection)` `link_in.lua:442` ✓。

## L11 · ★ 只有一个决策者（指定指挥官时兜底不许下单 / 冒名）

- **症状**：指定会话指挥官后，块里「你上一单」的结果其实可能来自 fallback（单发），决策者被「冒名」。
- **当时的错误判断**：以为块里的「你上一单」就是本会话自己上一单。
- **错因**：`lastResultFor` 只按船名取最近一条决策记录，**不带来源**（session / single-shot / shadow），所以单发兜底下的单也会被当成「你的上一单」喂回来。
- **正确判据**：★ 指定会话指挥官时，兜底（单发）**不许下单** ✗、**不许冒名** ✗——决策来源必须显式，块里「你上一单」要标出来源。
- **证据出处**：投递阶梯 ①会话 → ②单发 `plugin/src/dispatch.ts:287-312` ✓；来源标记 `source`（session/single-shot/shadow）`dispatch.ts:396` ✓；`lastResultFor` 只按船名取、不看 source `plugin/src/index.ts:429-453` ✓；「你上一单的结果」渲染 `task.ts:196-197` ✓。★ 「兜底不许下单」是主人本会话给定，当前代码阶梯里会话没答成仍会走 ②单发下单（`dispatch.ts:343-374` ✗）——这条**代码尚未落地**，标 ⚠未验证（待主人确认是否要改 dispatch 阶梯）。

## L13 · ★ 不许强杀游戏；Lua 改动要重启游戏（正常退出）

- **症状**：为改 Lua 强杀游戏进程。
- **当时的错误判断**：以为强杀能快速套用 Lua 改动。
- **错因**：Steam P2P 残留 + player value 丢失；Lua 是启动时加载的，强杀不干净。
- **正确判据**：不许强杀游戏 ✗；Lua 改动要**重启游戏（正常退出）** ✓。
- **证据出处**：本会话实测（Steam P2P 残留 + player value 丢失）✓（会话记录）。★ 具体「player value」指哪个存档值、残留的确切表现，代码证据不足，标 ⚠未验证（待主人确认）。
