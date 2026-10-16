/**
 * client.js -- the per-session "fleet commander" SWITCH (owner's request, 2026-10-17).
 *
 * Owner's words:
 *   "至于投递到哪个会话，我认为应该允许选择，我的想法是像代理插件一样，
 *    在会话上方做个开关，打开就切到对应会话，不再投递到之前会话。"
 *
 * WHY THIS FILE IS HAND-WRITTEN (and not a tsdown/tsc bundle)
 *   Every DSH client plugin ships as a plain `window.__ModuleLoader__.load({...})`
 *   factory. The stock build pipeline needs a DSH SOURCE checkout, and the desktop
 *   app here installs only `app.asar`. So this wrapper is written by hand in exactly
 *   the shipped shape. It is plain ES2020 + React.createElement -- nothing to compile.
 *
 * HOW IT IS PICKED UP (verified on the running desktop app, DSH 0.2.0-rc.2)
 *   `dsh-client-modules` scans the host Loader's entries for packages declaring
 *   `dsh.client` (`platform: 'web'`) and serving `exports["./client"]`
 *   (docs: reference/subsystems/client-modules). A `link:`-installed external plugin
 *   IS a Loader entry (its host half loads), so its bundle is composed into
 *   `window.__DSH_BOOT__` and served under `/plugins/??<pkg>/client.js&rev=<rev>`.
 *   Observed on this machine -- the desktop host's own index really carries the row:
 *     {"id":"@dsh-external/dsh-avorion-copilot","url":"plugins/??@dsh-external/dsh-avorion-copilot/client.js&rev=8262b5fb7e75", ...}
 *   and that URL answers 200 with this very file. No `pnpm run dev:web` and no
 *   build step is involved: the host reads `lib/client.js` from disk at boot.
 *
 * WHERE IT ATTACHES (verified)
 *   `conversation.session.header.actions` is a REAL slot of the shipped hierarchy
 *   (docs: reference/subsystems/slots -> Current hierarchy -> main.conversation ->
 *   conversation.header -> conversation.session.header -> .actions).
 *   It is a `list` slot: cells are addressed by `id` and ordered by `order`.
 *   A session-scoped occupant receives `sessionId` -- the stock jobs plugin
 *   destructures it directly (`dsh-client-ui-jobs/lib/client.js`, `JobListAction`).
 *   Registration pattern copied verbatim from the docs and from that stock plugin:
 *     ctx.slots.inject(NAME, () => ctx.slots.register({ name, id, order }, Component))
 *
 * HOW IT TALKS TO THE PLUGIN
 *   The host half registers `prefix /avorion-copilot/api` on `ctx.webServer`
 *   (see `src/index.ts` -> `mountCommanderApi`) and this file just `fetch`es it.
 *
 * ★ WHY IT USED TO BE INVISIBLE (fixed 2026-10-17, second pass)
 *   Nothing was wrong with the bundle: it loaded and registered fine. The host had
 *   registered NO route, because `apply()` asked for `ctx.get('webServer')` BEFORE
 *   that service existed and then silently gave up (proved by the plugin's own
 *   `decisions.live.log` line "拿不到 webServer -> 没有 UI 开关"). A 404 made
 *   `read()` resolve to null, and this component renders nothing until it knows the
 *   state -- so the switch was a correct-but-invisible null. The host now waits for
 *   the service, and any transport failure is logged (never silently swallowed).
 */
window.__ModuleLoader__.load({
  id: '@dsh-external/dsh-avorion-copilot',
  factory: (require) => {
    const module = { exports: {} }
    const exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    const react = require('react')
    const API = '/avorion-copilot/api'
    const SLOT = 'conversation.session.header.actions'
    const PLUGIN = '@dsh-external/dsh-avorion-copilot'

    /** Required service: the UI slot registry. */
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
      tag.dataset.plugin = PLUGIN
      tag.textContent = css
      document.head.appendChild(tag)
    }

    /**
     * Read the current commander state. `mine` = the session asking.
     * A failure is reported (once) instead of vanishing: a missing host route used
     * to look exactly like "this feature does not exist".
     */
    let complained = false
    function fail(what, error) {
      if (complained) return
      complained = true
      // eslint-disable-next-line no-console
      console.error(
        `[avorion-copilot] ${what}: ${API} is unreachable (${String(error)}). ` +
        'The fleet-commander switch needs the host HTTP route; use the fleet_commander tool meanwhile.',
      )
    }

    function read(mine) {
      return fetch(`${API}/commander?session=${encodeURIComponent(mine ?? '')}`)
        .then((r) => {
          if (!r.ok) throw new Error(`HTTP ${r.status}`)
          return r.json()
        })
        .catch((error) => {
          fail('read', error)
          return null
        })
    }

    /** Toggle: make THIS session the commander, or turn it off if it already is. */
    function toggle(mine) {
      return fetch(`${API}/commander/toggle`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ session: mine }),
      })
        .then((r) => {
          if (!r.ok) throw new Error(`HTTP ${r.status}`)
          return r.json()
        })
        .catch((error) => {
          fail('toggle', error)
          return null
        })
    }

    /**
     * The switch itself. `sessionId` is supplied by the harness for this
     * session-scoped slot. It renders NOTHING until we know the state, so a
     * transient failure never puts a bogus "off" in front of the owner.
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

    /** Client plugin body: contribute the header action (docs' exact pattern). */
    function apply(ctx) {
      ctx.slots.inject(SLOT, () => ctx.slots.register({
        name: SLOT,
        id: 'avorion-fleet-commander',
        order: 30,
      }, FleetCommanderSwitch))
    }

    exports.apply = apply
    exports.inject = inject
    return module.exports
  },
})
