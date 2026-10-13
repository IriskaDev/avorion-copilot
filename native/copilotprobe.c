/*
 * copilotprobe.dll —— 第二阶段：验证「DLL 能否与宿主 Lua 交换数据」。
 *
 * 原理：把 Lua 5.2.4 的核心编译进本 DLL，调用**我们自己这份** lua_pushstring 去操作
 * **宿主传进来的** lua_State。Lua C API 的函数就是按固定内存布局操作那个结构体，所以只要
 * 版本与配置一致（lua_Number=double、LUA_INTEGER=ptrdiff_t、LUAI_BITSINT=32），就能动宿主的状态。
 *
 * 危险点：布局一旦不匹配，写栈就是**直接崩游戏**。所以分两级，且级别由一个普通文件控制
 * ——这样不用重启游戏就能推进实验：
 *
 *   abi_stage.txt 内容为 1（或不存在）：只调 lua_gettop（**只读**），绝不动栈
 *   abi_stage.txt 内容为 2：         额外调 lua_pushstring 并返回它
 *
 * 判读方法：
 *   级别 1 —— require 一个模块时 Lua 会把模块名压栈，所以 lua_gettop 应该正好是 1。
 *             是 1 就说明布局对上了；是某个离谱的大数就说明配置不同，到此为止。
 *   级别 2 —— Lua 侧 print(require('copilotprobe')) 能打出那句话 = 数据通道打通。
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

#include "lua.h"
#include "lauxlib.h"

#define BRIDGE_DIR "C:\\Users\\IriskaDev\\AppData\\Roaming\\Avorion\\moddata\\copilot"
#define PROOF_FILE BRIDGE_DIR "\\native_abi_proof.txt"
#define STAGE_FILE BRIDGE_DIR "\\abi_stage.txt"

static void proof(const char *fmt, ...)
{
    FILE *f = fopen(PROOF_FILE, "a");
    if (f == NULL) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static int stage(void)
{
    FILE *f = fopen(STAGE_FILE, "r");
    if (f == NULL) return 1;
    int s = 1;
    if (fscanf(f, "%d", &s) != 1) s = 1;
    fclose(f);
    return s;
}

__declspec(dllexport) int luaopen_copilotprobe(lua_State *L)
{
    const int st = stage();

    /* ---- 级别 1：只读探查，绝不动栈 ---- */
    const int top = lua_gettop(L);
    proof("stage=%d  lua_gettop(L)=%d  sizeof(lua_Number)=%d  sizeof(lua_Integer)=%d",
          st, top, (int)sizeof(lua_Number), (int)sizeof(lua_Integer));

    if (st < 2) {
        proof("  -> 只读探查结束（未触碰 Lua 栈，无论布局对错都不会崩）");
        return 0; /* 不压任何值 */
    }

    /* ---- 级别 2：写栈 + 返回值 ---- */
    lua_pushstring(L, "native data channel alive");
    proof("  -> 已压入字符串，lua_gettop 现在 = %d（应为上一个值 +1）", lua_gettop(L));
    return 1; /* 把那个字符串作为模块值返回给 require */
}
