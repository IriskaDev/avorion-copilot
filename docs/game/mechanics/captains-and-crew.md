# 船长与船员（职业各自解锁什么 / 哪些是硬门槛）

> 上一级：[`index.md`](index.md) · 命令门槛见 [`commands.md`](commands.md) ·
> 引用约定见 [`../README.md`](../README.md) §4。原版根：`data/scripts/`。

## 1. 下单的硬门槛（先看这条）

| 门槛 | 事实 | 证据 |
|---|---|---|
| **必须有船长** | `isShipUsable`：船可用 → 不在裂隙 → 是船 → ★ **有船长（硬）** → 船员满足 → 能源够 → 未受损 → 未受攻击 | `player/background/simulation/simulationutility.lua:28-89` ✓（`NoCaptain` 在 `:57-61`；注释 `:29` 说明前四项**不可忽略**） |
| **Trade 额外要求 Merchant** | 否则预测直接报 "I don't know enough about trading…" | `tradecommand.lua:750-755` ✓ |
| Sell 的货物门槛 | `stolen/illegal` → 必须 **Smuggler**；`dangerous/suspicious` → **Smuggler 或 Merchant** | `sellcommand.lua:389-395` ✓ |
| 缺船长怎么办 | 本 mod 的决策链会**自动补一个船长**（`CaptainGenerator` + `entry:setCaptain`） | `LLM-OPS.md` §3.2（本 mod 行为） |

## 2. 船长职业（10 类）

枚举顺序**不可改**（要存库）：`lib/captainclass.lua:3-15` ✓
`None=0, Commodore=1, Smuggler=2, Merchant=3, Miner=4, Scavenger=5, Explorer=6, Daredevil=7, Scientist=8, Hunter=9`

| 职业 | 解锁/加成 | 证据 |
|---|---|---|
| Commodore | **+2 武装炮塔位、+4 自动炮塔位** ✓`:550-566`；风险模型里每艘 `baseProbability × 0.85`、主船 `−0.15`（见 [`risk-and-ambush.md`](risk-and-ambush.md)） | `lib/captainutility.lua:550-566` ✓ |
| Smuggler | 「一切」货物执照（赃物/违禁品都能卖、走私不被刁难） | `captainutility.lua:56-74`（转引 §A10）、`sellcommand.lua:389-395` ✓ |
| **Merchant** | ★ **唯一能跑 Trade**；危险/可疑货执照 | `tradecommand.lua:752-755` ✓ |
| Miner | **+2 非武装炮塔位**、高亮**隐藏矿**、**加长采矿时长**（`+0.5 + tier + level×0.5` 小时）✓`:594-618` | `captainutility.lua:594-618` ✓ |
| Scavenger | +2 非武装炮塔位、高亮**贵重残骸**、加长打捞时长 | `captainutility.lua:568-592`（转引） |
| Explorer | 深空扫描距离 +3；★ Scout 里 `revealsOffgrid = 2`（揭全部隐藏档位） | `captainutility.lua:620-630`（转引）、`scoutcommand.lua:521-522` ✓ |
| Daredevil | +10% 炮塔射速 | `captainutility.lua:632-642`（转引） |
| Scientist | 裂隙内采集研究数据 +200% | 转引 §A10 |
| Hunter | 裂隙内吸引稀有 Xsotan | 转引 §A10 |
| None | 未专精（**到 4 级且 tier=0 时**才定型为某职业） | `captainutility.lua:16-34` ✓ |

- 船长还有 **Tier 0~3 / Level 1~6、主/副职业、工资、22 种 perk**；perk 会影响工资、被伏击概率、
  命令速度、利润、经验、掉落（`captainutility.lua:221-245`，转引 §A10）。
- ★ **职业怎么来的**：升到 **level 4 且 tier == 0** 时，按"当时在跑的命令"给一个主职业
  （`simulation.lua:1219-1232` ✓）：

| 命令 | 定型职业 |
|---|---|
| Mine / Refine | Miner |
| Salvage | Scavenger |
| Expedition / Prototype | Daredevil |
| Scout / Travel | Explorer |
| Procure / Maintenance / Sell / Supply / Trade | **Merchant** |
| Escort | Commodore |

→ **事实推论**：想稳定得到 Merchant，就让它跑 Sell/Trade/Supply/Procure/Maintenance 这类命令升级；
Trade 本身需要 Merchant → 先靠别的商业命令练出来（或直接买/招一个）。

## 3. 船员（8 类）与炮塔

- 职业：`None / Engine / Gunner / Miner / Repair / Pilot / Security / Attacker`（`Documentation/Enums.html:1007-1018`，转引 §A10）。
- 炮塔要靠船员干活：武器塔要 **Gunner**、采矿塔要 **Miner**、维修光束要 **Repair**；引擎要 **Engine**
  （转引 §A10）。船有 `idealCrew`，Boss 直接满编。
- 船员不满 → 后台命令会被拒（`isShipUsable` 的 `BadCrew`，`simulationutility.lua:63-69` ✓；不过这一项
  **可以**被 `ignoredErrors` 忽略，前四项不行）。
- 军衔 `CrewRank`，**Trinium 学院（Academy）** 可训练（转引 §A10）。

## 4. 登舰（boarding）

- 登舰是**实体层**机制（Boarding Shuttle + Boarders），**不是后台命令**；
  后台 13 条命令里唯一碰船员的是 **Maintenance**（补人）。
- 实体层有 `OrderType.Board = 15`（`lib/ordertypes.lua:5-29`，转引 §B5）。
- → 决策时**不要**期待"派船去登舰"这类动作：本 mod 的 action 表里没有，后台层也做不了。

## 5. 能力卡里跟船长有关的字段

- `captainClass`（模型直接可读的职业）、`hasCaptain`、`captainClassKnown`
  （`has a captain but getClass() did not answer` 的情况）—— 见 `data/scripts/lib/copilot/card.lua:342-349` ✓。
- ★ 只有 `captain:hasClass(CaptainUtility.ClassType.X)` 这种问法，**没有** `getClass()`
  （`tradecommand.lua:752` ✓ 的原版用法；本 mod 实测）。
