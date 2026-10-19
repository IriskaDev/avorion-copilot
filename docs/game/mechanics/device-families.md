# 设备族：粗 / 净化 × 采集 / 分解（Mining & Salvaging device families）

> 本文回答：四种「挖/拆」设备**各自产出到哪**（货舱 vs 派系全局资源池）、对决策的影响、
> 以及混装时产出怎么分。★ 先说一个**命名坑**：原版里 **「R-」= Raw（粗）**，不是 Refined（净化）。
>
> 证据路径约定：下文 `文件:行` 均相对原版脚本目录 `data/scripts/`
> （游戏目录 `D:\SteamLibrary\steamapps\common\Avorion\data\scripts`，2.5.13，2026-10 实读 ✓）。
> 本 mod 路径用 `mods/copilot/` 前缀。`✓` = 实读核对；`⚠未验证` = 未找到原版证据。

---

## 0. 术语对照（先纠正命名）

主人说的四类设备在**语义**上与原版一一对应，但主人给的「原版叫 X」有**两处反了**：

| 主人用词 | 语义（主人描述） | 原版 `WeaponType` | 游戏内显示名 | 关键效率字段 | 对应关系 |
|---|---|---|---|---|---|
| 粗采集 / Raw Mining | 把**原矿**装进货舱 | `RawMiningLaser` | "Raw Mining Laser"，武器名 **"R-Mining Laser"** | `stoneRawEfficiency` | ✅ 正确 |
| 净化采集 / Refined Mining | 产出**精炼资源**直接进资源池 | `MiningLaser` | "Mining Laser"（= Refining Mining Laser） | `stoneRefinedEfficiency` | ⚠ 主人写成「R-Mining 一类」，**反了** |
| 粗分解 / Raw Salvaging | 把**废铁**装进货舱 | `RawSalvagingLaser` | "Raw Salvaging Laser"，武器名 **"R-Salvaging Laser"** | `metalRawEfficiency` | ✅ 正确 |
| 净化分解 / Refined Salvaging | 回收**直接进资源池** | `SalvagingLaser` | "Salvaging Laser"（= Refining Salvaging Laser） | `metalRefinedEfficiency` | ⚠ 主人写成「R-Salvage 一类」，**反了** |

**关键结论**：原版里 **带「R-」前缀的那一档是「粗（Raw）」**，产出原矿/废铁进**货舱**；
**不带前缀的 `Mining Laser` / `Salvaging Laser` 才是「净化（Refining）」**，产出精炼资源进**资源池**。

- 证据：`lib/weapontype.lua:42-45`（四个 `WeaponType` 的显示名）；
- `lib/weapongenerator.lua:138-139`（"R-Mining Laser … **the R- abbreviation refers to Raw Mining**"）、
  `:175-176`（"R-Salvaging Laser … **the R- abbreviation refers to Raw Salvaging**"）✓；
- 百科原文：`player/ui/encyclopedia/chapters/resourcemanagement.lua:53`（"Refining Mining Lasers and **Raw Mining Lasers**"）、
  `:85`（"Refining Salvaging Lasers and **Raw Salvaging Lasers**"）✓。

---

## 1. 四类对照表（主人用词 ↔ 原版名 ↔ 产出到哪 ↔ 货舱影响 ↔ 决策含义）

> 「资源池」= 派系全局资源库（账户里的精炼材料），不经货舱、不会占舱、不用 Sell 腾舱。
> 「货舱」= 船上 cargo bay，会满、要 Sell/Refine 腾出，否则挡 Trade。

| 主人用词 | 原版名 | 产出到哪 | 货舱影响 | 决策含义 |
|---|---|---|---|---|
| 粗采集 | Raw Mining Laser（R-Mining） | 原矿 → **货舱**（需后续精炼） | 会占舱；后台命令有**货舱下限门**；召回时粗料落舱 | 货舱会成为瓶颈；需 Cargo Blocks；收益不直接到账 |
| 净化采集 | Mining Laser（Refining） | 精炼资源 → **资源池**（即到账） | 不占舱 | 货舱不成为瓶颈；无需 Sell 腾舱；收益直接到账 |
| 粗分解 | Raw Salvaging Laser（R-Salvaging） | 废铁 → **货舱**（需后续精炼） | 会占舱；后台命令有**货舱下限门**；召回时粗料落舱 | 同上；另 Salvage 还会捡到交易货物（也占舱） |
| 净化分解 | Salvaging Laser（Refining） | 精炼资源 → **资源池**（即到账） | 不占舱（但捡到的交易货物仍占舱） | 货舱不成为瓶颈；收益直接到账 |

- 产出流向的证据：`resourcemanagement.lua:64-69`（R-Mining 把矿打碎成 **ore**，存进 **Cargo Bay**，需 Cargo Blocks，之后到 Resource Depot 精炼）、
  `:91-95`（Refining 直接提取资源进账户；Raw 需要货舱收集 + 之后精炼）✓。
- 货舱下限门的证据：`minecommand.lua:872-877`、`salvagecommand.lua:991-996`（见 §2/§4）✓。
- 召回时粗料落舱的证据：`minecommand.lua:288-339`、`salvagecommand.lua:347-395`（见 §6）✓。

---

## 2. 粗采集（Raw Mining / R-Mining Laser）

- **产出到哪**：原矿（ore）进**货舱**，之后要到 Resource Depot 精炼成材料。
  `resourcemanagement.lua:64-69` ✓；矿石是独立货物（`lib/goodsindex.lua:68` "Iron Ore" 等，`tags={ore=true}`）。
- **效率字段**：`stoneRawEfficiency`，生成基值 `0.63 + rand(0,0.06) + rarity*0.06`
  （`weapongenerator.lua:148`）——比净化版的 `0.15` 高出约 **4 倍**（`:77`）✓。
- **炮塔要求**：`RawMiningLaser` 一类（`weapontype.lua:43`）；射程 150 vs 净化版 75（`:132` vs `:63`）。
- **可采层级**：与净化版**完全相同**——都由 `Balancing_MineableBy(minedMaterial, laserMaterial)`
  判定，看的是**炮塔材料**（`laserMaterial = turret.material`，`minecommand.lua:647`），
  `laserMaterial.value + 1 >= minedMaterial.value`（`lib/galaxy.lua:412-414`）。
  **粗/净化不影响可采层级** ✓。
- **后台命令里的代价（有明确数值）**：
  - 8% 精炼税：`refineryTax = 0.08`（`minecommand.lua:756`）；粗料进入产量时乘 `(1 - refineryTax)`（`:992`）✓。
  - 货舱下限门：`maxOres = min(600000, cargoSpace / ore.size)`（`:755` `:872`）；
    `rawMining and maxOres <= 1000` → 报错「货舱没空间」无法开单（`:874-877`）✓。
  - 精炼往返耗时：开单即扣 `maxCarriableOres*0.5/2000 + 180s`（`:754` `:734` `:948-951`）；
    舱满再扣一次 `currentOres/2000 + 180s`（`:996-1003`）；多次往返 → `cargoEfficiency` 掉（`:1104-1115`）✓。

## 3. 净化采集（Refined Mining / Mining Laser）

- **产出到哪**：精炼资源**直接进派系资源池**，不占货舱。
  百科 `resourcemanagement.lua:91-93`（Refining 直接提取，需大量能量、效率显著低于 Raw）✓。
- **效率字段**：`stoneRefinedEfficiency`，基值 `0.15 + rand(0,0.015) + rarity*0.015`（`weapongenerator.lua:77`）✓。
- **炮塔要求**：`MiningLaser` 一类（`weapontype.lua:42`）。
- **可采层级**：同 §2，由 `Balancing_MineableBy` 判定，与粗/净化无关 ✓。
- **代价（明确数值）**：效率约为粗版的 **1/4**（0.15 vs 0.63）——这就是「净化」换「不占舱」的代价。
  **没有额外模块**；不需要货舱。

## 4. 粗分解（Raw Salvaging / R-Salvaging Laser）

- **产出到哪**：废铁（scrap metal）进**货舱**，之后精炼。
  `resourcemanagement.lua:94-95`（Raw 提取废铁需货舱收集、Resource Depot 精炼，小额费用）✓；
  废铁是独立货物（`lib/goodsindex.lua:119-126` "Scrap Iron" 等，`tags={scrap=true}`）。
- **效率字段**：`metalRawEfficiency`，基值 `0.45 + rand(0,0.05) + rarity*0.05`（`weapongenerator.lua:185`）
  vs 净化版 `0.12`（`:111`）——约 **3.75 倍** ✓。
- **炮塔要求**：`RawSalvagingLaser` 一类（`weapontype.lua:45`）。
- **可拆层级**：同采集，`Balancing_MineableBy(collectedMaterial, laserMaterial)`（`salvagecommand.lua:732`），
  与粗/净化无关 ✓。
- **后台命令里的代价（有明确数值）**：同采集——8% 精炼税（`salvagecommand.lua:863`）、
  货舱下限门 `maxScrapMetal = min(600000, cargoSpace/Scrap.size)` 且 `<=2000` 报错（`:862` `:991` `:993-996`）、
  精炼往返 300s（`:842`，比采集的 180s 更长）、且 **货物空间砍半**留舱给废铁（`:1065-1072`）✓。

## 5. 净化分解（Refined Salvaging / Salvaging Laser）

- **产出到哪**：精炼资源**直接进派系资源池**，不占货舱（`resourcemanagement.lua:85`、`:91-93`）。
  ★ 但注意：Salvage 命令**还会捡到残骸里的交易货物**，那些**仍进货舱**（`salvagecommand.lua:1147-1166` 收集 `cargos`，
  `onFinish` 的 `makeFoundCargos` + `setCargo` `:431-433`）——所以「不占舱」只针对**精炼资源/废铁**，不针对捡到的货 ✓。
- **效率字段**：`metalRefinedEfficiency`，基值 `0.12 + rand(0,0.01) + rarity*0.01`（`weapongenerator.lua:111`）✓。
- **炮塔要求**：`SalvagingLaser` 一类（`weapontype.lua:44`）。
- **可拆层级**：同 §4，与粗/净化无关 ✓。
- **代价**：效率约为粗版 **1/4**（0.12 vs 0.45），换「不占舱」；无额外模块。
  ★ 另：无打捞激光时可**用武装炮塔兜底**——`dropChance 0.4 × efficiency 0.02`，且按 0.1/0.9 偏向 raw
  （`salvagecommand.lua:773-787`、`:795-798`）✓。

---

## 6. 关键函数出处（代码里在哪判「产出到哪」）

- **能力收集（炮塔 → 粗/净化布尔 + 效率权重）**：
  - `MineCommand:getMiningProperties`（`minecommand.lua:545`）：遍历 `entry:getTurrets()`（`:552`），
    `stoneRefinedEfficiency>0` → `properties.refinedMining=true`（`:652-657`），
    `stoneRawEfficiency>0` → `properties.rawMining=true`（`:659-664`）。
  - `SalvageCommand:getSalvagingProperties`（`salvagecommand.lua:626`）：`metalRefinedEfficiency>0` → `refinedSalvaging`（`:734-738`），
    `metalRawEfficiency>0` → `rawSalvaging`（`:741-745`）。
- **混装时产出怎么分（DPS 加权）**：
  - 注释直接说明：「depending on the DPS it's more likely for raw/refining lasers to do the **last hit**,
    resulting in refined or raw resources」（`minecommand.lua:673-674`、`salvagecommand.lua:759-760`）✓。
  - 权重公式：`refinedEfficiencyWeight = refiningDps/(refiningDps+rawDps)`、
    `rawEfficiencyWeight = rawDps/(refiningDps+rawDps)`（`minecommand.lua:682-684`、`salvagecommand.lua:768-770`）✓。
- **单颗小行星/残骸的产出切分**：
  - `MineCommand:calculateGatheredResources`（`minecommand.lua:720-727`）：
    `refined = refinedEfficiency × refinedEfficiencyWeight × resourcesPerAsteroid`、`raw = …× rawEfficiencyWeight × …`。
  - `SalvageCommand:calculateGatheredResources`（`salvagecommand.lua:823-835`）：同构，外加 `credits`。
- **同一艘船两种设备都有 → 货舱与资源池是否同时进账**：
  - **后台命令正常完成**：**不**同时进账——粗料在循环里被内部精炼，最终**全进资源池**；
    `gatheredResources[material] += refined + oresGained*(1-refineryTax)`（`minecommand.lua:992`、`salvagecommand.lua:1136`），
    结算走 `sendYield`（`minecommand.lua:179-186`：`immediateDelivery` → `parent:receive`，否则 `addYield`；`salvagecommand.lua:223-232` 同）。
  - **被伏击召回（onRecall）时才分流**：精炼部分 → `addYield`（进资源池），
    粗部分按 `rawEfficiencyWeight` 拆出、**写进货舱**（`minecommand.lua:288-339`：`:303` 拆比例、`:312` 上限半舱、`:320-338` 写 ore 入 `cargo`；`salvagecommand.lua:347-395` 写 Scrap）✓。
- **「即到账」的开关**：`immediateDelivery`（默认 false）只决定**结算时点**（任务中 `receive` vs 结束时 `addYield`），
  不影响「精炼资源进资源池、不占货舱」这一事实（`minecommand.lua:179-186`、`:526`）✓。

---

## 7. 与现有文档/提示词说法的冲突（明说，不静默统一）

1. **命名冲突（最重要）**：本项目若出现「R-Mining = 净化/精炼」的说法，**与原版相反**。
   原版 `weapongenerator.lua:138-139` 明确「R- abbreviation refers to **Raw** Mining」。
   本文 §0 的对照表是权威口径。
2. **`card.lua` 的 yield 文案不精确**（`mods/copilot/data/scripts/lib/copilot/card.lua:363`）：
   > "refined mining output goes straight into the faction stockpile … **cargo space is NOT a constraint**
   > (only a different mining device fills cargo)"
   这句对**净化激光**成立，但对**粗（Raw）激光不成立**：Raw 有 8% 精炼税 + 货舱下限门（`minecommand.lua:872-877`）、
   且召回时粗料落舱。`card.lua:371`（Salvage）同理，还漏了「捡到的交易货物占舱」。
   **本文未改 card.lua**（它另有 owner），此处只做**冲突标注**。
3. **`MECHANICS.md` / `index.md` 的「不占货舱」说法是简化**：
   - `MECHANICS.md:87`「精采矿；会装满货舱的是另一种采矿设备」、`docs/game/mechanics/index.md:47` 同——方向对，
     但「另一种设备」= 原版的 **Raw（R-）** 一档，且后台命令里 Raw 也是被内部精炼（非真的装满货舱，只在**召回**时落舱）。
     细节见本文 §2/§4/§6，**不改写 MECHANICS.md**（它是生成源，见仓库 `MECHANICS.md:8-10`）。

---

## 8. 未验证项

- ⚠未验证：星区内（非后台命令）到 Resource Depot 精炼的**具体手续费率**——百科只说 "for a small fee"
  （`resourcemanagement.lua:95`），没给数字；后台命令里用的是 **8%**（`minecommand.lua:756` / `salvagecommand.lua:863`）✓。
- ⚠未验证：`immediateDelivery` 的 `receive` 是否真的**逐批**到账（代码在 `minecommand.lua:180-182`，语义为「直接送达账户」，
  但本鱼未开游戏逐帧看账户余额变化）。
