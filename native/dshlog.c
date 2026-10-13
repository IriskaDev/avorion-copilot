/*
 * dshlog.c —— 原生模块的日志系统。
 *
 * 设计目标（顺序即优先级）：
 *
 *  1. **崩溃也不丢**：setvbuf(_IONBF) + 每行 fflush，完全不缓冲。进程被 AV 打死时，
 *     最后一行恰恰是最重要的那行，缓冲式日志会把它吞掉。
 *  2. **打不开也要能说话**：逐个尝试候选路径；若全失败，把 attempts / errno / 候选路径
 *     记进一个静态串，由 dshlog_status() 交给调用方（Lua 侧可打印）。
 *     这条通道是必要的：日志写不出去时，任何文件通道都不可用，必须另有一条路把原因送出来。
 *  3. **多进程/多线程安全**：fopen 默认共享读写，不会因为别人开着而失败。
 *  4. **能被调试器看到**：同时发一份 OutputDebugStringA。
 *
 * 为什么最终用 fopen 而不是 Win32 CreateFileA：
 *   实测 CreateFileA(FILE_APPEND_DATA, ..., OPEN_ALWAYS, ...) 在同一进程、同一目录下
 *   对三个候选路径**全部返回 ERROR_ACCESS_DENIED(5)**，而 fopen(path,"a") 对同一路径
 *   可以正常写入。故采用 fopen。
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>

#include "dshlog.h"

static FILE      *g_file = NULL;
static char       g_path[MAX_PATH] = {0};
static DWORD      g_open_error = 0;
static int        g_attempts = 0;
static DWORD      g_pid = 0;
static char       g_self_path[MAX_PATH] = {0};   /* 本 DLL 自己的磁盘路径 */

/*
 * 让本 DLL 留在进程里。
 *
 * 背景（实测）：Avorion 的脚本加载器在 `require` 返回后会 FreeLibrary 我们的 DLL，
 * 而游戏 Lua 里那些指向我们的 C 闭包仍然活着 —— DLL 一卸载它们就是悬空指针，
 * 之后脚本一碰就坏（表现为飞船不动、单机实例"崩"）。
 *
 * 对策：自己再 Load 一次，把引用计数加一，抵消宿主那次 FreeLibrary。
 * 必须从 DllMain 之外调用（在加载器锁内做 LoadLibrary 不安全），所以由 luaopen_copilot 调用。
 */
void dshlog_keep_resident(void)
{
    if (g_self_path[0] == '\0') {
        dshlog("keep_resident: 自己路径未知，跳过");
        return;
    }
    HMODULE h = LoadLibraryA(g_self_path);
    dshlog("keep_resident: LoadLibraryA(self) -> %p  引用计数已抵消宿主的 FreeLibrary",
           (void *)h);
}

const char *dshlog_self_path(void) { return g_self_path; }

/*
 * 候选路径：按顺序试，第一个能打开的胜出。
 *
 * 顺序有讲究：moddata 那条最适合游戏（好找、和桥接文件放一起）；
 * mod 目录那条是为了**独立测试台**——DSH 沙箱会限制子进程写 %APPDATA% 与 %TEMP%
 * （实测 lua.exe 写这两处是 Permission denied，写工作区才行），
 * 而游戏进程不受该沙箱约束，两条都能用。
 */
static const char *CANDIDATES[] = {
    "C:\\Users\\IriskaDev\\AppData\\Roaming\\Avorion\\moddata\\copilot\\native.log",
    "D:\\SteamLibrary\\steamapps\\common\\Avorion\\mods\\copilot\\native\\copilot_native.log",
    "D:\\SteamLibrary\\steamapps\\common\\Avorion\\bin\\copilot_native.log",
    NULL
};

static void raw_write(const char *text, DWORD len)
{
    if (g_file != NULL) {
        fwrite(text, 1, len, g_file);
        fflush(g_file);                 /* 每行落盘：崩溃时最后一行也不会丢 */
    }
    OutputDebugStringA(text);
}

static int try_open(const char *path)
{
    FILE *f = fopen(path, "a");
    if (f == NULL) {
        g_open_error = (DWORD)errno;
        return 0;
    }
    setvbuf(f, NULL, _IONBF, 0);        /* 无缓冲 */
    g_file = f;
    strncpy(g_path, path, sizeof(g_path) - 1);
    g_path[sizeof(g_path) - 1] = '\0';
    return 1;
}

void dshlog_open(void)
{
    if (g_file != NULL) return;         /* 已成功 */
    if (g_attempts >= 5) return;        /* 失败也重试有限次 */
    g_attempts++;

    if (g_pid == 0) g_pid = GetCurrentProcessId();

    char temp[MAX_PATH] = {0};
    const char *cands[8];
    int n = 0;
    for (int i = 0; CANDIDATES[i] != NULL && n < 6; i++) cands[n++] = CANDIDATES[i];

    DWORD tlen = GetTempPathA(sizeof(temp), temp);
    if (tlen > 0 && tlen < sizeof(temp)) {
        strncat(temp, "copilot_native.log", sizeof(temp) - strlen(temp) - 1);
        cands[n++] = temp;
    }
    cands[n] = NULL;

    for (int i = 0; cands[i] != NULL; i++) {
        if (try_open(cands[i])) break;
    }

    if (g_file == NULL) return;

    {
        char msg[MAX_PATH + 200];
        SYSTEMTIME st;
        GetLocalTime(&st);
        _snprintf(msg, sizeof(msg),
                  "\n===== dshlog attached (attempt %d) =====\n"
                  "[%04d-%02d-%02d %02d:%02d:%02d] pid=%lu tid=%lu path=%s\n",
                  g_attempts,
                  st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
                  g_pid, GetCurrentThreadId(), g_path);
        raw_write(msg, (DWORD)strlen(msg));
    }
}

void dshlog_va(const char *fmt, va_list ap)
{
    dshlog_open();                      /* 惰性初始化：不依赖 DllMain 的时序 */

    char body[2048];
    int n = _vsnprintf(body, sizeof(body) - 1, fmt, ap);
    if (n < 0) n = (int)sizeof(body) - 1;
    body[n] = '\0';

    SYSTEMTIME st;
    GetLocalTime(&st);

    char line[2304];
    int m = _snprintf(line, sizeof(line),
                      "[%02d:%02d:%02d.%03d] pid=%lu tid=%lu %s\n",
                      st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
                      g_pid, GetCurrentThreadId(), body);
    if (m < 0) m = (int)sizeof(line) - 1;
    raw_write(line, (DWORD)m);
}

void dshlog(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    dshlog_va(fmt, ap);
    va_end(ap);
}

void dshlog_hex(const char *tag, const void *data, size_t len)
{
    dshlog_open();
    const unsigned char *p = (const unsigned char *)data;
    char buf[1024];
    int off = _snprintf(buf, sizeof(buf), "%s (%d bytes):", tag, (int)len);
    if (off < 0) off = 0;
    for (size_t i = 0; i < len && off < (int)sizeof(buf) - 4; i++) {
        off += _snprintf(buf + off, sizeof(buf) - off, " %02X", p[i]);
    }
    _snprintf(buf + off, sizeof(buf) - off, "\n");
    raw_write(buf, (DWORD)strlen(buf));
}

const char *dshlog_path(void) { return g_path; }

/* 日志自身的状态。日志写不出去时，这是唯一能告诉外界「为什么」的通道。 */
const char *dshlog_status(void)
{
    static char buf[1024];
    _snprintf(buf, sizeof(buf),
              "attempts=%d file=%s path=\"%s\" errno=%lu",
              g_attempts,
              (g_file == NULL) ? "NULL" : "open",
              g_path[0] ? g_path : "(none)",
              g_open_error);
    buf[sizeof(buf) - 1] = '\0';
    return buf;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        /* 先记下自己的路径——宿主 FreeLibrary 我们时，keep_resident 要靠它把自己 Load 回来 */
        GetModuleFileNameA((HMODULE)inst, g_self_path, sizeof(g_self_path));
        dshlog_open();                  /* 一加载就开日志，之后任何异常都留下痕迹 */
        dshlog("DllMain: DLL_PROCESS_ATTACH  self=%s", g_self_path);
    } else if (reason == DLL_PROCESS_DETACH) {
        /* 注意：这条在进程正常退出时也会走，所以「出现 DETACH」不等于「崩溃」 */
        dshlog("DllMain: DLL_PROCESS_DETACH  (reserved=%p -> %s)",
               reserved, (reserved == NULL) ? "FreeLibrary 卸载" : "进程正在终止");
    }
    return TRUE;
}
