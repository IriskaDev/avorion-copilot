# DSH 技能（skills）：扫描根 / rank / 生效方式

> 上一级：仓库根 [`AGENTS.md`](../../AGENTS.md)（工程入口索引）。
> 本页讲「DSH 从哪儿读技能、改了什么时候生效」；技能**内容**在 `.dsh/skills/`，
> 它的文档副本见 [`../game/ops/fleet-decision-skill.md`](../game/ops/fleet-decision-skill.md)（逐字一致，有守卫）。

## 1. 扫描根与优先级

DSH 的 `@deepseek-ai/dsh-skill-filesystem` 按 rank 扫描（**rank 越小优先级越高**）：

| 根 | rank | 说明 |
|---|---|---|
| `<项目根>/.dsh/skills` | **100** | ★ 本项目用这个（`<项目根>` = 仓库根，含 `.git`） |
| `<项目根>/.agents/skills` | 200 | 备选的项目级根 |
| `~/.dsh/skills` | 400 | 用户级，**任何 cwd** 都扫描 |
| `~/.agents/skills` | 500 | 备选用户级 |
| 打包技能根 | 600 | 随 DSH 分发 |

发现规则：目录下的 `*/SKILL.md`（或直接放的 `*.md`）；格式 = YAML frontmatter（必填 `name`（kebab-case）
与 `description`）+ Markdown 正文。

## 2. 本仓库的技能

| 技能 | 文件 | 用途 |
|---|---|---|
| `fleet-decision` | [`.dsh/skills/fleet-decision/SKILL.md`](../../.dsh/skills/fleet-decision/SKILL.md) | Avorion 舰队决策者：决策目标 / 硬规矩 / 机制骨头 / 原子接口作业规程 / 答复契约 |

★ **`.dsh/` 那份是运行时唯一被加载的** ✗ 别把它删了（`docs/game/ops/fleet-decision-skill.md`
只是给人和 review 看的副本 ✓）。**安装指引**随技能包走：
[`.dsh/skills/fleet-decision/INSTALL.md`](../../.dsh/skills/fleet-decision/INSTALL.md) ✓

## 2.5 放到别的 agent（摘要，细节以 INSTALL.md 为准）

| Agent | 项目级 | 用户级 |
|---|---|---|
| DSH | `<仓库根>/.dsh/skills/`（rank 100） | `~/.dsh/skills/`（rank 400） |
| Claude Code | `.claude/skills/` | `~/.claude/skills/` |
| Codex CLI | 随仓库 + `AGENTS.md` 指路 | `$CODEX_HOME\skills\`（默认 `~/.codex/skills/`；★ 社区实践，用 `codex --help` 复核） |
| CodeBuddy | `<工作区>/.codebuddy/skills/` | 设置页 → Skills → 导入 |
| Gemini CLI | `.gemini/skills/`（别名 `.agents/skills/`） | `~/.gemini/skills/`（别名 `~/.agents/skills/`） |

- 形状统一：`<skills 根>/<技能名>/SKILL.md`（frontmatter 必填 `name` + `description`）。
- **`.agents/skills/` 是多工具互操作别名**（Gemini 文档明说，DSH 也扫）→ 想一份文件到处用，优先用它 ✓。
- 出处：[Claude](https://code.claude.com/docs/en/skills) ·
  [Codex（skills 官方页）](https://developers.openai.com/plugins/build/skills) ·
  [CodeBuddy](https://www.codebuddy.ai/docs/zh/ide/Features/Skills) ·
  [Gemini](https://geminicli.com/docs/cli/skills/) ·
  Codex 用户级路径：[codex-skills](https://github.com/ooshka/codex-skills)（社区）✓。
- ⚠️ `SKILL.md` 里的 `docs/...` 是**相对仓库根**：搬去无关仓库就会断链 —— 处理办法见
  [`INSTALL.md`](../../.dsh/skills/fleet-decision/INSTALL.md) §3 ✓。

## 3. 生效方式（不用重启 DSH）

- 技能是**按需发现 + 文件监听**：新增/改 `SKILL.md` 后，chokidar 监听器（`followSymlinks: true`）
  或模型自己用的 `write`/`edit` 会触发目录失效并重扫 → **新会话自然列出**，运行中的会话下次收集时刷新 ✓。
- 为让「任意 cwd 的会话」也能用，本机另建了目录联接（**单一来源**仍在仓库里）：

  ```
  C:\Users\IriskaDev\.dsh\skills\fleet-decision
      -> D:\SteamLibrary\steamapps\common\Avorion\mods\copilot\.dsh\skills\fleet-decision   (Junction)
  ```

  于是它同时出现在**用户技能根** `~/.dsh/skills`（rank 400）✓。
  （同一手法先例：`%AppData%\Avorion\mods\copilot` 的 junction，见 [`install-and-deploy.md`](install-and-deploy.md) ✓）

## 4. ★ 副本不能漂移

`docs/game/ops/fleet-decision-skill.md` 是 `.dsh` 那份的**逐字副本**（夹在
`<!-- BEGIN SKILL-COPY -->` / `<!-- END SKILL-COPY -->` 之间）。
守卫命令（仓库根执行）：

```powershell
node tools/check-skill-copies.mjs          # 期望 ALL SKILL COPIES IN SYNC ✓；漂了就 exit 1 并指出差异行
node tools/check-skill-copies.mjs --sync   # 以 .dsh 那份为准，把文档副本刷过来
```

**为什么用副本而不是符号链接**：Windows 上建文件符号链接要开发者模式/管理员，而 git 对符号链接的
支持取决于 `core.symlinks`；**副本 + 守卫**在任何机器上都能工作 ✓✓。
