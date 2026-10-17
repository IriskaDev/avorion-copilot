/**
 * 离线自测用的 @deepseek-ai/dsh-llm 桩。
 *
 * npm 装好的 dsh-llm 无法脱离 DSH 单独加载（它的传递依赖 @deepseek-ai/cordis 在 npm 包里
 * 是个空目录），离线测试用不着真包，这里只提供插件实际用到的那个构造器。
 */
let counter = 0

export function createUserMessage(input) {
  counter += 1
  return {
    id: `stub-user-${counter}`,
    role: 'user',
    content: input.content,
    source: input.source ?? { kind: 'user' },
  }
}
