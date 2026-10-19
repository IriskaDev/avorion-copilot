/*
 * copilot.dll —— Avorion 的原生网络模块（第一期：传输层骨架）。
 *
 * 提供 Lua 侧 `require("copilot")`，拿到一张表：
 *
 *   net.connect(host, port)   非阻塞发起连接，返回 bool
 *   net.connected()           连接是否就绪
 *   net.send(str)             按帧发送一条消息（4 字节小端长度 + 载荷），返回 ok, err
 *   net.recv()                非阻塞；完整一帧则返回字符串，否则返回 nil
 *   net.close()               关闭
 *   net.state()               返回内部状态字符串，便于诊断
 *
 * 帧格式见 docs/dev/protocol.md：
 *     uint32 小端长度 | 载荷字节
 *
 * 关键约束：**任何调用都不得长时间阻塞游戏主线程**。
 *   - connect 用非阻塞 + select 检查
 *   - send    非阻塞 + select 等待可写，总超时 2 秒
 *   - recv    纯非阻塞，读不到就返回 nil
 *   - 收包维护累积缓冲与状态机（TCP 是字节流，一次读不等于一条消息）
 *
 * Lua C API 来自编进本 DLL 的 Lua 5.2.4 核心，操作的是宿主传进来的 lua_State
 * （见 docs/dev/native.md：ABI 已实测匹配）。
 */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <errno.h>

#include "lua.h"
#include "lauxlib.h"
#include "dshlog.h"
#include "lua_json.h"

/* 全部日志走 dshlog（每行一次 WriteFile，崩溃也不丢最后一行）。
   旧版直接用 fopen 写死一条绝对路径，结果日志文件根本没生成，排查时毫无可观测性。 */
/*
 * Verbose per-call logging.
 *
 * 2026-10-15: this used to run on EVERY call, i.e. several times per tick, from
 * several Lua worker threads at once, inside dshlog -- which keeps a shared
 * FILE* and several shared buffers. That made the log writer a multi-thread
 * write target and it was the last shared-state suspect (the API lock did not
 * make the crash go away, but the crash is definitely inside the native module:
 * with the DLL unavailable the same Lua scripts run for 5+ minutes untouched).
 *
 * It was always meant to be temporary (see AGENTS.md: "DLL 里的 numprobe/逐步日志待清理").
 * Default is now SILENT. Set DSHLOG_VERBOSE=1 in the environment to bring the
 * per-call trace back when investigating.
 */
static int nlog_enabled(void)
{
    static int cached = -1;
    if (cached < 0) {
        const char *v = getenv("DSHLOG_VERBOSE");
        cached = (v != NULL && v[0] == '1') ? 1 : 0;
    }
    return cached;
}

static void nlog(const char *fmt, ...)
{
    if (!nlog_enabled()) return;
    va_list ap;
    va_start(ap, fmt);
    dshlog_va(fmt, ap);
    va_end(ap);
}

/* ------------------------------------------------------------------ 连接状态 */

typedef enum { ST_IDLE = 0, ST_CONNECTING, ST_READY, ST_DEAD } netstate_t;

static SOCKET     g_sock = INVALID_SOCKET;
static netstate_t g_state = ST_IDLE;
static int        g_wsa_done = 0;

/* 收包累积缓冲 */
static unsigned char *g_rbuf = NULL;
static size_t         g_rlen = 0;
static size_t         g_rcap = 0;

static void ensure_wsa(void)
{
    if (!g_wsa_done) {
        WSADATA wsa;
        WSAStartup(MAKEWORD(2, 2), &wsa);
        g_wsa_done = 1;
    }
}

static const char *state_name(netstate_t s)
{
    switch (s) {
        case ST_IDLE:       return "idle";
        case ST_CONNECTING: return "connecting";
        case ST_READY:      return "ready";
        default:            return "dead";
    }
}

static void shutdown_socket(void)
{
    if (g_sock != INVALID_SOCKET) {
        closesocket(g_sock);
        g_sock = INVALID_SOCKET;
    }
    g_rlen = 0;
}

/* 连接中 → 检查是否已就绪；失败则置 DEAD。返回是否 ready。 */
static int poll_connect(void)
{
    if (g_state != ST_CONNECTING) return g_state == ST_READY;

    fd_set wf, ef;
    FD_ZERO(&wf); FD_SET(g_sock, &wf);
    FD_ZERO(&ef); FD_SET(g_sock, &ef);
    struct timeval tv = {0, 0};

    int rc = select(0, NULL, &wf, &ef, &tv);
    if (rc <= 0) return 0;                     /* 还在连 */

    if (FD_ISSET(g_sock, &ef)) { g_state = ST_DEAD; nlog("connect failed (exception)"); return 0; }

    int err = 0, len = sizeof(err);
    getsockopt(g_sock, SOL_SOCKET, SO_ERROR, (char *)&err, &len);
    if (err != 0) { g_state = ST_DEAD; nlog("connect failed, SO_ERROR=%d", err); return 0; }

    /* 连上后切成非阻塞，避免 recv/send 挂住主线程 */
    u_long nb = 1;
    ioctlsocket(g_sock, FIONBIO, &nb);
    g_state = ST_READY;
    nlog("connected");
    return 1;
}

/* ------------------------------------------------------------------ 收发 */

/* 非阻塞发送全部字节，总超时约 2 秒。不阻塞主线程超过一个 select 周期。 */
static int send_all(const unsigned char *buf, size_t len)
{
    size_t sent = 0;
    int waited_ms = 0;

    while (sent < len) {
        int n = send(g_sock, (const char *)buf + sent, (int)(len - sent), 0);
        if (n > 0) { sent += (size_t)n; continue; }

        int e = WSAGetLastError();
        if (e != WSAEWOULDBLOCK) { nlog("send error %d", e); g_state = ST_DEAD; return 0; }

        fd_set wf;
        FD_ZERO(&wf); FD_SET(g_sock, &wf);
        struct timeval tv = {0, 20000};         /* 20ms */
        int rc = select(0, NULL, &wf, NULL, &tv);
        waited_ms += 20;
        if (rc < 0) { nlog("send select error"); g_state = ST_DEAD; return 0; }
        if (waited_ms > 2000) { nlog("send timeout, %d/%d bytes", (int)sent, (int)len); g_state = ST_DEAD; return 0; }
    }
    return 1;
}

/* 把 socket 当前可读的数据读进累积缓冲。返回 0 = 对端关闭/出错。 */
static int pump(void)
{
    for (;;) {
        /* 缓冲满则扩容 */
        if (g_rlen + 65536 > g_rcap) {
            size_t ncap = g_rcap ? g_rcap * 2 : 65536;
            unsigned char *nb = (unsigned char *)realloc(g_rbuf, ncap);
            if (nb == NULL) { nlog("oom"); return 0; }
            g_rbuf = nb; g_rcap = ncap;
        }

        int n = recv(g_sock, (char *)g_rbuf + g_rlen, (int)(g_rcap - g_rlen), 0);
        if (n > 0) { g_rlen += (size_t)n; continue; }
        if (n == 0) { nlog("peer closed"); g_state = ST_DEAD; return 0; }

        int e = WSAGetLastError();
        if (e == WSAEWOULDBLOCK) return 1;      /* 读干净了 */
        nlog("recv error %d", e);
        g_state = ST_DEAD;
        return 0;
    }
}

/*
 * Frame extraction.
 *
 * 2026-10-15 -- THIS FUNCTION WAS THE CRASH. Two separate defects:
 *
 *   1. It handed the caller a pointer INTO g_rbuf and then immediately memmove()d
 *      that very buffer, so the pointer was stale before the caller used it.
 *   2. The frame length came straight off the wire with no sanity check. A garbage
 *      4-byte prefix (torn read, half-initialised buffer, anything) made both the
 *      memmove and the following push read/relocate an unbounded amount of memory.
 *
 * The old comment even said "caller must copy immediately" -- but the copy in
 * l_recv happened AFTER the memmove, so it never held.
 *
 * Why only l_recv crashed and l_connected did not: l_connected just pushes a
 * boolean (no buffer, no allocation), whereas l_recv walked this broken path and
 * then allocated a Lua string, which is where the damaged heap finally surfaced
 * -- as the lua::WorkerPool crash roughly a minute into play.
 *
 * Fix: reject implausible lengths outright, and copy the frame into a
 * caller-owned buffer BEFORE compacting the accumulation buffer.
 */
#define COPILOT_MAX_FRAME (64u * 1024u * 1024u)   /* matches the Lua/DLL framing limit */

/* Number of bytes of the next frame still missing, or 0 when nothing usable yet.
 * Returns -1 when the frame length is implausible (caller should drop the link). */
static int frame_status(void)
{
    if (g_rlen < 4) return 0;
    uint32_t len;
    memcpy(&len, g_rbuf, 4);
    if (len > COPILOT_MAX_FRAME) return -1;
    if (g_rlen < 4 + (size_t)len) return 0;
    return 1;
}

/*
 * Copy the next complete frame into dst (capacity dstcap) and remove it from the
 * accumulation buffer. Returns the frame length, or 0 when there is no complete
 * frame, or (size_t)-1 on an implausible frame length.
 */
static size_t extract_copy(unsigned char *dst, size_t dstcap)
{
    if (g_rlen < 4) return 0;

    uint32_t len;
    memcpy(&len, g_rbuf, 4);
    if (len > COPILOT_MAX_FRAME) return (size_t)-1;
    if (g_rlen < 4 + (size_t)len) return 0;
    if ((size_t)len > dstcap)     return (size_t)-1;

    if (len > 0) memcpy(dst, g_rbuf + 4, len);        /* copy BEFORE compacting */

    size_t consumed = 4 + (size_t)len;
    if (g_rlen > consumed) {
        memmove(g_rbuf, g_rbuf + consumed, g_rlen - consumed);
    }
    g_rlen -= consumed;
    return (size_t)len;
}

/* ------------------------------------------------------------------ Lua 绑定 */

static int l_connect(lua_State *L)
{
    nlog("l_connect ENTER top=%d", lua_gettop(L));

    const char *host = luaL_checkstring(L, 1);
    nlog("  arg1 OK: %s", host);
    int port = (int)luaL_checkinteger(L, 2);
    nlog("  arg2 OK: %d", port);

    ensure_wsa();
    nlog("  wsa OK");
    shutdown_socket();
    g_state = ST_IDLE;

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    char portstr[16];
    _snprintf(portstr, sizeof(portstr), "%d", port);

    if (getaddrinfo(host, portstr, &hints, &res) != 0 || res == NULL) {
        nlog("  resolve FAILED");
        lua_pushboolean(L, 0);
        lua_pushstring(L, "resolve failed");
        return 2;
    }
    nlog("  resolve OK");

    SOCKET s = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (s == INVALID_SOCKET) {
        freeaddrinfo(res);
        nlog("  socket FAILED");
        lua_pushboolean(L, 0);
        lua_pushstring(L, "socket failed");
        return 2;
    }
    nlog("  socket OK");

    u_long nb = 1;
    ioctlsocket(s, FIONBIO, &nb);               /* 非阻塞 connect */

    int rc = connect(s, res->ai_addr, (int)res->ai_addrlen);
    nlog("  connect rc=%d err=%d", rc, (rc == SOCKET_ERROR) ? WSAGetLastError() : 0);
    freeaddrinfo(res);

    if (rc == SOCKET_ERROR) {
        int e = WSAGetLastError();
        if (e != WSAEWOULDBLOCK) {
            closesocket(s);
            lua_pushboolean(L, 0);
            lua_pushstring(L, "connect failed");
            return 2;
        }
        g_state = ST_CONNECTING;
    } else {
        g_state = ST_READY;
    }

    g_sock = s;
    nlog("connect %s:%d (%s)", host, port, state_name(g_state));

    lua_pushboolean(L, 1);
    return 1;
}

static int l_connected(lua_State *L)
{
    nlog("l_connected ENTER");
    if (g_state == ST_CONNECTING) poll_connect();
    lua_pushboolean(L, g_state == ST_READY);
    nlog("l_connected OK");
    return 1;
}

static int l_state(lua_State *L)
{
    lua_pushstring(L, state_name(g_state));
    return 1;
}

static int l_send(lua_State *L)
{
    /* 参数可以是字符串（原样发）或 table（编码成 JSON 再发）——
       这样 Lua 侧写协议消息时不用关心 JSON：net.send{cmd="state", params={...}} */
    char *encoded = NULL;
    const char *payload = NULL;
    size_t len = 0;

    if (lua_type(L, 1) == LUA_TTABLE) {
        encoded = dshjson_encode(L, 1);
        if (encoded == NULL) {
            nlog("l_send: json encode FAILED");
            lua_pushboolean(L, 0);
            lua_pushstring(L, "json encode failed");
            return 2;
        }
        payload = encoded;
        len = strlen(encoded);
    } else {
        payload = luaL_checklstring(L, 1, &len);
    }

    nlog("l_send: %d bytes%s", (int)len, encoded ? " (encoded)" : "");

    if (g_state == ST_CONNECTING) poll_connect();
    if (g_state != ST_READY) {
        dshjson_free(encoded);
        lua_pushboolean(L, 0);
        lua_pushstring(L, state_name(g_state));
        return 2;
    }

    /* 组帧：4 字节小端长度 + 载荷 */
    size_t total = 4 + len;
    unsigned char *frame = (unsigned char *)malloc(total);
    if (frame == NULL) {
        dshjson_free(encoded);
        lua_pushboolean(L, 0);
        lua_pushstring(L, "oom");
        return 2;
    }
    uint32_t n32 = (uint32_t)len;
    memcpy(frame, &n32, 4);
    memcpy(frame + 4, payload, len);

    int ok = send_all(frame, total);
    free(frame);
    dshjson_free(encoded);

    lua_pushboolean(L, ok);
    if (!ok) lua_pushstring(L, "send failed");
    return ok ? 1 : 2;
}

/* table -> JSON 字符串（便于调试与自测） */
static int l_encode(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TTABLE);
    char *text = dshjson_encode(L, 1);
    if (text == NULL) { lua_pushnil(L); lua_pushstring(L, "encode failed"); return 2; }
    lua_pushstring(L, text);
    dshjson_free(text);
    return 1;
}

/* JSON 字符串 -> table（没人做解析器的话，Lua 侧只能自己写，容易错） */
static int l_decode(lua_State *L)
{
    size_t len = 0;
    const char *text = luaL_checklstring(L, 1, &len);
    if (!dshjson_decode(L, text)) {
        lua_pushnil(L);
        lua_pushstring(L, "json decode failed");
        return 2;
    }
    return 1;
}

/* 收一帧并直接解码成 table；没有完整帧就返回 nil */
static int l_recv_json(lua_State *L)
{
    l_recv(L);                                  /* 压入 string 或 nil */
    if (lua_isnil(L, -1)) return 1;

    size_t len = 0;
    const char *text = lua_tolstring(L, -1, &len);
    char *copy = (char *)malloc(len + 1);
    if (copy == NULL) { lua_pushnil(L); return 1; }
    memcpy(copy, text, len);
    copy[len] = '\0';
    lua_pop(L, 1);                              /* 弹掉 string */

    int ok = dshjson_decode(L, copy);
    free(copy);
    if (!ok) { lua_pushnil(L); }
    return 1;
}

static int l_recv(lua_State *L)
{
    nlog("l_recv ENTER state=%s rlen=%d rcap=%d", state_name(g_state), (int)g_rlen, (int)g_rcap);

    if (g_state == ST_CONNECTING) poll_connect();
    if (g_state != ST_READY) {
        nlog("  -> not ready (%s), return nil", state_name(g_state));
        lua_pushnil(L);
        return 1;
    }

    /* A frame may already be buffered; otherwise read the socket once. */
    int st = frame_status();
    if (st <= 0) {
        int ok = pump();
        nlog("  pump -> %d, rlen now %d", ok, (int)g_rlen);
        if (!ok) { lua_pushnil(L); return 1; }
        if (g_state != ST_READY) { lua_pushnil(L); return 1; }
        st = frame_status();
    }
    if (st < 0) {
        /* Implausible length on the wire: drop the connection instead of walking
         * off the end of the buffer. */
        nlog("  implausible frame length, dropping link");
        g_state = ST_DEAD;
        lua_pushnil(L);
        return 1;
    }
    if (st == 0) {
        nlog("  no complete frame yet (rlen=%d)", (int)g_rlen);
        lua_pushnil(L);
        return 1;
    }

    /* Copy into a stack buffer first: extract_copy compacts g_rbuf, so a pointer
     * into it would be stale by the time Lua got the string. */
    {
        static __declspec(thread) unsigned char tls_frame[65536];
        size_t flen = extract_copy(tls_frame, sizeof(tls_frame));
        if (flen == (size_t)-1) {
            nlog("  frame too large for the per-thread buffer, dropping link");
            g_state = ST_DEAD;
            lua_pushnil(L);
            return 1;
        }
        nlog("  frame extracted: %d bytes, rlen left %d", (int)flen, (int)g_rlen);
        lua_pushlstring(L, (const char *)tls_frame, flen);
    }
    return 1;
}

/* 数值布局探针：把几个数压给 Lua 读回。
 *
 * 为什么需要它：lua_gettop 与 lua_pushstring 都**不碰数值分支**，所以它们在游戏里通过
 * 并**不代表** lua_Number / lua_Integer 的配置一致。而 luaL_checkinteger（connect 的第二个
 * 参数）恰好走数值分支 —— 这就解释了「游戏里 gettop/pushstring 正常、一调 connect 就 AV」。
 *
 * 这个探针是安全的：布局不符时读回的只是垃圾值，**不会崩**（不像写错栈那样直接完蛋）。
 * 期望读到 42, 1.5, -7。
 */
static int l_numprobe(lua_State *L)
{
    nlog("l_numprobe ENTER (sizeof lua_Number=%d lua_Integer=%d)",
         (int)sizeof(lua_Number), (int)sizeof(lua_Integer));
    lua_pushinteger(L, 42);
    lua_pushnumber(L, 1.5);
    lua_pushinteger(L, -7);
    nlog("l_numprobe OK, top=%d", lua_gettop(L));
    return 3;
}

/* 读任意文件，内容以字符串返回。
 *
 * 为什么需要它：游戏侧 io.open 被限制在 moddata/ 开头（否则 filename is not secure），
 * 读不到 mod 目录里的脚本。而**热重载**必须能读到脚本源码，再交给 load() 重新执行。
 * 原生代码不受那个路径限制，所以这个能力只能由 DLL 提供。
 */
static int l_readfile(lua_State *L)
{
    size_t plen = 0;
    const char *path = luaL_checklstring(L, 1, &plen);

    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        nlog("l_readfile: cannot open %s (errno=%d)", path, errno);
        lua_pushnil(L);
        lua_pushfstring(L, "cannot open (%d)", errno);
        return 2;
    }

    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); lua_pushnil(L); lua_pushstring(L, "seek failed"); return 2; }
    long size = ftell(f);
    if (size < 0) { fclose(f); lua_pushnil(L); lua_pushstring(L, "tell failed"); return 2; }
    rewind(f);

    char *buf = (char *)malloc((size_t)size + 1);
    if (buf == NULL) { fclose(f); lua_pushnil(L); lua_pushstring(L, "out of memory"); return 2; }

    size_t got = fread(buf, 1, (size_t)size, f);
    fclose(f);
    buf[got] = '\0';

    nlog("l_readfile: %s -> %d bytes", path, (int)got);
    lua_pushlstring(L, buf, got);
    free(buf);
    return 1;
}

/* 内部状态快照，便于从 Lua 侧诊断（不依赖文件日志）。 */
static int l_diag(lua_State *L)
{
    char buf[256];
    _snprintf(buf, sizeof(buf), "state=%s rlen=%d rcap=%d log=%s",
              state_name(g_state), (int)g_rlen, (int)g_rcap, dshlog_status());
    buf[sizeof(buf) - 1] = '\0';
    lua_pushstring(L, buf);
    return 1;
}

static int l_close(lua_State *L)
{
    shutdown_socket();
    g_state = ST_IDLE;
    lua_pushboolean(L, 1);
    return 1;
}

/*
 * ===========================================================================
 * THREAD SAFETY  (2026-10-15 -- this was the real crash)
 * ===========================================================================
 *
 * The game calls these functions from SEVERAL Lua worker-pool threads at the
 * same time (the dll log shows a different tid= on almost every call). All the
 * state below the API is file-scope globals -- g_sock, g_state, g_rbuf, g_rlen,
 * g_rcap -- and there was NO lock anywhere. Concurrent l_recv/l_connected/
 * l_send calls therefore raced on that state.
 *
 * Symptom: after roughly 70 seconds the server log gets
 *
 *     X_X
 *     Sending crash report ...
 *     Error cleaning up lua::WorkerPool: shutdown() not called!
 *
 * The process stays alive and keeps rendering, but all Lua stops: the game
 * becomes a zombie. (Earlier, with a mismatched Lua core, the same corruption
 * took the whole process down with STATUS_HEAP_CORRUPTION 0xC0000374.)
 *
 * Fix: one recursive critical section around every exported entry point.
 * Windows critical sections are re-entrant, so the helpers below may call each
 * other while the lock is held. Nothing in here calls back into the game's Lua
 * while locked, so there is no deadlock path.
 */
static CRITICAL_SECTION g_api_lock;
static INIT_ONCE        g_api_lock_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK copilot_lock_ctor(PINIT_ONCE once, PVOID param, PVOID *ctx)
{
    (void)once; (void)param; (void)ctx;
    InitializeCriticalSection(&g_api_lock);
    return TRUE;
}

static void copilot_lock_init(void)
{
    /* InitOnceExecuteOnce is the correct primitive here: the first thread
     * initialises, and every other thread BLOCKS until that is done. A plain
     * InterlockedCompareExchange test would let the losers run straight into
     * EnterCriticalSection on a lock that is not initialised yet. */
    InitOnceExecuteOnce(&g_api_lock_once, copilot_lock_ctor, NULL, NULL);
}

/*
 * Diagnostic (temporary): record which lua_State pointer arrives from which
 * OS thread. Printed ONLY when the (thread, L) pair changes, so it stays cheap.
 *
 * Why it matters: if the same lua_State is handed to several worker threads
 * concurrently, then EVERY Lua C API call is a race that no lock of ours can
 * fix -- the game's own Lua code does not take our lock. If each thread has its
 * own L, the Lua side is safe and the fault is somewhere else in the module.
 */
static void note_thread_state(lua_State *L)
{
    static DWORD seen_tid[64];
    static const void *seen_L[64];
    static int seen_n = 0;
    static CRITICAL_SECTION cs;
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    /* Reuse InitOnce via a tiny local ctor is overkill here; the caller already
     * holds g_api_lock, so this is serialised. */
    (void)once; (void)cs;

    DWORD tid = GetCurrentThreadId();
    int i;
    for (i = 0; i < seen_n; i++) {
        if (seen_tid[i] == tid && seen_L[i] == (const void *)L) return;
    }
    if (seen_n < 64) {
        seen_tid[seen_n] = tid;
        seen_L[seen_n] = (const void *)L;
        seen_n++;
    }
    dshlog("THREAD/STATE #%d tid=%lu L=%p", seen_n, (unsigned long)tid, (const void *)L);
}
static void copilot_lock(void)
{
    copilot_lock_init();
    EnterCriticalSection(&g_api_lock);
}

static void copilot_unlock(void)
{
    LeaveCriticalSection(&g_api_lock);
}

/* One wrapper per exported function. Deliberately verbose rather than a macro
 * soup: this file is the crash site and it has to stay readable. */
#define COPILOT_LOCKED(fn)                       \
    static int fn##_locked(lua_State *L)         \
    {                                            \
        copilot_lock();                          \
        int _r = fn(L);                          \
        copilot_unlock();                        \
        return _r;                               \
    }

COPILOT_LOCKED(l_connect)
COPILOT_LOCKED(l_connected)
COPILOT_LOCKED(l_state)
COPILOT_LOCKED(l_send)
COPILOT_LOCKED(l_recv)
COPILOT_LOCKED(l_recv_json)
COPILOT_LOCKED(l_encode)
COPILOT_LOCKED(l_decode)
COPILOT_LOCKED(l_close)
COPILOT_LOCKED(l_diag)
COPILOT_LOCKED(l_numprobe)
COPILOT_LOCKED(l_readfile)

static const luaL_Reg copilot_lib[] = {
    {"connect",   l_connect_locked},
    {"connected", l_connected_locked},
    {"state",     l_state_locked},
    {"send",      l_send_locked},
    {"recv",      l_recv_locked},
    {"recv_json", l_recv_json_locked},
    {"encode",    l_encode_locked},
    {"decode",    l_decode_locked},
    {"close",     l_close_locked},
    {"diag",      l_diag_locked},
    {"numprobe",  l_numprobe_locked},
    {"readfile",  l_readfile_locked},
    {NULL, NULL}
};

/* 由 dshlog.c 提供：日志自身的状态。日志写不出去时，这是唯一可读的通道。 */
extern const char *dshlog_status(void);

__declspec(dllexport) int luaopen_copilot(lua_State *L)
{
    ensure_wsa();

    /*
     * ★ 关键：让本 DLL 留在进程里。
     *
     * 实测：Avorion 的脚本加载器在 require 返回后会 FreeLibrary 我们，而游戏 Lua 里
     * 指向我们的 C 闭包仍然活着 —— DLL 一卸载它们就是悬空指针，脚本一碰就坏
     * （表现为飞船不动 / 单机实例"崩"）。自己 Load 一次把引用计数加一即可抵消。
     * 放在这里而不是 DllMain，是因为加载器锁内不能安全地 LoadLibrary。
     */
    dshlog_keep_resident();

    nlog("luaopen_copilot: top=%d", lua_gettop(L));

    lua_createtable(L, 0, 12);
    nlog("  createtable ok, top=%d", lua_gettop(L));

    for (const luaL_Reg *r = copilot_lib; r->name != NULL; r++) {
        lua_pushcfunction(L, r->func);
        lua_setfield(L, -2, r->name);
        nlog("  registered %s, top=%d", r->name, lua_gettop(L));
    }

    lua_pushstring(L, dshlog_status());
    lua_setfield(L, -2, "logstatus");
    lua_pushstring(L, dshlog_path());
    lua_setfield(L, -2, "logpath");

    /*
     * 诊断字段：整数键 vs 字符串键。
     *
     * 游戏里的现象是「require 返回 table 成功，但 net.numprobe 是 nil」——即宿主读不出
     * 我们用字符串键设的字段，而我们自己（同一份 Lua 代码）读得到。字符串键要经过
     * **字符串哈希**（Lua 5.2 的 TString 存 hash，种子来自 global_State->seed），
     * 整数键走数组部分**完全不哈希**。
     *
     * 所以这一对字段能把问题一刀切开：
     *   net[1] 有值、net.strkey 为 nil  -> 字符串哈希/字符串表这条线坏了
     *   两个都坏                        -> 表结构整体读不到
     *   两个都好                        -> 假设推翻，另找原因
     */
    lua_pushstring(L, "int-key-visible");
    lua_rawseti(L, -2, 1);                  /* t[1] = "int-key-visible"（不哈希） */

    lua_pushstring(L, "str-key-visible");
    lua_setfield(L, -2, "strkey");          /* t.strkey（要哈希） */

    nlog("  table built, top=%d", lua_gettop(L));

    /*
     * 自检：在加载时**从 DLL 内部**调一次我们自己的 C 闭包。
     *
     * 游戏里的现象是「require 成功返回 table，但 Lua 一侧一调其中任何函数就 AV，
     * 而函数的入口日志都没打印」—— 说明崩在「Lua 派发到 C 闭包」这一步，我们的函数
     * 根本没进去。这一步把同一条路径单独拎出来测：若这里也崩，日志会停在上一条；
     * 若这里通过而游戏侧仍崩，问题就在游戏侧的调用路径，不在闭包本身。
     */
    lua_getfield(L, -1, "numprobe");
    nlog("  self-test: about to lua_pcall(numprobe), top=%d, isfunc=%d",
         lua_gettop(L), lua_isfunction(L, -1));

    int rc = lua_pcall(L, 0, 3, 0);
    nlog("  self-test: lua_pcall rc=%d top=%d", rc, lua_gettop(L));

    if (rc == 0) {
        nlog("  self-test: results = %s | %s | %s",
             lua_tostring(L, -3), lua_tostring(L, -2), lua_tostring(L, -1));
        lua_pop(L, 3);
    } else {
        nlog("  self-test: pcall error = %s", lua_tostring(L, -1));
        lua_pop(L, 1);
    }

    nlog("luaopen_copilot: returning, top=%d", lua_gettop(L));
    return 1;
}
