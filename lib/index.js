/**
 * @dsh-external/dsh-avorion-copilot —— Avorion Copilot 桥接插件。
 *
 * 游戏侧（Lua）没有任何网络能力，也无法启动进程，所以两边只能靠文件通信：
 *
 *   %APPDATA%/Avorion/moddata/copilot/req_<船名>.txt   游戏写，本插件读
 *   %APPDATA%/Avorion/moddata/copilot/res_<船名>.txt   本插件写，游戏读
 *   %APPDATA%/Avorion/moddata/copilot/log_<船名>.txt   决策记录（含模型思维链）
 *
 * 本插件每隔几秒扫一次请求目录，对每个「还没有响应的」请求问一次模型，把决策原子性地
 * 写回响应文件。模型的思维链（reasoning-delta）会记进 log_<船名>.txt，便于事后回看。
 *
 * 请求与响应都是 key=value 行文本：游戏侧是 Lua，没有 JSON 库，行文本最不容易出错。
 * 写入一律先写 .tmp 再 rename，避免对面读到半截文件。
 *
 * 依赖说明：只 import @deepseek-ai/dsh-llm（拿 createUserMessage 与其类型）。
 * cordis 与 schemastery 的类型只存在于 DSH 源码 checkout 的 vendor/ 里，本机装好的
 * npm 包里没有，所以这里不 import 它们：ctx 用一个最小结构化接口描述，Config 干脆不导出
 * （已装的 dsh-mode-boost 同样不导出 Config，是合法形态）。
 */
import fs from 'node:fs';
import path from 'node:path';
import { createUserMessage } from '@deepseek-ai/dsh-llm';
export const name = '@dsh-external/dsh-avorion-copilot';
/** 需要 LLM 服务；没有它插件不启动。 */
export const inject = ['llm'];
/**
 * 开机自检：把插件实际看到的运行时事实写进 _diag.txt。
 *
 * 失败时（例如 MISSING_CREDENTIAL）光看错误码分不清是「服务看不到」还是「引用名对不上」，
 * 而 DSH 的日志位置不固定，写文件最可靠。涉及密钥时**只记长度，绝不记值**。
 */
async function writeDiagnostics(ctx, dir) {
    const lines = [`time: ${new Date().toISOString()}`, `dir: ${dir}`];
    try {
        const llm = ctx.llm;
        if (typeof llm.listProviders === 'function') {
            lines.push(`providers: ${JSON.stringify(llm.listProviders()).slice(0, 1000)}`);
        }
        else {
            lines.push('providers: listProviders is not available');
        }
    }
    catch (error) {
        lines.push(`providers probe failed: ${String(error)}`);
    }
    try {
        const get = ctx.get;
        if (typeof get !== 'function') {
            lines.push('ctx.get: not a function -> cannot probe services');
        }
        else {
            const credentials = get.call(ctx, 'credentials');
            lines.push(`credentials service: ${credentials === undefined ? 'MISSING' : 'present'}`);
            if (credentials !== undefined && typeof credentials.resolve === 'function') {
                try {
                    // 用变量做说明符：字面量会让 TS 去解析类型，而这个包不需要在编译期可见
                    // （运行时由宿主解析，与其它 @deepseek-ai/* 一样）。
                    const specifier = '@deepseek-ai/dsh-credentials';
                    const mod = (await import(specifier));
                    const hit = await credentials.resolve(mod.credentialRef('DEEPSEEK_API_KEY'));
                    const raw = hit?.value;
                    lines.push(`resolve(DEEPSEEK_API_KEY): ${hit === undefined ? 'MISS' : `HIT, length ${typeof raw === 'string' ? raw.length : '?'}`}`);
                }
                catch (error) {
                    lines.push(`resolve probe failed: ${String(error)}`);
                }
            }
        }
    }
    catch (error) {
        lines.push(`credentials probe failed: ${String(error)}`);
    }
    try {
        fs.writeFileSync(path.join(dir, '_diag.txt'), lines.join('\n') + '\n', 'utf8');
    }
    catch (error) {
        ctx.logger?.warn?.(`avorion-copilot: cannot write diagnostics: ${String(error)}`);
    }
}
const DEFAULTS = {
    dir: '',
    intervalMs: 4000,
    provider: 'deepseek-official',
    model: 'deepseek-flash',
    maxTokens: 700,
    temperature: 0.2,
};
/**
 * 系统提示词。放的是「模型必须知道、但请求文件里不必重复」的领域知识：
 * 四条命令的语义、区域规则，以及伏击概率为什么是非线性代价。
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
choice=<候选编号，只写数字，例如 choice=1（不要写成 choice=opt1）>
duration=<小时，可选；不填则用候选里的默认值>
escorts=<逗号分隔的船名，可选；不派就留空>
reason=<一句话理由，用中文>`;
function resolveDir(dir) {
    if (dir && dir.trim().length > 0)
        return path.resolve(dir.trim());
    const appData = process.env.APPDATA ?? '';
    return path.join(appData, 'Avorion', 'moddata', 'copilot');
}
/** 先写 .tmp 再改名，保证对面只会看到完整文件。 */
function atomicWrite(file, text) {
    const tmp = `${file}.tmp`;
    fs.writeFileSync(tmp, text, 'utf8');
    fs.renameSync(tmp, file);
}
/**
 * 从回复里取一个字段。容忍模型常见的自由发挥：
 * `choice=1` / `choice: 1` / `**choice=1**` / 全角冒号。逐行匹配，不跨行。
 */
function field(text, key) {
    const match = new RegExp(`^\\s*\\**\\s*${key}\\s*[:=：]\\s*(.*)$`, 'im').exec(text);
    if (match === null)
        return undefined;
    return match[1].replace(/\*+$/, '').trim();
}
/**
 * 解析候选编号。模型经常写成 `opt1` 而不是 `1`（实测第一次就踩到了），
 * 所以只取其中的数字：`opt1` / `OPT 2` / `选项3` / `1` 都能认。
 */
function parseChoice(raw) {
    const match = /(\d+)/.exec(raw);
    if (match === null)
        return undefined;
    const value = Number(match[1]);
    return Number.isFinite(value) ? value : undefined;
}
/** 表示"没有"的几种写法，别当成船名。 */
const NONE_WORDS = new Set(['', '-', 'none', 'null', 'n/a', 'na', '无', '没有', '否']);
/** 解析模型回复。解析不出 choice 就算失败，交给游戏按错误处理。 */
function parseDecision(text) {
    const decision = {};
    const rawChoice = field(text, 'choice');
    if (rawChoice !== undefined) {
        const choice = parseChoice(rawChoice);
        if (choice !== undefined)
            decision.choice = choice;
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
    if (decision.choice === undefined) {
        const seen = rawChoice === undefined ? 'no choice line' : JSON.stringify(rawChoice);
        decision.error = `model reply contained no usable choice (saw: ${seen})`;
    }
    return decision;
}
/** 跑一次模型调用，把正文与思维链分别收拢。 */
async function askModel(ctx, cfg, requestText) {
    let text = '';
    let reasoning = '';
    let failure;
    let truncated = false;
    const messages = [createUserMessage({ content: [{ type: 'text', text: requestText }], source: { kind: 'user' } })];
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
                // 带上 message：只有 code 时（例如 MISSING_CREDENTIAL）分不清是哪个适配器报的
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
/** 处理一个请求；无论成功失败都写响应文件，避免游戏反复重试同一个请求。 */
async function handleRequest(ctx, cfg, dir, ship) {
    const reqFile = path.join(dir, `req_${ship}.txt`);
    const resFile = path.join(dir, `res_${ship}.txt`);
    let requestText;
    try {
        requestText = fs.readFileSync(reqFile, 'utf8');
    }
    catch (error) {
        ctx.logger?.warn?.(`avorion-copilot: cannot read ${reqFile}: ${String(error)}`);
        return;
    }
    ctx.logger?.info?.(`avorion-copilot: deciding for ${ship}`);
    let result;
    try {
        result = await askModel(ctx, cfg, requestText);
    }
    catch (error) {
        result = {
            text: '',
            reasoning: '',
            failure: error instanceof Error ? error.message : String(error),
            truncated: false,
        };
    }
    const stamp = new Date().toISOString();
    const decision = result.failure
        ? { error: `model call failed: ${result.failure}` }
        : parseDecision(result.text);
    // 人类可读的决策记录（含思维链），便于事后回看模型在想什么。
    // 注意别用 filter 去掉空行：段落之间靠空行分隔，滤掉就粘成一团了。
    const logLines = [
        `time: ${stamp}`,
        `ship: ${ship}`,
        `provider/model: ${cfg.provider}/${cfg.model}`,
    ];
    if (result.truncated)
        logLines.push('warning: reply hit maxTokens and may be truncated');
    logLines.push('', '--- request ---', requestText.trim(), '', '--- reasoning ---', result.reasoning.trim() || '(none)', '', '--- reply ---', result.text.trim() || '(empty)', '', '--- decision ---', JSON.stringify(decision), '');
    try {
        atomicWrite(path.join(dir, `log_${ship}.txt`), logLines.join('\n'));
    }
    catch (error) {
        ctx.logger?.warn?.(`avorion-copilot: cannot write decision log: ${String(error)}`);
    }
    const lines = ['version=1', `ship=${ship}`, `time=${stamp}`];
    if (decision.error) {
        lines.push(`error=${decision.error}`);
    }
    else {
        lines.push(`choice=${decision.choice}`);
        if (decision.duration !== undefined)
            lines.push(`duration=${decision.duration}`);
        if (decision.escorts && decision.escorts.length > 0)
            lines.push(`escorts=${decision.escorts.join(',')}`);
        if (decision.reason)
            lines.push(`reason=${decision.reason.replace(/\s+/g, ' ')}`);
    }
    try {
        atomicWrite(resFile, lines.join('\n') + '\n');
        ctx.logger?.info?.(decision.error
            ? `avorion-copilot: ${ship} -> error (${decision.error})`
            : `avorion-copilot: ${ship} -> choice ${String(decision.choice)}${decision.reason ? ` (${decision.reason})` : ''}`);
    }
    catch (error) {
        ctx.logger?.warn?.(`avorion-copilot: cannot write ${resFile}: ${String(error)}`);
    }
}
export async function apply(ctx, rawConfig) {
    const cfg = { ...DEFAULTS, ...(rawConfig ?? {}) };
    const dir = resolveDir(cfg.dir);
    let busy = false;
    try {
        fs.mkdirSync(dir, { recursive: true });
    }
    catch (error) {
        ctx.logger?.warn?.(`avorion-copilot: cannot create bridge dir ${dir}: ${String(error)}`);
    }
    ctx.logger?.info?.(`avorion-copilot: bridge watching ${dir} every ${cfg.intervalMs} ms`);
    // 开机自检写进 _diag.txt：出错时能一眼看出是服务缺失、引用名不对，还是别的
    await writeDiagnostics(ctx, dir);
    const tick = async () => {
        if (busy)
            return;
        busy = true;
        try {
            let names;
            try {
                names = fs.readdirSync(dir);
            }
            catch {
                return;
            }
            for (const entry of names) {
                if (!entry.startsWith('req_') || !entry.endsWith('.txt'))
                    continue;
                const ship = entry.slice('req_'.length, entry.length - '.txt'.length);
                if (ship.length === 0)
                    continue;
                // 已经有响应 = 游戏还没取走，别重复裁决
                if (fs.existsSync(path.join(dir, `res_${ship}.txt`)))
                    continue;
                await handleRequest(ctx, cfg, dir, ship);
            }
        }
        catch (error) {
            ctx.logger?.warn?.(`avorion-copilot: tick failed: ${String(error)}`);
        }
        finally {
            busy = false;
        }
    };
    // ctx.effect 的资源注册：插件卸载/热重载时定时器自动清理
    ctx.effect(() => {
        const timer = setInterval(() => void tick(), cfg.intervalMs);
        return () => clearInterval(timer);
    }, 'avorion-copilot bridge watcher');
    // 启动后立刻扫一次，不用等第一个间隔
    void tick();
}
//# sourceMappingURL=index.js.map