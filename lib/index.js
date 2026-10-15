/**
 * @dsh-external/dsh-avorion-copilot —— Avorion `copilot` mod ⇄ DSH 的桥接插件。
 *
 * ## 本版（RPC 版）
 *
 * 传输从「文件桥」换成「**TCP + 对称 RPC**」✓（协议见 mod 仓库的 PROTOCOL.md v2）。
 * 本质就是主人点透的那句话：
 *   **让 DSH 能调游戏的功能，也让游戏能调 DSH 的功能。** ✓
 *
 * ```
 *   游戏（Lua rpc.lua）  ⇄  TCP 127.0.0.1:8765  ⇄  本插件（rpc.ts）
 *        handle: hello/query/order/decide/reload/ping      ← 游戏提供的功能
 *        call:   hello/state/decide                        ← 游戏发起的请求
 * ```
 *
 * 本插件**监听** 8765（游戏主动连过来 ✓ —— 这样不触发 Windows 防火墙弹窗 ✓）。
 *
 * ## 文件桥时代的东西去哪了
 *
 * `watch`/`atomicWrite`/`writeDiagnostics` 全部删掉 ✓ —— 不再需要 ✓。
 * **`SYSTEM_PROMPT` 与 `parseDecision` 那一套一字未改** ✓ —— 它们是调研出来的领域知识
 * 和踩过坑的鲁棒解析 ✓，与传输无关 ✓。
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createUserMessage } from '@deepseek-ai/dsh-llm';
import { RpcPeer } from './rpc.js';
import { registerFleetTools, ask } from './tools.js';
export const name = '@dsh-external/dsh-avorion-copilot';
/** 需要 LLM 服务；没有它插件不启动。 */
export const inject = ['llm', 'tools']; // ★ 'tools'：注册 fleet_* 工具必需 ✓（照 dsh-global-memory ✓）
/**
 * ★ 把日志**同时写进文件** ✓
 *
 * 因为 DSH 的 `ctx.logger` 只进控制台、**不落盘** ✗ —— 而本项目的验证方式一直是"读日志" ✓。
 * 写到与 mod 同一个目录（`moddata/copilot/`）✓，agent 就能像读其他日志一样读它 ✓✓。
 */
const LOG_FILE = path.join(os.homedir(), 'AppData', 'Roaming', 'Avorion', 'moddata', 'copilot', 'rpc_dsh.log');
function fileLog(line) {
    try {
        fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
        fs.appendFileSync(LOG_FILE, `${new Date().toISOString()}  ${line}\n`);
    }
    catch { /* 日志失败绝不能影响主流程 ✓ */ }
}
const DEFAULTS = {
    port: 8765,
    provider: 'deepseek-official',
    model: 'deepseek-flash',
    maxTokens: 700,
    temperature: 0.2,
};
/**
 * 系统提示词。放的是「模型必须知道、但请求里不必重复」的领域知识：
 * 四条命令的语义、区域规则，以及伏击概率为什么是非线性代价。
 *
 * ★ 一字未改，从文件桥版本原样搬来 ✓。
 */
const SYSTEM_PROMPT = `你是 Avorion 舰队的运营大脑。玩家把若干艘船交给你自动运营，现在需要你为其中一艘空闲的船决定下一步做什么。

可用命令（都属"后台命令"：船长带队离开玩家所在星区，在指定区域自动作业，期间联系不上）：
- Mine    采矿，产出矿石。区域 15x15，且船必须已经在该区域内。
- Salvage 打捞残骸，产出资源与装备。区域 15x15，船必须已经在该区域内。
- Trade   按贸易路线买卖商品赚钱。区域 17x17 / 29x11 / 11x29，船必须已经在该区域内，且船长职业必须是 Merchant。
- Travel  跃迁到指定星区。区域 1x1，即单个目标星区，目的地至少要 2 跳远。

判断依据：
- attackChance 是整段任务期间遭遇伏击的概率（0~1）。0.20 以上在原版里就是"应该派护卫"的分档。
- 被伏击 = 命令被强制召回，拿不到结束时的最终大额产出，只能按已完成进度部分结算。所以风险对期望收益的影响是非线性的。
- 派一艘"自身够硬"的护卫大约把伏击基础概率乘 0.75，但护卫本身占用了另一艘船。
- 任务时长越长风险越高：超过 1 小时后，每多 1 小时伏击概率再增加约 40%。收益随时长增加，但边际有限。
- 收益区间（yield）已经是"含可选护卫"的预估。

只回复下面这几行，不要任何多余文字：
action=<Mine | Salvage | Trade | Travel | None，只写这一个词>
x=<目标星区 x 坐标，整数；action=None 时省略>
y=<目标星区 y 坐标，整数；action=None 时省略>
duration=<小时，可选>
reason=<一句话理由，用中文>`;
/**
 * 从回复里取一个字段。容忍模型常见的自由发挥：
 * `choice=1` / `choice: 1` / `**choice=1**` / 全角冒号。逐行匹配，不跨行。
 * ★ 原样保留 ✓。
 */
function field(text, key) {
    const match = new RegExp(`^\\s*\\**\\s*${key}\\s*[:=：]\\s*(.*)$`, 'im').exec(text);
    if (match === null)
        return undefined;
    return match[1].replace(/\*+$/, '').trim();
}
/**
 * 从一个字段里取数字。坐标可能是 `-406` / `x = -406` / `(-406,73)`（括号里取第一个），
 * 所以**只取第一段数字**（含负号）✓ —— 原版那个 `opt1`/`选项3` 的容错也一并在里面 ✓。
 */
function parseNumberField(raw) {
    const match = /-?\d+(?:\.\d+)?/.exec(raw);
    if (match === null)
        return undefined;
    const value = Number(match[0]);
    return Number.isFinite(value) ? value : undefined;
}
/** 表示"没有"的几种写法，别当成船名。★ 原样保留 ✓ */
const NONE_WORDS = new Set(['', '-', 'none', 'null', 'n/a', 'na', '无', '没有', '否']);
/** 解析模型回复。解析不出 action 就算失败，交给游戏按错误处理 ✓ */
function parseDecision(text) {
    const decision = {};
    const rawAction = field(text, 'action');
    if (rawAction !== undefined) {
        // 容忍 `action=Mine` / `action: mine` / `**action = Mine**` ✓
        const word = rawAction.replace(/[`*"'。，,]/g, '').trim();
        const known = ['Mine', 'Salvage', 'Trade', 'Travel', 'None'];
        const hit = known.find((k) => k.toLowerCase() === word.toLowerCase());
        if (hit !== undefined)
            decision.action = hit;
        else if (word.length > 0)
            decision.action = word; // 原样带出，由 toAnswer 判合法性 ✓
    }
    const x = field(text, 'x');
    if (x !== undefined) {
        const v = parseNumberField(x);
        if (v !== undefined)
            decision.x = v;
    }
    const y = field(text, 'y');
    if (y !== undefined) {
        const v = parseNumberField(y);
        if (v !== undefined)
            decision.y = v;
    }
    const duration = field(text, 'duration');
    if (duration !== undefined) {
        const match = /(\d+(?:\.\d+)?)/.exec(duration);
        if (match !== null)
            decision.duration = Number(match[1]);
    }
    const escorts = field(text, 'escorts');
    if (escorts !== undefined) {
        decision.escorts = escorts
            .split(/[,，、]/)
            .map((s) => s.trim())
            .filter((s) => !NONE_WORDS.has(s.toLowerCase()));
    }
    const reason = field(text, 'reason');
    if (reason !== undefined && reason.length > 0)
        decision.reason = reason;
    if (decision.action === undefined) {
        const seen = rawAction === undefined ? 'no action line' : JSON.stringify(rawAction);
        decision.error = `model reply contained no usable action (saw: ${seen})`;
    }
    return decision;
}
/** 跑一次模型调用，把正文与思维链分别收拢。★ 逐字段保留（猜不得 ✗） */
async function askModel(ctx, cfg, prompt) {
    let text = '';
    let reasoning = '';
    let failure;
    let truncated = false;
    const messages = [createUserMessage({ content: [{ type: 'text', text: prompt }], source: { kind: 'user' } })];
    const stream = ctx.llm.stream({
        provider: cfg.provider,
        model: cfg.model,
        system: SYSTEM_PROMPT,
        messages,
        maxTokens: cfg.maxTokens,
        temperature: cfg.temperature,
    });
    for await (const chunk of stream) {
        if (chunk.type === 'text-delta') {
            text += chunk.text;
        }
        else if (chunk.type === 'reasoning-delta') {
            reasoning += chunk.text;
        }
        else if (chunk.type === 'finish') {
            // 失败与取消都以 finish 结束，细节在 reason 里，带稳定 code（NO_ADAPTER / AUTH / RATE_LIMIT ...）
            const reason = chunk.reason;
            if (reason.kind === 'error' || reason.kind === 'aborted') {
                failure = reason.failure.code
                    ? `${reason.failure.code}: ${reason.failure.message}`
                    : reason.failure.message;
            }
            else if (reason.kind === 'max-tokens') {
                truncated = true;
            }
        }
    }
    return { text, reasoning, failure, truncated };
}
/** 组一份给模型看的请求：目标 + 边界 + 事实 ✓ */
function buildPrompt(f) {
    const lines = [];
    lines.push(`船：${f.ship}`);
    lines.push('');
    lines.push('玩家给这艘船设定的运营目标：');
    lines.push(f.goalText !== '' ? f.goalText : '(玩家没有写文字目标，只给了下面的动作边界)');
    lines.push('');
    lines.push('允许的动作：');
    lines.push(f.goalOptions.length > 0 ? f.goalOptions.join(', ') : '(玩家没有限制 —— 你可以从 Mine/Salvage/Trade/Travel 里选)');
    lines.push('');
    lines.push('这艘船的现状（能力卡）：');
    lines.push(JSON.stringify(f.card ?? {}, null, 2));
    lines.push('');
    lines.push('请按系统提示的格式回复。');
    return lines.join('\n');
}
/** 把模型的正文解析成 action + 坐标（这才是要回给游戏的答案 ✓） */
function toAnswer(decision, f, raw) {
    if (decision.error !== undefined)
        return decision.error;
    const action = decision.action ?? 'None';
    const allowed = f.goalOptions.length > 0 ? f.goalOptions : ['Mine', 'Salvage', 'Trade', 'Travel'];
    // "None" 永远合法（什么都不做 ✓）
    if (action !== 'None' && !allowed.includes(action)) {
        return `model picked '${action}' which is not allowed here (allowed: ${allowed.join(', ')}, plus None)`;
    }
    const params = {};
    if (decision.x !== undefined)
        params.x = decision.x;
    if (decision.y !== undefined)
        params.y = decision.y;
    if (decision.duration !== undefined)
        params.duration = decision.duration;
    if (decision.escorts !== undefined && decision.escorts.length > 0)
        params.escorts = decision.escorts;
    return { action, params, reason: decision.reason, raw };
}
// ---------------------------------------------------------------------------
// 插件入口：把 RPC 接起来
// ---------------------------------------------------------------------------
export function apply(ctx, config = {}) {
    const cfg = {
        port: config.port ?? DEFAULTS.port,
        provider: config.provider ?? DEFAULTS.provider,
        model: config.model ?? DEFAULTS.model,
        maxTokens: config.maxTokens ?? DEFAULTS.maxTokens,
        temperature: config.temperature ?? DEFAULTS.temperature,
    };
    // 双写：控制台（人看 ✓）+ 文件（agent 读 ✓）
    const logger = {
        info: (m) => { ctx.logger?.info?.(m); fileLog(m); },
        warn: (m) => { ctx.logger?.warn?.(m); fileLog('WARN ' + m); },
    };
    fileLog(`=== 插件启动：监听 ${cfg.port}（模型 ${cfg.provider}/${cfg.model}）===`);
    const peer = new RpcPeer({
        port: cfg.port,
        logger,
        defaultTimeoutSec: 5,
    });
    // ---- 我提供的功能（游戏可以调我）------------------------------------------
    peer.handle('hello', (data) => {
        // 协议 §6/§8：两端各发一次 hello，各自声明 caps ✓
        logger.info(`avorion-copilot: 游戏握手 side=${data?.side} ver=${data?.ver} caps=${(data?.caps ?? []).join(',')}`);
        return [true, { side: 'dsh', ver: 2, caps: peer.caps() }];
    });
    peer.handle('ping', () => [true, { pong: true, from: 'dsh' }]);
    /**
     * ★ `decide` —— **游戏调 DSH 的决策能力**，整条链的核心 ✓
     *
     * `data` 由游戏侧给出：`{ship, card, options}` —— 其中 `options` 来自游戏侧的
     * `orderSchema` ✓，所以模型**只可能选到合法命令** ✓✓。
     *
     * 返回 `{action, params}` ✓；游戏侧拿到后走 `order` 真正下单 ✓。
     */
    peer.handle('decide', async (data) => {
        const req = (data ?? {});
        const ship = req.ship;
        if (typeof ship !== 'string' || ship === '') {
            return [false, 'BAD_REQUEST', 'decide needs data.ship'];
        }
        logger.info(`avorion-copilot: 为 ${ship} 决策中…`);
        // ★★ 按主人的架构：DSH **自己**用 RPC 去拉数据 ✓✓（游戏侧只给船名 ✗）
        const goalR = await ask(peer, 'query', { what: 'goal', ship }, 10);
        if (!goalR.ok) {
            logger.warn(`avorion-copilot: 拉目标失败 ${goalR.why ?? ''}`);
            return [false, 'GOAL_QUERY_FAILED', goalR.why ?? 'unknown'];
        }
        const cardR = await ask(peer, 'query', { what: 'ship', ship }, 10);
        if (!cardR.ok) {
            logger.warn(`avorion-copilot: 拉能力卡失败 ${cardR.why ?? ''}`);
            return [false, 'CARD_QUERY_FAILED', cardR.why ?? 'unknown'];
        }
        const gd = (goalR.data ?? {});
        const facts = {
            ship,
            goalText: typeof gd.text === 'string' ? gd.text : '',
            goalOptions: Array.isArray(gd.options) ? gd.options : [],
            card: cardR.data ?? {},
        };
        logger.info(`avorion-copilot: ${ship} 目标=[${facts.goalText}] 允许=${facts.goalOptions.join(',') || '(不限)'}`);
        let result;
        try {
            result = await askModel(ctx, cfg, buildPrompt(facts));
        }
        catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            logger.warn(`avorion-copilot: 模型调用异常 ${message}`);
            return [false, 'MODEL_ERROR', message];
        }
        if (result.failure !== undefined) {
            logger.warn(`avorion-copilot: 模型调用失败 ${result.failure}`);
            return [false, 'MODEL_FAILED', result.failure];
        }
        const decision = parseDecision(result.text);
        const answer = toAnswer(decision, facts, result.text);
        if (typeof answer === 'string') {
            logger.warn(`avorion-copilot: 决策无法解析 —— ${answer}`);
            return [false, 'BAD_MODEL_REPLY', answer];
        }
        logger.info(`avorion-copilot: ${ship} -> ${answer.action} ${JSON.stringify(answer.params)}` +
            (answer.reason !== undefined ? `  (${answer.reason})` : '') +
            (result.truncated ? '  [被 maxTokens 截断]' : '') +
            (result.reasoning.length > 0 ? `\n--- 思维链 ---\n${result.reasoning.trim()}` : ''));
        // ★ 真下单：DSH 主动调游戏的 order ✓✓（游戏侧会走两段式 ✓）
        if (answer.action !== 'None') {
            const ord = await ask(peer, 'order', { ship, action: answer.action, ...answer.params }, 30);
            if (ord.ok) {
                logger.info(`avorion-copilot: 已下单 ${ship} -> ${answer.action} → ${JSON.stringify(ord.data)}`);
            }
            else {
                logger.warn(`avorion-copilot: 下单失败 ${ord.why ?? ''}`);
            }
        }
        return [true, answer];
    });
    // ---- 我调游戏（DSH 主动查询 / 下单）---------------------------------------
    /** 查一次舰队快照（"眼睛" ✓ —— 不用截图 ✓） */
    const queryFleet = (cb) => peer.call('query', { what: 'fleet' }, cb, 5);
    const queryShip = (ship, cb) => peer.call('query', { what: 'ship', ship }, cb, 5);
    const order = (ship, action, params = {}, cb) => peer.call('order', { ship, action, ...params }, cb, 15);
    const reload = (cb) => peer.call('reload', {}, cb, 10);
    // 连上后打一份舰队快照到日志 —— 既是握手确认，也是"眼睛"的第一次使用 ✓
    peer.onConnected = () => {
        logger.info('avorion-copilot: 游戏已连接，查询舰队快照…');
        queryFleet((ok, data, why) => {
            if (!ok) {
                logger.warn(`avorion-copilot: query fleet 失败 ${why ?? ''}`);
                return;
            }
            // ★ 空的 Lua 表被 cJSON 编成 {}（不是 []）✗ —— 两种都当空列表处理 ✓
            const rawShips = data?.ships;
            const ships = Array.isArray(rawShips)
                ? rawShips
                : (rawShips !== null && typeof rawShips === 'object' ? Object.values(rawShips) : []);
            logger.info(`avorion-copilot: 名单 ${data?.designated ?? '?'} 艘，快照 ${ships.length} 条（玩家在开：${data?.piloted ?? '?'}）`);
            for (const s of ships) {
                logger.info(`  - ${s.name} busy=${s.busy} captain=${s.hasCaptain}` +
                    (s.status !== undefined ? ` status=${String(s.status).slice(0, 40)}` : ''));
            }
        });
    };
    // ---- 生命周期 --------------------------------------------------------------
    ctx.effect(() => {
        void peer.listen().catch((err) => {
            logger.warn(`avorion-copilot: 监听 ${cfg.port} 失败（${String(err)}）—— 插件不会工作`);
        });
        return () => {
            logger.info('avorion-copilot: 关闭 RPC');
            peer.close();
        };
    }, 'dsh-avorion-copilot:rpc');
    // ★ 把游戏能力暴露成 DSH 工具（主人要的"会话接管"就靠它们 ✓✓）
    registerFleetTools(ctx, peer);
    // 供将来从 DSH 侧主动操作（例如命令面板、定时巡检）使用 ✓
    void queryShip;
    void order;
    void reload;
}
//# sourceMappingURL=index.js.map