# 深度与材料（材料阶梯 / 越靠中心越好也越险 / 采矿 +1 级门槛）

> 上一级：[`index.md`](index.md) · 怎么**查**这些数字见 [`../ops/tools-cheatsheet.md`](../ops/tools-cheatsheet.md)
> （`what=sectorFacts` 与能力卡的 `depth{}`）· 引用约定见 [`../README.md`](../README.md) §4。
> 原版根：`data/scripts/`（`lib/galaxy.lua` 等）。

## 1. 坐标系

| 事实 | 证据 |
|---|---|
| 银河 **1000×1000** 星区，坐标范围 ±500，中心 **(0,0)**；距离是**欧氏距离** | `lib/galaxy.lua:387-389`、`:23-26`（转引 `../goals-and-ops.md` §A1） |
| 中心**屏障环**半径：`blockRingMin = 147`、`blockRingMax = 150` | `lib/galaxy.lua:8-9` ✓ |
| 过屏障只能靠 8 钥匙传送门或 Avorion 超空间核心；`Balancing_InsideRing(x,y)` 判断是否在环内 | `../mechanics-source.md` §0/§11；`../goals-and-ops.md` §A7（转引） |

## 2. 材料阶梯与"带心"

顺序（值 0..6，`MaterialType.Iron=0 … Avorion=6`）：**Iron → Titanium → Naonite → Trinium → Xanion → Ogonite → Avorion**
（`Documentation/Enums.html#MaterialType`；`NumMaterials()=7`，`lib/galaxy.lua:226` ✓）。

带心公式（`lib/galaxy.lua:357-377` ✓）：`带心距离 = ((7−m)/7 − 0.1) × 500` 星区；
带宽 ≈ 35.7 星区；存在范围 = 带心 ± 带宽 × 1.5。

| 材料 | 带心（距中心，星区） | 存在范围 | 建舰知识解锁半径 |
|---|---|---|---|
| Iron | 450 | 396~503 | 默认可用 |
| Titanium | 379 | 325~432 | <420 |
| Naonite | 307 | 254~361 | <360 |
| Trinium | 236 | 182~289 | <290 |
| Xanion | 164 | 111~218 | <210 |
| Ogonite | 93 | 39~146 | <145 |
| **Avorion** | 21 | **0~75** | <75 |

- 解锁半径的证据：`lib/buildingknowledgeutility.lua:17-22` ✓（Avorion 75 / Ogonite 145 / Xanion 210 /
  Trinium 290 / Naonite 360 / Titanium 420）。
- 相邻材料带**重叠**：概率是"到带心距离 → lerp + 二次项"再归一化，不是硬性二选一
  （`lib/galaxy.lua:217-262` ✓，本会话实读该函数）。
- 两个特殊规则（`lib/galaxy.lua:240-249` ✓）：
  - 最外缘（归一化距离 > **0.852**，即 >426 星区）**强制只出 Iron 90% + Titanium 10%** ✓`:241-244`；
  - ✗ **死代码注记**：`:247` 的「屏障外禁 Avorion」写成 `distFromCenter > Balancing_GetBlockRingMin()`，
    左边是**归一化值 0~1.414**、右边是**原始 147** → **永远为假、永不触发**
    （正确写法见 `lib/plangenerator.lua:94-98`）。实际效果仍由带心公式兜住（Avorion 只在 0~75），
    **所以不用改判断，但别依赖这一行**（`../goals-and-ops.md` §A3.5，其作者已复核）。

## 3. ★ 采矿"自身 +1 级"门槛（为什么能力卡里某些矿 `dps=0`）

| 事实 | 证据 |
|---|---|
| `Balancing_MineableBy(mined, laser) = (laser.value + 1 >= mined.value)` —— **采矿激光只能采"自身材料 +1 级"及以下** | `lib/galaxy.lua:412-414` ✓ |
| 低一级激光打高一级矿，伤害按"每差一级 ×0.25"衰减 | `lib/galaxy.lua:404-410` ✓ |
| 星区"推荐采矿 DPS" = `3.0 × (1 + (材料强度−1) × 0.1)` | `lib/galaxy.lua:206-214` ✓ |

→ 能力卡里某材料 `dps = 0` 就是"采不动"，**原因**是上面这条 +1 规则（`../ops/prompt-insert-proposal.md` §3 F3）。

## 4. "越靠中心越富、越强、越险"—— 具体刻度（转引 `../goals-and-ops.md` §A4）

| 量 | 边缘 → 中心 | 证据（`lib/galaxy.lua`） |
|---|---|---|
| 富饶度 `Balancing_GetSectorRichnessFactor(x,y,scale)` | `1 + richness/20 × scale`；默认 scale=20 → **1× → 21×** | `:18-37` ✓（本会话实读） |
| 奖励倍率 `GetSectorRewardFactor` | scale=25 → 最高 **26×** | `:39-42` |
| 舰船体积 `Balancing_GetSectorShipVolume` | ~150 → ~**2750** | `:46-79`（`shipVolumeInCenter=2750` `:11`） |
| 武器 DPS `Balancing_GetSectorWeaponDPS` | 7 档 95/190/310/370/470/550/650 | `:156-197` |
| 炮塔数 `Balancing_GetSectorTurrets` | **2 → 25**（敌人 ×1.5） | `:129-144` ✓ |
| 船 HP | `体积 × 材料强度 × 4` | `:147-154` ✓ |
| 科技等级 `Balancing_GetTechLevel` | **1 → 52** | `:108-117` ✓ |
| 海盗等级 | 边缘 0 → 中心 32 | `:391-402` |

→ 这些数字就是**伏击概率**（见 [`risk-and-ambush.md`](risk-and-ambush.md) §2）的底层原因：
中心星区的敌人 `HP/DPS` 更高，同样的船更难打，所以风险更高。

## 5. 这些数字怎么**查**（决策时用得到的一条事实）

| 想查 | 怎么查 |
|---|---|
| 某个坐标的富饶度 / 材料概率（前 4）/ 是否在环内 / 离中心距离 | `fleet_query what=sectorFacts x=… y=…`（本 mod 用原版 `Balancing_GetSectorRichnessFactor` / `Balancing_GetMaterialProbability` / `Balancing_InsideRing`）→ `data/scripts/net/link_in.lua:121-212` ✓ |
| ★ 同一个坐标还会顺带给"**朝中心方向的三个取样点**"（+8 / +16 / +28 星区）的同类数字，便于横向比较 | 同上 ✓`:179-186` |
| 当前这艘船所在星区的同类数字（含 `insideCentreRing`） | 能力卡的 `depth` 段 `data/scripts/lib/copilot/card.lua:327-337` ✓ |

★ **这些查询只给"事实"，不给"该不该去"的结论** —— 要不要走、什么时候走、走多远由决策者自己判断
（`link_in.lua:207-211` ✓ 的原话）。
★ 而且**别处的产量/伏击预测算不出来**：原版预测要求船**已经在那片区域里**
（`link_in.lua:208-210` ✓）→ 要那里的数字，得先 Travel / Scout 过去。

## 6. 建造侧的事实（顺带，别和决策混）

- 建舰知识决定"能用哪种材料造块"（`player.maxBuildableMaterial`）；道具 Tier I~VI
  （`lib/buildingknowledgeutility.lua:63-79`，转引）。
- **子系统槽位随材料递增**：Iron 4 / Ti 5 / Na 6 / Tr 8 / Xa 10 / Og 12 / **Av 15**
  （`lib/buildingknowledgeutility.lua:44-55` ✓）。
- 每种材料解锁什么（报告原引 `resourcemanagement.lua:98-294`）：Iron 惯性阻尼器；Titanium 发电机/电池/
  完整性力场；Naonite 护盾发生器 + 超空间核心；Trinium 机库/装配块/计算机核心/学院；Xanion 传送块/克隆舱；
  Ogonite 装甲特化；Avorion 轻且强（其超空间核心可**直接穿越屏障**）。
