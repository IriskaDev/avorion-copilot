# .dsh/skills/ —— DSH 项目级技能根（运行时扫描位置）

> ★ **这里的 `*/SKILL.md` 是 DSH 真正加载的那份**（项目级技能根，rank 100）——
> 扫描根/rank/生效方式/副本守卫的完整说明在
> [`docs/dev/skills-and-roots.md`](../../docs/dev/skills-and-roots.md) ✓（本文件不再重复内容 ✓）。

## 现有技能

| 技能 | 文件 | 文档副本 | 安装指引 |
|---|---|---|---|
| `fleet-decision` | [`fleet-decision/SKILL.md`](fleet-decision/SKILL.md) | [`docs/game/ops/fleet-decision-skill.md`](../../docs/game/ops/fleet-decision-skill.md) | [`fleet-decision/INSTALL.md`](fleet-decision/INSTALL.md)（DSH / Claude Code / Codex / CodeBuddy / Gemini 各放哪） |

## 改完必须做

```powershell
node tools/check-skill-copies.mjs --sync   # 把文档副本刷成一致（以本目录为准）
node tools/check-skill-copies.mjs          # 期望 ALL SKILL COPIES IN SYNC ✓
```
