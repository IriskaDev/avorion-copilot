# dsh-avorion-copilot

Avorion `copilot` mod 与 DSH 之间的桥接插件。

游戏侧的 Lua **没有网络能力，也不能启动进程**（沙箱里 `os.execute`、`io.popen`、`io.http`
全被移除），所以两边只能靠文件通信。本插件在 DSH 宿主平面运行，每隔几秒扫一次桥接目录，
对每个请求问一次模型，把决策写回响应文件。

```
%APPDATA%/Avorion/moddata/copilot/
    req_<船名>.txt    游戏写 → 插件读      请求：舰队快照 + 候选方案
    res_<船名>.txt    插件写 → 游戏读      响应：选择 + 参数
    log_<船名>.txt    插件写              决策记录（含模型思维链）
```

写文件一律先写 `.tmp` 再 `rename`，保证对面不会读到半截内容。

## 配置

```yaml
- name: '@dsh-external/dsh-avorion-copilot'
  config:
    dir: ''                 # 留空 = %APPDATA%/Avorion/moddata/copilot
    intervalMs: 4000        # 轮询间隔
    provider: deepseek-official
    model: deepseek-flash
    maxTokens: 700
    temperature: 0.2
```

## 请求格式

`key=value` 行文本（游戏侧是 Lua，没有 JSON 库，行文本最不容易出错）：

```
version=1
ship=Miner-00002
tick=17
state=idle
pos=42,-8
caps=mining:2,salvaging:0,cargo:1500,free:1200,dps:130,hp:4000,jump:12
captain=Miner/3/1
cargo=Iron:200
money=1234560
opt1=Mine|area:30,-12,44,2|attack:0.08|duration:1|yield:Iron:1200-1500
opt2=Mine|area:12,5,26,19|attack:0.31|duration:1|yield:Titanium:400-600
opt3=Salvage|area:...|attack:0.05|duration:1|items:3-5
```

## 响应格式

```
version=1
ship=Miner-00002
time=2026-10-06T18:40:00.000Z
choice=2
duration=1
escorts=Miner-00001
reason=低风险钛矿，收益接近且伏击概率可接受
```

失败时写 `error=<原因>`（例如模型调用失败、回复里没有可用的 `choice=`）。
**无论成功失败都会写响应文件**，避免游戏反复重试同一个请求。

## 行为要点

- 已经有 `res_<船名>.txt` 的请求会被跳过 —— 那表示游戏还没取走上一次的决策
- 模型回复只认 `choice` / `duration` / `escorts` / `reason` 四行，其余文字忽略
- 模型思维链（`reasoning-delta` 分片）与原始回复一起记进 `log_<船名>.txt`
- 回复被 `maxTokens` 截断时会在日志里标警告
- 定时器注册在 `ctx.effect` 上，插件卸载/热重载时自动清理

## 构建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1
```

本机没有 DSH 源码 checkout（没有 `packages/` 与 `vendor/`），所以脚本：

- 类型取自**全局安装的 npm 包** `@deepseek-ai/dsh-llm`（它自带 `.d.ts`）
- `tsc` 借用另一个插件工程 `node_modules.bak` 里的那份（5.9.3）

### ⚠️ 产物绝不能带 `node_modules`

DSH 宿主**自己解析** `@deepseek-ai/*` 与 `schemastery` —— 已装且能工作的
`dsh-global-memory` 与 `dsh-cosplay` 都没有自己的 `node_modules`。

插件自带 `node_modules` 反而会**遮蔽**宿主那份，而 npm 版 `dsh-llm` 的传递依赖
`@deepseek-ai/cordis` 是个**空目录**，会直接加载失败：

```
我们 → dsh-llm → dsh-typert-protocol → @deepseek-ai/cordis   ← 空目录
```

所以 `scripts/build.ps1` 的流程是 **建链接 → 编译 → 删链接**，跑完插件目录是干净的。
`.ps1` 里的中文注释要求文件带 UTF-8 BOM，否则 Windows PowerShell 5.1 会按 ANSI 解码而语法崩坏。

> `cordis` 与 `schemastery` 的类型只存在于源码 checkout 的 `vendor/`，装好的 npm 包里是空目录，
> 所以源码里不 import 它们：`ctx` 用最小结构化接口描述，`Config` 不导出
> （已装的 `dsh-mode-boost` 同样不导出，是合法形态）。

## 离线自测

```powershell
node test/harness.mjs      # 8/8
```

用假 ctx 跑完整链路（扫目录 → 读请求 → 组 prompt → 收分片 → 解析 → 原子写回 → 写日志），
并覆盖三条错误路径。`@deepseek-ai/dsh-llm` 在测试里由 `test/llm-stub.mjs` 顶替
（原因同上：npm 版脱离 DSH 加载不了）。

## 装配

装进 profile（以 desktop 为例）：

```jsonc
// ~/.dsh/profiles/desktop/package.json
"dependencies": {
  "@dsh-external/dsh-avorion-copilot": "link:D:/workbench/projects/dsh/dsh-avorion-copilot"
},
"dsh": { "profile": { "bundles": [ ..., "@dsh-external/dsh-avorion-copilot" ] } }
```

再把该包 junction 进 profile 的 `node_modules/@dsh-external/`，然后**重启 DSH**。

**脱离游戏验证**：往 `%APPDATA%/Avorion/moddata/copilot/` 放一个 `req_test.txt`，
几秒后应出现 `res_test.txt` 与 `log_test.txt`。
