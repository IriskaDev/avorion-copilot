# INSTALL —— 把 fleet-decision 技能放进别的 agent

> 本文件随技能走：不管你把 `fleet-decision/` 拷到哪个 agent，这里都写着该放哪、怎么验。
> 技能本体 = 同目录的 [`SKILL.md`](SKILL.md)（YAML frontmatter + 正文，**不要改名**）。
>
> ★ 事实来源都标了出处；**没有官方出处的会写明「社区实践」**，别当官方承诺 ✗。

## 0. 技能目录长什么样

几乎所有支持 Agent Skills 的 agent 都认同一个形状：**`<某个 skills 根>/<技能名>/SKILL.md`** ✓

```
fleet-decision/
└── SKILL.md          # 必需：frontmatter 里 name: fleet-decision + description: ...
```

本仓库里它住在 `.dsh/skills/fleet-decision/`（DSH 的项目级技能根）。
**注意**：`SKILL.md` 正文里的 `docs/...` 路径是**相对仓库根**的 —— 见 §3 的「脱离仓库使用」。

## 1. 各家该放哪（一张表）

| Agent | 项目级（随仓库走） | 用户级（本机全局） | 出处 |
|---|---|---|---|
| **DSH**（DeepSeek Harness，本项目主用） | `<仓库根>/.dsh/skills/<名>/SKILL.md`（rank **100**，优先级最高）；备选 `<仓库根>/.agents/skills`（rank 200） | `~/.dsh/skills/<名>/`（rank **400**，任何 cwd 都扫）；备选 `~/.agents/skills`（rank 500） | 本仓库实测（[`docs/dev/skills-and-roots.md`](../../../docs/dev/skills-and-roots.md)） |
| **Claude Code** | `.claude/skills/<名>/SKILL.md` | `~/.claude/skills/<名>/SKILL.md` | [Claude Code 文档：Extend Claude with skills](https://code.claude.com/docs/en/skills) |
| **Codex CLI**（OpenAI） | 项目内随仓库放，靠 `AGENTS.md` 指到它（Codex 本人读 `AGENTS.md`） | `$CODEX_HOME\skills\<名>\SKILL.md`（默认 `~/.codex/skills/`） | 官方有 skills（`$skill-creator`，见 [Build skills](https://developers.openai.com/plugins/build/skills)）；**用户级路径为社区实践**（[codex-skills](https://github.com/ooshka/codex-skills)），新版请用 `codex --help` 复核 |
| **CodeBuddy**（腾讯，IDE/CLI） | `<工作区>/.codebuddy/skills/<名>/SKILL.md` | 设置页 → Skills → 导入（User Skills） | [CodeBuddy 文档：Skills](https://www.codebuddy.ai/docs/zh/ide/Features/Skills) |
| **Gemini CLI** | `.gemini/skills/<名>/SKILL.md`（或别名 `.agents/skills/`） | `~/.gemini/skills/<名>/`（或别名 `~/.agents/skills/`） | [Gemini CLI 文档：Agent Skills](https://geminicli.com/docs/cli/skills/) |
| **Cursor 等只支持「规则」的编辑器** | 没有 skills → 放 `.cursor/rules/*.mdc`（CodeBuddy 侧则是 `.codebuddy/rules/<名>/RULE.mdc`） | — | CodeBuddy 规则文档：[规则](https://www.codebuddy.ai/docs/zh/ide/User-guide/Rules) |

> `.agents/skills` 是多个工具的**互操作别名**（Gemini 文档明说；DSH 也扫它）——想「一份文件到处能用」，
> 优先放进 `.agents/skills/` 或 `~/.agents/skills/` ✓。

## 2. 复制命令（PowerShell；本仓库 → 目标）

```powershell
$src = "D:\SteamLibrary\steamapps\common\Avorion\mods\copilot\.dsh\skills\fleet-decision"

# ① DSH 用户级（任何 cwd 都能用）
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.dsh\skills" | Out-Null
Copy-Item $src "$env:USERPROFILE\.dsh\skills\fleet-decision" -Recurse -Force

# ② Claude Code 用户级
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude\skills" | Out-Null
Copy-Item $src "$env:USERPROFILE\.claude\skills\fleet-decision" -Recurse -Force

# ③ Codex CLI 用户级（CODEX_HOME 可覆盖，默认 ~/.codex）
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.codex\skills" | Out-Null
Copy-Item $src "$env:USERPROFILE\.codex\skills\fleet-decision" -Recurse -Force

# ④ CodeBuddy / Gemini：放进**工作区**（= 你要下决策的那个仓库根）
Copy-Item $src ".\.codebuddy\skills\fleet-decision" -Recurse -Force   # CodeBuddy
Copy-Item $src ".\.gemini\skills\fleet-decision"   -Recurse -Force   # Gemini CLI
```

**验证**（文件层，永远有效）：

```powershell
foreach ($p in @("$env:USERPROFILE\.dsh\skills\fleet-decision\SKILL.md",
                 "$env:USERPROFILE\.claude\skills\fleet-decision\SKILL.md",
                 "$env:USERPROFILE\.codex\skills\fleet-decision\SKILL.md",
                 ".\.codebuddy\skills\fleet-decision\SKILL.md")) { "{0}  {1}" -f (Test-Path $p), $p }
```

期望：装了哪个就 `True` 哪个；目标里 `SKILL.md` 的 frontmatter 必须还是 `name: fleet-decision` ✓。

**生效方式**（互不相同，别记混）：

- **DSH**：文件监听，**不用重启** ✓（新会话自然列出）。
- **Claude Code / Codex / Gemini**：一般需要**新开会话**（技能列表在会话开始时注入）；Gemini 首次激活还会弹一次**授权确认**（[文档](https://geminicli.com/docs/cli/skills/) §How it works）。
- **CodeBuddy**：规则/技能在**会话开始**加载 —— 改完要**新建对话**才生效（[规则文档](https://www.codebuddy.ai/docs/zh/ide/User-guide/Rules) 明确写了）。

## 3. ★ 脱离本仓库使用会缺东西（重要）

`SKILL.md` 正文里的所有 `docs/...` 路径都是**相对仓库根**（本仓库的 `docs/game/*`）。
所以：

- **在别的 agent 里、但 cwd 仍是本仓库** → 全部链接有效 ✓（这是设计用法：技能卡负责「怎么决策」，细节回仓库查）。
- **把技能搬到完全不相干的仓库** → 那些 `docs/...` 会 404。此时二选一：
  1. 把 `docs/game/`（至少 `README.md` + `mechanics/` + `lessons/` + `ops/`）一起带过去；或
  2. 只当「决策规矩与答复契约」用，别指望它自己会去读细节文档（技能卡里已声明：**拿不准要查，不许猜** ✓）。

## 4. 改完怎么保证两份一致

本仓库里 `SKILL.md` 有两份：`.dsh/skills/fleet-decision/SKILL.md`（**运行时权威**）与
[`docs/game/ops/fleet-decision-skill.md`](../../../docs/game/ops/fleet-decision-skill.md)（文档副本）。改完跑：

```powershell
node tools/check-skill-copies.mjs          # 期望 ALL SKILL COPIES IN SYNC ✓
node tools/check-skill-copies.mjs --sync   # 漂了就以 .dsh 那份为准刷副本
```
