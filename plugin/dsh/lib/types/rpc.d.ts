/**
 * rpc.ts —— DSH 侧的**对称 RPC 框架**（协议见 mod 的 PROTOCOL.md v2）。
 *
 * 与游戏侧的 `data/scripts/net/rpc.lua` 一一对应，也与 `native/test-peer.mjs`
 * 同构 —— 后者的等价逻辑**已在真实游戏上验证过** ✓（hello 往返 ✓ query fleet 拿到数据 ✓）。
 *
 * 本质（主人点透的那句）：
 *   **让 DSH 能调游戏的功能，也让游戏能调 DSH 的功能。** ✓
 *
 * 帧格式：uint32LE 长度 + UTF-8 JSON
 * 信封：  { id, type: "request"|"response", cmd, data?, ok?, code?, message? }
 * 铁律：  答复的 id 与 cmd 都等于请求；每个 request 都必须被答复（推送也要 ack ✓）
 */
export interface Envelope {
    id: number;
    type: 'request' | 'response';
    cmd: string;
    data?: any;
    ok?: boolean;
    code?: string;
    message?: string;
}
/** handler 返回值：[ok, payload, message?]；ok=false 时 payload 当作 code。
 *  ★ 允许 async —— `decide` 要等模型好几秒 ✓（协议 §6：绝不允许阻塞主循环 ✓，
 *  所以这里 await 的是**这条连接的处理**，不是游戏的主线程 ✓✓） */
export type HandlerResult = [boolean, any?, string?];
export type Handler = (data: any) => HandlerResult | Promise<HandlerResult>;
/** 答复回调：与 handler 返回值同形 */
export type ReplyCallback = (ok: boolean, payload?: any, why?: string) => void;
export interface RpcLogger {
    info?: (message: string) => void;
    warn?: (message: string) => void;
}
export interface RpcOptions {
    port?: number;
    host?: string;
    logger?: RpcLogger;
    /** 默认超时（秒）；query 用 5，decide 由调用方显式给更长 */
    defaultTimeoutSec?: number;
}
export declare class RpcPeer {
    private readonly logger;
    private readonly port;
    private readonly host;
    private readonly defaultTimeoutSec;
    private server;
    private sock;
    private rxBuf;
    private nextId;
    private readonly handlers;
    private readonly pending;
    private sweepTimer;
    /** 链路状态变化时回调（用于上层做握手 ✓） */
    onConnected: (() => void) | null;
    onDisconnected: (() => void) | null;
    constructor(opts?: RpcOptions);
    private log;
    private warn;
    /** 注册一个功能：对面可以用 `cmd` 调我 ✓（自动进入 caps ✓） */
    handle(cmd: string, fn: Handler): void;
    /** 我提供哪些功能（hello 时声明 ✓，对面不用猜 ✓） */
    caps(): string[];
    /** 发起请求。返回是否成功送出（答复通过 cb 回来 ✓） */
    call(cmd: string, data: any, cb?: ReplyCallback, timeoutSec?: number): boolean;
    /** 发送一个已经构造好的信封（内部用；也便于测试 ✓） */
    send(msg: Envelope): boolean;
    /** 开始监听。**端口占用必须明确报错** ✗（协议 §6；今晚踩过静默失败的坑 ✓） */
    listen(): Promise<void>;
    close(): void;
    private onConnection;
    private feed;
    private dispatch;
    private onResponse;
    private onRequest;
    private sweepTimeouts;
    private failAllPending;
}
