# dsh-avorion-copilot

Avorion `copilot` mod 与 DSH 之间的桥接插件。

## ★ 本插件的角色：**游戏 RPC 接口提供者**（2026-10-17 主人定的范围）

主人原话：

> 「dsh 插件的角色其实就应该变为了'**游戏 RPC 请求接口提供者**'。」
> 「那就不需要是分身了，直接就可以投递到**当前会话**，决策完，再将操作传递给游戏。」

所以它**只做三件事** ✗✓（多一件都不做 ✗）：

```
① 让 agent 能操作游戏     → 注册 fleet_* 工具（fleet_query / fleet_order / fleet_escort /
                            fleet_goal / fleet_recall / fleet_decisions ✓）
② 把游戏的事件变成任务     → 空闲船要决策时，组装 <fleet_task> 投进**主人自己的会话** ✓
③ 把会话的结论交回游戏     → 解析 action 行 → 校验 → 走原来那条 order RPC 下单 ✓
```

**没有分身、没有新建会话、没有编排者角色** ✗ —— 人格归主人的会话自己（cosplay 全局提示段 ✓），
上下文长度归 DSH 的**自动会话压缩**（见 `AGENT-DESIGN.md` 的"上下文与持久性"一节 ✓）。

传输是 **TCP + 对称 RPC**（`127.0.0.1:8765`，协议见 mod 仓库 `PROTOCOL.md` v2 ✓）：
插件**监听**，游戏主动连过来（这样不触发 Windows 防火墙弹窗 ✓）。

## 一次决策的流程

```
游戏侧（Lua）                                    插件（DSH 宿主平面）
 空闲船 ── TCP decide {ship} ─────────────────▶ 预取事实（query：goal/ship/minePlan/tradePlan/…）
                                                  │
                                        ┌─────────┴──────────────────────────────┐
                                        │ ① 投给**主人指定的那个会话**（空闲时）  │
                                        │    agent.followup(<fleet_task …>)      │
                                        │    等这一轮结束（硬闸 20s）→ 校验答案  │
                                        │ ② 会话忙/没答成 → 单发模型调用（硬闸 15s）│
                                        │ ③ 两条都不行 → action=None（明说 ✓）    │
                                        └─────────┬──────────────────────────────┘
                          TCP query/order ◀───────┘
 下单（两段式 startAreaAnalysis → startCommand）
```

- **主人正在聊天时绝不打扰** ✓：会话一忙就直接落单发，**不插队、不排队** ✗
  （主人的对话永远优先 ✓）。
- **一次只有一个指挥官** ✓：指定新会话会**原子顶掉**旧的 —— 旧会话立刻不再收到任务 ✓
  （与 `TAKEOVER.md` 的"同一时刻只有一个决策者"一致 ✓）。
- 没指定指挥官 → 逐字回到"插件自己单发决策"（= 之前的全部行为 ✓）。

## 怎么指定指挥官（三种入口，任选）

| 入口 | 用法 |
|---|---|
| ★ **会话页顶部的开关** | 会话标题旁边那个 `接管舰队 / Fleet 指挥官` 开关 ✓ —— 打开 = **这个会话**接管；再点 = 关掉 ✓（别的会话打开 = 顶掉当前那个 ✓） |
| **对 agent 说话** | 「你接管舰队」→ 她调 `fleet_commander { action: "claim" }` ✓（用 `currentInitiator()` 认出**是哪个会话**开的口 ✓，认不出就要求显式给 id ✓，**绝不猜** ✗） |
| **配置文件** | `config.commanderSession: <会话 id>` ✓（DSH 重启后自动恢复 ✓） |

指定结果**落在** `%APPDATA%/Avorion/moddata/copilot/commander.json` ✓（只有一个 `session` 字段 ✓），
每次变化都往 `decisions.live.log` 写一行 ✓ —— 主人随时能确认"现在谁在指挥" ✓。
租约（60s，每次成功投递续期 ✓）**只用于状态显示**，不是投递闸门 ✓（会不会投，只看那个会话还活着没有 ✓）。

## 配置

```yaml
- name: '@dsh-external/dsh-avorion-copilot'
  config:
    port: 8765
    provider: deepseek-official
    model: deepseek-flash
    maxTokens: 8000          # ★ 700 不够：额度会被思维链烧光，正文被截断 → 解析失败 ✗
    temperature: 0.2
    commanderSession: ''     # 指挥官会话 id（留空 = 用 commander.json 里落盘的那个 ✓）
    decideMode: shadow       # ★ shadow（默认）= 只观测不采纳；live = 采纳会话的答案 ✓
    steerWhenBusy: false     # 主人在聊天时要不要插队（默认 false ✓ 主人的对话优先）
    retrySessionOnce: false  # 会话第一次没给动作行时要不要再投一次（默认 false）
```

### `decideMode` 是**两阶段上线**，也是回滚开关

| 模式 | 谁真的决定了这一单 | 用途 |
|---|---|---|
| `shadow`（**默认**） | **单发**（会话的答案只被记录 + 与单发并排比较 ✓） | 零风险地量她答得怎么样、延迟多少、花了多少 token ✓ |
| `live` | 会话（答成才算；没答成落单发 ✓） | 真正让她指挥 ✓ |

改回 `shadow` 即回滚 ✓；`fleet_commander { clear: true }`（或关掉开关）也立刻回到单发 ✓。

## 决策记录：`source` 字段说真话

每条 `DecisionRecord` 都有 `source` ✓（`fleet_decisions` 工具 / `decisions.log` / `decisions.live.log` ✓）：

| `source` | 含义 |
|---|---|
| `session` | 投进主人会话、由她定的 ✓ |
| `single-shot` | 插件自己那一次单发调用定的 ✓ |
| `shadow` | ★ 影子模式：她答了，但这一单**采纳的是单发** ✓ |
| `asked-owner` | 她在问主人 → 本轮**明确延期**、未派单 ✓（人在环里 ✓） |
| `none` | 两条路都没有可用答案 ✓ |
| `rendezvous` | 插件先派护航、本轮不下单 ✓（既有逻辑 ✓） |

记录里还有 `session`（她答了什么/几步/多久 ✓）与 `agreement`（她的答案与单发是否一致 ✓）——
`shadow` 模式下这两个字段就是"她靠不靠谱"的量尺 ✓。

## 工具面（agent 手上的工具）

| 工具 | 读/写 | 说明 |
|---|---|---|
| `fleet_query` | 读 | `what=fleet / ship / goal / orderSchema / sectorFacts` ✓ —— **唯一正当的"看游戏"方式** ✓（别靠截图 ✗） |
| `fleet_decisions` | 读 | 历史决策 + 思维链（纯本地记忆，游戏关着也能查 ✓） |
| `fleet_commander` | 读/写 | 看/设/清"谁是舰队指挥官" ✓（`action=claim` 认调用者自己的会话 ✓） |
| `fleet_order` | 写（动船） | 下后台命令 ✓ |
| `fleet_escort` | 写（动船） | 派护航去目标船所在星区 ✓ |
| `fleet_goal` | 写（改意图） | 设/清某船的长期目标 ✓ |
| `fleet_recall` | 写（动船） | 召回 ✓ |

## 任务块与答案契约（**压缩免疫** ✓）

投进会话的是一条**普通 user 消息**（`source.kind='plugin'` ✓），所以主人在会话里**看得见** ✓：

```
<fleet_task id="t-1a2b3c4d" ship="Miner-00002" deadline_hint="20s">
★ 这是**插件**投递的**舰队决策请求** —— **不是主人在说话** ✗✓。
…
action=<动作>
task=t-1a2b3c4d          ← ★ 必须回显（舰队认出"这是回给我的"的唯一凭据 ✓）
x=…  y=…  size=…  reason=…
</fleet_task>
```

- **自包含但精简** ✓：每块都带齐"答这一单需要的一切"（船 / 目标 / 事实 / 答案格式 ✓）——
  因为 DSH 的**自动压缩**可能把更早的任务块改写成摘要 ✗，所以**不许**依赖"上一条消息是任务" ✗✓。
- **任务块外的闲聊不受影响** ✓：她可以在字段行之后继续跟主人聊天，舰队只认回显对上号的那条 ✓。
- 回显**写错** → 判 `TASK_MISMATCH` 并**绝不采纳** ✓（绝不把别的船的答案用在这艘船上 ✓）；
  回显**没写** → 仍然采纳（她是会话、不是背格式的机器人 ✓），只是标 `echoed=false` ✓。

## 离线自测

```powershell
node test/commander-dispatch.mjs   # 16/16：四种失效模式 + 回显错配 + 影子 + 忙碌不打扰 + 唯一性
node test/order-payload.mjs        # 55/55：下单载荷 + 提示词可见性 + 重试恰好一次
node test/prompt-file.mjs          # 提示词读文件 / 覆盖优先 / 兜底
node test/actions-consistency.mjs  # 动作集合三处一致
node test/rendezvous.mjs           # 护航判据（原版口径）
node test/memory-demo.mjs          # 长期记忆
node scripts/check-mechanics.mjs   # 机制段/提示词不漂移
```

> ★ `test/harness.mjs` 是**文件桥时代**的测试（那个 API 早就不存在了 ✗），跑不动，与本次改动无关 ✓。
> `test/commander-dispatch-proto.mjs` / `test/toolcall-wire-probe.mjs` 是设计 pass 的**原型/探针** ✓
> （`commander-dispatch.mjs` 是它的生产版 ✓）。

## 构建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1
```

本机没有 DSH 源码 checkout（没有 `packages/` 与 `vendor/`），所以脚本：

- 类型取自**全局安装的 npm 包** `@deepseek-ai/dsh-llm`（它自带 `.d.ts`）
- `tsc` 借用另一个插件工程 `node_modules.bak` 里的那份

### ⚠️ 产物绝不能带 `node_modules`

DSH 宿主**自己解析** `@deepseek-ai/*` 与 `schemastery`。插件自带 `node_modules` 反而会**遮蔽**
宿主那份，而 npm 版 `dsh-llm` 的传递依赖 `@deepseek-ai/cordis` 是个**空目录**，会直接加载失败：

```
我们 → dsh-llm → dsh-typert-protocol → @deepseek-ai/cordis   ← 空目录
```

所以 `scripts/build.ps1` 是 **建链接 → 编译 → 删链接**，跑完插件目录是干净的 ✓。

### `lib/client.js` 是**手写**的（不进编译器 ✓）

它是浏览器侧那个会话开关 ✓（见下节）。DSH 的客户端插件产物必须是
`window.__ModuleLoader__.load({ id, factory })` 这种形态 ✓，而上游的打包流程需要**DSH 源码 checkout**
（本机只有 App.asar ✗）—— 所以它按**原样形态手写**（纯 ES2020 + React.createElement ✓，无需构建 ✓），
`package.json` 里用 `dsh.client` 声明它是 web 平台客户端入口 ✓。

## ★ 会话页顶部那个开关（客户端 UI）

- **挂在哪**：`conversation.session.header.actions` ✓（`kind: 'list'`、`scope: 'session'` ✓）。
  它**不是本鱼发明的** ✓ —— 契约声明在
  `@deepseek-ai/dsh-client-ui-conversation/lib/types/client/contract/slots.d.ts:134` ✓；
  官方插件就在用同一处（`dsh-client-ui-jobs/lib/client.js:266`、
  `dsh-client-ui-schedule/lib/client.js:293` ✓）。会话作用域的组件能拿到 `sessionId` ✓
  （官方用法逐字：`dsh-client-ui-jobs/lib/client.js:117` ✓）。
- **怎么和插件说话**：插件用 `ctx.webServer.register({kind:'prefix', path:'/avorion-copilot/api', …})`
  挂了一条 HTTP 路由 ✓，客户端 `fetch` 它 ✓（同一个模式见 `dsh-super-injector`：
  路由 `/super-injector/api` ✓）。
  `GET /avorion-copilot/api/commander` 读状态 ✓；
  `POST …/commander/toggle` 原子切换 ✓；`POST …/commander/clear` 清除 ✓。
- **生效方式（诚实说明）**：
  - 客户端资源是**构建期**打包进 web 壳的 ✗ —— 所以**改客户端代码后要重建 Web 产物 + 刷新页面** ✓。
    只有在 **DSH 源码 checkout 里跑着 `pnpm run dev:web`** 时，客户端插件才会**热重载** ✓；
    本机没有那个 checkout ✗ → **对本插件来说=需要重建/重启** ✓。
  - 服务端那一半（HTTP 路由、投递阶梯）是宿主插件 ✓ —— 也要**重启 DSH** 才会带上新代码 ✓。
  - ★ 拿不到 `webServer`（或没有客户端壳）时**没有 UI 开关** ✗ —— 但功能本体**不依赖它** ✓，
    用 `fleet_commander` 工具/配置照样能用 ✓（启动时会往流水里写清是哪一种情况 ✓）。
