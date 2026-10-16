/**
 * agent-toolcall-probe.mjs -- PROOF that the REAL DeepSeek adapter does tool calling.
 *
 * What this proves (design pass 2026-10-17, task "she needs to be an AGENT"):
 *   1. `GenerateOptions.tools` reaches the provider: the adapter's
 *      `requestWithMessages` maps it to wire `tools: [{type:'function', ...}]`
 *      (dsh-llm-deepseek/lib/index.js:228-244).
 *   2. The provider answers with a tool call and the adapter turns it into the
 *      harness vocabulary: `block-end` carrying a `tool-call` block, a
 *      `tool-call-delta` stream, and `finish` with `reason.kind === 'tool-calls'`
 *      (index.js:1192, 1291-1307, 1134).
 *   3. Feeding a `tool-result` message back produces a second, ordinary answer.
 *
 * It uses a DIRECT `DeepSeekAdapter` instance (no cordis Context, no DSH host),
 * because the adapter's `stream()` is the whole transport: everything above it
 * in `LlmRuntime` is registry/replay/waterfall bookkeeping that this probe does
 * not need. That keeps the probe honest AND runnable while DSH and the game are
 * live (it never touches either).
 *
 * Run:  node test/agent-toolcall-probe.mjs
 * Skips (exit 0) when no API key can be found -- it must never be a hard gate.
 *
 * NOTE: kept ASCII in code; Chinese only in comments is avoided on purpose --
 * this file is executed by plain node, but keeping it ASCII avoids any console
 * codepage question in PowerShell 5.1.
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { registerHooks } from 'node:module'
import { pathToFileURL } from 'node:url'

// The runtime packages live in the globally installed dsh checkout on this
// machine. Resolve every @deepseek-ai/* import from there so this probe needs
// no node_modules of its own (the plugin builds links only transiently).
const DSH_NM = 'C:\\nvm4w\\nodejs\\node_modules\\@deepseek-ai\\dsh\\node_modules'
// Extra hoist roots seen on this machine; the profile root is the complete one.
const EXTRA_NM = [
  'C:\\Users\\IriskaDev\\.dsh\\profiles\\node_modules',
  'C:\\Users\\IriskaDev\\.dsh\\profiles\\desktop\\node_modules',
]
const ROOTS = [DSH_NM, ...EXTRA_NM]
if (!fs.existsSync(DSH_NM)) {
  console.log(`SKIP: dsh runtime node_modules not found at ${DSH_NM}`)
  process.exit(0)
}

registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith('@deepseek-ai/')) {
      for (const root of ROOTS) {
        // Let Node's own package resolution do the work (exports maps, "main",
        // "module", ...) by asking from a file inside the candidate root.
        try {
          const from = pathToFileURL(path.join(root, 'probe-anchor.mjs')).href
          return { url: import.meta.resolve(specifier, from), shortCircuit: true }
        } catch {
          /* try the next root */
        }
      }
    }
    return next(specifier, context)
  },
})

/** Read one credential ref out of the DSH credentials file (never printed). */
function readCredential(ref) {
  if (process.env[ref] !== undefined && process.env[ref].length > 0) {
    return process.env[ref]
  }
  const file = path.join(os.homedir(), '.dsh', '.credentials.yaml')
  if (!fs.existsSync(file)) return undefined
  const text = fs.readFileSync(file, 'utf8')
  // refs: \n  NAME: value
  const m = new RegExp(`^\\s{2}${ref}:\\s*(\\S+)\\s*$`, 'm').exec(text)
  return m === null ? undefined : m[1]
}

const apiKey = readCredential('DEEPSEEK_API_KEY')
if (apiKey === undefined) {
  console.log('SKIP: no DEEPSEEK_API_KEY in env or ~/.dsh/.credentials.yaml')
  process.exit(0)
}

const { DeepSeekAdapter } = await import('@deepseek-ai/dsh-llm-deepseek')
const { createUserMessage, createToolResultMessage, resolveRetryPolicy } = await import('@deepseek-ai/dsh-llm')

// Build the validated connection facts by hand instead of calling the plugin's
// `resolveAdapterOptions`: that helper pulls in schemastery, whose install in
// this machine's global dsh mount is an empty junction. Every field below is a
// documented default (dsh-llm-deepseek/lib/types/adapter.d.ts:112-133).
const connection = {
  baseURL: process.env.DEEPSEEK_BASE_URL ?? 'https://api.deepseek.com',
  apiKeyEnv: 'DEEPSEEK_API_KEY',
  defaults: {},
  maxTokens: 8192,
  defaultContextWindow: 1000000,
  models: [],
  streamIdleTimeoutMs: 300000,
  maxRequestFilesBytes: 128 * 1024 * 1024,
  maxInlineRequestImageBytes: 20 * 1024 * 1024,
  maxImagesPerRequest: 600,
  imageOffloadByteQuantum: 64 * 1024 * 1024,
  inlineImageOffloadByteQuantum: 10 * 1024 * 1024,
  imageOffloadCountQuantum: 20,
  filesApiTimeoutMs: 60000,
  filePolicy: { expiresAfterSeconds: 604800, refreshMarginSeconds: 3600, quotaCleanupBatch: 100 },
  retryPolicy: resolveRetryPolicy(undefined, 'probe'),
}
console.log('provider route : deepseek-official')
console.log('baseURL        : ' + connection.baseURL)
console.log('key            : present (len ' + apiKey.length + ', not printed)')

const adapter = new DeepSeekAdapter({
  options: () => connection,
  resolveApiKey: async () => apiKey,
  resolveUserId: () => 'probe-user',
  prepareExtensions: async () => ({ fields: {}, accept: async () => {} }),
})

// ---------------------------------------------------------------- the tool
const tools = [
  {
    name: 'sector_facts',
    description: 'Return facts about one galaxy sector (richness, material probability, distance from centre).',
    parameters: {
      type: 'object',
      properties: {
        x: { type: 'integer', description: 'sector x' },
        y: { type: 'integer', description: 'sector y' },
      },
      required: ['x', 'y'],
    },
  },
  {
    name: 'ship_card',
    description: 'Return the capability card of one fleet ship, including its current sector.',
    parameters: {
      type: 'object',
      properties: { ship: { type: 'string', description: 'ship name' } },
      required: ['ship'],
    },
  },
]

const MODEL = 'deepseek-flash'
const SYSTEM = 'You are a fleet operations agent. Use the provided tools to look up facts before deciding. ' +
  'When you have enough facts, answer with one short line.'

/** Collect one streamed model call into blocks, text, reasoning and the finish reason. */
async function callOnce(messages, label) {
  const calls = []
  const texts = []
  const reasonings = []
  let finish
  console.log(`\n=== ${label} ===`)
  const stream = adapter.stream({
    provider: 'deepseek-official',
    model: MODEL,
    system: SYSTEM,
    messages,
    tools,
    maxTokens: 2000,
    temperature: 0.2,
  })
  for await (const chunk of stream) {
    if (chunk.type === 'text-delta') texts.push(chunk.text)
    else if (chunk.type === 'reasoning-delta') reasonings.push(chunk.text)
    else if (chunk.type === 'tool-call-delta') {
      console.log(`  tool-call-delta  index=${chunk.index} id=${chunk.id} name=${chunk.name ?? ''} args+=${JSON.stringify(chunk.argumentsDelta)}`)
    } else if (chunk.type === 'block-end') {
      if (chunk.block.type === 'tool-call') {
        calls.push(chunk.block)
        console.log(`  block-end        tool-call name=${chunk.block.name} id=${chunk.block.id} args=${chunk.block.arguments}`)
      }
    } else if (chunk.type === 'finish') {
      finish = chunk.reason
      console.log(`  finish           kind=${chunk.reason.kind}`)
    }
  }
  console.log(`  text             ${JSON.stringify(texts.join('').slice(0, 200))}`)
  console.log(`  reasoning chars  ${reasonings.join('').length}`)
  return { calls, text: texts.join(''), reasoning: reasonings.join(''), finish }
}

// ------------------------------------------------------- turn 1: expect a call
const prompt = 'I need to know what sector (12,-7) looks like before I send a miner there. ' +
  'Look it up, then tell me in one line whether it is worth mining.'
const turn1 = await callOnce(
  [createUserMessage({ content: [{ type: 'text', text: prompt }], source: { kind: 'user' } })],
  'turn 1 -- tool schemas attached',
)

const checks = []
checks.push(['turn 1 finished with tool-calls', turn1.finish?.kind === 'tool-calls'])
checks.push(['adapter surfaced >= 1 tool-call block', turn1.calls.length >= 1])
checks.push(['tool name is one of the offered tools', ['sector_facts', 'ship_card'].includes(turn1.calls[0]?.name)])
let parsedArgs = undefined
try { parsedArgs = JSON.parse(turn1.calls[0]?.arguments ?? '') } catch { /* reported below */ }
checks.push(['tool arguments are raw JSON that parses', parsedArgs !== undefined])

// ------------------------------------------- turn 2: feed the result back
// The assistant message MUST carry the tool-call block (and its reasoning, which
// the adapter replays as reasoning_content -- required on tool-call turns in
// thinking mode: dsh-llm-deepseek/lib/types/types.d.ts:75-90).
const assistantBlocks = []
if (turn1.reasoning.length > 0) assistantBlocks.push({ type: 'reasoning', text: turn1.reasoning })
if (turn1.text.length > 0) assistantBlocks.push({ type: 'text', text: turn1.text })
assistantBlocks.push(...turn1.calls)

const toolResultText = JSON.stringify(
  { sector: { x: parsedArgs?.x ?? 12, y: parsedArgs?.y ?? -7 }, richness: 0.62, materialProbability: { Iron: 0.41, Titanium: 0.18 }, distanceFromCentre: 13.9 },
  null, 2,
)

let turn2
if (turn1.calls.length >= 1) {
  turn2 = await callOnce(
    [
      createUserMessage({ content: [{ type: 'text', text: prompt }], source: { kind: 'user' } }),
      { id: 'probe-assistant-1', role: 'assistant', content: assistantBlocks, source: { kind: 'model', provider: 'deepseek-official', model: MODEL } },
      createToolResultMessage({
        callId: turn1.calls[0].id,
        content: [{ type: 'text', text: toolResultText }],
        isError: false,
      }),
    ],
    'turn 2 -- tool result fed back',
  )
  checks.push(['turn 2 finished normally (not another tool call)', turn2.finish?.kind === 'stop'])
  checks.push(['turn 2 produced a final answer', turn2.text.trim().length > 0])
} else {
  checks.push(['turn 2 skipped (turn 1 produced no tool call)', false])
  checks.push(['turn 2 skipped', false])
}

console.log(`\n${'='.repeat(72)}\n## probe result\n${'='.repeat(72)}`)
let failed = 0
for (const [label, ok] of checks) {
  console.log(`${ok ? '  OK  ' : '  FAIL'} ${label}`)
  if (!ok) failed++
}
console.log(`\n${checks.length - failed}/${checks.length} passed`)
console.log('VERDICT: ' + (failed === 0
  ? 'NATIVE TOOL CALLING WORKS end to end through the real adapter.'
  : 'tool calling did NOT behave as expected -- see the failing line above.'))
process.exit(failed === 0 ? 0 : 1)
