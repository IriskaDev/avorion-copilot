/**
 * task.ts —— 投递进投递目标会话的**任务块**，与它的**答案契约**（Phase A ✓）
 *
 * 这是「插件 ⇄ 会话」之间唯一的接口 ✗✓ —— 协议在这里、校验也在这里 ✓，
 * 这样"任务长什么样"和"什么算合格答案"永远不会各改各的 ✓（原型
 * `test/commander-dispatch-proto.mjs` 的 shape 原样搬过来 ✓）。
 *
 * ## 为什么答案里必须回显 `task=<id>`（**这条不能省**）
 *
 * 投递目标会话是**一条活着的、主人也在用的普通会话** ✓✓。所以同一轮里可能出现：
 *   · 主人在聊天，她的回复与任务交错 ✓
 *   · 主人一次性投了几艘船 → 会话里连着几条任务 ✓
 * 于是"最后一条 assistant/message 就是结论"**不总成立** ✗。
 * 契约要求她回显 `task=<id>` ✓；对不上就判 `TASK_MISMATCH` 并走阶梯 ✓ ——
 * **绝不把别的船的答案用在这艘船上** ✗✓。
 *
 * （★ 诚实说明：她**不回显**时我们**不判失败** ✗ —— 只降级成"无回显"✓。
 *  理由是主人要的是"能聊天、能现修"的会话，不是必须背格式的机器人 ✓；
 *  而**回显了但写错**才是真危险（说明她在答别的船 ✓）→ 那才判 MISMATCH ✓。）
 */
/** 表示"没有"的几种写法，别当成值 ✓（与 index.ts 的 NONE_WORDS 同源 ✓） */
const NONE_WORDS = new Set(['', '-', 'none', 'null', 'n/a', 'na', '无', '没有', '否']);
/**
 * 逐行取 `key=value`（与 `index.ts` 的 `field()` 同一套容错 ✓）：
 * 容忍 `key: value`、`**key=value**`、全角冒号、行首 `- `/`* `、行尾星号 ✓。
 * ★ 与 index.ts 那份**故意保持同形** ✓ —— 两边读同一份"她的回答"必须得出一致的结论 ✓。
 */
export function field(text, key) {
    const match = new RegExp(`^\\s*[*-]?\\s*\\**\\s*${key}\\s*[:=：]\\s*(.*)$`, 'im').exec(text);
    if (match === null)
        return undefined;
    return match[1].replace(/\*+$/, '').replace(/[`*"']/g, '').trim();
}
/** 数字字段（容忍 `-406` / `x = -406` / `(-406,73)` 取第一段 ✓） */
function numField(text, key) {
    const raw = field(text, key);
    if (raw === undefined)
        return undefined;
    const m = /-?\d+(?:\.\d+)?/.exec(raw);
    if (m === null)
        return undefined;
    const v = Number(m[0]);
    return Number.isFinite(v) ? v : undefined;
}
/** 布尔字段（容忍 true/false、yes/no、1/0、是/否 ✓ —— 与 index.ts 同款 ✓） */
function boolField(text, key) {
    const raw = field(text, key);
    if (raw === undefined)
        return undefined;
    const w = raw.trim().toLowerCase();
    if (['true', 'yes', 'y', '1', '是', '开', 'on'].includes(w))
        return true;
    if (['false', 'no', 'n', '0', '否', '关', 'off'].includes(w))
        return false;
    return undefined;
}
/** ★ 「你上一单的结果」一行的字节预算（~200 ✓；超了就当没加 ✗✓） */
export const PREV_RESULT_BUDGET_BYTES = 200;
/** 船名清单字段（`Miner-1, Miner-2`；"无" 之类的词丢掉 ✓ —— 与 index.ts 同款 ✓） */
function listField(text, key) {
    const raw = field(text, key);
    if (raw === undefined)
        return [];
    return raw.split(/[,，、]/).map((s) => s.trim())
        .filter((s) => s !== '' && !NONE_WORDS.has(s.toLowerCase()));
}
/**
 * ★★★ 渲染任务块 —— **只告知，不灌数据** ✓✓（2026-10-17 主人批准的改动）
 *
 * 这个函数是"agent 路径"的**唯一**渲染点 ✓。它的输出目标是 **远小于 2 KB** ✓，
 * 且**与计划有多大无关** ✗✓ —— 因为计划一个字节都不进来 ✓。
 *
 * ## 它为什么长这样（每条都有实测理由 ✓）
 *
 * | 要素 | 为什么不能省 |
 * |---|---|
 * | `<fleet_task …>` / 结尾标记 | 投递目标是主人**正在聊天的那条会话** ✓ —— 她必须一眼看出"这是舰队的活儿，不是主人在说话" ✗✓ |
 * | 船名 | 不写船名，她连该查哪艘都不知道 ✓ |
 * | `task=<id>` 回显 | **唯一**能认出"哪条回复是这一单"的锚点 ✓（见文件头 ✓）；对不上就判 MISMATCH 并走阶梯 ✓ |
 * | 一行"它空闲了、要一个决策" | 这就是**全部**的请求内容 ✓（主人原话 ✓） |
 * | 工具指针 | 让"自拉"变得**不用猜** ✓ —— 哪个 `what` 查什么、哪个参数要小答案 ✓（这是这次改动的**关键**：光说"你自己查"而不给路由，等于把体积问题换成瞎猜问题 ✗✓） |
 * | 期限提示 | 会话层有硬闸 ✓（超了 `cancel({kind:'hook'})` 并落单发 ✓）—— 写进任务头告知硬期限 ✓ |
 * | 答案行契约（**放最后**，且要"放最前"） | 实机事故：正文被 maxTokens 截断、一个动作行都没吐 ✓ → 契约必须显眼 ✓ |
 *
 * ★ 为什么结论行要求**放最前** ✗✓：`plugin/dsh/prompt/system.md` 与 `src/index.ts` 的重试路径
 *   都记录了同一个事故 ✓ —— 把契约写清楚，最坏情况丢的是散文，不是结论 ✓。
 *
 * ★ 为什么**没有**"参考计划"段 ✗✓：那一段以前是 `planText`（`buildPrompt()` 的全文 ✓）——
 *   也就是 8.7 MB 的入口 ✓。现在她要计划就**自己查** ✓（`fleet_query`，缺省 compact ✓）。
 */
export function renderTaskBlock(req) {
    const L = [];
    L.push(`<fleet_task id="${req.taskId}" ship="${req.ship}" deadline_hint="${req.deadlineHintSec}s">`);
    L.push('★ 这是**插件**投递的**舰队决策请求** —— **不是主人在说话** ✗✓。');
    L.push(`  ${req.ship} 现在**空闲**了，需要一个决策。`);
    L.push('  ★ 本块**只告知**，不带任何数据 ✗ —— 需要什么就**自己查** ✓（下面是路由表）。');
    L.push('');
    L.push('查证工具（原子接口，先 list 再按需查）：');
    L.push('  · {what:"list"} → 有哪些船（名字/忙闲/船长/星区）');
    L.push(`  · {what:"ship", ship:"${req.ship}", brief:true} → 这艘船现状`);
    L.push(`  · {what:"goal", ship:"${req.ship}"} → 目标/动作边界`);
    L.push('  · {what:"sectorFacts", x, y} → 星区事实');
    L.push('  · {what:"tradeRoutes", ship, x, y, sizeX, sizeY} → 框内贸易路线');
    L.push('  · {what:"predict", ship, action, x, y, sizeX, sizeY, …} → 一框一动作预测');
    L.push('  · 侦察覆盖：predict{action:"Scout", sizeX:21, sizeY:21} → 未知/已知/总数 + revealsNothingNew');
    L.push('  · legacy 计划(扫67框+排序)：tradePlan|minePlan|salvagePlan|sellPlan|scoutPlan');
    if (req.goalOptions.length > 0) {
        L.push(`  · 玩家限定动作：${req.goalOptions.join(', ')}（★ 只有这些 + None ✓）`);
    }
    L.push(`  · fleet_decisions {ship:"${req.ship}"} → 历史决策`);
    L.push('  ★ 用 fleet_query；legacy 计划用 compact/top。');
    L.push('');
    L.push('答复格式（★ **第一行**请直接写结论行 action=…（便于解析；之后再写理由 ✓））：');
    L.push('  第 1 行 action=<Mine | Salvage | Trade | Sell | Scout | Travel | Refine | None>');
    L.push(`  第 2 行 task=${req.taskId}  ← ★**必须回显**，这是认出"回给哪一单"的**唯一凭据**；`);
    L.push('    写错/写成别的号 → 判无效 ✗（绝不把别船的答案用在这艘船上 ✗）。');
    L.push('  之后按需要：x= y= sizeX= sizeY= duration= goodName= deposit= safeMode= escorts= goodsToSell= reason=');
    L.push('  需要主人拍板就直接把问题写出来 ✓（不写 action 行 → 记为"等主人裁决"，不替你编动作 ✓）。');
    L.push('  这些行之后**照常**跟主人聊天、继续原来的话题都行 ✓（舰队只看上面这几行 ✓）。');
    // ★ 上一单结果（2026-10-17 补 ✓）：决策者下一轮就能看到"上次成没成"，失败回投时也能看到"为什么失败" ✓。
    //   体积预算 ~200 字节：超了就当没加 ✗✓（调用方 index.ts 会先截断并在流水里说明 ✓）。
    if (typeof req.prevResult === 'string' && req.prevResult.trim() !== '') {
        // ★ 2026-10-17：措辞"上一单"（不是"你上一单"✗）—— 上一单可能是单发/兜底定的，
        //   来源由调用方 index.ts 的 renderPrevResult 用 `[decider]` 标签标明 ✓（不冒名 ✗✓）。
        const line = `★ 上一单的结果：${req.prevResult.trim()}`;
        if (Buffer.byteLength(line, 'utf8') <= PREV_RESULT_BUDGET_BYTES)
            L.push(line);
    }
    L.push('</fleet_task>');
    return L.join('\n');
}
/**
 * 校验会话的答案 ✓（**机器可检** —— 人格多花哨都不影响 ✓）。
 *
 * @param text           这一轮里**最后一条** assistant 文本 ✓
 * @param taskId         本任务 id ✓
 * @param allowedActions 允许的动作集合 ✓（含 'None' 与否都行；'None' 永远合法 ✓）
 */
export function validateAnswer(text, taskId, allowedActions) {
    if (typeof text !== 'string' || text.trim() === '') {
        return { ok: false, code: 'EMPTY_REPLY', message: '这一轮没有任何文本' };
    }
    const q = field(text, 'question');
    const rawAction = field(text, 'action');
    // ★ 人在环里是**特性** ✓，但绝不许实现成"悬着的 promise"✗ —— 这里只判"她在问" ✓，
    //   延期动作由 dispatch 层做 ✓（它会写清"投递会话在问主人：…"并**不派单** ✓）。
    if (rawAction === undefined && (q !== undefined && q !== ''
        || /[?？]\s*$/.test(text.trim()))) {
        return {
            ok: false,
            code: 'ASKED_OWNER',
            question: q !== undefined && q !== '' ? q : text.trim(),
        };
    }
    if (rawAction === undefined) {
        return {
            ok: false,
            code: 'NO_ACTION_LINE',
            // 与 index.ts 同一句话：把"她看到了什么"一起报出来，省得靠猜 ✓
            message: `reply has no action line (${text.length} chars)`,
        };
    }
    // ★★ 回显对不上 → **绝不采纳** ✗✓（她答的是别的船 / 别的任务 ✓）
    const echoedRaw = field(text, 'task');
    const echoed = echoedRaw !== undefined && echoedRaw !== '';
    if (echoed && echoedRaw !== taskId) {
        return {
            ok: false,
            code: 'TASK_MISMATCH',
            message: `回显的 task=${echoedRaw} 不是本任务 ${taskId} —— 绝不采纳 ✗`,
        };
    }
    const word = rawAction.replace(/[`*"'。，,]/g, '').trim();
    const action = word.toLowerCase() === 'none' ? 'None' : word;
    if (action !== 'None' && !allowedActions.includes(action)) {
        return {
            ok: false,
            code: 'BAD_ACTION',
            message: `action ${action} 不在允许集合内（${allowedActions.join(', ')}，以及 None）`,
        };
    }
    const params = {};
    const goodName = field(text, 'goodName');
    if (goodName !== undefined && goodName !== '' && !NONE_WORDS.has(goodName.toLowerCase())) {
        params.goodName = goodName;
    }
    const x = numField(text, 'x');
    if (x !== undefined)
        params.x = x;
    const y = numField(text, 'y');
    if (y !== undefined)
        params.y = y;
    // ★ Trade 的框形状：29x11 / 11x29 **不是正方形** ✗ → 两个边长分别取 ✓
    const shape = field(text, 'shape');
    if (shape !== undefined) {
        const m = /(\d+)\s*[x×*]\s*(\d+)/i.exec(shape);
        if (m !== null) {
            params.sizeX = Number(m[1]);
            params.sizeY = Number(m[2]);
        }
    }
    const sizeX = numField(text, 'sizeX');
    if (sizeX !== undefined && sizeX > 0)
        params.sizeX = sizeX;
    const sizeY = numField(text, 'sizeY');
    if (sizeY !== undefined && sizeY > 0)
        params.sizeY = sizeY;
    const size = numField(text, 'size');
    if (size !== undefined && size > 0)
        params.size = size;
    const deposit = numField(text, 'deposit');
    if (deposit !== undefined && deposit > 0)
        params.deposit = deposit;
    const duration = numField(text, 'duration');
    if (duration !== undefined)
        params.duration = duration;
    const safeMode = boolField(text, 'safeMode');
    if (safeMode !== undefined)
        params.safeMode = safeMode;
    // ★ Sell 的选货：`all` **不回传** ✗（游戏侧不给它就是"默认全卖" ✓ —— 与 index.ts 同款 ✓）
    const goods = field(text, 'goodsToSell');
    if (goods !== undefined && goods !== '' && !/^all$/i.test(goods) && goods !== '全部' && goods !== '全卖') {
        const list = [];
        for (const part of goods.split(/[,，;；]/)) {
            const m = part.trim().match(/^(.+?)\s*[:：=]\s*(\d+(?:\.\d+)?)$/);
            if (m !== null)
                list.push({ goodName: m[1].trim(), amount: Number(m[2]) });
        }
        if (list.length > 0)
            params.goodsToSell = list;
    }
    const escorts = listField(text, 'escorts');
    if (escorts.length > 0)
        params.escorts = escorts;
    const reason = field(text, 'reason');
    return {
        ok: true,
        echoed,
        answer: { action, params, reason: reason !== undefined && reason !== '' ? reason : undefined, raw: text },
    };
}
/**
 * 造一个任务 id ✓（**只用于人眼对号** —— 不参与任何逻辑判断 ✓）。
 * 形如 `t-1a2b3c4d`：前缀可读、后缀 8 位随机 ✓（同一轮多艘船不会撞 ✓）。
 */
export function makeTaskId(rand = Math.random) {
    const hex = '0123456789abcdef';
    let s = '';
    for (let i = 0; i < 8; i++)
        s += hex[Math.floor(rand() * 16) % 16];
    return `t-${s}`;
}
//# sourceMappingURL=task.js.map