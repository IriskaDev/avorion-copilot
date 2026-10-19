# AGENTS.md —— Copilot mod 工程入口（索引）

> 本文件**只做索引**：工程细节都在 `docs/dev/*`。
> ★ 游戏侧内容不在这里，全部收在二级索引 [`docs/game/README.md`](docs/game/README.md)。

## 这是什么 / 仓库布局

Avorion 的「AI 副驾驶」mod：实体级自动驾驶（已完成）+ 战略级运营大脑（规划中）。
游戏目录 `D:\SteamLibrary\steamapps\common\Avorion`（2.5.13），原版脚本在 `data/scripts/`（全部可读）。
本仓库 = mod 根（`data/` + `native/` + `plugin/` + 文档）。完整布局见 [`docs/dev/overview.md`](docs/dev/overview.md)。

## 索引：主题 → 读哪个文件

| 主题 | 读 |
|---|---|
| 工程总览 / 仓库布局 / 开发工作流 | [`docs/dev/overview.md`](docs/dev/overview.md) |
| ★ 接口原子化（接口怎么拆：一次一件小事 / 不做策略推荐 / 发命令原子化） | [`docs/dev/interface-atomicity.md`](docs/dev/interface-atomicity.md) |
| ★ 接口（原语）清单 → 有哪些原子接口、各吃什么参数 | [`docs/game/ops/fleet-ops-manual.md`](docs/game/ops/fleet-ops-manual.md)（§2 原子字典）+ [`docs/dev/interface-atomicity.md`](docs/dev/interface-atomicity.md) |
| Lua / VFS / 引擎约定（挂载层级、UI 图标栏、两条硬规矩） | [`docs/dev/lua-vfs-and-engine.md`](docs/dev/lua-vfs-and-engine.md) |
| 热重载与 VM 边界 | [`docs/dev/hot-reload-and-vm-boundaries.md`](docs/dev/hot-reload-and-vm-boundaries.md) |
| 构建与编译 / 原生 DLL / ABI | [`docs/dev/build-and-native.md`](docs/dev/build-and-native.md) |
| 测试与验证 / 日志与排错 | [`docs/dev/testing-and-verification.md`](docs/dev/testing-and-verification.md) |
| 安装 / 部署与坑 | [`docs/dev/install-and-deploy.md`](docs/dev/install-and-deploy.md) |
| git 与仓库规矩 | [`docs/dev/git-and-repo.md`](docs/dev/git-and-repo.md) |
| 当前状态 / 待办 | [`docs/dev/current-status.md`](docs/dev/current-status.md) |
| 原生 DLL / ABI 实测结论（动 DLL 前必读） | [`docs/dev/native.md`](docs/dev/native.md) |
| ★ 游戏侧全部内容（决策/机制/规则/教训/作业手册） | [`docs/game/README.md`](docs/game/README.md) |
| 游戏 ⇄ DSH 的 TCP 协议 | [`docs/dev/protocol.md`](docs/dev/protocol.md) |
| 自行验证手册（开游戏/截图/点击/按键/看日志） | [`docs/dev/verify-manual.md`](docs/dev/verify-manual.md) |
| ★ 截图 / 抓屏：**必须用游戏内 F12（Steam）**；GDI / PrintWindow 会抓黑 ✗ —— 换 F12 别重试，目录见 §2.1 | [`docs/dev/verify-manual.md`](docs/dev/verify-manual.md) §2 |
| 面向用户的说明 | [`README.md`](README.md) |
| 根文档收敛记录（哪份根文档搬到哪、删了什么） | [`docs/dev/overview.md`](docs/dev/overview.md) §根文档收敛记录 |

> ★ **仓库根只放 `AGENTS.md` + `README.md`**（2026-10-19 收敛 ✓）—— 其它文档一律进
> `docs/dev/`（工程侧）或 `docs/game/`（游戏侧）。新增文档前先定归属，别再往根目录堆 ✗。
