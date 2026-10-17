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
/** 一份计划里我们**认得**的字段（认不出的一律不猜 ✓ —— 只透传标量 ✓） */
type Row = Record<string, unknown>;
export interface DossierPlan {
    action?: string;
    recommendation?: Row | null;
    riskWarning?: string | null;
    noCandidatesReason?: string | null;
    noCandidatesReasonKind?: string | null;
    orderHint?: Row | null;
    areaRanking?: Row[];
    scanMs?: number;
    areasScanned?: number;
    boxesEvaluated?: number;
    scoreBasis?: string;
    capability?: Row | null;
    durationChoices?: unknown;
    hold?: Row | null;
    perGoodBest?: Row[];
    coverage?: Row | null;
    neighbourhood?: Row | null;
    scan?: Row | null;
    [k: string]: unknown;
}
export interface DossierPayload {
    name?: string;
    sector?: Row | null;
    busy?: boolean;
    hasCaptain?: boolean;
    captainClass?: string;
    captainClassKnown?: boolean;
    freeCargoSpace?: number;
    cargoUsed?: number;
    cargoCapacity?: number;
    cargoUsedPercent?: number;
    holdHasGoods?: boolean;
    cargoState?: string;
    hyperspace?: Row | null;
    actionNames?: string[];
    actions?: Record<string, Row>;
    sectorFacts?: Row | null;
    depth?: Row | null;
    probe?: unknown;
    [k: string]: unknown;
}
export interface DossierInput {
    /** 游戏侧 `query {what:"dossier"}` 的载荷（已经是 compact + trim ✓）；拿不到时用兜底 ✓ */
    payload: DossierPayload | undefined;
    /** 兜底卡：dossier 取不到时，至少还有 facts.card 可以渲染骨架 ✓ */
    fallbackCard?: DossierPayload;
    goalText: string;
    goalOptions: string[];
    gate?: number;
    /**
     * ★★ 护航候选（2026-10-17 ✓）：原版判据 =「与行动船距离 ≤ **护卫自己一跳航程**」✓
     *   （不要求同星系 ✗ —— 见 simulationutility.lua:145-176 ✓）。
     *   ★ 它对 Trade 那一单是**决策必需**的 ✗：不知道能带谁，就没法判断能不能把风险压到闸门内 ✓。
     */
    escortCandidates?: string[];
    /** 逐计划候选行数上限（缺省 3 ✓ —— 主人要的"最好的 2~3 个" ✓） */
    rowsPerPlan?: number;
    /** ★ 硬字节预算（UTF-8 字节 ✓，缺省 24000 ✓ —— 单发提示词的**其余部分**还要留余量 ✓） */
    budgetBytes?: number;
    /** 记忆块：**单发路径专属**的拼装点（agents 那条路不给 ✓） */
    memoryBlock?: string;
    /** 需要时把"裁了什么"记进流水 ✓ */
    log?: (line: string) => void;
}
export interface DossierStats {
    budgetBytes: number;
    finalBytes: number;
    /** 第一次渲染出来的字节数（= 还没裁剪，**含记忆块** ✓）—— before/after 的 before ✓ */
    untouchedBytes: number;
    rowsPerPlan: number;
    plansIncluded: string[];
    plansDropped: string[];
    /** ★ 每一刀都记下来（顺序 + 原因 ✓） */
    dropped: string[];
}
export interface DossierResult {
    text: string;
    stats: DossierStats;
}
/** UTF-8 字节数（**权威口径** —— 会话/上下文限制都是按字节算的 ✓） */
export declare function byteLen(s: string): number;
/**
 * 计划段的**丢弃顺序**（固定 ✓ —— 测试钉住它 ✓）。留下的最后一个是最可能要用到的 ✓。
 * ★ 这是**规则**不是建议 ✗：`renderDossier` 的 ④ 刀就按这个数组走 ✓。
 */
export declare const PLAN_DROP_ORDER: readonly ["Sell", "Scout", "Trade", "Salvage", "Mine"];
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
export declare function renderDossier(input: DossierInput): DossierResult;
export {};
