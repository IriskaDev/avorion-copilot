# .dsh/skills/ —— DSH 项目级技能根（官方扫描位置）

本目录是 DeepSeek Harness 的**项目级技能根** `<项目根>/.dsh/skills`（rank 100，优先级最高的本地技能根）。
DSH 的 `@deepseek-ai/dsh-skill-filesystem` 会扫描它，发现目录下的 `*/SKILL.md`（或直接放的 `*.md`）。
格式：YAML frontmatter（必填 `name`（kebab-case）与 `description`）+ Markdown 正文。

## 现有技能

| 技能 | 文件 | 用途 |
|---|---|---|
| `fleet-decision` | [`fleet-decision/SKILL.md`](fleet-decision/SKILL.md) | Avorion 舰队决策者：目标 / 硬规矩 / 机制骨头 / 原子接口作业规程 / 答复契约 |

## 生效方式（无需重启 DSH）

- 本目录只要在**仓库根**（= 决策者会话的 cwd，含 `.git`），DSH 就会把它当作 project-dsh 根扫描（rank 100）。
- 技能是**按需发现 + 文件监听**的：新增/改动 `SKILL.md` 后，chokidar 监听器（`followSymlinks: true`）或
  模型自用的 `write`/`edit` 会触发目录失效并重扫 —— **不用重启 DSH**；新会话自然列出，运行中的会话在下次收集时刷新。
- 为让「任意 cwd 的会话」（不一定是本仓库）也能用，本机另建了一个目录联接，指向同一份文件（单一来源）：

  ```
  C:\Users\IriskaDev\.dsh\skills\fleet-decision
      -> D:\SteamLibrary\steamapps\common\Avorion\mods\copilot\.dsh\skills\fleet-decision   (Junction)
  ```

  这样它同时出现在**用户技能根** `~/.dsh/skills`（rank 400，任何 cwd 都扫描）。（先例见
  [`docs/dev/install-and-deploy.md`](../docs/dev/install-and-deploy.md) 里 `%AppData%\Avorion\mods\copilot` 的 junction。）

## 其余官方扫描根（备查）

`<项目根>/.agents/skills`（rank 200）、`~/.dsh/skills`（rank 400）、`~/.agents/skills`（rank 500）、
打包技能根（rank 600）。rank 越小优先级越高。
