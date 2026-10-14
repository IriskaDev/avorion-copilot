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
 * occasionally (see NATIVE.md), and a broken plugin would need a DSH restart to detect.
 */
import type { RpcPeer } from './rpc.js';
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
export declare function registerFleetTools(ctx: ToolCtx, peer: RpcPeer): void;
export {};
