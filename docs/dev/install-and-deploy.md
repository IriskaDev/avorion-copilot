# 安装 / 部署与坑

> 上一级：仓库根 [`AGENTS.md`](../../AGENTS.md)（工程入口索引）。

## ⚠️ 安装位置（踩过的坑）

**本仓库路径不是游戏读取 mod 的路径。** 游戏只扫描 **`%AppData%\Avorion\mods\`**
（`modconfig.lua` 和 `workshop/` 都在那儿，是游戏自己建的）；游戏目录下的 `mods\` 游戏根本不看，
那是早期会话误建的。

已建立目录联接让两边指向同一份文件，改源码即生效：

```
C:\Users\IriskaDev\AppData\Roaming\Avorion\mods\copilot
    -> D:\SteamLibrary\steamapps\common\Avorion\mods\copilot   (Junction)
```

- mod 列表**只在游戏启动时扫描一次**，新增/启用 mod 后必须重启游戏。
- 游戏内「模组 & 创意工坊」默认停在**创意工坊页签**（列的是 Steam 订阅项，带 workshop ID）；
  本地 mod 在**另一个页签**（左上角列表图标）。
- 启用状态存在 `%AppData%\Avorion\mods\modconfig.lua` 的 `enabled = {}` 里。

## ★ 布局：DSH 插件住在 `plugin/dsh/`（2026-10-17 二次搬家，主人要求）

```
mods/copilot/
├── modinfo.lua / data/ / native/    ← 游戏读的部分 ✓（native/ 只放源码，产物在 build/）
├── AGENTS.md / README.md            ← 根目录**只留这两个** ✓（2026-10-19 收敛）
├── docs/dev/ · docs/game/           ← 工程侧 / 游戏侧文档（见 overview.md §根文档收敛记录）
└── plugin/                          ← ★ 插件：文档在根、本体在 dsh/（原本在 D:\workbench\projects\dsh\）
      ├── dsh/                       ← ★ 插件本体（代码与资产）
      │     src/ lib/ prompt/ test/ scripts/ tools/ types/ package.json tsconfig.json pnpm-lock.yaml
      └── AGENT-DESIGN.md / README.md / MEMORY.md / TAKEOVER.md  ← 关于插件的文档 ✓
```
**规矩**：
* DSH 的装配是 `C:\Users\<你>\.dsh\profiles\desktop\package.json` 里的
  `"@dsh-external/dsh-avorion-copilot": "link:.../mods/copilot/plugin/dsh"` ✓ —— **改路径要重启 DSH** ✓
* 游戏**不读** `plugin/`（含 `dsh/`）✓（只读 `modinfo.lua` + `data/` ✓）→ 放这儿对游戏是惰性的 ✓
* 插件的提交历史已**并入本仓库** ✓（不再有自己的 .git ✓）；
  旧目录 `D:\workbench\projects\dsh\dsh-avorion-copilot` **留作备份** ✓，确认新家能加载后再删 ✓
* `plugin/dsh/lib/` 是**编译产物但必须入库** ✓（DSH 直接读它 ✓）；`node_modules/` 是构建期临时物 ✓ 已忽略 ✓

## ⚠️ 部署坑（实测）：junction 指向旧备份

profile 的 `package.json` 写的是新家 `.../mods/copilot/plugin/dsh` ✓，
但 `node_modules` 里那个 junction **仍指向旧备份** `D:\workbench\projects\dsh\dsh-avorion-copilot`
✗✓ —— 于是**新代码根本没被加载**（运行日志里能看到旧行为 ✓）。
修法：把该 junction 删掉重建到新家，然后**重启 DSH** ✓（改装配必重启 ✓）。

## ★ 提示词住在插件里（2026-10-17 ✓）

决策提示词**不在**本仓库的机制文档里 ✗，它住在插件 `plugin/dsh/prompt/system.md` ✓
（运行时读取 ✓，用户可用 `%AppData%\Avorion\moddata\copilot\prompt\system.md` 覆盖 ✓，
改完**不用重启 DSH** ✓）。机制段仍以本仓库的 [`../game/mechanics-source.md`](../game/mechanics-source.md) 为**单一来源** ✓
（插件脚本由它生成 ✓，`check-mechanics.mjs` 防漂移 ✓，并会拦住"照抄指令"与"策略措辞" ✗✓）。

## ★★ DSH 客户端插件（UI）的真相（2026-10-17 实测，别再猜 ✗✓）

主人用的是 **DSH 桌面版**（`DeepSeek Harness.exe`，DSH **0.2.0-rc.2** ✓）——
**它不是"把客户端资源烤进 App"的壳** ✗✓，别拿这个当借口 ✗：

| 事实 | 证据 |
|---|---|
| 桌面版跑的是**真 web 服务器**（`127.0.0.1:19387` ✓），宿主半由 `@deepseek-ai/dsh-desktop-host` 起 ✓ | 进程命令行 `--port 19387`；`dsh-client-connection` 的 401 文案 |
| 外部 `link:` 插件的 `lib/client.js` **启动时直接从磁盘读** ✓，不用重建、不用 `pnpm run dev:web` ✗✓ | 运行中的页面里 `window.__DSH_BOOT__` 真有我们那行，且 `/plugins/??<pkg>/client.js&rev=…` 返回 200 + 本文件字节 ✓✓ |
| `rev` 由**文件 mtime/ctime/size** 推 ✓，每次启动都重新组图 ✓ | 官方文档 `reference/subsystems/client-modules` ✓ |
| 桌面版 Electron 窗口**没有绑刷新快捷键** ✗ → 改完客户端要**完全退出 App 再开** ✓ | 主人实测 Ctrl+F5 无反应 ✓ |

**读安装版 DSH 本体的办法**（本机没有 DSH 源码 checkout ✗，只有 `app.asar` ✓）：
`plugin/dsh/tools/asar_read.py`（纯 stdlib ✓）：
`python asar_read.py list|cat|grep "<...>\resources\app.asar" …` ✓ ——
官方文档在 `https://deepseek-harness.github.io/deepseek-harness/`（**开源 ✓，先查它再猜** ✓✓）。

### ★ 两条给未来的硬规矩

1. **可选服务一律 `ctx.inject(['服务名'], cb)` 等它** ✓，**不要**当场 `ctx.get()` 就下判断 ✗。
   `apply()` 跑的时刻，兄弟 bundle 提供的服务（如 `webServer`）**可能还没就绪** ✗✓ ——
   当场判断 + 静默兜底 = **功能悄悄少一半**（本次的"开关看不见"就是这么来的 ✗）。
   反例/正例都在官方 `dsh-client-modules/lib/index.js` 里 ✓。
   ★ 也**不要**把可选服务写进 `export const inject` ✗ —— 那样没有它的 profile（headless）
   里**整个插件都不会启动** ✗✓。
2. **UI 从不许"静默什么都不画"** ✗：客户端组件在拿不到宿主状态时返回 `null` ✓，
   而宿主那条 HTTP 路由 404 时**界面和"功能不存在"长得一模一样** ✗✓。
   至少 `console.error` 一次 ✓（本次已补 ✓），别让下次排查又要去翻 asar ✓。

## ⚠️ SYSTEM_PROMPT 里禁止用反引号（2026-10-16，踩了两次 ✗）

`src/index.ts` 的 `SYSTEM_PROMPT` 是一个**模板字符串**（反引号界定 ✓）。
在里面写 `action=None` 这类**行内代码**时若用反引号 ✗，会**提前结束模板** →
TypeScript 报 `TS1005: ',' expected` ✓。

**规矩**：在 SYSTEM_PROMPT / buildPrompt 的模板串里，**一律不要用反引号** ✓。
（同理：`${` 也要避免出现在正文里 ✓。）
