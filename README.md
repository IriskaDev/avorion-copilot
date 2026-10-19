# Copilot —— Avorion 的 AI 副驾驶（游戏 mod + DSH 插件）

一句话：把 Avorion 的操船与舰队运营接成 AI 可调用的接口 —— 游戏内面板管你正在开的那条船，
DSH（DeepSeek Harness）侧用 `fleet_*` 工具读事实、下后台命令、看决策记录。

> 本文件是**安装与使用说明**（给 AI 和愿意看的人）。
> 要改代码 / 读机制，从 [`AGENTS.md`](AGENTS.md) 进；游戏侧机制从 [`docs/game/README.md`](docs/game/README.md) 进。

## 1. 这是什么

三层能力，全部是**接口**，不含自动替你做决定的策略（策略在 DSH 会话里，规则见
[`docs/game/rules/owner-rules.md`](docs/game/rules/owner-rules.md)）：

1. **实体级自动驾驶**：面板开关接管你正在开的船，星区内自动接敌 / 采矿 / 打捞 / 跃迁
   （`data/scripts/player/ai/autopilot.lua`）。
2. **舰队运营 RPC**：**7 个** `fleet_*` 工具在 DSH 里可用 —— `fleet_query`（读事实）、
   `fleet_order`（下后台命令）、`fleet_escort`、`fleet_goal`、`fleet_recall`、`fleet_commander`、
   `fleet_decisions`（注册处：`plugin/dsh/src/tools.ts:135,418,582,709,747,787,885`）。
3. **决策投递闭环**：名单里的船空闲时，把一条 `<fleet_task>` 投进**你指定的那个 DSH 会话**，
   会话里答出 `action=` 行后由插件映射回游戏下单（`plugin/README.md` §一次决策的流程）。

传输是 **游戏 DLL 主动连 `127.0.0.1:8765`**，插件侧监听（`PROTOCOL.md:163`）。
这样不触发 Windows 防火墙弹窗，也不需要给游戏开端口。

状态（如实）：实体层与 RPC 已可用；战略层的运营大脑仍是增量开发中，见
[`docs/dev/current-status.md`](docs/dev/current-status.md)。

## 2. 依赖

| 依赖 | 版本 | 出处 |
|---|---|---|
| Avorion | **2.5.13**（mod 声明 `2.0.*`～`2.5.*`） | 实测版本 `docs/dev/overview.md:13`；`modinfo.lua` 的 `dependencies` |
| DSH 桌面版（DeepSeek Harness） | **0.2.0-rc.2** | `docs/dev/install-and-deploy.md:58` |
| Node.js | **v26.2.0**（插件运行在 DSH 宿主里；`node` 命令本机实测） | `node --version` |
| Lua 源码（编译基准） | **5.2.1**（★ 不能换版本，见 §3.2） | `docs/dev/build-and-native.md:15-22` |
| Visual Studio 2022（MSVC）+ Windows SDK | 任意近期版本 | `NATIVE.md:179-196` |

★ 仓库里**没有**任何 `*.dll`（`.gitignore` 排除了它）。想跑起来必须自己编一次
`copilot.dll`，见 §3.2 —— 这是本仓库最容易踩空的一步。

## 3. 安装

三步：游戏侧（mod 本体 + 原生 DLL）→ 插件侧（DSH 装配）→ DSH 侧（插件配置）。
每一步都给了**验证命令**，跑完对一下再往下走。

### 3.1 游戏侧：把 mod 放进游戏读的位置

★ 游戏只扫 `%AppData%\Avorion\mods\`，**不扫游戏目录下的 `mods\`**（`docs/dev/install-and-deploy.md:7-9`）。
所以用目录联接（junction）把源码目录挂过去，改源码即生效，不用复制。

```powershell
git clone https://github.com/IriskaDev/avorion-copilot.git "$env:USERPROFILE\avorion-copilot"
$src = "$env:USERPROFILE\avorion-copilot"
$dst = "$env:APPDATA\Avorion\mods\copilot"
New-Item -ItemType Directory -Force -Path "$env:APPDATA\Avorion\mods" | Out-Null
if (Test-Path $dst) { Write-Host "已存在，先确认它不是真目录：$dst" } else { New-Item -ItemType Junction -Path $dst -Target $src | Out-Null }
```

验证：

```powershell
Get-Item "$env:APPDATA\Avorion\mods\copilot" | Select-Object LinkType, Target
Test-Path "$env:APPDATA\Avorion\mods\copilot\modinfo.lua"
```

期望：`LinkType` = `Junction`、`Target` = 你的克隆目录；`Test-Path` = `True`。

启用：**重启游戏** → 主菜单「模组 & 创意工坊」→ 左上角的列表图标切到**本地 mod 页签**
（默认停的是创意工坊页签，那里不会出现本 mod）→ 勾选 **Copilot** → **再重启一次游戏**
（mod 列表只在启动时扫一次，`docs/dev/install-and-deploy.md:18-21`）。

验证：

```powershell
Get-Content "$env:APPDATA\Avorion\mods\modconfig.lua" | Select-String 'copilot'
```

期望：能看到 `copilot` 出现在启用表里。

### 3.2 游戏侧：编译并放置 `copilot.dll`

为什么需要它：Lua 本身没有 socket，游戏与 DSH 之间的 TCP 通道由这个原生模块提供
（`docs/dev/build-and-native.md:7-13`）。

1. 下载 **Lua 5.2.1** 源码，解到 `<仓库>\native\lua-src\lua-5.2.1\`（该目录被 `.gitignore` 排除）。
2. 用「x64 Native Tools Command Prompt for VS 2022」打开 PowerShell，然后按 `NATIVE.md:179-196` 编译：

```powershell
$repo = "$env:USERPROFILE\avorion-copilot"
$nat  = "$repo\native"
$lsrc = "$nat\lua-src\lua-5.2.1\src"   # ★ 必须是 5.2.1
$out  = "$repo\build"                  # ★ 产物统一落 build/，别留在 native/ 里
New-Item -ItemType Directory -Force -Path $out | Out-Null
Set-Location $nat
$core = 'lapi','lcode','lctype','ldebug','ldo','ldump','lfunc','lgc','llex','lmem',
        'lobject','lopcodes','lparser','lstate','lstring','ltable','ltm','lundump',
        'lvm','lzio','lauxlib'
cl /nologo /LD /O2 /utf-8 /D_CRT_SECURE_NO_WARNINGS /I"$lsrc" /I"$nat" `
   copilot.c dshlog.c lua_json.c cJSON.c @core ws2_32.lib `
   /Fo:"$out\" /Fe:"$out\copilot.dll"
```

3. 把产物放到**游戏真正加载的那一份**位置（编译产物统一落 `build/`，别往 `native/` 里丢）：

```powershell
Copy-Item "$repo\build\copilot.dll" "D:\SteamLibrary\steamapps\common\Avorion\bin\copilot.dll" -Force
```

验证：

```powershell
Test-Path "$repo\build\copilot.dll"                                     # 期望 True
Test-Path "D:\SteamLibrary\steamapps\common\Avorion\bin\copilot.dll"   # 期望 True
```

★ 编译基准**必须是 Lua 5.2.1**：宿主 exe 里写的就是 5.2.1，用 5.2.3/5.2.4 编会堆损坏，
进游戏约一分钟后进程消失（`0xC0000374`），实测记录见 `docs/dev/build-and-native.md:20-22`。
★ `NATIVE.md:180-181` 那两行示例路径里写的是 `lua-5.2.4`，属旧文未同步 —— 按 5.2.1 走。

### 3.3 插件侧：把插件注册进 DSH 桌面版

`plugin/dsh/lib/` 是**已入库的编译产物**，DSH 启动时直接读它，所以这一步**不需要编译**
（`docs/dev/install-and-deploy.md:40`）。注册 = 改一个 JSON、加一段 YAML。

先加依赖与 bundle（可整段复制执行）：

```powershell
$p = "$env:USERPROFILE\.dsh\profiles\desktop\package.json"
$j = Get-Content $p -Raw | ConvertFrom-Json
$link = "link:" + (Resolve-Path "$env:USERPROFILE\avorion-copilot\plugin\dsh").Path.Replace('\','/')
$j.dependencies | Add-Member -NotePropertyName '@dsh-external/dsh-avorion-copilot' -NotePropertyValue $link -Force
if ($j.dsh.profile.bundles -notcontains '@dsh-external/dsh-avorion-copilot') {
  $j.dsh.profile.bundles += '@dsh-external/dsh-avorion-copilot'
}
$j | ConvertTo-Json -Depth 10 | Set-Content $p -Encoding UTF8
```

再给插件一条配置（会话/端口/决策模式都在这里；字段含义见 `plugin/README.md` §配置）：

```powershell
@'

- id: avorion-copilot
  name: "@dsh-external/dsh-avorion-copilot"
  config:
    port: 8765
    decideMode: shadow
'@ | Add-Content "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml" -Encoding UTF8
```

★ 装配改完**必须完全退出 DSH 桌面版再开**（桌面版没有绑刷新快捷键，`docs/dev/install-and-deploy.md:66`）。

验证：

```powershell
(Get-Content "$env:USERPROFILE\.dsh\profiles\desktop\package.json" -Raw | ConvertFrom-Json).dependencies.'@dsh-external/dsh-avorion-copilot'
Get-NetTCPConnection -LocalPort 8765 -State Listen | Select-Object LocalAddress, LocalPort, OwningProcess
```

期望：第一行打印 `link:.../plugin/dsh`；第二行有 `127.0.0.1 8765 ...`。第二行空了就是插件没被加载，
按 §6 第 3 条查。

→ 想要「空闲船把决策任务投进我的会话」，再按 `plugin/README.md` §怎么指定指挥官
（会话顶部开关 / 对 agent 说 `你接管舰队` / 配置 `commanderSession`）指定一次；
默认 `decideMode: shadow` 只观测不采纳，确认无误再改 `live`。

### 3.4 改代码后怎么生效

| 改了 | 怎么生效 |
|---|---|
| `data/**.lua` | 重载存档，或重启游戏（热重载入口已退役，`docs/dev/hot-reload-and-vm-boundaries.md`） |
| `native/*.c` → `copilot.dll` | 重新编译 + 覆盖游戏 `bin\copilot.dll` + **重启游戏** |
| `plugin/dsh/src/**.ts` | 重编到 `lib/`：`pwsh -File plugin/dsh/scripts/build.ps1`（脚本会自建编译期链接、编完删掉，见该文件头注释），然后重启 DSH |
| `plugin/dsh/prompt/system.md` | **不用重启**（运行时可覆盖，`docs/dev/install-and-deploy.md:49-54`） |

## 4. 第一次跑

1. **先起 DSH 桌面版**（它监听 8765），再经 Steam 启动 Avorion，进存档。
2. 确认 mod 活着：`rpc_trace.log` 里出现心跳行。

```powershell
Select-String -Path "$env:APPDATA\Avorion\moddata\copilot\rpc_trace.log" -Pattern 'hb connected=true' | Select-Object -Last 3
```

期望：打印出若干行 `hh:mm:ss  hb connected=true roster=N`（心跳每 5 秒一条，
写日志的是 `data/scripts/net/rpc.lua:30`，心跳文本由 `data/scripts/net/net.lua:162` 产出）。

3. 确认插件看得到游戏：在 DSH 里调一次 `fleet_query {what: "caps"}`。
期望：返回游戏**自我声明**支持的 `what` 列表（`data/scripts/net/link_in.lua:222`）；
若回 `not connected to the game`，说明 §3.3 的端口没在听。

4. 面板：游戏内**按住 SHIFT** 才出现右上角快捷栏（原版行为），点那个机器人图标（`panel.lua:23-26`、`:770`）。
   面板里有：自驾开关、AI 实时状态、允许 AI 自动运营的舰船名单、每船目标输入框、
   炮塔底座材料升级（`docs/dev/current-status.md:10-13`）。

## 5. 怎么用

AI（DSH 会话里的 agent）用的是这 7 个工具，`fleet_query` 是**唯一正当的看游戏方式**（别靠截图）：

```jsonc
// 读：名单 → 某船能力卡 → 一个框的预测
fleet_query { what: "list" }
fleet_query { what: "ship", ship: "Miner-00001", brief: true }
fleet_query { what: "predict", ship: "Miner-00001", action: "Mine", x: 12, y: -34, sizeX: 15, sizeY: 15, duration: 2 }

// 写：下单（异步；船长会把船开出当前星区）
fleet_order { ship: "Miner-00001", action: "Mine", x: 12, y: -34, size: 15, duration: 2 }

// 写：改意图 / 召回
fleet_goal { ship: "Miner-00001", text: "在西北方向采矿，被攻击就撤" }
fleet_recall { ship: "Miner-00001" }
```

- 工具清单与每个 `what` 的返回字段：[`docs/game/ops/tools-cheatsheet.md`](docs/game/ops/tools-cheatsheet.md)。
- 完整作业流程（采矿/贸易/打捞/侦察/护航/材料/改名）与故障对照：
  [`docs/game/ops/fleet-ops-manual.md`](docs/game/ops/fleet-ops-manual.md)。
- 玩家的硬规矩（风险闸门 10%、什么时候**不**开 safeMode、绝不碰玩家正开的船）：
  [`docs/game/rules/owner-rules.md`](docs/game/rules/owner-rules.md)。

## 6. 排错（症状 → 命令 → 期望）

| # | 症状 | 命令 | 期望 |
|---|---|---|---|
| 1 | 游戏里没有 Copilot 图标 / 面板 | `Get-Item "$env:APPDATA\Avorion\mods\copilot" \| Select-Object LinkType,Target`；`Get-Content "$env:APPDATA\Avorion\mods\modconfig.lua" \| Select-String copilot` | `Junction` + 目标正确；modconfig 里能看到 `copilot`（不在就回 §3.1 的启用步骤，且改完要重启） |
| 2 | 面板在，但完全没有 RPC（`fleet_query` 报 `not connected to the game`） | `Select-String "$env:APPDATA\Avorion\moddata\copilot\rpc_trace.log" -Pattern 'hb connected' \| Select-Object -Last 3` | 有 `hb connected=true`。若一直是 `false`，看 §6 第 3、4 条；日志文件根本没有 → DLL 没加载（第 4 条） |
| 3 | 8765 没有监听 | `Get-NetTCPConnection -LocalPort 8765 -State Listen` | 有 `127.0.0.1:8765`。空 → 插件没被加载：检查 profile `package.json` 的 `dependencies`/`bundles` 与 `cordis.patch.yml`，改完**完全退出 DSH 再开**；端口被别的进程占住时 DSH 会报 `EADDRINUSE`（`PROTOCOL.md:174`） |
| 4 | 日志里 `require('copilot')` 失败 / 原生通道不可用 | `Test-Path "D:\SteamLibrary\steamapps\common\Avorion\bin\copilot.dll"` | `True`。`False` → 回 §3.2 编译并复制；注意**不要**用仓库里 `native/` 下的残留 DLL，游戏只认 `bin\` 那份（`docs/dev/build-and-native.md:42`） |
| 5 | 进星区约一分钟后游戏进程直接消失（`0xC0000374`） | 查服务端日志 `Avorion\galaxies\<存档>\serverlog*.txt`（客户端日志里看不到，`NATIVE.md:211`） | 若是这个码：编译基准不是 Lua **5.2.1**，用 5.2.1 重编（`docs/dev/build-and-native.md:26-31`） |
| 6 | 代码改了但行为没变（插件侧） | `Get-Item "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\@dsh-external\dsh-avorion-copilot" \| Select-Object LinkType,Target` | `Target` 指向**本仓库** `plugin/dsh`。指向旧的备份目录 = junction 陈旧，删了重建再重启 DSH（`docs/dev/install-and-deploy.md:42-47`） |

## 7. 目录结构（一句话版）

```
copilot/
├── modinfo.lua / data/       游戏读的部分：mod 元数据 + 全部 Lua 脚本（VFS 追加，不覆盖原版）
├── native/                   原生 TCP 模块源码（copilot.dll）+ 测试台脚本（不开游戏也能验）
├── build/                    ★ 唯一的编译产物目录（obj/lib/exp/dll/lua.exe，已在 .gitignore）
├── plugin/dsh/               DSH 插件本体（RPC 服务 + fleet_* 工具 + 客户端 UI），lib/ 已入库
├── docs/dev/                 工程侧：安装、构建、测试、热重载、git 规矩
├── docs/game/                游戏侧：机制 / 规则 / 教训 / 作业手册
└── AGENTS.md  PROTOCOL.md  NATIVE.md  VERIFY.md   入口索引、TCP 协议、ABI 实测、验证手册
```

## 8. 来源与许可

- 本项目是**第三方 mod**，与 Boxelware / Avorion 官方无关，不是官方产品或官方认可的扩展。
- 它通过 Avorion 的 VFS 机制追加脚本（`modinfo.lua` + `data/`），只**追加**不改原版文件；
  游戏本体文件不在本仓库内。
- 插件 `plugin/dsh/package.json:23` 声明 `license: MIT`；**仓库根目前没有 `LICENSE` 文件**，
  正式对外分发前建议补一个（内容由仓库所有者定）。
- 少数文件里带开发机的绝对路径（如 `data/scripts/lib/copilot/cli.lua:1846`、
  `native/dshlog.c:67`），它们只用于本机的日志 / 探针路径；换机器时按需修改即可。

## 9. 给 AI 的阅读顺序

1. 本文件（装起来、跑起来）。
2. [`AGENTS.md`](AGENTS.md) —— 工程侧索引（我要改哪一块 → 读哪个文件）。
3. [`docs/game/README.md`](docs/game/README.md) —— 游戏侧二级索引；要做舰队决策从它的 §2 开始。
4. [`docs/dev/testing-and-verification.md`](docs/dev/testing-and-verification.md) —— 验证手段；
   截图一律用游戏内 F12（`VERIFY.md` §2），GDI 抓屏会得到黑图。
