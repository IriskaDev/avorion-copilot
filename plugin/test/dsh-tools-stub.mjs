/**
 * dsh-tools-stub.mjs —— `@deepseek-ai/dsh-tools` 的离线替身（2026-10-17 加 ✓）
 *
 * 为什么需要它 ✗→✓：
 *   `lib/tools.js` 顶部 `import { defineTool } from '@deepseek-ai/dsh-tools'` ✓ ——
 *   而**离线测试环境里没有这个包**（插件的 `node_modules` 是 build.ps1 建的**编译期**联接，
 *   跑完就删 ✓；真正运行时由 DSH 宿主解析 ✓）。
 *   → 于是 `node test/harness.mjs` 直接 `ERR_MODULE_NOT_FOUND` ✗✓
 *     （**不是新问题** ✓ —— 本改动之前就是这样 ✓）。
 *
 * ★ 这里只**照形状**提供 `defineTool` ✓（官方形状抄自已装的 dsh-global-memory ✓）：
 *     defineTool({ name, description, parameters, output, execute })
 *   它做的唯一一件事是**校验并返回**定义 ✓ —— 离线测试要的是"插件能加载、
 *   工具能注册"✓，不是"工具真的被模型调用"（那是实机的活儿 ✓）。
 *
 * 用法（在测试文件里注册一个解析钩子 ✓，见 `test/harness.mjs` ✓）：
 *     registerHooks({ resolve(spec, ctx, next) {
 *       if (spec === '@deepseek-ai/dsh-tools') return { url: new URL('./dsh-tools-stub.mjs', import.meta.url).href, shortCircuit: true }
 *       return next(spec, ctx)
 *     }})
 */

export function defineTool(def) {
  if (def === null || typeof def !== 'object') throw new TypeError('defineTool: definition must be an object')
  if (typeof def.name !== 'string' || def.name === '') throw new TypeError('defineTool: name is required')
  if (typeof def.execute !== 'function') throw new TypeError('defineTool: execute is required')
  return {
    name: def.name,
    description: def.description ?? '',
    parameters: def.parameters ?? {},
    output: def.output,
    execute: def.execute,
  }
}

export default { defineTool }
