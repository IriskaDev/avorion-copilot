# PROTOCOL.md —— 游戏 ⇄ DSH 的 TCP 协议（v2 草案 · 待主人再审）

> **相对 v1 的变化**：加入 **`id`（必填）** 与 **`type`（`request`/`response`）**，
> 把单向决策流升级为**双向 RPC**。
>
> **为什么**：验证不该靠截图 ✗。截图会暂停、会被窗口挡住、F12 还挑按键 ✗。
> 而 `{"what":"fleet"}` 这种一问一答，能**直接拿到数字** ✓✓ —— 游戏本体或 DSH 都能当"眼睛"。
>
> **v1 的东西全部保留** ✓（分帧、信封、`hello/state/order/result` 兼容），只是**加了能力**。

---

## 1. 帧格式（v1 不变）

```
┌────────────────┬──────────────────────────┐
│ uint32 长度(LE) │  载荷：长度那么多字节       │
└────────────────┴──────────────────────────┘
```

| 项 | 定值 |
|---|---|
| 长度字段 | **uint32 小端**（原生侧写 `int` 即小端；Node 侧 `readUInt32LE`） |
| 长度含义 | **写入 buffer 的总字节数**（不是字符数） |
| 上限 | 无。仅做防错检查：明显不可能的值 → 协议错误 → 断开重连 |
| 载荷 | **UTF-8 的 JSON 文本** |

### ⚠️ 两端都必须维护累积缓冲

TCP 是字节流，**不能假设"一次读 = 一条消息"**：

```
不足 4 字节         → 等
够 4 字节但不足 len  → 等
够 len              → 切出一帧交上层，剩余字节留在缓冲继续判
```

一次 `recv` 可能拿到**半条**，也可能一次拿到**三条**。这是最容易出的 bug ✓（v1 已经踩过）。

---

## 2. 消息信封（v2：`id` 与 `type` 都是必填）

```json
{"id": 7, "type": "request",  "cmd": "query", "params": {"what": "fleet"}}
{"id": 7, "type": "response", "cmd": "reply", "params": {"ok": true, "data": {}}}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | **✓ 必填** | 发起方生成，**单条连接内唯一**（建议整数自增） |
| `type` | **✓ 必填** | `request` 或 `response` |
| `cmd` | ✓ 必填 | 命令名（见 §3） |
| `params` | 可选 | 该命令的参数对象 |

### 铁律

1. **`response` 的 `id` 必须等于对应 `request` 的 `id`** ✓✓
2. **每个 `request` 都必须得到一个 `response`** ✓ —— 包括 `event`/`state` 这类"通知"：
   对方回一个 `{"ok":true}` 即可 ✓✓
   > ★ 这个 ack **顺便就是心跳** —— 因此**不需要单独的心跳机制** ✓✓
3. `response` 的 `cmd` **固定为 `reply`** ✓（表示"这是对某请求的答复"，
   具体是什么答复看 `params` ✓）；`order`/`reload` 的答复同样走 `reply` ✓
4. 收到 **`id` 未知的 `response`** → **丢弃并记日志** ✗，不崩、不断连 ✓
5. 收到 **`type` 非法 / `id` 缺失** 的帧 → 回 `error` ✓ 并记日志 ✓（协议错误但仍保持连接 ✓）

---

## 3. 命令表

| cmd | 起点 | 语义 |
|---|---|---|
| `hello` | 双向 | 握手：`{ver: 2, side: "game"\|"dsh", caps: [...]}` |
| `query` | DSH → 游戏 | **RPC 读取**（见 §4） |
| `order` | DSH → 游戏 | 下指令：`{ship, action, ...}` |
| `reload` | DSH → 游戏 | 触发热重载：`{which?: "ops"}` |
| `state` | 游戏 → DSH | 舰队快照推送（是否开启由 DSH 决定 ✓） |
| `event` | 游戏 → DSH | 自发事件：`{kind: "connected"\|"background_finished"\|"attacked", ...}` |
| `reply` | 被请求方 → 请求方 | **所有答复统一走这条**：`{ok, data \| code, message}` |
| `error` | 双向 | 协议层错误：`{code, message}` |

> **`state` 与 `query` 的分工** ✓：`state` 是游戏**主动推**（流式观察 ✓）；
> `query` 是 DSH **按需拉**（工具调用 ✓✓）。两者**数据形状完全一致**（§5 ✓）✓

---

## 4. `query` —— 本协议的重点（这就是"眼睛"）

### 4.1 请求

```json
{"id": 7, "type": "request", "cmd": "query", "params": {"what": "fleet"}}
{"id": 8, "type": "request", "cmd": "query", "params": {"what": "ship", "ship": "Miner-00002"}}
{"id": 9, "type": "request", "cmd": "query", "params": {"what": "orderSchema", "ship": "Miner-00002"}}
```

### 4.2 第一期的 `what`

| what | params | 返回 |
|---|---|---|
| `fleet` | — | **全部名单船**的快照数组（§5） |
| `ship` | `ship` | 单船快照 |
| `orderSchema` | `ship` | ★ **这艘船允许下哪些命令、每个命令的 config 形状** |
| `caps` | — | 游戏侧**支持的全部 `what`**（自我声明 ✓） |

> ★ `orderSchema` 是**关键设计** ✓：游戏侧用原版的
> `getConfigurableValues(owner, ship)` / `getAreaSize` / `isAreaFixed` / `isShipRequiredInArea`
> （见 `LLM-OPS.md` §3.3）**自己声明**命令参数结构 ✓✓。
> **DSH 因此不必硬编码任何命令形状** ✓ —— 加命令、改参数，DSH 侧零改动 ✓✓。

### 4.3 答复

```json
{"id": 7, "type": "response", "cmd": "reply", "params": {"ok": true, "data": {"ships": [ ... ]}}}
{"id": 8, "type": "response", "cmd": "reply", "params": {"ok": false, "code": "NO_SUCH_SHIP", "message": "..."}}
```

- `ok: false` 时**不抛异常也不断连** ✗ —— 只回错误码 ✓（工具调用失败是正常业务 ✓）
- `data` 形状由 `what` 决定 ✓（§5）

---

## 5. 快照结构（`fleet` / `ship` / `state` 共用）

**全部字段用今晚实测验证过的 API 取** ✓（见 `LLM-OPS.md` 的实测纠正表）：

```json
{
  "name": "Miner-00002",
  "busy": true,                              // player:getShipAvailability(name) == ShipAvailability.InBackground
  "availability": 2,                         // 原始枚举值，便于排查
  "hasCaptain": true,                        // ShipDatabaseEntry:getCaptain() ~= nil
  "captainClass": "Miner",                   // 可选
  "sector": [-394, 74],                      // 当前星区
  "cargo": {"free": 1200, "max": 4000},      // 可选
  "status": "正在采矿",                       // ★ Simulation.getDescription(shipName)，与游戏舰船页一致
  "remaining": "37 min",                     // 可选
  "probe": {"turrets": "getTurrets is nil"}  // ★ 探测失败的原因也报出来，便于迭代
}
```

**原则** ✓：
- **任何一项取不到都不许崩** ✗ → 用 `null` 或 `probe` 里写明原因 ✓（本项目规矩：不确定就 `pcall` ✓）
- **字段只增不减** ✓（DSH 侧按需读 ✓）
- `status` 就是玩家在舰船页看到的那句话 ✓✓ —— **DSH 看到的与主人看到的完全一致** ✓

---

## 6. 连接与生命周期

**DSH 侧监听，DLL 主动连 `127.0.0.1:8765`** ✓（理由不变：DLL 主动连**不触发防火墙弹窗** ✓；让游戏 listen 会 ✗）

| 事项 | 规则 |
|---|---|
| 握手 | 连上后双方各发一次 `hello`（都是 `request`，各回一个 `response` ✓） |
| 版本 | `ver` 不等 → 记日志，**按最低版本运行** ✓ |
| 心跳 | **不需要专门心跳** ✓✓ —— 任何帧都要求 ack（§2 铁律 2 ✓），ack 本身就是活性证明 ✓ |
| 判死 | 任一方向 **30 秒**没收到任何帧 → 认为连接已死 → 关闭 ✓ |
| 重连 | **DLL 负责重连** ✓（每 5 秒一次），DSH 只管 accept ✓ |
| 多连接 | DSH **只接受一条** ✓；新连接到达 → 关旧连接并记日志 ✓（防重连竞态堆连接 ✓） |
| 非阻塞 | **DLL 侧一切非阻塞** ✓，收发绝不允许阻塞游戏主线程 ✗ |
| 端口占用 | DSH 启动失败（`EADDRINUSE`）→ **明确报错** ✓，不许静默 ✓<br>（今晚踩过：旧监听占着 8765，插件静默起不来 ✗✓） |

---

## 7. 版本与兼容

- 本文件是 **`ver: 2`** ✓
- `hello` 带 `ver` ✓ + `caps` ✓（支持的 `cmd` 与 `what` 列表 ✓）
- **未知 `cmd`** → 回 `error` ✓（不断连、不崩 ✓）
- **未知 `what`** → 回 `reply{ok:false, code:"UNSUPPORTED"}` ✓

---

## 8. 一次完整交互（跑通即说明整条链好了）

```
DLL → DSH   {"id":1,"type":"request","cmd":"hello","params":{"ver":2,"side":"game","caps":["fleet","ship","orderSchema"]}}
DSH → DLL   {"id":1,"type":"response","cmd":"reply","params":{"ok":true}}

DSH → DLL   {"id":2,"type":"request","cmd":"hello","params":{"ver":2,"side":"dsh"}}
DLL → DSH   {"id":2,"type":"response","cmd":"reply","params":{"ok":true}}

DSH → DLL   {"id":3,"type":"request","cmd":"query","params":{"what":"fleet"}}
DLL → DSH   {"id":3,"type":"response","cmd":"reply","params":{"ok":true,"data":{"ships":[
                {"name":"Miner-00002","busy":true,"hasCaptain":true,"status":"正在采矿","sector":[-394,74]},
                {"name":"Trader-00001","busy":true,"hasCaptain":true,"status":"交易","sector":[-412,73]}
            ]}}}

DSH → DLL   {"id":4,"type":"request","cmd":"query","params":{"what":"orderSchema","ship":"Miner-00002"}}
DLL → DSH   {"id":4,"type":"response","cmd":"reply","params":{"ok":true,"data":{"actions":[
                {"action":"Mine","areaSize":{"min":3,"max":8},"areaFixed":false,"shipRequiredInArea":false,
                 "config":{"refinedMining":{"type":"bool"},"rawMining":{"type":"bool"}}}
            ]}}}

DSH → DLL   {"id":5,"type":"request","cmd":"order","params":{"ship":"Miner-00002","action":"Mine","x":-394,"y":74,"size":5}}
DLL → DSH   {"id":5,"type":"response","cmd":"reply","params":{"ok":true,"data":{"detail":"command started"}}}

DLL → DSH   {"id":6,"type":"request","cmd":"event","params":{"kind":"background_finished","ship":"Miner-00002"}}
DSH → DLL   {"id":6,"type":"response","cmd":"reply","params":{"ok":true}}

DSH → DLL   {"id":7,"type":"request","cmd":"reload","params":{}}
DLL → DSH   {"id":7,"type":"response","cmd":"reply","params":{"ok":true,"data":{"detail":"9 ok, 1 failed"}}}
```

---

## 9. Lua 侧 API 形状（v1 已实现，只需补 `id`/`type`）

```lua
local net = require("copilot")
net.connect("127.0.0.1", 8765)              -- 非阻塞
net.connected()                             -- bool
net.send({id = 1, type = "request", cmd = "state", params = {...}})
local msg = net.recv()                      -- 非阻塞；完整一帧则返回 table
net.close()
```

**新增需求**（都很小）：
1. **`id` 生成与回填** ✓ —— `link_out` 自增 `id` ✓；`link_in` 收到 `request` 后原样把 `id` 填进 `response` ✓
2. **待答复表** ✓ —— `link_in` 收到 `response` 时按 `id` 找等待者 ✓（N 秒无答复 → 超时 ✓）
3. **发送队列** ✓ —— 一次问 10 条 `query` 时别写阻塞 ✓（当前非阻塞 ✓，需处理 `EWOULDBLOCK` 与排队 ✓）

---

## 10. 主人的三条批注（已采纳 ✓）

1. ✅ **`id` 改为必填** ✓
2. ✅ **加 `type`，分 `request`/`response`** ✓
3. ⏳ **`state` 保留还是砍掉** —— 还没说 ✓。
   本鱼的建议：**保留但默认关闭** ✓ —— DSH 想要实时流时发一条
   `{"cmd":"query","params":{"what":"subscribe","what2":"state"}}` ✗ hmm ——
   hmm，更简单：**保留 `state`，由 DSH 侧配置决定开不开** ✓（默认开，嫌吵就关 ✓）
