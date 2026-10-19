// ★ 本文件由 docs/game/mechanics-source.md 的「浓缩版」段落生成 —— 不要手改 ✗
//   单一来源: D:\\SteamLibrary\\steamapps\\common\\Avorion\\mods\\copilot\\docs\\game\\mechanics-source.md
//   重新生成: node scripts/render-mechanics.mjs ｜ 校验: node scripts/check-mechanics.mjs
export const MECHANICS_BRIEF = `可用命令（都是后台命令：船长带队离开你的星区，期间联系不上；产出/结算见下）：
- Mine    精采矿：区域 15x15，船须在区内。产出进全局资源，不占货舱。配置 duration(0.5~2+,Miner 船长加长)/safeMode/collected。
- Salvage 打捞：区域 15x15，船须在区内。产出资源 + 装备/插件(炮塔与子系统各半)，稀有度用原版固定混合表(Exceptional .02/Rare .05/Uncommon .25/Common .5/Petty .18)，期望层级约 1.23。配置同 Mine，Scavenger 船长加长时长。
- Trade   贸易：合法区域只有 17x17 / 29x11 / 11x29，船须在区内，且船长必须是 Merchant。需要 goodName(路线名，必填) 与 deposit(>0)。收益 = 每航班利润 × 航班数；预付款结束时退还(不是成本)。被伏击时被中断的那一班不给利润；已完成的班次照算；中止后货可能留在船上。
- Sell    卖货：区域 15x15，船须在区内。卖的是船上那些"该星区有需求"的货。被伏击时只有 runTime>=11 分钟或 >duration*0.8 才按 runTime/duration 部分卖出，否则一点也卖不掉；未卖完的货留在船上。
- Refine  精炼：区域 31x31 且**固定**(isAreaFixed：服务端无视你给的框心、按船重算)，船须在区内。**货舱里必须有原矿**(按货物 tag 认材料，rich 富矿产出×4)；**不需要**精炼厂/阵营/友好度 —— 区域里有自有/友方精炼厂只让时长÷2、税率更低，一个都没有则时长×2(不是错误)。产出进**派系资源池**，货舱里的原矿被扣掉(不变成货舱成品)。没有 duration/safeMode 配置。attackChance 是原版**硬编码 0**(该命令从不登记伏击)。
- Travel  旅行：区域 1x1(目标星区)，船不必在区内；只移动，不产出；★ 原版**服务端**也拒"一跳就能到"的目的地(initialize 里：路线段<=2 → "This route is too short.")，所以现在 order 的预检直接回 MIN_DISTANCE、不发单。到达后可在那儿接新命令；航程中坐标**不变**(只在到达/召回时写)，所以"位置没变"不是失败证据(看 busy)。
- Scout   侦察/开图：区域 21x21，船须在区内；配置只有 addCaptainsNote；时长由原版按 reachable/25 自算。产出 revealsOffgrid = 隐藏质量星区的**枚举档位**(0=none / 1=some / 2=all；不是计数 ✗)；真实揭图由原版按运行时间调 revealSectors(ratio) 完成(scoutcommand.lua:157/162/179)，可达星区数在 area.analysis.reachable。

框选区域(所有用框的命令共用)：区域是**必须包含船**的方块，框心可以在这个约束内平移(船不用动)；框选位置不同 → 落在框里的星区不同 → 那里的收益与伏击概率也不同(实机：同船同星区，Salvage 偏移 (0,0)=0.04、(0,-4)=0.02)。Trade 的框形状也能变，合法形状只有 17x17 / 29x11 / 11x29(tradecommand.lua:584-585)。我们的扫描是两阶段的：粗扫(步长 4) + 在最好的几个粗扫框周围步长 1 细扫。计划里每条候选都带绝对星区坐标 x/y(= 框心)与 offset(= 相对船的偏移)。Scout 的候选框另外带**框内未探索星区数**(unknownCount / knownCount / totalSectors，判据 player:getKnownSector(x,y)==nil)；框内一个未探索星区都没有的框，侦察它揭不出新地图。

风险(所有命令共用)：attackChance 是整段任务期间的被伏击概率。被伏击 = 强制召回 + 只按已完成进度部分结算。
- safeMode(Mine/Salvage) 会把概率改成：<0.1 则 0，否则 ×0.1，但只走友方星区、产量下降。
  · ★ **为什么收益低**（原版证据 ✓）：原版提示「The captain avoids dangerous sectors, such as those with
    pirate activity. **However, these contain more resources.**」(minecommand.lua:1260)；
    且 safeMode 会**主动把选择权重从更肥的派系星区挪开**（outerFactionSectorWeight/3、
    centralFactionSectorWeight/1.5，minecommand.lua:1180 附近）—— 字面上把船长赶去更贫瘠的地面。
  · ★★ **主人的规矩（玩家约束）**：「安全模式**一般不要开**；我们说的**安全**是指
    **遭遇伏击概率 < 10%**（是**局势**，不是这个开关）；概率 < 10% 时**绝不要开**；
    它是**最后手段**，不是默认的求稳手段。」✗ 也不许用"没拿到风险数字 → 先开 safeMode 保平安"这条推理 ✗。
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

框选区域(所有用框的命令共用)：区域是**必须包含船**的方块，**框心可以在这个约束内平移**(船不用动)；
框选位置不同 → 落在框里的星区不同 → 那里的收益与伏击概率也不同(实机：同船同星区，Salvage 偏移 (0,0)=0.04、(0,-4)=0.02)。
Trade 的框**形状**也能变，合法形状只有 17x17 / 29x11 / 11x29(tradecommand.lua:584-585)。
我们的扫描是两阶段的：粗扫(步长 4) + 在最好的几个粗扫框周围步长 1 细扫。
计划里每条候选都带绝对星区坐标 x/y(= 框心)与 offset(= 相对船的偏移)。
Scout 的候选框另外带**框内未探索星区数**(unknownCount / knownCount / totalSectors)：判据是
player:getKnownSector(x,y)==nil 视为未探索(orderchain.lua:887)；框内一个未探索星区都没有的框，侦察它揭不出新地图。

风险(所有命令共用)：attackChance 是整段任务期间的被伏击概率。被伏击 = 强制召回 + 只按已完成进度部分结算。
- safeMode(Mine/Salvage) 会把概率改成：<0.1 则 0，否则 ×0.1，但只走友方星区、产量下降。
  · ★ **为什么收益低**（原版证据 ✓）：原版提示「The captain avoids dangerous sectors, such as those with
    pirate activity. **However, these contain more resources.**」(minecommand.lua:1260)；
    且 safeMode 会**主动把选择权重从更肥的派系星区挪开**（outerFactionSectorWeight/3、
    centralFactionSectorWeight/1.5，minecommand.lua:1180 附近）—— 字面上把船长赶去更贫瘠的地面。
  · ★★ **主人的规矩（玩家约束）**：「安全模式**一般不要开**；我们说的**安全**是指
    **遭遇伏击概率 < 10%**（是**局势**，不是这个开关）；概率 < 10% 时**绝不要开**；
    它是**最后手段**，不是默认的求稳手段。」✗ 也不许用"没拿到风险数字 → 先开 safeMode 保平安"这条推理 ✗。
  · ★ 比较口径：判断「概率 < 10% 吗」只看 **baseAttackChance**(= 不开 safeMode 的基准概率，计划里显式给了)；开了 safeMode 之后被修正出的 attackChance 是**结果**不是局势，拿它去比是循环论证 ✗。
- 时长与风险：伏击概率随任务时长上升 —— **超过 1 小时后，每多 1 小时在基准概率上再 +40%**
  （原版 'attackProbability = attackProbability + attackProbability * (hours - 1) * 0.4'，
  'simulationutility.lua:818-821' ✓）；短于 1 小时则低于基准 ✓；最后还会取 'max(baseProbability, …)' ✓。
- 护航既降风险也加产量；护航资格=不忙 + 与行动船距离不超过**护航自己的一个跳跃航程**（同环限制），
  **不要求同星区**；把护航调过来要花一次 Travel 的时间。
  ★ **强到"在那个星区不会被袭击"的护航会把基准概率 ×0.75**（每个这样的护航各乘一次），
  判据是它在采样星区里"不会挨打"的比例 <50%（'simulationutility.lua:810-816' ✓）。

货舱：entry:getCargo() 返回(货物表, 总容量)，entry:getFreeCargoSpace() 是剩余空间。货舱满了(或货占着舱位)会挡住 Trade 装货，Sell 是腾出舱位的命令。★「有货」不等于「满舱」。

能力(会随升级变化)：炮塔数量与类型、跳跃航程、货舱容量/货物、船长职业与专长，决定它能不能采某种矿、能带多少货、能承受多少风险。

深度：越靠地图中心，矿层级越高(Iron<Titanium<Naonite<Trinium<Xanion<Ogonite<Avorion)、装备越好、也越危险。
游戏可直接查询某坐标的富饶度 Balancing_GetSectorRichnessFactor(x,y) 与材料概率 Balancing_GetMaterialProbability(x,y)；Balancing_InsideRing(x,y) 表示中心屏障环内。

计划(plan)给的是事实与选项：多区域 × 多参数档的原版预测数字(伏击概率、风险折算后的期望收益、时长、口径 scoreBasis)。每条候选都带绝对星区坐标 x/y(= 框心)与 offset；每条命令的概率都带 riskKind 标签(Sell/Salvage/Trade 的概率不是一回事，比较前先看标签)。
玩家的风险闸门默认 attackChance<=0.10：超闸门的候选也会列出并标 exceedsRiskLimit=true，不静默丢弃。
recommendation/orderHint 只是其中一个选项，供人审计，不是必须照抄的答案。
已知缺口：计划只在船当前星区周围扫描(框心可在船周围 half 格内平移，但不会跑到别的星区)；可直接查上面的富饶度/材料函数，或先 Travel/Scout 过去。

回执(下单=两段式：先区域分析、6 秒后才 startCommand)：accepted/executed 只代表"进了 RPC 队列"，**不是做成了**。所以回执还带 preflight(下单**前**的前置核对：ok=false 表示**根本没下单**，code 如 MIN_DISTANCE/SHIP_NOT_IN_AREA/CAPTAIN_NOT_MERCHANT；warnings 里是"原版不拒但值得知道"的事，如卖不掉的货被剔除/时长被夹紧/护航没武装)与 verify(下单**后**延迟重读实体状态：ok=false + reason = 启动后短窗口内没有任何成功证据，多半是原版静默拒了)。成功证据：busy=true(=后台在跑，原版在所有闸门之后才置它)最硬；Travel 看位置/到达；Sell/Refine 的货舱只在**跑完**才降，所以短窗口里别指望 cargoUsed 掉。取实测：fleet_query what=orderStatus 带 orderId(或 ship=该船最近一单)；verify.pending=true 只是"还没到采样点"，不是成功。`
