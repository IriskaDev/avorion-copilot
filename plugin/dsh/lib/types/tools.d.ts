/**
 * tools.ts -- expose the GAME's abilities as DSH tools (design by the master, 2026-10-14).
 *
 * The master's words:
 *   "DSH side: I want a session to take over this DECIDE job, e.g. let you take it over."
 *   "Make it an MCP so you can verify things yourself."
 *   "Not every session may handle it -- only ONE session. Add a switch in the UI:
 *    opening it from this session means this session takes over, others give up."
 *
 * The real `defineTool` shape was copied from an ALREADY-INSTALLED plugin
 * (`@dsh-external/dsh-global-memory`) -- NOT guessed:
 *     defineTool({ name, description, parameters: {...}, output: {schema, render}, execute })
 *     ctx.effect(() => ctx.tools.register(...), 'label')
 * That plugin's `inject` includes 'tools', so ours does too.
 *
 * The exclusive single-session lease ("only one session may take over") is specified in
 * TAKEOVER.md and is the NEXT increment. This file wires up the three operations that are
 * independent of who owns the lease: read / order / set goal.
 *
 * NOTE: kept ASCII-only on purpose -- PowerShell 5.1 here-strings mangle Chinese text
 * occasionally (see docs/dev/native.md), and a broken plugin would need a DSH restart to detect.
 */
import type { RpcPeer } from './rpc.js';
import type { DecisionRecord } from './index.js';
/** The slice of ctx these tools need (structural, so we don't depend on unavailable cordis types). */
interface ToolCtx {
    logger?: {
        info?: (m: string) => void;
        warn?: (m: string) => void;
    };
    tools: {
        register(tool: unknown): void;
    };
    effect(fn: () => void | (() => void), label?: string): void;
}
/**
 * The delivery target for fleet decisions (2026-10-17, scope set by the owner).
 *
 * The owner's words: "no clone needed -- just deliver to the CURRENT session; the plugin's
 * role becomes the GAME RPC INTERFACE PROVIDER". So the target is ONE explicitly chosen
 * session id (his own session), never guessed and never listed as clone candidates.
 */
export interface CommanderBridge {
    /** current target session id, or undefined = no delivery (pure single-shot) */
    current(): string | undefined;
    /** designate (empty/null = clear). Returns the new state. */
    set(session: string | null): {
        session: string | null;
        leasedUntil: number | null;
    };
    /** read the persisted state without changing it */
    state(): {
        session: string | null;
        leasedUntil: number | null;
    };
    /** is the lease still fresh (status display only -- never a delivery gate) */
    leaseFresh(now?: number): boolean;
    /** the live agent for a session id, when the registry is reachable */
    agent(id: string): {
        status?: string;
    } | undefined;
    /**
     * The session that CALLED this tool, when the harness can tell us.
     *
     * Real implementation: `ctx.agents.currentInitiator()` -- the harness carries the
     * initiating Agent through the call (`dsh-goal-round-driver/lib/index.js:173`/`:237`).
     * This is what makes "open it from THIS session and this session takes over" work
     * without the owner having to copy a session id around.
     *
     * undefined = we cannot tell -> the tool must then REQUIRE an explicit `session=`.
     */
    currentSessionId?(): string | undefined;
    /** persistence path (so the owner knows which file holds the choice) */
    file?: string;
}
/** Wrap the callback-based RpcPeer.call into a Promise (tool execute is async). */
export declare function ask(peer: RpcPeer, cmd: string, data: unknown, timeoutSec?: number): Promise<{
    ok: boolean;
    data?: any;
    why?: string;
}>;
export declare function registerFleetTools(ctx: ToolCtx, peer: RpcPeer, decisionLog?: DecisionRecord[], commander?: CommanderBridge, 
/** ★ 待命裁定（2026-10-17 ✓）：召回/改目标时清掉同船的 None 冷却 ✓ */
standby?: {
    clear(ship: string): void;
}, 
/** the recall/query timeouts differ in tests; keep the production defaults */
opts?: {
    orderTimeoutSec?: number;
}): void;
export {};
