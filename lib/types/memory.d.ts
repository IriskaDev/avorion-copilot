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
/** Retrieval budget for the memory section of a prompt (characters). */
export declare const MEMORY_BUDGET_CHARS = 1600;
export interface ShipOutcome {
    at: string;
    action: string;
    goodName?: string;
    sector?: string;
    /** wall-clock seconds it actually stayed busy (0 when unknown). */
    busySeconds?: number;
    /** what the model asked for, in hours, when known. */
    requestedHours?: number;
    /** heuristic: came back far earlier than requested -> likely attacked / recalled. */
    endedEarly?: boolean;
    credits?: number;
}
export interface ShipMemory {
    firstSeen: string;
    lastSeen: string;
    /** actions it has actually run, with counts (the "proven specialty"). */
    actions: Record<string, number>;
    jobsStarted: number;
    jobsCompleted: number;
    jobsEndedEarly: number;
    creditsTotal: number;
    creditsSamples: number;
    /** rolling human-readable summary so the raw list can stay short. */
    summary: string;
    recent: ShipOutcome[];
}
export interface SectorMemory {
    firstSeen: string;
    lastSeen: string;
    /** material index seen as the best mineable tier here (1 = Iron .. 7 = Avorion). */
    bestOreTier?: number;
    /** best observed goods/route name. */
    bestGood?: string;
    /** highest measured ambush chance we were willing to run, and the worst we saw. */
    minAttackChance?: number;
    maxAttackChance?: number;
    /** how many jobs we ran here, and how many needed an escort. */
    jobs: number;
    escortNeeded: number;
    note?: string;
}
export interface LedgerEntry {
    at: string;
    action: string;
    goodName?: string;
    value: number;
}
export interface MemoryStore {
    version: 1;
    updatedAt: string;
    ships: Record<string, ShipMemory>;
    sectors: Record<string, SectorMemory>;
    lessons: string[];
    /** per ship+"|"+action(+"|"+good) realized results. */
    ledger: Record<string, LedgerEntry>;
}
export declare function memoryPath(): string;
export declare function load(force?: boolean): MemoryStore;
/** Atomic, bounded, best-effort save. Returns an error string, or null on success. */
export declare function save(): string | null;
/** Remember that we handed this ship a job (called when the order is accepted). */
export declare function rememberStart(shipName: string, action: string, params: Record<string, unknown>, sector?: string): void;
/** Remember how a job actually ended. */
export declare function rememberOutcome(shipName: string, o: ShipOutcome): void;
/** Map knowledge: what we learned about a sector by doing jobs there. */
export declare function noteSectorInternal(store: MemoryStore, key: string, info: {
    action?: string;
    goodName?: string;
    attackChance?: number;
    oreTier?: number;
    escortNeeded?: boolean;
}): void;
export declare function noteSector(key: string, info: Parameters<typeof noteSectorInternal>[2]): void;
/** Fleet-level lesson (deduplicated, newest last). */
export declare function addLesson(text: string): void;
/**
 * Build the memory section for ONE decision: this ship + the sectors the fresh plan touches
 * + a small fleet digest. Never the whole store. Honors MEMORY_BUDGET_CHARS.
 */
export declare function retrieve(shipName: string, sectors: string[]): {
    text: string;
    counts: string;
    compressed: number;
};
export declare function describe(): string;
/** Wipe the store (and keep a .bak of what was there). */
export declare function forget(shipName?: string): string;
