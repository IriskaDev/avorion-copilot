/**
 * rpc.ts —— DSH 侧的**对称 RPC 框架**（协议见 mod 的 docs/dev/protocol.md v2）。
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
import net from 'node:net';
// ---------------------------------------------------------------------------
// 框架
// ---------------------------------------------------------------------------
export class RpcPeer {
    logger;
    port;
    host;
    defaultTimeoutSec;
    server = null;
    sock = null;
    rxBuf = Buffer.alloc(0);
    nextId = 0;
    handlers = new Map();
    pending = new Map();
    sweepTimer = null;
    /** 链路状态变化时回调（用于上层做握手 ✓） */
    onConnected = null;
    onDisconnected = null;
    constructor(opts = {}) {
        this.port = opts.port ?? 8765;
        this.host = opts.host ?? '127.0.0.1';
        this.logger = opts.logger ?? {};
        this.defaultTimeoutSec = opts.defaultTimeoutSec ?? 5;
    }
    log(...args) {
        this.logger.info?.(args.map(String).join(' '));
    }
    warn(...args) {
        this.logger.warn?.(args.map(String).join(' '));
    }
    // ---- 我提供的功能 --------------------------------------------------------
    /** 注册一个功能：对面可以用 `cmd` 调我 ✓（自动进入 caps ✓） */
    handle(cmd, fn) {
        this.handlers.set(cmd, fn);
    }
    /** 我提供哪些功能（hello 时声明 ✓，对面不用猜 ✓） */
    caps() {
        return [...this.handlers.keys()].sort();
    }
    // ---- 我调用对面 ----------------------------------------------------------
    /** 发起请求。返回是否成功送出（答复通过 cb 回来 ✓） */
    call(cmd, data, cb, timeoutSec) {
        if (this.sock === null || this.sock.destroyed) {
            this.warn(`call ${cmd} 失败：没有连接`);
            return false;
        }
        const id = ++this.nextId;
        this.pending.set(id, {
            cmd,
            cb,
            deadline: Date.now() + (timeoutSec ?? this.defaultTimeoutSec) * 1000,
        });
        return this.send({ id, type: 'request', cmd, data: data ?? {} });
    }
    /** 发送一个已经构造好的信封（内部用；也便于测试 ✓） */
    send(msg) {
        if (this.sock === null || this.sock.destroyed)
            return false;
        const body = Buffer.from(JSON.stringify(msg), 'utf8');
        const head = Buffer.alloc(4);
        head.writeUInt32LE(body.length, 0);
        return this.sock.write(Buffer.concat([head, body]));
    }
    // ---- 生命周期 ------------------------------------------------------------
    /** 开始监听。**端口占用必须明确报错** ✗（协议 §6；今晚踩过静默失败的坑 ✓） */
    listen() {
        return new Promise((resolve, reject) => {
            const server = net.createServer((s) => this.onConnection(s));
            server.on('error', (err) => {
                if (err.code === 'EADDRINUSE') {
                    this.warn(`端口 ${this.port} 被占用 —— 找出占用进程；不要静默重试`);
                }
                this.warn(`监听失败: ${err.code ?? ''} ${err.message}`);
                reject(err);
            });
            server.listen(this.port, this.host, () => {
                this.server = server;
                this.log(`RPC 已监听 ${this.host}:${this.port}`);
                // 超时扫描（游戏侧靠 tick 泵 ✓，这里靠定时器 ✓）
                this.sweepTimer = setInterval(() => this.sweepTimeouts(), 500);
                resolve();
            });
        });
    }
    close() {
        if (this.sweepTimer !== null) {
            clearInterval(this.sweepTimer);
            this.sweepTimer = null;
        }
        this.sock?.destroy();
        this.sock = null;
        this.server?.close();
        this.server = null;
    }
    onConnection(s) {
        // 协议 §6：只接受一条连接；新连接到达 → 关掉旧的 ✓（防重连竞态堆连接）
        if (this.sock !== null && !this.sock.destroyed) {
            this.warn('新连接到达 —— 按协议只保留一条，关掉旧连接');
            this.sock.destroy();
            this.failAllPending('DISCONNECTED', 'connection replaced by a newer one');
        }
        this.sock = s;
        this.rxBuf = Buffer.alloc(0);
        this.log(`游戏连上来了 ${s.remoteAddress}:${s.remotePort}`);
        s.on('data', (chunk) => this.feed(chunk));
        s.on('error', (err) => this.warn(`socket 错误: ${err.message}`));
        s.on('close', () => {
            this.log('连接关闭');
            if (this.sock === s)
                this.sock = null;
            this.failAllPending('DISCONNECTED', 'connection lost');
            this.onDisconnected?.();
        });
        this.onConnected?.();
    }
    // ---- 收帧 ----------------------------------------------------------------
    feed(chunk) {
        this.rxBuf = Buffer.concat([this.rxBuf, chunk]);
        // 不足 4 字节 → 等；够 4 但不足 len → 等；够 len → 切一帧，剩余继续判
        for (;;) {
            if (this.rxBuf.length < 4)
                return;
            const len = this.rxBuf.readUInt32LE(0);
            if (len === 0 || len > 64 * 1024 * 1024) {
                this.warn(`非法长度 ${len} —— 协议错误，断开`);
                this.sock?.destroy();
                return;
            }
            if (this.rxBuf.length < 4 + len)
                return;
            const raw = this.rxBuf.subarray(4, 4 + len).toString('utf8');
            this.rxBuf = this.rxBuf.subarray(4 + len);
            let msg;
            try {
                msg = JSON.parse(raw);
            }
            catch (err) {
                this.warn(`JSON 解析失败: ${String(err)}  raw=${raw.slice(0, 120)}`);
                continue;
            }
            this.dispatch(msg);
        }
    }
    dispatch(msg) {
        if (msg === null || typeof msg !== 'object')
            return;
        // 协议 §2 铁律 5：信封三件套缺一不可
        if (typeof msg.id !== 'number') {
            this.warn(`信封缺 id: ${JSON.stringify(msg).slice(0, 120)}`);
            return;
        }
        if (msg.type === 'response')
            return this.onResponse(msg);
        if (msg.type === 'request') {
            // ★ 不 await：一条慢 handler（decide 等模型）不许卡住收帧循环 ✓（协议 §6）
            void this.onRequest(msg).catch((err) => this.warn(`onRequest 异常: ${String(err)}`));
            return;
        }
        this.warn(`非法 type: ${String(msg.type)}`);
    }
    onResponse(msg) {
        const entry = this.pending.get(msg.id);
        if (entry === undefined) {
            // 协议 §2 铁律 4：id 未知的答复 → 丢弃并记日志 ✓（不崩、不断连）
            this.log(`(未知 id 的答复 ${msg.id}，按协议丢弃)`);
            return;
        }
        this.pending.delete(msg.id);
        this.log(`<<< response id=${msg.id} cmd=${msg.cmd} ok=${String(msg.ok)}` +
            (msg.ok ? '' : ` code=${msg.code ?? ''} message=${msg.message ?? ''}`));
        if (typeof entry.cb === 'function') {
            try {
                entry.cb(msg.ok === true, msg.data, msg.message ?? msg.code);
            }
            catch (err) {
                this.warn(`答复回调异常: ${String(err)}`);
            }
        }
    }
    async onRequest(msg) {
        this.log(`>>> request id=${msg.id} cmd=${msg.cmd} data=${JSON.stringify(msg.data ?? {}).slice(0, 300)}`);
        const fn = this.handlers.get(msg.cmd);
        let ok = false;
        let payload;
        let message;
        if (fn === undefined) {
            ok = false;
            payload = 'UNSUPPORTED';
            message = `this side has no handler for '${msg.cmd}'`;
        }
        else {
            try {
                const r = await fn(msg.data ?? {}); // ★ 可能是 Promise（decide 等模型 ✓）
                ok = r[0] === true;
                payload = r[1];
                message = r[2];
            }
            catch (err) {
                ok = false;
                payload = 'HANDLER_ERROR';
                message = String(err);
            }
        }
        // 协议 §2 铁律 2：答复的 cmd 与请求相同 ✓
        const resp = { id: msg.id, type: 'response', cmd: msg.cmd, ok };
        if (ok)
            resp.data = payload ?? {};
        else {
            resp.code = typeof payload === 'string' ? payload : 'ERROR';
            if (message !== undefined)
                resp.message = message;
            resp.data = {};
        }
        this.send(resp);
        this.log(`<<< 已答复 id=${msg.id} cmd=${msg.cmd} ok=${String(ok)}`);
    }
    // ---- 超时 ----------------------------------------------------------------
    sweepTimeouts() {
        const now = Date.now();
        for (const [id, entry] of [...this.pending]) {
            if (now < entry.deadline)
                continue;
            this.pending.delete(id);
            this.warn(`超时 id=${id} cmd=${entry.cmd}`);
            if (typeof entry.cb === 'function') {
                try {
                    entry.cb(false, 'TIMEOUT', 'no response');
                }
                catch { /* ignore */ }
            }
        }
    }
    failAllPending(code, why) {
        for (const [id, entry] of this.pending) {
            this.pending.delete(id);
            if (typeof entry.cb === 'function') {
                try {
                    entry.cb(false, code, why);
                }
                catch { /* ignore */ }
            }
        }
    }
}
//# sourceMappingURL=rpc.js.map