/**
 * dossier.ts —— ★★ 单发路径的**有界档案**（2026-10-17 按主人批准的改动加 ✓✓）
 *
 * ## 它解决的到底是什么（把根因说清楚，不然下次还会再犯 ✗）
 *
 * 一条投进会话的 `<fleet_task>` 曾经长到 **8,761,847 字符** ✓。根因**不是**"少了一个上限" ✗，
 * 而是插件把**预取的全部数据**原样**推**给会话：
 *   · 船卡**两遍**（任务块一遍 + 提示词一遍 ✓）、
 *   · 每个计划的**原始 JSON**（一份 Scout 计划就是 8.7 MB ✓）、
 *   · 再叠一层**渲染好的候选表** ✓、
 *   · 再加一大段解释性散文 ✓。
 *
 * 主人给的设计（原话）：
 *   「你应该仅投递决策请求，就仅仅是告知会话，有东西需要决策就行了，
 *     然后会话再根据插件提供的工具自行查询，有什么东西需要决策。」
 * → 于是三条路**各自有各自的渲染** ✓✓，**共享的只有数据** ✓：
 *
 * | 路径 | 渲染在哪 | 体积策略 |
 * |---|---|---|
 * | agent（投递进会话） | `task.ts` 的 `renderTaskBlock` | **一行通知 + 工具指针**（< 2 KB ✓） |
 * | agent 自己查 | 游戏侧 `planQuery`（**compact 缺省** ✓） | 有界小答案 ✓（`link_in.lua`） |
 * | 单发（无工具、无文件） | **本文件** | **预取 + 裁剪 + 硬字节预算** ✓ |
 *
 * ## 单发那条路为什么必须"预取"
 *
 * 它是**一个没有工具、没有文件访问**的模型调用 ✓（`ctx.llm.stream` 一次性问答 ✓）——
 * 它**不能**自己查任何东西 ✗。所以它必须**带着数据上桌** ✓；但"带多少"必须**有界** ✓。
 * 于是：数据来自游戏侧的 `query {what:"dossier"}`（船 + 规则 + 能做什么 + 每个计划前几个候选 ✓，
 * 已经是 compact + trim 的 ✓），本文件再按**自己的字节预算**收一道 ✓。
 *
 * ## 裁剪顺序（**确定性** —— 同一份输入一定裁出同一份输出 ✓，测试钉住了它 ✓✓）
 *
 * 预算不够时**严格按下面这个顺序**一刀一刀来，每一刀都记进 `dropped` ✓（绝不静默 ✗✓）：
 *
 * ```
 * ① 散文：先砍"说明性段落"（读法 / 口径 / note），数字全留 ✓
 * ② 候选行数：每个计划逐步 3 → 2 → 1 行（先砍每张表的**尾行** ✓）
 * ③ 计划的辅助段：scan / coverage / 邻域覆盖 / 能力表 / 口径（审计用 ✓）
 * ④ 整个计划段：按固定顺序 Sell → Scout → Trade → Salvage → Mine 丢
 *    （留到最后的正是"最可能这一单要用的" ✓：Mine 是默认动作 ✓）
 * ⑤ 兜底：只留"船 + 规则 + 能做什么"这三段骨架 ✓
 * ⑥ 仍然超预算 → **明说自己超了** ✓，并留给最后那道**钝刀**（index.ts 的
 *    `PROMPT_JSON_MAX_CHARS` ✓）—— 它是**最后的保险丝**，不该是"救我们命的那一件" ✓✓
 *    （本文件与测试保证正常情况它碰不到 ✓）。
 * ```
 *
 * ★ 为什么顺序是"先散文、后数字" ✗✓：散文（"怎么读这个数"）**平台提示词里已经有了** ✓
 *   （`prompt/system.md` 就是为这件事存在的 ✓），而**数字没有替代品** ✗ ——
 *   删掉一个数字，单发那条路就再也拿不回来了 ✓。
 */
const DEFAULT_BUDGET = 24_000;
const DEFAULT_ROWS = 3;
/** UTF-8 字节数（**权威口径** —— 会话/上下文限制都是按字节算的 ✓） */
export function byteLen(s) {
    return Buffer.byteLength(s, 'utf8');
}
/** 数字格式化：**不编** ✗ —— 认不出就写 `?`（"缺数据"是一个事实 ✓） */
function num(v) {
    if (typeof v !== 'number' || !Number.isFinite(v))
        return '?';
    return Number.isInteger(v) ? String(v) : String(Math.round(v * 1000) / 1000);
}
function pct(v) {
    if (typeof v !== 'number' || !Number.isFinite(v))
        return '?';
    return `${Math.round(v * 1000) / 10}%`;
}
function str(v) {
    if (typeof v === 'string' && v !== '')
        return v;
    if (typeof v === 'number')
        return String(v);
    return undefined;
}
/**
 * 计划段的**丢弃顺序**（固定 ✓ —— 测试钉住它 ✓）。留下的最后一个是最可能要用到的 ✓。
 * ★ 这是**规则**不是建议 ✗：`renderDossier` 的 ④ 刀就按这个数组走 ✓。
 */
export const PLAN_DROP_ORDER = ['Sell', 'Scout', 'Trade', 'Salvage', 'Mine'];
function renderShip(d) {
    const L = [];
    const nm = str(d.name) ?? '(船名读不到 ✗)';
    const sec = d.sector;
    const where = sec !== null && sec !== undefined && typeof sec.x === 'number' && typeof sec.y === 'number'
        ? `(${String(sec.x)},${String(sec.y)})`
        : '(坐标读不到 —— **当作缺数据** ✓，不要当成 (0,0) ✗)';
    L.push(`船：${nm}  星区：${where}`);
    const bits = [];
    if (d.busy !== undefined)
        bits.push(`忙=${d.busy === true ? '是' : '否'}`);
    if (d.hasCaptain !== undefined)
        bits.push(`有船长=${d.hasCaptain === true ? '是' : '否'}`);
    if (d.captainClass !== undefined)
        bits.push(`船长职业=${d.captainClass}`);
    if (d.freeCargoSpace !== undefined)
        bits.push(`剩余舱位=${num(d.freeCargoSpace)}`);
    if (d.cargoUsed !== undefined) {
        bits.push(`船上有货=${num(d.cargoUsed)}` +
            (d.cargoCapacity !== undefined ? `/${num(d.cargoCapacity)}（${num(d.cargoUsedPercent)}%）` : ''));
    }
    if (d.holdHasGoods === true)
        bits.push('★ 先 Sell 变现，否则贸易装不进货');
    if (bits.length > 0)
        L.push(bits.join('  '));
    const hs = d.hyperspace;
    if (hs !== null && hs !== undefined && typeof hs === 'object') {
        L.push(`跳跃：航程=${num(hs.reach)}  能穿裂隙=${hs.canPassRifts === true ? '是' : '否'}`);
    }
    return L;
}
function renderRules(goalText, goalOptions, gate) {
    const L = [];
    L.push(`主人给这艘船的目标：${goalText !== '' ? goalText : '(只给了动作边界，没有文字目标)'}`);
    // ★ 2026-10-19：这层仍是**白名单** ✓，但已**按船自动推导** ✗✓（不再由主人/模型填 ✓）
    L.push(`可选动作（按船自动）：${goalOptions.length > 0 ? goalOptions.join(', ') : '(不限 —— Mine/Salvage/Trade/Travel/Sell/Scout/Refine 里挑)'}`);
    L.push(`风险闸门：attackChance ≤ ${gate}（★ 判断只看**基准**概率 baseAttackChance，不看被 safeMode 修正后的数 ✓）`);
    return L;
}
function renderActions(d) {
    const L = [];
    const names = Array.isArray(d.actionNames) ? d.actionNames : Object.keys(d.actions ?? {});
    if (names.length === 0)
        return L;
    L.push('这艘船现在**能做什么**（游戏卡片口径 ✓）：');
    for (const nm of names) {
        const a = (d.actions ?? {})[nm];
        if (a === undefined) {
            L.push(`  · ${nm}`);
            continue;
        }
        const bits = [];
        const area = a.areaSize;
        if (Array.isArray(area) && area.length >= 2)
            bits.push(`区域 ${String(area[0])}x${String(area[1])}`);
        if (a.shipMustBeInside === true)
            bits.push('船必须在区内');
        if (a.needsCaptain === true)
            bits.push('要船长');
        if (typeof a.captainClass === 'string')
            bits.push(`船长须为 ${a.captainClass}`);
        if (typeof a.minDistance === 'number')
            bits.push(`目的地至少 ${String(a.minDistance)} 跳`);
        L.push(`  · ${nm}${bits.length > 0 ? '：' + bits.join('，') : ''}`);
    }
    return L;
}
/** 取一个"可能是 null 的坐标对象"的 x / y ✓ —— ★ null 与 undefined **一起判** ✗✓ */
function coordOf(v) {
    if (typeof v !== 'object' || v === null)
        return {};
    const o = v;
    return { x: o.x, y: o.y };
}
/**
 * 一行候选的**绝对框心** ✓ —— 三级来源，**绝不自己算** ✗（模型不做算术，插件也不该猜 ✓）：
 *   ① 游戏侧早就算好的 `x` / `y` ✓（首选 —— 它连星系边界都夹好了 ✓）；
 *   ② 退回 `area.lower/upper`（**同一对数字的另一种写法** ✓ —— 老替身/旧响应只有这个 ✓）；
 *   ③ 再退回 `offset`（**相对**船的偏移 ✓ —— 那就**明说**是相对值 ✗，别让它看起来像绝对值 ✓）。
 *
 * ★★ 每一层都**必须先判 null** ✗✓（2026-10-17 实机崩溃抓到，与 index.ts 里那两处同源 ✓）：
 *   JSON 里"没有"常常写成 **null** ✓ —— 而 `null !== undefined` 成立 ✗ →
 *   直接点 `.x` 就抛 `Cannot read properties of null (reading 'x')` ✓✓。
 *   本文件就在这次自检里**真的**被它崩过一次（单发那条路直接失败 ✗ → 舰队没有决策 ✓）。
 */
function centreOf(r) {
    if (typeof r.x === 'number' && typeof r.y === 'number')
        return { x: r.x, y: r.y, relative: false };
    const area = (typeof r.area === 'object' && r.area !== null)
        ? r.area
        : undefined;
    const lo = coordOf(area?.lower);
    const up = coordOf(area?.upper);
    if (typeof lo.x === 'number' && typeof up.x === 'number'
        && typeof lo.y === 'number' && typeof up.y === 'number') {
        return {
            x: lo.x + Math.floor((up.x - lo.x + 1 - 1) / 2),
            y: lo.y + Math.floor((up.y - lo.y + 1 - 1) / 2),
            relative: false,
        };
    }
    const off = coordOf(r.offset);
    if (typeof off.x === 'number' && typeof off.y === 'number') {
        return { x: off.x, y: off.y, relative: true };
    }
    return { relative: false };
}
/** 一行候选（**表**格式，与主人要的"并排比较"一致 ✓） */
function renderRow(action, r) {
    const centre = centreOf(r);
    const cells = [
        `${num(centre.x)},${num(centre.y)}${centre.relative ? '(相对船的偏移 ✗不是绝对坐标)' : ''}`,
        r.shape === undefined || r.shape === null ? '?' : String(r.shape),
        r.origin === 'fine' ? '细扫' : '粗扫',
    ];
    if (action === 'Mine' || action === 'Salvage') {
        cells.push(String(r.bestTag ?? '?'));
        cells.push(`时长${num(r.duration)}`);
        cells.push(`safeMode=${r.safeMode === true ? '开' : '关'}`);
        cells.push(`基准风险${pct(r.baseAttackChance)}`);
        cells.push(`本次概率${pct(r.attackChance)}`);
        cells.push(`产出${num(r.valueLow)}~${num(r.valueHigh)}`);
        cells.push(`最高层级${num(r.topTier)}/${String(r.topMaterial ?? '?')}`);
        if (r.items !== undefined)
            cells.push(`装备件数${num(r.items.from)}~${num(r.items.to)}`);
    }
    else if (action === 'Trade') {
        cells.push(String(r.bestRouteName ?? '(无路线)'));
        cells.push(`伏击${pct(r.attackChanceBase ?? r.attackChance)}`);
        cells.push(`净收益${num(r.netProfitLow)}~${num(r.netProfitHigh)}`);
        cells.push(`航班${num(r.flights)}`);
        cells.push(`预付金${num(r.deposit)}`);
    }
    else if (action === 'Sell') {
        cells.push(`伏击${pct(r.attackChanceBase ?? r.attackChance)}`);
        cells.push(`期望净收益${num(r.netProfitLow)}~${num(r.netProfitHigh)}`);
        cells.push(`时长${num(r.duration)}`);
    }
    else if (action === 'Scout') {
        cells.push(`框内未探索${num(r.unknownCount)}/${num(r.totalSectors)}`);
        cells.push(`伏击${pct(r.attackChanceBase ?? r.attackChance)}`);
        cells.push(`离中心${num(r.distance)}`);
    }
    cells.push(r.acceptable === true ? '达标' : '不达标');
    return `| ${cells.join(' | ')} |`;
}
function renderPlan(action, p, o) {
    const L = [];
    const rec = p.recommendation;
    const recBits = [];
    if (rec !== null && rec !== undefined && typeof rec === 'object') {
        if (rec.goodName !== undefined)
            recBits.push(`货「${String(rec.goodName)}」`);
        if (rec.x !== undefined)
            recBits.push(`框心 ${num(rec.x)},${num(rec.y)}`);
        if (rec.sizeX !== undefined)
            recBits.push(`形状 ${num(rec.sizeX)}x${num(rec.sizeY)}`);
        if (rec.attackChance !== undefined)
            recBits.push(`伏击 ${pct(rec.attackChance)}`);
        if (rec.baseAttackChance !== undefined)
            recBits.push(`基准 ${pct(rec.baseAttackChance)}`);
        if (rec.netProfitLow !== undefined)
            recBits.push(`期望净收益 ${num(rec.netProfitLow)}~${num(rec.netProfitHigh)}`);
        if (rec.valueLow !== undefined)
            recBits.push(`产出 ${num(rec.valueLow)}~${num(rec.valueHigh)}`);
        if (rec.duration !== undefined)
            recBits.push(`时长 ${num(rec.duration)}`);
        if (rec.unknownCount !== undefined)
            recBits.push(`框内未探索 ${num(rec.unknownCount)}/${num(rec.totalSectors)}`);
        if (rec.deposit !== undefined)
            recBits.push(`预付金 ${num(rec.deposit)}`);
        if (rec.safeMode !== undefined)
            recBits.push(`safeMode=${rec.safeMode === true ? '开' : '关'}`);
        if (Array.isArray(rec.escorts) && rec.escorts.length > 0)
            recBits.push(`护航 ${rec.escorts.join(',')}`);
    }
    L.push(`★★ ${action}${recBits.length > 0 ? ' —— 评分器推荐：' + recBits.join('，') : ''}`);
    if (recBits.length === 0) {
        // ★★ 零候选必须**说清是哪一种** ✗✓（"没设备"/"不知道"/"真没有" 是三件事 ✓）
        const why = str(p.riskWarning) ?? str(p.noCandidatesReason) ?? '没有推荐，也没给出原因 ✗（当成缺数据 ✓）';
        L.push(`   无推荐：${why}`);
        if (p.noCandidatesReasonKind !== undefined)
            L.push(`   原因类别：${String(p.noCandidatesReasonKind)}`);
    }
    // ★★ 两种形状都吃 ✗✓（2026-10-17 自查抓到）：
    //   游戏侧的计划里叫 `areaRanking` ✓，而插件侧 `facts.tradeRoutes` 是**投影过**的
    //   （它把候选放在 `areas` 里 ✓，且只留了要用的字段 ✓）。少认一种 = 那张表**静默消失** ✗✓。
    const rows = Array.isArray(p.areaRanking)
        ? p.areaRanking
        : (Array.isArray(p.areas) ? (p.areas ?? []) : []);
    const shown = rows.slice(0, Math.max(1, Math.min(o.rows, rows.length)));
    if (shown.length > 0) {
        L.push(`   候选框（共 ${rows.length} 个，这里列前 ${shown.length} 个 ✓；x/y 是**已经算好的绝对星区坐标**（框心）✓，`);
        L.push('   不要再加 offset、也不要加船的位置 ✗ —— 那句 "绝对星区坐标" 说的就是这件事 ✓。');
        L.push('   ★ **同一个星区里，框的位置可以变** ✓（框心只能在船周围 half 格之内平移 ✓）；');
        L.push('   `"origin"` = 粗扫还是细扫发现的；`offset` = 相对船所在星区的偏移 ✓）：');
        for (const r of shown)
            L.push('   ' + renderRow(action, r));
    }
    // ★★ Sell 的**逐货数字**必须真的送到眼前 ✗✓（主人 2026-10-17 的要求 ✓）：
    //   这里按**原字段名**列出来 ✓ —— 它们是**算好的数字** ✓，单发那条路没法再查 ✓，
    //   所以一个都不能省 ✓（`expectedRevenue` / `priceDeltaPercent` /
    //   `expectedUnitPrice` / `normalRevenueEstimate` 都要看得见 ✓）。
    if (action === 'Sell') {
        const recRow = (p.recommendation ?? {});
        const perGood = Array.isArray(recRow.perGood) ? recRow.perGood : [];
        for (const g of perGood) {
            const bits = [`货「${String(g.goodName ?? '?')}」`];
            if (g.amount !== undefined)
                bits.push(`amount=${num(g.amount)}`);
            if (g.expectedRevenue !== undefined)
                bits.push(`expectedRevenue=${num(g.expectedRevenue)}`);
            // ★ 这一项用**原样 JSON 片段**（`"priceDeltaPercent":50` ✓）——
            //   因为它是**带符号的涨跌幅** ✓，模型最容易读错的就是它 ✓（数字写法是主人点名的 ✓）。
            if (g.priceDeltaPercent !== undefined)
                bits.push(`"priceDeltaPercent":${num(g.priceDeltaPercent)}`);
            if (g.expectedUnitPrice !== undefined)
                bits.push(`expectedUnitPrice=${num(g.expectedUnitPrice)}`);
            if (g.normalRevenueEstimate !== undefined)
                bits.push(`normalRevenueEstimate=${num(g.normalRevenueEstimate)}`);
            L.push(`   · ${bits.join('  ')}`);
        }
        const best = Array.isArray(p.perGoodBest) ? p.perGoodBest : [];
        if (best.length > 0) {
            L.push('   · perGoodBest（**跨框**每种货期望收入最高的那个框 ✓）：');
            for (const g of best.slice(0, o.rows)) {
                const off = coordOf(g.offset);
                L.push(`     - 货「${String(g.goodName ?? '?')}」` +
                    (g.expectedRevenue !== undefined ? ` expectedRevenue=${num(g.expectedRevenue)}` : '') +
                    (typeof off.x === 'number' ? ` offset=${num(off.x)},${num(off.y)}` : '') +
                    (g.origin !== undefined && g.origin !== null ? ` origin=${String(g.origin)}` : ''));
            }
        }
        const hold = p.hold;
        if (hold !== null && hold !== undefined && typeof hold === 'object') {
            L.push(`   · 货舱 hold{}：used=${num(hold.used)} capacity=${num(hold.capacity)} free=${num(hold.free)}` +
                ` usedPercent=${num(hold.usedPercent)} isHoldFull=${String(hold.isHoldFull)}` +
                ` blocksTradeLoading=${String(hold.blocksTradeLoading)}`);
        }
    }
    if (o.aux) {
        const bits = [];
        if (p.areasScanned !== undefined)
            bits.push(`粗扫 ${num(p.areasScanned)} 区`);
        if (p.boxesEvaluated !== undefined)
            bits.push(`共评估 ${num(p.boxesEvaluated)} 框`);
        if (p.scanMs !== undefined)
            bits.push(`${num(p.scanMs)}ms`);
        if (bits.length > 0)
            L.push(`   扫描：${bits.join(' / ')}`);
        const cap = p.capability;
        if (cap !== null && cap !== undefined && Array.isArray(cap.materials)) {
            const mats = cap.materials.map((m) => `${String(m.material ?? '?')}:dps=${num(m.dps)}`);
            if (mats.length > 0)
                L.push(`   这船对这几种材料的能力：${mats.join(' ')}（dps=0 = 完全采不动 ✓）`);
        }
        const cov = p.coverage;
        if (cov !== null && cov !== undefined && cov.unknown !== undefined) {
            L.push(`   船所在邻域未探索：${num(cov.unknown)}/${num(cov.total)}`);
        }
    }
    if (o.prose) {
        const sb = str(p.scoreBasis);
        if (sb !== undefined)
            L.push(`   口径：${sb}`);
    }
    return L;
}
function render(d, goalText, goalOptions, gate, planList, o, escorts, missing) {
    const L = [];
    L.push(...renderShip(d));
    L.push('');
    L.push(...renderRules(goalText, goalOptions, gate));
    L.push('');
    if (missing.length > 0) {
        L.push(`★ 本次有 ${missing.length} 个计划**没取到**（取数失败 ✗ —— **并不代表那里没有候选** ✗）：${missing.join('、')}`);
        L.push('   → 不要据"它没来"就断定"没得挖/没得捞" ✗；可以再等一轮、换个动作、先侦察/换位置，或先做别的 ✓。');
        L.push('');
    }
    const acts = renderActions(d);
    if (acts.length > 0) {
        L.push(...acts);
        L.push('');
    }
    // ★ 护航候选 = **舰队名单里**能来护航的船 ✓（判据见 index.ts 的那段 ✓）。
    //   ★★ 2026-10-24：门控从 `有 Trade 计划段` 改成 `名单非空` ✗→✓ ——
    //     单发兜底**不再预取任何 legacy 计划** ✓，所以"有 Trade 计划才印名单"会让这份名单
    //     永远不出现 ✗。名单本身是**原子事实**（一次 roster 读 ✓，不扫区域 ✓），照旧给模型看 ✓。
    if (escorts.length > 0) {
        L.push(`护航候选（★ 原版判据：与行动船距离 ≤ 护卫**自己一跳的航程** —— **不要求同星系** ✗✓）：${escorts.join(', ')}`);
        L.push('  候选路线的伏击概率偏高时，可以带 1~2 艘护航把它压到闸门内；`attackChanceBase` 是不带护航的基准 ✓。');
        L.push('');
    }
    // ★★ 2026-10-24：**没有计划**就明说 ✗✓（单发兜底不再预扫描 ✓ —— 见 index.ts 的
    //   `prefetchSingleShot` ✓）。这一句是**显式事实**，不是沉默：
    //   模型据此老实给 None / 先侦察 / 换个动作 ✓，**绝不凭空编一个框心** ✗✓。
    if (planList.length === 0) {
        L.push('★ 计划：**无计划（已移除预扫描）** —— 本次**没有**预取 tradePlan / minePlan /');
        L.push('  salvagePlan / sellPlan / scoutPlan ✓（它们会在游戏主循环里同步扫 67~71 个区域 ✗）。');
        L.push('  → 想挖 / 捞 / 跑商 / 侦察，请**先给 None**（或只做能凭现有事实判断的事）✓，');
        L.push('    **不要凭空编一个框心** ✗✓；要真候选框，得让决策者用原子接口点名');
        L.push('    （`predict` ≤24 框 / `tradeRoutes` / `tradeEvaluate`）✓。');
        L.push('');
    }
    for (const item of planList) {
        L.push(...renderPlan(item.action, item.plan, o));
        L.push('');
    }
    L.push('请按系统提示的格式回复（action 必须在第一行 ✓）。');
    return L.join('\n');
}
/**
 * ★★ 主入口：把游戏侧的有界档案渲染成**必然落在预算内**的一段文本 ✓。
 *
 * 保证（测试里逐条断言过 ✓）：
 *   · 返回的 `text` **UTF-8 字节数 ≤ budgetBytes** ✓（除非连骨架都超 —— 那也会**明说** ✓）
 *   · **确定性** ✓：同一份输入 → 同一份输出（同一串 `dropped` ✓）
 *   · 保证事实**永远在** ✓：船名 / 星区 / 目标 / 允许的动作 / 风险闸门 / 能做什么
 *     （它们在第 ①~⑥ 刀里**从不被砍** ✓ —— 砍的只有散文、行数、辅助段、整段计划 ✓）
 *
 * ★ 输入的两种形状都吃 ✓：
 *   · `query {what:"dossier"}` 的**整段载荷**（`{card, goal, gate, plans}` ✓ —— 首选 ✓）
 *   · 一张**能力卡**（兜底 / 测试用 ✓）
 */
export function renderDossier(input) {
    const budget = Math.max(512, Math.floor(input.budgetBytes ?? DEFAULT_BUDGET));
    const rows0 = Math.max(1, Math.floor(input.rowsPerPlan ?? DEFAULT_ROWS));
    const rootRaw = (input.payload ?? input.fallbackCard ?? {});
    // ★★ "没取到 ≠ 没有候选"（2026-10-17 血案 ✓）：取数失败的计划**不能**被读成"那里没候选" ✗。
    //   数据由 index.ts 的 `dossierInputOf()` 以 `planFetchFailures`（[{what,why}]）带进来 ✓。
    const missing = (() => {
        const raw = rootRaw.planFetchFailures;
        if (!Array.isArray(raw))
            return [];
        return raw.map((m) => {
            if (m !== null && typeof m === 'object') {
                const w = m.what;
                return typeof w === 'string' && w !== '' ? w : '?';
            }
            return typeof m === 'string' && m !== '' ? m : '?';
        });
    })();
    // ★★ 形状归一 ✗✓：`dossier` 载荷把船卡放在 `card` 里 ✓ —— 老形状（直接一张卡）也照吃 ✓。
    const cardSrc = (rootRaw.card !== undefined && rootRaw.card !== null
        ? rootRaw.card
        : rootRaw);
    const goalObj = (rootRaw.goal ?? {});
    const goalText = input.goalText !== '' ? input.goalText : (str(goalObj.text) ?? '');
    const goalOptions = input.goalOptions.length > 0
        ? input.goalOptions
        : (Array.isArray(goalObj.options) ? goalObj.options.map((o) => String(o)) : []);
    const gate = input.gate ?? (typeof rootRaw.gate === 'number' ? rootRaw.gate : 0.1);
    const log = input.log ?? (() => { });
    const plansRaw = Array.isArray(rootRaw.plans) ? rootRaw.plans : [];
    const all = plansRaw
        .map((p) => ({ action: String(p.action ?? '?'), plan: p }));
    // 顺序固定（按动作名排序 ✓）：渲染顺序不影响内容，但**影响确定性** ✓
    all.sort((a, b) => a.action.localeCompare(b.action));
    const dropped = [];
    const escortCandidates = Array.isArray(input.escortCandidates) ? input.escortCandidates : [];
    const draw = (list, o) => render(cardSrc, goalText, goalOptions, gate, list, o, escortCandidates, missing);
    // ★ **未裁剪的那一份** = 每个计划给**全部**候选、散文与辅助段全开 ✓ ——
    //   它就是 before/after 里的 **before** ✓（不是估算，是**渲染出来量过的** ✓）。
    //   ★ 它**含记忆块** ✓ —— 预算管的是**整个提示词**（记忆块也在里面 ✓），
    //     所以 before/after 必须同一个口径 ✓（否则两个数不可比 ✓）。
    const untouchedText = draw(all, { rows: Number.MAX_SAFE_INTEGER, prose: true, aux: true });
    const mem = input.memoryBlock !== undefined && input.memoryBlock !== '' ? `\n${input.memoryBlock}` : '';
    const untouchedBytes = byteLen(untouchedText + mem);
    const fits = (t) => byteLen(t + mem) <= budget;
    // 骨架（会一直留到最后 ✓）
    const skeleton = draw([], { rows: 1, prose: false, aux: false });
    let remaining = all.slice();
    let state = { rows: rows0, prose: true, aux: true };
    let text = untouchedText;
    const done = () => ({
        text: text + mem,
        stats: {
            budgetBytes: budget, finalBytes: byteLen(text + mem), untouchedBytes,
            rowsPerPlan: state.rows,
            plansIncluded: remaining.map((p) => p.action),
            plansDropped: all.filter((p) => !remaining.includes(p)).map((p) => p.action),
            dropped,
        },
    });
    if (fits(text))
        return done();
    // ---- ① 散文 ----
    state = { ...state, prose: false };
    text = draw(all, state);
    dropped.push('① 散文（读法/口径/note 段落）—— 数字全部保留 ✓');
    if (fits(text))
        return done();
    // ---- ② 候选行数：rows → 2 → 1 ----
    for (const r of [2, 1]) {
        if (r >= rows0)
            continue;
        state = { ...state, rows: r };
        text = draw(all, state);
        dropped.push(`② 每个计划的候选行数 → ${r}（先砍每张表的尾行 ✓）`);
        if (fits(text))
            return done();
    }
    // ---- ③ 计划的辅助段 ----
    state = { ...state, aux: false };
    text = draw(all, state);
    dropped.push('③ 计划的辅助段（扫描统计 / 能力表 / 邻域覆盖 / 口径）');
    if (fits(text))
        return done();
    // ---- ④ 整个计划段（**固定顺序** ✓）----
    for (const act of PLAN_DROP_ORDER) {
        if (!remaining.some((p) => p.action === act))
            continue;
        remaining = remaining.filter((p) => p.action !== act);
        text = draw(remaining, state);
        dropped.push(`④ 丢掉整个 ${act} 计划段（固定顺序：${PLAN_DROP_ORDER.join(' → ')}）`);
        if (fits(text))
            return done();
    }
    // ---- ⑤ 只剩骨架 ----
    text = skeleton;
    remaining = [];
    dropped.push('⑤ 只剩骨架（船 + 规则 + 能做什么）—— ★ 这几段**从不**被砍 ✓');
    if (fits(text))
        return done();
    // ---- ⑥ 连骨架都超预算：**明说**，绝不假装没事 ✓ ----
    dropped.push('⑥ ★ 连骨架都超预算 ✗ —— 已如实写明；最后那道钝刀（PROMPT_JSON_MAX_CHARS）仍在 ✓');
    log(`  ⚠ dossier 骨架本身就 ${byteLen(text + mem)} 字节 > 预算 ${budget} ✓ —— 已如实写明 ✓`);
    const flag = `\n★ 【档案已被压到骨架且仍超预算：${byteLen(text + mem)} > ${budget} 字节 ✓】\n`;
    return {
        text: text + flag + mem,
        stats: {
            budgetBytes: budget, finalBytes: byteLen(text + flag + mem), untouchedBytes,
            rowsPerPlan: 1, plansIncluded: [], plansDropped: all.map((p) => p.action), dropped,
        },
    };
}
//# sourceMappingURL=dossier.js.map