/**
 * client.js -- the per-session "fleet commander" SWITCH (owner's request, 2026-10-17).
 *
 * Owner's words:
 *   "至于投递到哪个会话，我认为应该允许选择，我的想法是像代理插件一样，
 *    在会话上方做个开关，打开就切到对应会话，不再投递到之前会话。"
 *
 * WHY THIS FILE IS HAND-WRITTEN (and not a tsdown/tsc bundle)
 *   Every installed DSH client plugin ships as a plain `window.__ModuleLoader__.load({...})`
 *   factory -- see `C:\Users\IriskaDev\.dsh\plugins\dsh-super-injector\lib\client.js:1`
 *   and any stock client module, e.g.
 *   `...\@deepseek-ai\dsh-api-remotes\lib\client.js:1`. The stock build pipeline needs a DSH
 *   SOURCE checkout (`DSH_CHECKOUT/packages`, see dsh-super-injector/scripts/build.sh), and
 *   this machine has none (only `app.asar`). So this wrapper is written by hand in exactly the
 *   documented shape. It is plain ES2020 + React.createElement -- nothing to compile.
 *
 * WHERE IT ATTACHES (verified, with evidence)
 *   `conversation.session.header.actions` is a REAL slot:
 *     * declared `kind: 'list'`, `scope: 'session'` in
 *       `...\@deepseek-ai\dsh-client-ui-conversation\lib\types\client\contract\slots.d.ts:134`
 *     * actually injected by stock plugins, e.g.
 *       `...\@deepseek-ai\dsh-client-ui-jobs\lib\client.js:266-271`
 *       `...\@deepseek-ai\dsh-client-ui-schedule\lib\client.js:293-298`
 *   A session-scoped occupant receives `sessionId`: the jobs plugin destructures it directly at
 *   `...\@deepseek-ai\dsh-client-ui-jobs\lib\client.js:117` -> `function JobListAction({ sessionId, useSessions, t })`.
 *
 * HOW IT TALKS TO THE PLUGIN (verified)
 *   The host plugin registers an HTTP route with `ctx.webServer.register({kind:'prefix', path, handler})`
 *   and the client just `fetch`es it -- exactly the pattern in
 *   `C:\Users\IriskaDev\.dsh\plugins\dsh-super-injector\lib\index.js` (route `/super-injector/api`)
 *   and its client (`lib/client.js`, `API = "/super-injector/api"`).
 *   Our route is registered in `src/index.ts` (`/avorion-copilot/api/...`).
 *
 * SEMANTICS
 *   * ON  = THIS session is the one and only fleet commander (the previous one is displaced
 *           immediately: only one id is ever stored, so nothing is delivered to the old one).
 *   * OFF = no commander -> the plugin falls back to its own single-shot decision path.
 *   * The plugin is the GAME RPC INTERFACE PROVIDER; this switch only routes decision tasks.
 */
window.__ModuleLoader__.load({
  id: '@dsh-external/dsh-avorion-copilot',
  factory: (require) => {
    const module = { exports: {} }
    const exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    const react = require('react')
    const API = '/avorion-copilot/api'

    const inject = ['slots']

    const css = `
.aopc-switch{display:inline-flex;align-items:center;gap:6px;background:transparent;border:0;border-radius:6px;padding:3px 8px;font-size:12px;line-height:18px;cursor:pointer;color:var(--dsw-alias-label-tertiary)}
.aopc-switch:hover,.aopc-switch:focus-visible{color:var(--dsw-alias-label-primary)}
.aopc-switch.on{color:var(--dsw-alias-label-primary)}
.aopc-track{position:relative;flex:none;width:26px;height:15px;border-radius:999px;background:var(--dsw-alias-fill-l2);transition:background .12s}
.aopc-switch.on .aopc-track{background:#4a9eff}
.aopc-knob{position:absolute;top:2px;left:2px;width:11px;height:11px;border-radius:50%;background:#fff;transition:transform .12s}
.aopc-switch.on .aopc-knob{transform:translateX(11px)}
.aopc-label{white-space:nowrap}
.aopc-other{opacity:.6;font-size:11px}
`
    let cssTagged = false
    function ensureCss() {
      if (cssTagged || typeof document === 'undefined') return
      cssTagged = true
      const tag = document.createElement('style')
      tag.dataset.plugin = '@dsh-external/dsh-avorion-copilot'
      tag.textContent = css
      document.head.appendChild(tag)
    }

    /** Read the current commander state. `mine` = the session asking. */
    function read(mine) {
      return fetch(`${API}/commander?session=${encodeURIComponent(mine ?? '')}`)
        .then((r) => r.json())
        .catch(() => null)
    }

    /** Toggle: make THIS session the commander, or turn it off if it already is. */
    function toggle(mine) {
      return fetch(`${API}/commander/toggle`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ session: mine }),
      }).then((r) => r.json()).catch(() => null)
    }

    /**
     * The switch itself. `sessionId` is supplied by the harness for this session-scoped slot.
     * It renders NOTHING until we know the state, so a transient failure never puts a bogus
     * "off" in front of the owner.
     */
    function FleetCommanderSwitch({ sessionId }) {
      ensureCss()
      const [state, setState] = react.useState(null)
      const [busy, setBusy] = react.useState(false)

      react.useEffect(() => {
        let alive = true
        if (typeof sessionId !== 'string' || sessionId === '') return undefined
        read(sessionId).then((s) => { if (alive && s !== null) setState(s) })
        return () => { alive = false }
      }, [sessionId])

      if (typeof sessionId !== 'string' || sessionId === '' || state === null) return null

      const on = state.isMine === true
      const other = on ? null : state.commander
      const title = on
        ? 'Fleet commander: THIS session. Fleet decision tasks are delivered here.'
        : other !== null && other !== undefined
          ? `Fleet commander: ${other}. Turn this on to take over (it will be displaced).`
          : 'Fleet commander: off. Decisions use the plugin single-shot path.'

      return react.createElement('button', {
        type: 'button',
        className: 'aopc-switch' + (on ? ' on' : ''),
        title,
        disabled: busy,
        onClick: () => {
          if (busy) return
          setBusy(true)
          toggle(sessionId).then((s) => {
            if (s !== null) setState(s)
            setBusy(false)
          })
        },
      },
        react.createElement('span', { className: 'aopc-track' },
          react.createElement('span', { className: 'aopc-knob' })),
        react.createElement('span', { className: 'aopc-label' },
          on ? 'Fleet 指挥官' : '接管舰队'),
        other !== null && other !== undefined
          ? react.createElement('span', { className: 'aopc-other' }, '· 别处')
          : null,
      )
    }

    function apply(ctx) {
      ctx.effect(() => ctx.slots.inject('conversation.session.header.actions', () => ctx.slots.register({
        name: 'conversation.session.header.actions',
        id: 'avorion-fleet-commander',
        order: 30,
      }, FleetCommanderSwitch)))
    }

    exports.apply = apply
    exports.inject = inject
    return module.exports
  },
})
