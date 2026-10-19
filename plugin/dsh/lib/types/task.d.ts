/**
 * task.ts —— 投递进投递目标会话的**任务块**，与它的**答案契约**（Phase A ✓）
 *
 * 这是「插件 ⇄ 会话」之间唯一的接口 ✗✓ —— 协议在这里、校验也在这里 ✓，
 * 这样"任务长什么样"和"什么算合格答案"永远不会各改各的 ✓（原型
 * `test/commander-dispatch-proto.mjs` 的 shape 原样搬过来 ✓）。
 *
 * ## 为什么答案里必须回显 `task=<id>`（**这条不能省**）
 *
 * 投递目标会话是**一条活着的、主人也在用的普通会话** ✓✓。所以同一轮里可能出现：
 *   · 主人在聊天，她的回复与任务交错 ✓
 *   · 主人一次性投了几艘船 → 会话里连着几条任务 ✓
 * 于是"最后一条 assistant/message 就是结论"**不总成立** ✗。
 * 契约要求她回显 `task=<id>` ✓；对不上就判 `TASK_MISMATCH` 并走阶梯 ✓ ——
 * **绝不把别的船的答案用在这艘船上** ✗✓。
 *
 * （★ 诚实说明：她**不回显**时我们**不判失败** ✗ —— 只降级成"无回显"✓。
 *  理由是主人要的是"能聊天、能现修"的会话，不是必须背格式的机器人 ✓；
 *  而**回显了但写错**才是真危险（说明她在答别的船 ✓）→ 那才判 MISMATCH ✓。）
 */
/**
 * 一次任务请求（插件 → 会话）的**全部**内容 ✓。
 *
 * ★★★ 2026-10-17 主人批准的改动：**agent 路径只投递"通知"** ✓✓
 *
 * 主人的原话：
 *   「你应该仅投递决策请求，就仅仅是告知会话，有东西需要决策就行了，
 *     然后会话再根据插件提供的工具自行查询，有什么东西需要决策。」
 *
 * → 所以投进会话的块里**只有**：船名 ✓、任务号 ✓、期限提示 ✓、
 *   一行"它空闲了、要一个决策" ✓、**工具指针**（哪个查询查什么 ✓）、
 *   答案行契约 ✓、`task=` 回显要求 ✓。
 * → 而**数据一律不给** ✗✓：船卡、计划 JSON、渲染好的候选表**都不进这个块** ✓。
 *
 * 为什么 ✗→✓（实测血案，别忘）：这个块曾经是"预取的全部数据"——
 *   船卡两遍 ✓、每个计划的原始 JSON ✓、再叠一层渲染好的候选表 ✓、再加一段散文 ✓，
 *   于是一份 8.7 MB 的 Scout 计划把整条任务文本撑到 **8,761,847 字符** ✓，
 *   被会话层截断 ✓、模型侧直接超上下文 ✓（requested 3,068,511 tokens > 1,048,576 ✓）。
 *   ★ 根因不是"少了一个上限" ✗，而是**推**（push）而不是**通知 + 自拉**（notify + pull）✓✓。
 *
 * ★ 那两条字段（`card` / `planText`）**保留在类型里**是为了**向后兼容** ✓：
 *   老的调用方仍然可以传（TS 不报错 ✓），但 `renderTaskBlock` **不再读它们** ✗✓ ——
 *   也就是说"就算有人传了 8 MB，这个块也不会变大" ✓✓（这条有测试钉住 ✓）。
 */
export interface TaskRequest {
    /** 任务 id：回显契约的锚点 ✓（形如 `t-1a2b3c4d`） */
    taskId: string;
    ship: string;
    goalText: string;
    goalOptions: string[];
    /**
     * @deprecated agent 路径**不再投递数据** ✗（2026-10-17 ✓）。
     *   类型上留着只为向后兼容；`renderTaskBlock` 忽略它 ✓。
     *   单发那条路的档案在 `dossier.ts`（预取 + 裁剪 + 字节预算 ✓）。
     */
    card?: unknown;
    /**
     * @deprecated 同上：agent 路径不再投递渲染好的计划 ✗（那正是 8.7 MB 的来源 ✓）。
     *   会话要用计划就**自己查**（`fleet_query` 的 `*Plan`，缺省 compact ✓）。
     */
    planText?: string;
    /** 建议预算（秒）；写进任务头，告知会话层硬期限 ✓ */
    deadlineHintSec: number;
    /**
     * ★★ B：**上一轮没答到的船数**（2026-10-18 主人点名要的"可见" ✓✓）。
     *
     * 为什么必须写进块里 ✗→✓：漏答以前是**静默**的 ✓ —— 决策者根本不知道
     * 上一轮有船没被答到（`fallbackNone` 只落在插件自己的日志里 ✗）。
     * 现在它渲染成块**末尾一行**「上次未答：X 艘」✓，她每一轮都看得见 ✓✓。
     */
    unansweredBefore?: number;
    /**
     * ★ 上一单结果（2026-10-17 补 ✓）：渲染时附在块末尾的「你上一单的结果」一行 ✓。
     *   用途两个（同一字段 ✓）：
     *     · 正常轮：决策者下一轮就能看到"上次成没成"（不触发回投也看得见 ✓）；
     *     · 失败回投：带上一单的失败原因 + "请重新决策" ✓。
     *   ★ 体积预算 ~200 字节：超了就当没加上 ✗✓（renderTaskBlock 会跳过 ✓）。
     */
    prevResult?: string;
}
/** 校验结论 */
export type AnswerCode = 'EMPTY_REPLY' | 'NO_ACTION_LINE' | 'ASKED_OWNER' | 'TASK_MISMATCH' | 'BAD_ACTION';
/** 解析出来的答案（与 `DecideAnswer` 同形 ✓ —— 下单那条路径一个字都不用改 ✓） */
export interface TaskAnswer {
    action: string;
    params: Record<string, unknown>;
    reason?: string;
    /** 原文（审计用 ✓） */
    raw?: string;
}
export type AnswerVerdict = {
    ok: true;
    answer: TaskAnswer; /** 有没有回显 task（false = 她没写，仍然采纳 ✓） */
    echoed: boolean;
} | {
    ok: false;
    code: AnswerCode;
    message?: string;
    question?: string;
};
/**
 * 逐行取 `key=value`（与 `index.ts` 的 `field()` 同一套容错 ✓）：
 * 容忍 `key: value`、`**key=value**`、全角冒号、行首 `- `/`* `、行尾星号 ✓。
 * ★ 与 index.ts 那份**故意保持同形** ✓ —— 两边读同一份"她的回答"必须得出一致的结论 ✓。
 */
export declare function field(text: string, key: string): string | undefined;
/** ★ 「你上一单的结果」一行的字节预算（~200 ✓；超了就当没加 ✗✓） */
export declare const PREV_RESULT_BUDGET_BYTES = 200;
export declare function renderTaskBlock(req: TaskRequest): string;
/** 一条待决策任务（合并块里的一个条目 ✓ —— 只有船名 + 任务号 + 动作边界 ✓） */
export interface TaskBatchRequest {
    items: TaskRequest[];
    /** ★ B：这一轮是「上一轮没答到」的重投（措辞不同、可见 ✓） */
    retryRound?: boolean;
}
/**
 * 渲染一个**合并**任务块 ✓（1 条 = 与 `renderTaskBlock` 逐字相同 ✓）。
 *
 * 体积：工具指针段在合并块里**只写一遍**（generic，不带船名 ✓），
 * 每艘船只占一行 ✓ —— 所以 3 艘也在 2 KB 目标内 ✓（`batch-merge.mjs` 钉住 ✓）。
 */
export declare function renderTaskBatchBlock(batch: TaskBatchRequest): string;
export interface AnswerGroupSpec {
    taskId: string;
    ship?: string;
    allowedActions: string[];
}
export interface MultiAnswerVerdict {
    /** 每条船自己的结论 ✓（**没有这个 key = 本轮没答到** ✓） */
    verdicts: Map<string, AnswerVerdict>;
    /** 这一轮里看到的 `action=` 组数 ✓ */
    groups: number;
    /** 靠 `task=` 回显对上的组数 ✓ */
    echoedGroups: number;
    /** 回了、但 task= 不属于本批的（别船的答案，**绝不采纳** ✗） */
    stray: string[];
}
/** 把一段文本按 `action=` 行切成组 ✓（每组从 action= 行起到下一组前 ✓） */
export declare function splitAnswerGroups(text: string): string[];
/**
 * 校验**一次回多条**的答案 ✓（N == 1 时等价于 `validateAnswer` ✓）。
 */
export declare function validateAnswers(text: string, items: AnswerGroupSpec[]): MultiAnswerVerdict;
/**
 * 校验会话的答案 ✓（**机器可检** —— 人格多花哨都不影响 ✓）。
 *
 * @param text           这一轮里**最后一条** assistant 文本 ✓
 * @param taskId         本任务 id ✓
 * @param allowedActions 允许的动作集合 ✓（含 'None' 与否都行；'None' 永远合法 ✓）
 */
export declare function validateAnswer(text: string, taskId: string, allowedActions: string[]): AnswerVerdict;
/**
 * 造一个任务 id ✓（**只用于人眼对号** —— 不参与任何逻辑判断 ✓）。
 * 形如 `t-1a2b3c4d`：前缀可读、后缀 8 位随机 ✓（同一轮多艘船不会撞 ✓）。
 */
export declare function makeTaskId(rand?: () => number): string;
