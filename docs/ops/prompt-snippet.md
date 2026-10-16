# 提示词片段（待粘贴的入口指引 + 该删的旧段落清单）

> 上一级：[`../README.md`](../README.md) · 入口文档：[`../../AGENTS.md`](../../AGENTS.md) 顶部 ·
> **本文件是文档，不是改动** —— 提示词本体住在 `plugin/prompt/system.md`（代码侧），由代码 agent 负责落地。

## 1. 设计（为什么要这样改）

**目标链路**：短提示词 → mod 根的 `AGENTS.md` 顶部一节 → `docs/` 树（逐级）→ 决策 → 下单。

| 层 | 内容 | 每轮都读？ |
|---|---|---|
| ① 提示词（`plugin/prompt/system.md`） | 身份 / **答案契约** / 硬规矩一句话 / **"不确定就去读 AGENTS.md"** / 路径 | ✅ 每轮 |
| ② mod 根 `AGENTS.md` 顶部一节 | 路由表 + 硬规矩细节 + 产出格式 | 需要时 |
| ③ `docs/mechanics/*`、`docs/rules/*`、`docs/ops/*` | 全部机制、规则、工具细节 | 按需（逐级） |
| ④ `MECHANICS.md`、`GAME-GOALS-AND-OPS.md`、`LLM-OPS.md` | 单一来源 / 资料库 / 调研 | 审计或深挖时 |

**★ 尺寸目标**：改完后**整份 `plugin/prompt/system.md` 控制在 ~2000 字符以内**（现在约 9.4 KB / ≈3100 汉字，
其中机制段 `{{MECHANICS}}` 展开后约 2.5 千字）。理由很实在：提示词**每轮决策都读一次**，
而机制/表格/卡片口径这些**只在需要时才用得上**，应当挪到 ②③ 后面。

**★ 改完后提示词里就**不再需要**出现这些**（都搬到文档树后面去了）：

| 现在提示词里的 | 搬到哪 |
|---|---|
| `{{MECHANICS}}` 整段机制（命令表、区域尺寸、safeMode 机制、扫框/两阶段、货舱口径、深度阶梯） | [`../mechanics/index.md`](../mechanics/index.md) 及其子文件 |
| 「判断依据」里教怎么读候选表的一大段（框可平移、`x`/`y` 是绝对值、`shape`/`sizeX`/`sizeY`、`riskKind` 口径、`perGood`、`hold{}`） | [`../mechanics/areas-and-boxes.md`](../mechanics/areas-and-boxes.md)、[`../mechanics/cargo-and-goods.md`](../mechanics/cargo-and-goods.md)、[`../ops/tools-cheatsheet.md`](../ops/tools-cheatsheet.md) |
| 「参考策略」整段（Scout 偏好等） | [`../rules/reference-strategy.md`](../rules/reference-strategy.md) |
| 「每次都值得先回答这个长期问题」整段 | [`../mechanics/depth-and-materials.md`](../mechanics/depth-and-materials.md) §5 |
| 输出格式里每个字段的长解释 | 保留一行字段名；解释进 [`../ops/tools-cheatsheet.md`](../ops/tools-cheatsheet.md) §3 |

★ 不搬走、也不能删的：**「大目标」段**（主人钦定的目标）与**答案必须在第一行**（实机事故：
想太久会把额度烧光、动作行根本吐不出来 —— `plugin/src/index.ts:1197` 的记录）。

## 2. 待粘贴的提示词块（可直接粘贴）

> ★ 下面围栏内的文字**本身就是粘贴内容**：它**不含任何反引号、也不含 `${`**，
> 因为 `plugin/src/prompt-default.ts` 的 `SYSTEM_PROMPT_DEFAULT` 是**模板字符串**
> —— 反引号会提前结束模板、`${` 会被当插值（mod 根的 `AGENTS.md` 记录过**两次**这类构建事故）。

```
你是 Avorion 舰队的运营大脑：一艘船空闲了，你替它决定下一步做什么。

★ 要产出什么（必须遵守）：
1. 第一行就是结论：action=（Mine / Salvage / Trade / Sell / Scout / Travel / None 之一），不要先写客套或长推理；
2. 第二行必须回显 task=（任务号）—— 舰队靠这一行认出"这是回给我的"；任务号写错，这一单会被判无效；
3. 之后按需要写字段：x= / y= / sizeX= / sizeY= / duration= / goodName= / deposit= / safeMode= / escorts= / goodsToSell= / reason=；
4. 如果你需要主人拍板，就直接把问题写出来、不写 action 行即可（本轮记为"等主人裁决"，不会替你编一个动作）。

★ 不确定该做什么时：先不要猜。去读 mod 的 AGENTS.md，按它顶部的指引逐级查阅文档与查询工具，然后再决策、再下单。

★ 那个文件的位置（稳的写法）：%APPDATA%\Avorion\mods\copilot\AGENTS.md
   —— 这是游戏 mod 目录的联接，与 mod 仓库根是同一份文件；不要写死某台机器的绝对路径。

★ 硬规矩（细节与理由见上面那份 AGENTS.md 的顶部）：
   风险闸门是 attackChance ≤ 0.10；判断"安全"只看基准概率 baseAttackChance（未经 safeMode 修正的那个数）；
   safeMode 一般不要开、基准概率 < 10% 时绝不要开；"安全"指的是局势的伏击概率，不是那个开关。
```

（本块约 **600 字** → 加上保留的「大目标」与极简输出格式，整份提示词可落在 **~2000 字符以内**。）

## 3. 给代码 agent 的落地清单（**逐条删**，我不动代码）

改动对象：`plugin/prompt/system.md`（及其生成物 `plugin/src/prompt-default.ts`）。当前该文件 96 行：

| # | 行范围（当前） | 动作 | 说明 |
|---|---|---|---|
| 1 | `1-7`（身份 + 大目标） | **保留** | 大目标是主人钦定；若精简，**必须保留「大目标」这三个字**（守卫 `check-mechanics.mjs:52`） |
| 2 | `9-11`（`★ 游戏机制（事实）：` + `{{MECHANICS}}`） | ★ **删段落，但保留 `{{MECHANICS}}` 这个占位符** | 守卫 `check-mechanics.mjs:49` **要求** `prompt/system.md` 里出现 `{{MECHANICS}}`；最省事的做法：把占位符接到 §2 那段指引上（即机制段从"整篇机制"变成"入口指引"），或同步改守卫 |
| 3 | `13-61`（`★ 判断依据（都是事实，不是指令）：` 整段） | **删** | 内容已进 `docs/mechanics/*` 与 `docs/ops/tools-cheatsheet.md`；留着就是第二份来源 |
| 4 | `63-74`（`★ 参考策略…` 整段） | **删**（或搬成一行指针） | 已进 `docs/rules/reference-strategy.md`；★ 若保留，**必须**保留"不具约束力/由你自己判断/供参考"任一句（守卫 `check-mechanics.mjs:104-127`）；删掉不算错（`checker` 只提示） |
| 5 | `76-80`（`★ 每次都值得先回答这个长期问题`） | **删** | 已进 `docs/mechanics/depth-and-materials.md` §5 |
| 6 | `82-96`（输出格式） | **压缩成字段名清单 + 第一行要求** | ★ **保留**"action 必须是第一行"（`src/index.ts:1197` 的截断事故）与全部字段名（`src/task.ts:227-252` 的解析器认这些名字） |
| 7 | 新增 | **插入 §2 的块** | 建议放在大目标之后、输出格式之前；也可直接替换 `{{MECHANICS}}` 的展开源 |

**改完必跑**（本仓库的既有纪律）：

```
node plugin/scripts/render-prompt.mjs     # 重新生成 src/prompt-default.ts（守卫②要求两者逐字一致）
node plugin/scripts/check-mechanics.mjs   # 5 道守卫
```

**可能的守卫冲突（必须一起处理，否则会红）**：

- 守卫② `check-mechanics.mjs:49`：`system.md` **必须含 `{{MECHANICS}}`** → 见上表第 2 行。
- 守卫⑤ `check-mechanics.mjs:153-164`：`src/` 里**必须有文件引用 `MECHANICS_BRIEF`** → 若你顺势让
  `src/mechanics.ts` 退休，这条守卫也要一起改；**否则机制段的单一来源就断了**。
- 守卫① `check-mechanics.mjs:27-42`：`MECHANICS.md` 的 BRIEF ↔ `src/mechanics.ts` 必须逐字一致 →
  **本次改动不必碰 `MECHANICS.md`**，所以这一条应保持绿。
- 守卫③ `:69-81` 与守卫④ `:83-150`：新块里**不要**出现"必须照抄 / 照它的 orderHint 下单"这类措辞，
  也不要塞"当 X 就做 Y"的策略句（§2 的块已自查过）。
- ★ 模板字符串里**不许出现反引号与 `${`**（`AGENTS.md` 记过两次构建事故）。

**同一份契约还有第二处**：会话路径的任务块格式在 `plugin/src/task.ts:150-162`
（它当前提示的字段较少：`x/y/size/duration/reason`），而解析器 `task.ts:227-252` 认全套字段。
落地时**两处别打架** —— 要么把任务块的提示行补齐，要么在 `AGENTS.md` 顶部写明"字段全集见工具速查"。

## 4. 落地后自检（人也能做）

1. 打开 `plugin/prompt/system.md`：**≤ ~2000 字符**，且**不含**机制表格/候选表读法/参考策略正文。
2. 提示词里能一眼看到 **`AGENTS.md` 这个文件名**与"不确定就先读它"的指令。
3. `%APPDATA%\Avorion\mods\copilot\AGENTS.md` 确实存在（目录联接），且顶部一节就是
   [`../../AGENTS.md`](../../AGENTS.md) 的那一节。
4. 在会话里问一句"我不知道该派哪艘船去哪" → 模型应当**先去读 `AGENTS.md` / 查工具**，
   而不是直接编一个动作。
