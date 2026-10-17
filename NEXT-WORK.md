# NEXT-WORK —— 待办交接单（2026-10-17 夜）

> ★ **权威说明**：决策口径以 [`docs/game/`](docs/game/README.md) 为准，本文件是历史/资料库。
#
# ⚠️ 2026-10-17 深夜更新：本单里的 **1（框选自由）/ 4（逐货数字）/ 5（货舱不可误读）**
#    以及主人后来追加的 **Scout 未知区决策** 与 **"单次无工具调用 → 数字都先算好"**
#    已经**做完并入库** ✓（4 个提交：abe9940 / 260f407 / 42882f4 / d1c0d84）。
#    验收清单里的**断言数已变**：luaparse 35 文件 0 失败；trade **92** / sell **50** /
#    job **78** / scout **62** 项断言全绿；_linkin_check OK；插件 build 0 error TS、
#    check-mechanics exit 0、order-payload **55** 项断言、其余 mjs 全 exit 0 ✓。
#    ★ **改到 net/*.lua 必须重启游戏**（热重载覆盖不到 net 链 ✓）；改到插件要重启 DSH ✓。
#    仍然欠着：§四 的其它欠账（六个未实现的后台命令等）✗。


**这份是给"下一轮接手的 agent"看的。** 上一轮会话把活定到了这里，但它自己
**已经没有上下文预算、且处在子代理层（无法再派子代理）** ✗，所以**原样写下来**，
让新会话（根层，可以派子代理）**一步都不用重写** ✓。

---

## 一、已完成（别重做 ✗）

| 事 | 状态 |
|---|---|
| 计划链**真的通了** ✓ | 真因: `onQuery` 把计划函数写在**非末位参数**位置 → Lua 只取第一个返回值 → 载荷变成布尔 `true` ✗。已改成先解包再传载荷 ✓ |
| 实机验证 ✓ | `Trader-00001 → action=Trade {"goodName":"Force Generator","deposit":1000000,…}` ✓ ；`Scout-00001 → action=Scout {...}` ✓ |
| `goodsToSell` 端到端 ✓ | 插件解析 + 透传 ✓（`all` **故意不回传** ✓ 游戏侧"没给=全卖" ✓）；提示词写明 **Sell 时必填** ✓ |
| safeMode 规矩 ✓ | 「一般不要开」✓；★★ **比较口径写死**：判断"<10% 吗"用的**永远是不开 safeMode 时的普通档概率** ✓；开了之后被修正出的数（如 0.04）**绝不能当输入** ✗（那是**循环论证** ✓）。已进 `MECHANICS.md` + 提示词 ✓，守卫全绿 ✓ |
| 无动作行 → 重试一次 ✓ | 首轮无动作行则重试一次（**同一批事实、不重取、只此一次** ✓），失败时错误里带两轮原因 ✓ |
| 崩溃真凶 ✓ | 结算块 `?.orderHint` 遇 JSON `null` 返回 `null` ✗ 而 `!== undefined` 仍成立 ✗ → `hint.x` 抛 ✓。已改对象级判空 + 保留栈定位 ✓ |
| 插件搬家 ✓ | 整个插件现在住在 `mods/copilot/plugin/dsh/` ✓（历史已并入 mod 仓库 ✓）；DSH profile 的 `link:` 已改 ✓；旧目录留作备份 ✓ |
| 启动脚本 ✓ | `tools/launch-game.ps1` ✓ —— 7 段带时间戳/累计耗时 ✓，末行 `LAUNCH-OK roster=N` ✓，实测 42 秒 ✓，无 `-Force` 时不强杀正在跑的游戏 ✓ |

---

## 二、要做（按优先级）

### ★★ 1. 框选自由：**位置**与（Trade 的）**形状**都要暴露出来

主人的原话：
> 「其余的涉及到框选区域的指令，都应清楚，**框选位置是可以变化的**。尤其 Trader，
>   **框的形状甚至能够改变**。」
> 「发现高危，她应该**再框选别的位置看看**（框选位置不同，伏击概率也不同的，
>  **不移动星系**，也可以变更框选区域），或者尝试旅行到安全的地方，再做尝试。」

**已核实的事实（当作给定 ✓）**

* 区域是"**必须包含船**"的**方块**：Mine/Salvage/Sell **15×15**（`minecommand.lua:494-503` /
  `salvagecommand.lua:572-585` / `sellcommand.lua:414-431`）；Scout **21×21**（`scoutcommand.lua:416-429`）；
  **Travel 1×1 且不要求包含船**（`travelcommand.lua:454-473`）。
  → ★ 所以**同一个星系里**，框的**中心可以平移**（船不动 ✓），而**风险与产出随框变化** ✓。
* ★ **实机铁证**：同船同星系，Salvage 偏移 `(0,0)` 显示 **0.04**，`(0,-4)` 显示 **0.02** ——
  只挪框，风险**减半** ✓✓。
* ★★ **Trade 的框还有多种合法形状**：`17×17`（289 格）/ `29×11` / `11×29`（319 格）
  —— 见 `tradecommand.lua` 的 `getAreaSize` 与合法尺寸处理（约 `:584-597`），
  以及我们自己的 `legalAreaSizes` 辅助函数。**形状会改变哪些星区/贸易路线落在框内** ✓。

**我们的问题（真因坐标 ✓）**

* `data/scripts/net/link_in.lua:604` `local SCAN_STEP = 4` → 候选框中心是**步长 4 的粗网格**；
  `scanOffsets(half, step)` 在 `:670`；扫描点在 `:1157` / `:2030` / `:2305` / `:2890`。
  → 只采样 **5–9 个框** ✗，而 15×15 的**合法框中心空间是 225 个**（覆盖率 2–4% ✗）。
* 实测耗时：`sellPlan` 9 个区域 ≈ **5.7–5.9 秒** ≈ **0.6 秒/框** → 全扫 225 个 ≈ **2 分钟**
  **不可接受** ✗ → 必须用两阶段。

**要做**

1) ★ **两阶段扫描**（Mine / Salvage / Sell / Trade / Scout 全部）：
   (a) 粗扫（当前步长）；(b) 对粗扫最好的 **2–3 个候选**做**细扫（step 1）**，
   使"同一星系里明显更安全/更好的框"**真的被发现并出现在榜上** ✓。
   保持时间预算（**报 scanMs** ✓，把预算写进响应并说明上限 ✓）；尊重现有的 `data.step` 覆盖 ✓；
   响应形状向后兼容 ✓；**风险闸门与 `informOnly` 语义不变** ✓（超闸门候选照样列出并带判定 ✓）。
2) ★★ **Trade 要跨"形状 × 位置"扫描** ✓：让 Trade 计划**真的呈现多种合法形状**的候选 ✓
   （而不是只有一个形状、且框心只在船身上 ✗）。同样受时间预算约束并报 scanMs ✓。
3) ★ **机制文字**（进 `MECHANICS.md`，再 `node plugin/dsh/scripts/render-mechanics.mjs` 重新生成）：
   * 每条用框的命令：**框的位置是自由选择**（只受该命令自身约束：Mine/Salvage/Sell/Scout 必须**含船**；
     Travel 1×1 无此要求 ✓）；同一艘船同一星区**允许多种框**，**风险/产出逐框不同** ✓；
   * ★ **Trade 的框形状也可变** ✓（列出合法形状 + file:line ✓）；
   * **货舱满了会挡住 Trade 装货**（所以游戏回 `HOLD_HAS_GOODS` ✓），而 **Sell 是腾出舱位的命令** ✓。
   * ✗ **措辞红线**：只写机制 —— **绝不写"所以你应该换个框/先卖货"** ✗（守卫 `check-mechanics.mjs`
     会拦策略/时机措辞 ✓；主人定的原则是提示词只放**大目标 + 机制** ✓）。
4) **Sell 的逐货数字**要**真的送到模型眼前** ✓：每个候选框、每种货 ——
   **舱里有多少 / 预计卖多少 / 涨跌幅 ±%** ✓（来源：游戏侧已有的 `pricesPerGood` / 百分比数据 ✓，
   给出 file:line ✓；插件裁剪**不许把它丢掉** ✗）。Lua 里确实拿不到的，**明说** ✗ 不许编 ✓。
5) **货舱状态不可误读** ✓：卡片字段本身是对的 ✓（`card.lua:205` `entry:getCargo()` 返回
   (货物表, 总容量) ✓；`:215` cargoUsed / `:218` holdHasGoods / `:221` cargoCapacity /
   `:222` cargoUsedPercent / `:234` freeCargoSpace ✓）—— **别"修"卡片** ✗，只确保
   模型读到的东西**used / capacity / free / 百分比 / 是否挡住 Trade** 一眼能分清 ✓。
   ★ 注意：主人以为那条 Salvager"舱库装满了" ✗ —— 实际数据是 **1110 单位 / 11 种 / 44%** ✓，
   **并没有满** ✓ → 这说明**显示方式仍会误导人** ✓，值得再校一遍 ✓。

**测试（新增，不许削弱已有断言 ✗）**

* 粗网格会漏掉、而细扫能找到的"更低风险框"，现在**必须出现在榜上** ✓；
* 对合法的船，Trade 候选集**必须包含多于一种合法形状** ✓；
* 扫描**不超预算** ✓（断言 scanMs 上限 ✓）；
* Sell 的逐货数字**确实进入**模型可见的载荷 ✓（扩 `test/order-payload.mjs` 或兄弟测试 ✓）。

---

## 三、验收清单（改完必须跑）

```
# 在 mod 仓库根跑（这些自检按相对路径读文件，换目录会失败 ✗）
node C:\Users\IriskaDev\AppData\Local\Temp\luacheck-copilot\check.js .
   → 期望 35 file(s), 0 failure(s)
native/harness/_scout_scan_selftest.lua   → 62 项断言 / 失败 0   ← ★ 2026-10-17 由 41 增到 62
native/harness/_sell_scan_selftest.lua    → 50 项断言 / 失败 0   ← ★ 由 35 增到 50
native/harness/_trade_scan_selftest.lua   → 92 项断言 / 失败 0   ← ★ 由 68 增到 92
native/harness/_job_scan_selftest.lua     → 78 项断言 / 失败 0
native/harness/_trade_selftest.lua        → selfTest: OK
native/harness/_linkin_check.lua          → COMPILE OK + RUN: OK（net/ 只放定义 ✓）

# 插件仓库（mods/copilot/plugin）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1   → 无 error TS
node scripts/check-mechanics.mjs                                        → exit 0（守卫全绿，逐行引用）
node test/order-payload.mjs → 55 项断言 / 失败 0   ← ★ 由 27 增到 55
node test/actions-consistency.mjs / prompt-file.mjs /
     rendezvous.mjs / rendezvous-flow.mjs / memory-demo.mjs             → 全 exit 0
```

**改到 `net/*.lua` → 必须重启游戏** ✓（`/copilot reload` 覆盖不到 ✓ VM 边界 ✓）；
**改到插件 → 必须重启 DSH** ✓。两者都由主人做 ✗ agent 不许自行重启 ✓。

---

## 四、别的欠账（较低优先）

* `plugin` 侧：重试路径**缺一条驱动式断言**（假 LLM 首轮只回推理 → 断言恰好重试一次）✗；
* 各 plan 的概率**没按命令/档位分别标注** ✗（Sell 的 0.27/0.14 与 Salvage 的 0.04 容易混比 ✓）；
* 还剩同类的 null `.x` 洞：`plugin/dsh/src/index.ts` 旧 817 行附近（`targetSector.x` ✓）、
  `plugin/dsh/src/tools.ts:426`（`sector !== undefined` 之后仍点 `sector.x` ✓）；
* 六个**尚未实现的后台命令**（pro 调研结论 ✓）：`Refine / Procure / Supply /
  **Expedition** / **Maintenance** / Escort` ✓ —— 价值最高的是 **Maintenance（修船补弹）**
  与 **Expedition（无人区被动收入）** ✓。资料库与插入提案见
  `GAME-GOALS-AND-OPS.md` 与 `PROMPT-INSERT-PROPOSAL.md` ✓（**提案未落地** ✓，等主人点头 ✓）。
* 后台层**没有战斗/巡逻/防守命令** ✓（`CommandType` 里根本没有 ✓）—— 写进机制可**防模型幻觉** ✓。
* 采矿硬门槛：激光只能采"**自身 +1 级**"及以下（`galaxy.lua:412-414` ✓），低一级伤害 ×0.25 ✓
  —— 这是 `capability.materials[i].dps=0` 的根因 ✓。
* 材料带心阶梯（`galaxy.lua:357-377` ✓）：Fe 450 / Ti 379 / Na 307 / Tr 236 / Xa 164 / Og 93 / Av 21 ✓
  —— **静态全局结构**，单点 `sectorFacts` 查不出来 ✓，值得进机制段 ✓。
