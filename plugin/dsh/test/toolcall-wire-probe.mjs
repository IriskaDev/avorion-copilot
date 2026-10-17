/**
 * toolcall-wire-probe.mjs -- PROOF that the model ROUTE we use does TOOL CALLING.
 *
 * Design pass 2026-10-17 for the "she must be a real AGENT" upgrade.
 * Run:  node test/toolcall-wire-probe.mjs        (exit 0 = proven, exit 1 = not)
 * Skips with exit 0 when no API key is available, so it is never a hard gate.
 *
 * WHY THIS EXISTS BESIDE agent-toolcall-probe.mjs (which another agent wrote and
 * which drives the real DeepSeekAdapter):
 *   That adapter package cannot be imported standalone on this machine -- its
 *   entry chain resolves @deepseek-ai/schemastery through a junction that holds
 *   no files -- so the adapter-driven probe hangs/fails here while DSH itself
 *   (which resolves these packages from its own profile root) runs fine.
 *   Rather than fake the adapter, this probe speaks the provider WIRE protocol
 *   directly, which is exactly what the adapter speaks, so it proves the
 *   CAPABILITY with real output.
 *
 * Adapter-side evidence is read from source (not executed):
 *   dsh-llm-deepseek/lib/index.js:228-244   tools -> wire `tools: [function]`
 *   dsh-llm-deepseek/lib/index.js:111-124   assistant text+reasoning+tool_calls
 *   dsh-llm-deepseek/lib/index.js:1291-1307 streaming tool-call deltas
 *   dsh-llm-deepseek/lib/index.js:1134      finish reason 'tool-calls'
 *   dsh-llm-deepseek/lib/types/types.d.ts:75-90  reasoning_content REQUIRED on
 *                                                tool-call turns in thinking mode
 *   dsh-llm/lib/types/types.d.ts:397-423    ToolSchema / GenerateOptions.tools
 *
 * WHAT IT PROVES (all four matter for the agent design):
 *   1. `tools` are accepted and the model CHOOSES to call one.
 *   2. Tool arguments arrive as CONCATENATED deltas (the classic bug: a naive
 *      reader sees `{` then `"` ... and gets invalid JSON). The probe
 *      concatenates by `index` and parses -- the algorithm a real tool loop must
 *      use. (This probe's own first draft failed exactly here.)
 *   3. `reasoning_content` is produced and passed back on the tool-call turn.
 *   4. A `role: "tool"` result with the matching `tool_call_id` yields a normal
 *      final answer.
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const BASE_URL = process.env.DEEPSEEK_BASE_URL ?? 'https://api.deepseek.com'
const MODEL = process.env.COPILOT_PROBE_MODEL ?? 'deepseek-flash'

function readCredential(ref) {
  if (typeof process.env[ref] === 'string' && process.env[ref].length > 0) return process.env[ref]
  const file = path.join(os.homedir(), '.dsh', '.credentials.yaml')
  if (!fs.existsSync(file)) return undefined
  const m = new RegExp(`^\\s{2}${ref}:\\s*(\\S+)\\s*$`, 'm').exec(fs.readFileSync(file, 'utf8'))
  return m === null ? undefined : m[1]
}

const apiKey = readCredential('DEEPSEEK_API_KEY')
if (apiKey === undefined) {
  console.log('SKIP: no DEEPSEEK_API_KEY in env or ~/.dsh/.credentials.yaml')
  process.exit(0)
}

const TOOLS = [{
  type: 'function',
  function: {
    name: 'sector_facts',
    description: 'Return facts about one galaxy sector (richness, material probability).',
    parameters: {
      type: 'object',
      properties: { x: { type: 'integer' }, y: { type: 'integer' } },
      required: ['x', 'y'],
    },
  },
}]

/** One streamed call; assembles tool calls by index the way a real loop must. */
async function call(messages, label) {
  const body = { model: MODEL, stream: true, stream_options: { include_usage: true }, messages, tools: TOOLS }
  const ac = new AbortController()
  const timer = setTimeout(() => ac.abort(), 60000)
  const out = { status: null, errBody: '', text: '', reasoning: '', calls: [], finish: null }
  try {
    const res = await fetch(`${BASE_URL}/chat/completions`, {
      method: 'POST',
      headers: { authorization: `Bearer ${apiKey}`, 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: ac.signal,
    })
    out.status = res.status
    if (!res.ok) {
      out.errBody = await res.text()
    } else {
      const reader = res.body.getReader()
      const dec = new TextDecoder()
      let buf = ''
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        buf += dec.decode(value, { stream: true })
        let nl
        while ((nl = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, nl).trim()
          buf = buf.slice(nl + 1)
          if (!line.startsWith('data:')) continue
          const payload = line.slice(5).trim()
          if (payload === '[DONE]') continue
          const json = JSON.parse(payload)
          const choice = json.choices?.[0]
          if (choice === undefined) continue
          if (choice.finish_reason) out.finish = choice.finish_reason
          const delta = choice.delta ?? {}
          if (delta.content) out.text += delta.content
          if (delta.reasoning_content) out.reasoning += delta.reasoning_content
          for (const tc of delta.tool_calls ?? []) {
            const i = tc.index ?? 0
            out.calls[i] = out.calls[i] ?? { id: undefined, name: undefined, args: '' }
            if (tc.id) out.calls[i].id = tc.id
            if (tc.function?.name) out.calls[i].name = tc.function.name
            if (tc.function?.arguments) out.calls[i].args += tc.function.arguments
          }
        }
      }
    }
  } catch (error) {
    console.log(`ERR ${error.name}: ${error.message}`)
  } finally {
    clearTimeout(timer)
  }
  console.log(`=== ${label} ===  HTTP ${out.status}${out.errBody ? '  BODY ' + out.errBody.slice(0, 400) : ''}`)
  console.log(`  finish_reason : ${out.finish}`)
  console.log(`  text          : ${JSON.stringify(out.text.slice(0, 300))}`)
  console.log(`  reasoning     : ${out.reasoning.length} chars`)
  console.log(`  tool calls    : ${JSON.stringify(out.calls)}`)
  return out
}

const PROMPT = 'Use the sector_facts tool to look up sector (12,-7), then tell me in one line whether it is worth mining.'
const turn1 = await call([{ role: 'user', content: PROMPT }], 'turn 1 -- tools attached')

let turn2 = null
if (turn1.calls.length > 0) {
  // The assistant turn MUST be replayed with its tool_calls AND its reasoning
  // (reasoning_content is required on tool-call turns in thinking mode).
  const assistant = {
    role: 'assistant',
    content: turn1.text || '',
    tool_calls: turn1.calls.map((c) => ({ id: c.id, type: 'function', function: { name: c.name, arguments: c.args } })),
  }
  if (turn1.reasoning.length > 0) assistant.reasoning_content = turn1.reasoning
  turn2 = await call([
    { role: 'user', content: PROMPT },
    assistant,
    {
      role: 'tool',
      tool_call_id: turn1.calls[0].id,
      content: JSON.stringify({ sector: { x: 12, y: -7 }, richness: 0.62, materialProbability: { Iron: 0.41, Titanium: 0.18 } }),
    },
  ], 'turn 2 -- tool result fed back')
}

const checks = [
  ['turn 1 finished with reason "tool_calls"', turn1.finish === 'tool_calls'],
  ['turn 1 tool call has id + name + non-empty args', turn1.calls.length > 0 && !!turn1.calls[0].id && !!turn1.calls[0].name && turn1.calls[0].args.length > 0],
  ['turn 1 concatenated args parse as JSON', turn1.calls.length > 0 && (() => { try { JSON.parse(turn1.calls[0].args); return true } catch { return false } })()],
  ['turn 1 produced reasoning_content (thinking-mode passback)', turn1.reasoning.length > 0],
  ['turn 2 answered (HTTP 200)', turn2 !== null && turn2.status === 200],
  ['turn 2 finished with reason "stop"', turn2 !== null && turn2.finish === 'stop'],
  ['turn 2 produced a final answer', turn2 !== null && turn2.text.trim().length > 0],
]

console.log(`\n${'='.repeat(72)}\n## probe result\n${'='.repeat(72)}`)
let failed = 0
for (const [label, ok] of checks) {
  console.log(`${ok ? '  OK  ' : '  FAIL'} ${label}`)
  if (!ok) failed++
}
console.log(`\n${checks.length - failed}/${checks.length} passed`)
console.log('VERDICT: ' + (failed === 0
  ? 'native tool calling works on this route -- a hand-rolled tool loop is viable.'
  : 'tool calling did NOT behave as expected (see the failing lines).'))
process.exit(failed === 0 ? 0 : 1)
