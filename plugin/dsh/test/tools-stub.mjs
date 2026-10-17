/**
 * 离线自测用的 @deepseek-ai/dsh-tools 桩。
 *
 * 与 llm-stub.mjs 同一个原因：插件只有在 DSH 宿主里才拿得到真的 dsh-tools。
 * 离线测试只用到 defineTool 一个符号，而它的作用就是「原样返回定义」。
 */
export function defineTool(def) {
  return def
}
