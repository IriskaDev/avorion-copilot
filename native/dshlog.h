/*
 * dshlog.h —— 原生模块日志系统接口。实现见 dshlog.c。
 *
 * 用法：
 *   链接时把 dshlog.c 一起编进去即可，DllMain 会自动打开日志。
 *   然后在任何地方 dshlog("...%d", x)。
 *
 * 拿日志路径：dshlog_path()。日志开在哪个候选路径，dshlog 启动时会记一行。
 */
#ifndef DSHLOG_H
#define DSHLOG_H

#include <stddef.h>
#include <stdarg.h>
#include <windows.h>

/* 打开日志（幂等；DllMain 已自动调用，一般不用手动调）。 */
void dshlog_open(void);

/* 主写入函数：每行一次 WriteFile + flush，绝不缓冲。 */
void dshlog(const char *fmt, ...);
void dshlog_va(const char *fmt, va_list ap);

/* 十六进制转储，用于看原始帧字节。 */
void dshlog_hex(const char *tag, const void *data, size_t len);

/* 实际使用的日志文件路径（未打开成功时为空串）。 */
const char *dshlog_path(void);

/* 本 DLL 自己的磁盘路径（DllMain 里记录）。 */
const char *dshlog_self_path(void);

/*
 * 让本 DLL 留在进程里：自己 LoadLibrary 一次，抵消宿主在 require 完成后对我们的 FreeLibrary。
 * **必须从 DllMain 之外调用**（加载器锁内 LoadLibrary 不安全）——由 luaopen_* 调用。
 */
void dshlog_keep_resident(void);

/*
 * 日志自身的状态串：attempts / file / path / errno。
 * 存在的理由：日志写不出去时任何文件通道都不可用，必须另有一条路把「为什么」送出去
 * （原生模块只能通过返回值给 Lua，所以做成字符串）。
 */
const char *dshlog_status(void);

#endif /* DSHLOG_H */
