/**
 * commander.ts —— 「**决策任务投递到哪个会话**」这一件事的唯一归口（Phase A ✓）
 *
 * ## ★ 范围（主人 2026-10-17 定的，本模块按此收敛）
 *
 * 主人的话：
 *   「那就不需要是分身了，直接就可以投递到**当前会话**，决策完，再将操作传递给游戏。
 *     dsh 插件的角色其实就应该变为了'**游戏 RPC 请求接口提供者**'。」
 *
 * 所以：
 *   · **没有分身、没有新建会话、没有候选列表 UI** ✗ —— 目标就是**主人自己在用的那个会话** ✓；
 *   · 人格也不归我们管 ✓（那个会话本来就带着人格/角色卡 ✓ —— 见 AGENT-DESIGN.md §1.5）✓；
 *   · 本模块只回答一个问题：**投给哪个会话 id** ✓ —— 而这必须由主人**显式**说出 ✓。
 *
 * ## 为什么是显式指定，绝不自动猜（这是本模块存在**全部**理由）
 *
 * `agent.followup()` **不校验调用者身份**（见 AGENT-DESIGN.md §1.1：`ctx.agents.get(id)` 对
 * 插件是开放的，`AgentRegistry` 不过问你是谁 ✓）。也就是说：
 * **插件能把一条舰队任务块塞进任何一个着着的会话** ✗ —— 包括主人正在聊天的那个。
 * 而"投给主人当前这个会话"恰恰**就是**我们要的 ✓ —— 那更不能猜 ✗：
 * 猜错 = 把任务块塞进**另一个**会话，主人的聊天记录被污染 ✓（而且他还在等答案 ✓）。
 *
 * 所以：
 *   · 目标会话 id 由主人给 ✓：`fleet_commander { session: <id> }`（或插件 config 的
 *     `commanderSession` ✓ —— 让它在 DSH 重启后自动恢复 ✓）；
 *   · 没指定 → `getCommanderSessionId()` 返回 undefined → 决策**逐字回到今天**的单发路径 ✓✓
 *     （这就是"关掉这个功能"的开关本身 ✓ 不需要另做一个 ✓）。
 *
 * ## 持久化
 *
 * 选择写在 `%AppData%\Avorion\moddata\copilot\commander.json` ✓（与 DSH 的会话库无关 ✗）——
 * 这样 DSH 重启 / 插件重载后**认得同一个会话 id** ✓（id 是 DSH 自己的，DSH 恢复会话即可 ✓）。
 *
 * ## 租约（**必须有**，照抄 TAKEOVER.md 的推理）
 *
 * `owner` 会**自己过期** ✓。若没有租约 ✗，主人关掉那个会话之后这里就永远挂着 ✗✓。
 *
 * ★ 但租约**只用于状态显示与"这条选择还新鲜吗"**：真正的存着判据是
 *   `ctx.agents.get(id) !== undefined` ✓（着着的 Agent 才可能被投递 ✓）。
 *   拿"多久没说话"当投递闸门 ✗ = 凭租约把着着的会话废掉 ✓（"只做一次的守卫"那类坑 ✓）。
 */
/** 默认租约：60 秒（TAKEOVER.md 定的数 ✓；每次成功投递续期 ✓） */
export declare const DEFAULT_LEASE_MS = 60000;
/** 落盘位置（与 decisions.log 同一个目录 ✓） */
export declare const COMMANDER_FILE: string;
/** 磁盘上的形状（**只有这两个字段**，多一个都不要 ✗ —— 便于人肉读 ✓） */
export interface CommanderFile {
    /** 目标会话 id；null/缺失 = 没指定（= 今天的单发路径 ✓） */
    session?: string | null;
    /** 最近一次**成功投递**的时刻（毫秒）；用来算租约 ✓ */
    leasedUntil?: number | null;
}
/** 运行期状态（单例 ✓ —— 与 TAKEOVER.md 的 owner/leaseUntil 一致 ✓） */
export interface CommanderState {
    session: string | null;
    /** 租约到期时刻（毫秒）；null = 从未投递过 ✓ */
    leasedUntil: number | null;
}
export declare function setCommanderNotifier(fn: ((line: string) => void) | undefined): void;
/**
 * 读当前状态（**懒加载 + 内存缓存** ✓）。
 * ★ 只在第一次读盘 ✓ —— 运行期由 `set` 自己维护 ✓（不反复 stat 磁盘 ✓）。
 */
export declare function getState(file?: string): CommanderState;
/** 当前目标会话 id；没指定就是 undefined ✓（调用方据此回到单发 ✓） */
export declare function getCommanderSessionId(): string | undefined;
/**
 * 指定 / 撤销**投递目标会话**。**空串或 null = 撤销** ✓（与 cosplay 的 activeRole 同款语义 ✓）。
 * 返回设置后的状态 ✓；写盘失败**不抛** ✗（只写一行流水 ✓ —— 运行期选择照样生效 ✓）。
 */
export declare function setCommanderSession(session: string | null | undefined, opts?: {
    file?: string;
}): CommanderState;
/** 一次成功投递 → 续期 ✓（照 TAKEOVER.md：owner 每次有动静就续期 ✓） */
export declare function renewLease(opts?: {
    file?: string;
    now?: number;
    leaseMs?: number;
}): CommanderState;
/**
 * 租约是否新鲜（**只用于示警与状态显示** ✓）。
 *
 * ★ 为什么不用它当"能不能投递"的判据 ✗：
 *   真正的判据是"那个 Agent 还着着吗"（`ctx.agents.get(id)` ✓）——
 *   会话着着但主人几小时没动过，租约必然"过期" ✓，可它**照样能接任务** ✓✓。
 *   拿租约当闸门 = 凭"多久没说话"把着着的投递会话废掉 ✗（正是"只做一次的守卫"那类坑 ✓）。
 */
export declare function isLeaseFresh(opts?: {
    now?: number;
}): boolean;
/** 给测试用：清掉内存缓存（好让下一次读盘真的去读 ✓） */
export declare function resetCommanderCache(): void;
