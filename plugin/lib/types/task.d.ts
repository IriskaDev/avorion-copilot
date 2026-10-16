/**
 * task.ts —— 投递进指挥官会话的**任务块**，与它的**答案契约**（Phase A ✓）
 *
 * 这是「插件 ⇄ 会话」之间唯一的接口 ✗✓ —— 协议在这里、校验也在这里 ✓，
 * 这样"任务长什么样"和"什么算合格答案"永远不会各改各的 ✓（原型
 * `test/commander-dispatch-proto.mjs` 的 shape 原样搬过来 ✓）。
 *
 * ## 为什么答案里必须回显 `task=<id>`（**这条不能省**）
 *
 * 指挥官会话是**一条活着的、主人也在用的普通会话** ✓✓。所以同一轮里可能出现：
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
 * 事实仍由插件**预取**（见 AGENT-DESIGN.md §2.2：让会话反复查 `minePlan` 会反复占住
 * 游戏主循环 ✗）；会话想自己核实可以用 `fleet_query` ✓。
 */
export interface TaskRequest {
    /** 任务 id：回显契约的锚点 ✓（形如 `t-1a2b3c4d`） */
    taskId: string;
    ship: string;
    goalText: string;
    goalOptions: string[];
    /** 能力卡（原样 JSON ✓） */
    card: unknown;
    /** 给模型看的计划文本（与单发路径同一份 ✓）；可缺省 ✓ */
    planText?: string;
    /** 建议预算（秒）；写进任务头，让她知道"别慢慢查" ✓ */
    deadlineHintSec: number;
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
/**
 * 渲染任务块 ✓ —— **与单发路径的 `buildPrompt()` 同源**（同一批事实、同一套读法 ✓）。
 *
 * 为什么结论行要求**放最前** ✗✓：`plugin/prompt/system.md` 与
 * `src/index.ts` 的重试路径都记录了实机事故 ——「她想太久、正文被 maxTokens 截断，
 * 一个动作行都没吐」✓。把契约放最前，最坏情况丢的是散文，不是结论 ✓。
 */
export declare function renderTaskBlock(req: TaskRequest): string;
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
