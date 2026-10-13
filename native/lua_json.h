/*
 * lua_json.h —— Lua 值 ↔ JSON 的桥（基于 cJSON）。
 *
 * 为什么要它：协议是 {"cmd":"...","params":{...}}，而**游戏侧是 Lua，没有 JSON 库**。
 * 手写 JSON 编码还行，手写**解析器**最容易出（转义、嵌套、数字、null），所以把这一层
 * 交给久经考验的 cJSON，放在原生模块里做。
 *
 * 于是 Lua 侧就只剩收发 table，不需要知道 JSON 的存在。
 */
#ifndef LUA_JSON_H
#define LUA_JSON_H

#include "lua.h"

/*
 * 把栈上 idx 处的 Lua 值编码成 JSON 字符串。
 * 返回 malloc 的字符串（调用方用 dshjson_free 释放）；失败返回 NULL。
 *
 * 数组/对象的判定：表的键恰好是连续的 1..n（且 n>0）→ 数组，否则对象。
 * 空表按**对象**处理（协议里 params 是对象；需要空数组就显式传一个占位）。
 */
char *dshjson_encode(lua_State *L, int idx);

/*
 * 把 JSON 文本解码成 Lua 值压栈。
 * 成功返回 1（栈顶是值）；失败返回 0 并压入 nil。
 */
int dshjson_decode(lua_State *L, const char *text);

/* 释放 dshjson_encode 返回的串。 */
void dshjson_free(char *text);

#endif /* LUA_JSON_H */
