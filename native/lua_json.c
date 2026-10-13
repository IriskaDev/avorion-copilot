/*
 * lua_json.c —— Lua 值 ↔ JSON 的桥（基于 cJSON）。接口说明见 lua_json.h。
 *
 * 注意栈纪律：value_to_json 只读栈、不弹栈。调用方负责保证被读的值还在原处
 * （lua_next 遍历时尤其关键：键必须留在栈上，否则下次 lua_next 行为未定义）。
 */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "lua.h"
#include "lauxlib.h"
#include "cJSON.h"
#include "lua_json.h"

static cJSON *value_to_json(lua_State *L, int idx);

static cJSON *table_to_json(lua_State *L, int idx)
{
    idx = lua_absindex(L, idx);

    /* 判定数组还是对象：键数是否恰好等于数组长度 */
    lua_Integer alen = luaL_len(L, idx);
    int keycount = 0;
    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        keycount++;
        lua_pop(L, 1);                      /* 弹值，留键给下一次 lua_next */
    }

    int is_array = (alen > 0 && keycount == (int)alen);

    if (is_array) {
        cJSON *arr = cJSON_CreateArray();
        if (arr == NULL) return NULL;
        for (lua_Integer i = 1; i <= alen; i++) {
            lua_rawgeti(L, idx, i);
            cJSON *elem = value_to_json(L, -1);
            lua_pop(L, 1);
            if (elem == NULL || !cJSON_AddItemToArray(arr, elem)) {
                if (elem) cJSON_Delete(elem);
                cJSON_Delete(arr);
                return NULL;
            }
        }
        return arr;
    }

    cJSON *obj = cJSON_CreateObject();
    if (obj == NULL) return NULL;

    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        /* 键在 -2，值在 -1 */
        char keybuf[64];
        const char *key = NULL;
        if (lua_type(L, -2) == LUA_TSTRING) {
            key = lua_tostring(L, -2);
        } else if (lua_type(L, -2) == LUA_TNUMBER) {
            _snprintf(keybuf, sizeof(keybuf), "%lld", (long long)lua_tointeger(L, -2));
            key = keybuf;
        }
        if (key != NULL) {
            cJSON *val = value_to_json(L, -1);
            if (val == NULL || !cJSON_AddItemToObject(obj, key, val)) {
                if (val) cJSON_Delete(val);
                /* 值已弹一层，但键还在，先清理再返回失败 */
                lua_pop(L, 2);
                cJSON_Delete(obj);
                return NULL;
            }
        }
        lua_pop(L, 1);
    }
    return obj;
}

static cJSON *value_to_json(lua_State *L, int idx)
{
    idx = lua_absindex(L, idx);
    switch (lua_type(L, idx)) {
        case LUA_TNIL:
            return cJSON_CreateNull();
        case LUA_TBOOLEAN:
            return cJSON_CreateBool(lua_toboolean(L, idx) ? 1 : 0);
        case LUA_TNUMBER: {
            double d = lua_tonumber(L, idx);
            /* 整数值就用整数表示，免得 1 变成 1.0 这种难看的东西 */
            if (d == (double)(long long)d) return cJSON_CreateNumber((double)(long long)d);
            return cJSON_CreateNumber(d);
        }
        case LUA_TSTRING:
            return cJSON_CreateString(lua_tostring(L, idx));
        case LUA_TTABLE:
            return table_to_json(L, idx);
        default:
            return cJSON_CreateString("<unsupported>");
    }
}

char *dshjson_encode(lua_State *L, int idx)
{
    cJSON *root = value_to_json(L, idx);
    if (root == NULL) return NULL;
    char *text = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    return text;                            /* malloc 的，交给 dshjson_free */
}

static void json_to_value(lua_State *L, const cJSON *item)
{
    if (item == NULL) { lua_pushnil(L); return; }

    if (cJSON_IsBool(item)) {
        lua_pushboolean(L, cJSON_IsTrue(item));
    } else if (cJSON_IsNull(item)) {
        lua_pushnil(L);
    } else if (cJSON_IsNumber(item)) {
        double d = item->valuedouble;
        if (d == (double)(long long)d) lua_pushinteger(L, (lua_Integer)(long long)d);
        else lua_pushnumber(L, d);
    } else if (cJSON_IsString(item)) {
        lua_pushstring(L, item->valuestring != NULL ? item->valuestring : "");
    } else if (cJSON_IsArray(item)) {
        int n = cJSON_GetArraySize(item);
        lua_createtable(L, n, 0);
        int i = 1;
        for (const cJSON *c = item->child; c != NULL; c = c->next) {
            json_to_value(L, c);
            lua_rawseti(L, -2, i++);
        }
    } else if (cJSON_IsObject(item)) {
        int n = cJSON_GetArraySize(item);
        lua_createtable(L, 0, n);
        for (const cJSON *c = item->child; c != NULL; c = c->next) {
            if (c->string == NULL) continue;
            json_to_value(L, c);
            lua_setfield(L, -2, c->string);
        }
    } else {
        lua_pushnil(L);
    }
}

int dshjson_decode(lua_State *L, const char *text)
{
    if (text == NULL) { lua_pushnil(L); return 0; }

    cJSON *root = cJSON_Parse(text);
    if (root == NULL) {
        lua_pushnil(L);
        return 0;
    }
    json_to_value(L, root);
    cJSON_Delete(root);
    return 1;
}

void dshjson_free(char *text)
{
    if (text != NULL) free(text);           /* cJSON_Print 用 malloc */
}
