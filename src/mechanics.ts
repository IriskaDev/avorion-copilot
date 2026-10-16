// ★ 本文件由 MECHANICS.md 的「浓缩版」段落生成 —— 不要手改 ✗
//   单一来源: D:/SteamLibrary/steamapps/common/Avorion/mods/copilot/MECHANICS.md
//   重新生成: node scripts/render-mechanics.mjs ｜ 校验: node scripts/check-mechanics.mjs
export const MECHANICS_BRIEF = `可用命令（都是后台命令：船长带队离开你的星区，期间联系不上；产出/结算见下）：
- Mine    精采矿：区域 15x15，船须在区内。产出进全局资源，不占货舱。配置 duration(0.5~2+,Miner 船长加长)/safeMode/collected。
- Salvage 打捞：区域 15x15，船须在区内。产出资源 + 装备/插件(炮塔与子系统各半)，稀有度用原版固定混合表(Exceptional .02/Rare .05/Uncommon .25/Common .5/Petty .18)，期望层级约 1.23。配置同 Mine，Scavenger 船长加长时长。
- Trade   贸易：合法区域只有 17x17 / 29x11 / 11x29，船须在区内，且船长必须是 Merchant。需要 goodName(路线名，必填) 与 deposit(>0)。收益 = 每航班利润 × 航班数；预付款结束时退还(不是成本)。被伏击时被中断的那一班不给利润；已完成的班次照算；中止后货可能留在船上。
- Sell    卖货：区域 15x15，船须在区内。卖的是船上那些"该星区有需求"的货。被伏击时只有 runTime>=11 分钟或 >duration*0.8 才按 runTime/duration 部分卖出，否则一点也卖不掉；未卖完的货留在船上。
- Travel  旅行：区域 1x1(目标星区)，船不必在区内；只移动，不产出；原版不允许"一跳就能到"的目的地(该检查在客户端，经 RPC 可能不生效)。到达后可在那儿接新命令。
- Scout   侦察/开图：区域 21x21，船须在区内；配置只有 addCaptainsNote；时长由原版按 reachable/25 自算。产出 revealsOffgrid = 隐藏质量星区的**枚举档位**(0=none / 1=some / 2=all；不是计数 ✗)；真实揭图由原版按运行时间调 revealSectors(ratio) 完成(scoutcommand.lua:157/162/179)，可达星区数在 area.analysis.reachable。

风险(所有命令共用)：attackChance 是整段任务期间的被伏击概率。被伏击 = 强制召回 + 只按已完成进度部分结算。
- safeMode(Mine/Salvage) 会把概率改成：<0.1 则 0，否则 ×0.1，但只走友方星区、产量下降。
  · ★ **为什么收益低**（原版证据 ✓）：原版提示「The captain avoids dangerous sectors, such as those with
    pirate activity. **However, these contain more resources.**」(minecommand.lua:1260)；
    且 safeMode 会**主动把选择权重从更肥的派系星区挪开**（outerFactionSectorWeight/3、
    centralFactionSectorWeight/1.5，minecommand.lua:1180 附近）—— 字面上把船长赶去更贫瘠的地面。
  · ★★ **主人的规矩（玩家约束）**：safeMode **收益十分低** ——
    **伏击概率在 10% 以下时不要开**；只有伏击概率 **> 10%** 时它才值得考虑。
- 时长与风险：伏击概率随任务时长上升 —— **超过 1 小时后，每多 1 小时在基准概率上再 +40%**
  （原版 'attackProbability = attackProbability + attackProbability * (hours - 1) * 0.4'，
  'simulationutility.lua:818-821' ✓）；短于 1 小时则低于基准 ✓；最后还会取 'max(baseProbability, …)' ✓。
- 护航既降风险也加产量；护航资格=不忙 + 与行动船距离不超过**护航自己的一个跳跃航程**（同环限制），
  **不要求同星区**；把护航调过来要花一次 Travel 的时间。
  ★ **强到"在那个星区不会被袭击"的护航会把基准概率 ×0.75**（每个这样的护航各乘一次），
  判据是它在采样星区里"不会挨打"的比例 <50%（'simulationutility.lua:810-816' ✓）。

能力(会随升级变化)：炮塔数量与类型、跳跃航程、货舱容量/货物、船长职业与专长，决定它能不能采某种矿、能带多少货、能承受多少风险。

深度：越靠地图中心，矿层级越高(Iron<Titanium<Naonite<Trinium<Xanion<Ogonite<Avorion)、装备越好、也越危险。
游戏可直接查询某坐标的富饶度 Balancing_GetSectorRichnessFactor(x,y) 与材料概率 Balancing_GetMaterialProbability(x,y)；Balancing_InsideRing(x,y) 表示中心屏障环内。

计划(plan)给的是事实与选项：多区域 × 多参数档的原版预测数字(伏击概率、风险折算后的期望收益、时长、口径 scoreBasis)。
玩家的风险闸门默认 attackChance<=0.10：超闸门的候选也会列出并标 exceedsRiskLimit=true，不静默丢弃。
recommendation/orderHint 只是其中一个选项，供人审计，不是必须照抄的答案。
已知缺口：计划只在船当前星区周围扫描，没有扫描别处的数字(可直接查上面的富饶度/材料函数，或先 Travel/Scout)；经 RPC 的 Travel 可能不受"不能太近"限制。`
