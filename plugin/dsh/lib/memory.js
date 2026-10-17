/**
 * memory.ts -- the decision brain's PERSISTENT OPERATIONAL KNOWLEDGE (2026-10-16).
 *
 * The owner's words (authoritative):
 *   "尤其是实际执行游戏决策的agent，长期记忆是很重要的。"
 *
 * Why this exists: until now every decision was a stateless one-shot model call, so the
 * brain re-derived the galaxy from scratch every round and never learned. Evidence from the
 * live log: the Trader re-compared all 9 candidate areas on every round, and it re-litigated
 * the same `captainClass: "3"` question three separate times.
 *
 * WHAT IS STORED (see the store schema below)
 *   ships    -- per ship: proven specialty, job counts, realized money, recalls/attacks, last few outcomes,
 *               plus a ROLLING SUMMARY so the raw list never grows without bound.
 *   sectors  -- per sector ("x,y"): what we learned by doing -- ore tiers seen, best goods/routes,
 *               measured ambush risk, whether escorts were needed. This is the map knowledge that
 *               should make the next multi-area scan smarter instead of blind.
 *   lessons  -- fleet-level factual notes the brain derived.
 *   ledger   -- outcome ledger per ship and per good/route, for experience-based reasoning.
 *
 * DESIGN RULES (all deliberate):
 *   * memory is ADVISORY. Fresh game data always wins (the prompt states this rule).
 *   * retrieval is BUDGETED (<= 1.6k chars) and only injects what THIS decision touches.
 *   * writes are atomic (tmp + rename) and bounded; a write failure must never break a decision.
 *   * a corrupt store is moved to a .bak and a fresh one starts -- never fatal.
 *   * the file is pretty JSON so a human can read it directly.
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
// ---------------------------------------------------------------------------
// Paths + limits
// ---------------------------------------------------------------------------
const DIR = path.join(os.homedir(), 'AppData', 'Roaming', 'Avorion', 'moddata', 'copilot');
const FILE = path.join(DIR, 'brain-memory.json');
/** Retrieval budget for the memory section of a prompt (characters). */
export const MEMORY_BUDGET_CHARS = 1600;
/** How many raw per-ship outcomes to keep before compressing into the summary. */
const SHIP_RECENT_KEEP = 5;
const SECTOR_LIMIT = 200;
const LESSON_LIMIT = 40;
const SHIP_LIMIT = 60;
function empty() {
    return { version: 1, updatedAt: new Date().toISOString(), ships: {}, sectors: {}, lessons: [], ledger: {} };
}
// ---------------------------------------------------------------------------
// Load / save (never throw out of here -- memory must not break decisions)
// ---------------------------------------------------------------------------
let cache = null;
export function memoryPath() {
    return FILE;
}
export function load(force = false) {
    if (cache !== null && !force)
        return cache;
    try {
        if (!fs.existsSync(FILE)) {
            cache = empty();
            return cache;
        }
        const raw = fs.readFileSync(FILE, 'utf8');
        const parsed = JSON.parse(raw);
        if (parsed === null || typeof parsed !== 'object' || parsed.version !== 1)
            throw new Error('bad version');
        // tolerate missing collections from older/partial files
        parsed.ships = parsed.ships ?? {};
        parsed.sectors = parsed.sectors ?? {};
        parsed.lessons = Array.isArray(parsed.lessons) ? parsed.lessons : [];
        parsed.ledger = parsed.ledger ?? {};
        cache = parsed;
        return cache;
    }
    catch (error) {
        // corrupt or unreadable -> keep the last good copy, start fresh, never fatal
        try {
            fs.copyFileSync(FILE, FILE + '.bak');
        }
        catch {
            /* ignore */
        }
        console.warn(`avorion-copilot: brain-memory unreadable (${String(error)}) -> backed up to .bak and started fresh`);
        cache = empty();
        return cache;
    }
}
/** Atomic, bounded, best-effort save. Returns an error string, or null on success. */
export function save() {
    const store = cache;
    if (store === null)
        return 'nothing loaded';
    try {
        if (!fs.existsSync(DIR))
            fs.mkdirSync(DIR, { recursive: true });
        store.updatedAt = new Date().toISOString();
        // bound growth
        const shipNames = Object.keys(store.ships);
        if (shipNames.length > SHIP_LIMIT) {
            const sorted = shipNames.sort((a, b) => (store.ships[a].lastSeen < store.ships[b].lastSeen ? -1 : 1));
            for (const n of sorted.slice(0, shipNames.length - SHIP_LIMIT))
                delete store.ships[n];
        }
        const sectorNames = Object.keys(store.sectors);
        if (sectorNames.length > SECTOR_LIMIT) {
            const sorted = sectorNames.sort((a, b) => (store.sectors[a].lastSeen < store.sectors[b].lastSeen ? -1 : 1));
            for (const n of sorted.slice(0, sectorNames.length - SECTOR_LIMIT))
                delete store.sectors[n];
        }
        if (store.lessons.length > LESSON_LIMIT)
            store.lessons = store.lessons.slice(-LESSON_LIMIT);
        const tmp = FILE + '.tmp';
        fs.writeFileSync(tmp, JSON.stringify(store, null, 2) + '\n', 'utf8');
        fs.renameSync(tmp, FILE); // atomic on the same volume
        return null;
    }
    catch (error) {
        return String(error);
    }
}
// ---------------------------------------------------------------------------
// Recording
// ---------------------------------------------------------------------------
function ship(store, name) {
    const now = new Date().toISOString();
    let m = store.ships[name];
    if (m === undefined) {
        m = {
            firstSeen: now, lastSeen: now, actions: {},
            jobsStarted: 0, jobsCompleted: 0, jobsEndedEarly: 0,
            creditsTotal: 0, creditsSamples: 0, summary: '', recent: [],
        };
        store.ships[name] = m;
    }
    m.lastSeen = now;
    return m;
}
/** Remember that we handed this ship a job (called when the order is accepted). */
export function rememberStart(shipName, action, params, sector) {
    const store = load();
    const m = ship(store, shipName);
    m.jobsStarted += 1;
    m.actions[action] = (m.actions[action] ?? 0) + 1;
    if (sector !== undefined && sector !== '')
        noteSectorInternal(store, sector, { action, attackChance: num(params.attackChance) });
    save();
}
/** Remember how a job actually ended. */
export function rememberOutcome(shipName, o) {
    const store = load();
    const m = ship(store, shipName);
    m.recent.push(o);
    if (m.recent.length > SHIP_RECENT_KEEP)
        m.recent = m.recent.slice(-SHIP_RECENT_KEEP);
    if (o.endedEarly === true)
        m.jobsEndedEarly += 1;
    else
        m.jobsCompleted += 1;
    if (o.credits !== undefined && Number.isFinite(o.credits)) {
        m.creditsTotal += o.credits;
        m.creditsSamples += 1;
    }
    if (o.sector !== undefined && o.sector !== '') {
        noteSectorInternal(store, o.sector, { action: o.action, goodName: o.goodName, attackChance: undefined });
    }
    const key = `${shipName}|${o.action}${o.goodName !== undefined ? '|' + o.goodName : ''}`;
    const prev = store.ledger[key];
    store.ledger[key] = {
        at: o.at, action: o.action, goodName: o.goodName,
        value: (prev?.value ?? 0) + (o.credits ?? 0),
    };
    m.summary = summarize(m);
    save();
}
/** Map knowledge: what we learned about a sector by doing jobs there. */
export function noteSectorInternal(store, key, info) {
    const now = new Date().toISOString();
    let s = store.sectors[key];
    if (s === undefined) {
        s = { firstSeen: now, lastSeen: now, jobs: 0, escortNeeded: 0 };
        store.sectors[key] = s;
    }
    s.lastSeen = now;
    if (info.action !== undefined)
        s.jobs += 1;
    if (info.goodName !== undefined)
        s.bestGood = info.goodName;
    if (info.oreTier !== undefined)
        s.bestOreTier = Math.max(s.bestOreTier ?? 0, info.oreTier);
    if (info.attackChance !== undefined) {
        s.minAttackChance = s.minAttackChance === undefined ? info.attackChance : Math.min(s.minAttackChance, info.attackChance);
        s.maxAttackChance = s.maxAttackChance === undefined ? info.attackChance : Math.max(s.maxAttackChance, info.attackChance);
        if (info.attackChance > 0.10)
            s.note = `ambush risk has been high here (${Math.round(info.attackChance * 100)}%)`;
    }
    if (info.escortNeeded === true)
        s.escortNeeded += 1;
}
export function noteSector(key, info) {
    const store = load();
    noteSectorInternal(store, key, info);
    save();
}
/** Fleet-level lesson (deduplicated, newest last). */
export function addLesson(text) {
    const store = load();
    const t = text.trim();
    if (t === '' || store.lessons.includes(t))
        return;
    store.lessons.push(t);
    save();
}
function summarize(m) {
    const acts = Object.entries(m.actions).map(([k, v]) => `${k}x${v}`).join(',') || 'none';
    const avg = m.creditsSamples > 0 ? Math.round(m.creditsTotal / m.creditsSamples) : 0;
    return `${m.jobsStarted} started / ${m.jobsCompleted} finished / ${m.jobsEndedEarly} early; `
        + `actions ${acts}; credits total ${m.creditsTotal} avg ${avg}`;
}
function num(v) {
    const n = typeof v === 'number' ? v : Number(v);
    return Number.isFinite(n) ? n : undefined;
}
// ---------------------------------------------------------------------------
// Retrieval (budgeted -- memory must never blow the context)
// ---------------------------------------------------------------------------
/**
 * Build the memory section for ONE decision: this ship + the sectors the fresh plan touches
 * + a small fleet digest. Never the whole store. Honors MEMORY_BUDGET_CHARS.
 */
export function retrieve(shipName, sectors) {
    const store = load();
    const m = store.ships[shipName];
    const lines = [];
    let compressed = 0;
    if (m !== undefined) {
        lines.push(`这艘船（${shipName}）的经验：${m.summary || summarize(m)}`);
        const touched = (m.recent ?? []).slice(-2);
        compressed += Math.max(0, (m.recent?.length ?? 0) - touched.length);
        for (const o of touched) {
            const dur = o.busySeconds !== undefined ? `busy ${Math.round(o.busySeconds)}s` : 'duration unknown';
            const how = o.endedEarly === true ? 'ended EARLY (likely attacked/recalled)' : 'completed';
            lines.push(`  - ${o.action}${o.goodName !== undefined ? ' ' + o.goodName : ''} @ ${o.sector ?? '?'}: ${how}, ${dur}${o.credits !== undefined ? `, ${o.credits} cr` : ''}`);
        }
    }
    else {
        lines.push(`这艘船（${shipName}）：没有历史记录（第一次）。`);
    }
    const secs = sectors.filter((s) => s !== '').slice(0, 4);
    for (const key of secs) {
        const s = store.sectors[key];
        if (s === undefined)
            continue;
        const bits = [`星区 ${key}`];
        if (s.bestOreTier !== undefined)
            bits.push(`最好矿层级 ${s.bestOreTier}`);
        if (s.bestGood !== undefined)
            bits.push(`见过的好货 ${s.bestGood}`);
        if (s.maxAttackChance !== undefined)
            bits.push(`伏击曾有 ${Math.round((s.maxAttackChance ?? 0) * 100)}%`);
        bits.push(`跑过 ${s.jobs} 次`);
        if (s.escortNeeded > 0)
            bits.push(`需要护航 ${s.escortNeeded} 次`);
        lines.push(bits.join(' / '));
    }
    if (store.lessons.length > 0) {
        const kept = store.lessons.slice(-3);
        compressed += Math.max(0, store.lessons.length - kept.length);
        lines.push('舰队级经验：' + kept.join('；'));
    }
    // budget: drop oldest lines first (keep the ship block + the header)
    let text = lines.join('\n');
    while (text.length > MEMORY_BUDGET_CHARS && lines.length > 2) {
        lines.splice(1, 1);
        compressed += 1;
        text = lines.join('\n');
    }
    if (text.length > MEMORY_BUDGET_CHARS)
        text = text.slice(0, MEMORY_BUDGET_CHARS);
    const counts = `船 ${m !== undefined ? Math.min(2, m.recent?.length ?? 0) : 0} 条 / 星区 ${secs.length} 条 / 舰队 ${Math.min(3, store.lessons.length)} 条`;
    return { text, counts, compressed };
}
// ---------------------------------------------------------------------------
// Human-facing helpers (inspection + wipe)
// ---------------------------------------------------------------------------
export function describe() {
    const store = load();
    return JSON.stringify({
        path: FILE,
        updatedAt: store.updatedAt,
        ships: Object.keys(store.ships).length,
        sectors: Object.keys(store.sectors).length,
        lessons: store.lessons.length,
        ledger: Object.keys(store.ledger).length,
    }, null, 2);
}
/** Wipe the store (and keep a .bak of what was there). */
export function forget(shipName) {
    const store = load();
    if (shipName !== undefined && shipName !== '') {
        delete store.ships[shipName];
        for (const k of Object.keys(store.ledger))
            if (k.startsWith(shipName + '|'))
                delete store.ledger[k];
        const err = save();
        return err === null ? `forgot ship ${shipName}` : `forget failed: ${err}`;
    }
    try {
        if (fs.existsSync(FILE))
            fs.copyFileSync(FILE, FILE + '.bak');
    }
    catch {
        /* ignore */
    }
    cache = empty();
    const err = save();
    return err === null ? 'memory wiped (previous copy kept as .bak)' : `wipe failed: ${err}`;
}
//# sourceMappingURL=memory.js.map