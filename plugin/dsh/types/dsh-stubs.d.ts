/**
 * 本地 tsc 编译用的**类型桩**（不是运行时实现 ✗）。
 *
 * 为什么要有它 ✗→✓：`@deepseek-ai/dsh-llm` / `@deepseek-ai/dsh-tools` 是 DSH 宿主的内部包，
 * 其中 dsh-tools 依赖的 `@deepseek-ai/dsh-type-meta` 不在公共 npm 上 ✗ —— 所以**离线**跑
 * `tsc -p tsconfig.json` 时解析不到它们的真实类型 ✓。
 *
 * 运行时**仍然用真包** ✓（DSH 宿主注入）—— 这个文件只影响**编译期**类型解析 ✓。
 * 它的形状对齐源码里**实际用到**的那几个符号（`createUserMessage` / `GenerateOptions` /
 * `StreamChunk` / `defineTool`）✓，与运行时真包的行为一致 ✓。
 *
 * ★ 这是**纯 ambient 声明**（没有顶层 import/export）✗✓ —— 顶层一旦 export 就变成模块，
 *   `declare module` 就失效 ✗。tsconfig 的 `paths` 指向本文件 ✓。
 */

declare module '@deepseek-ai/dsh-llm' {
  export interface MessageContentPart {
    type: string
    text?: string
    [k: string]: unknown
  }
  export interface UserMessageInput {
    content?: MessageContentPart[]
    source?: { kind?: string; [k: string]: unknown }
    [k: string]: unknown
  }
  /** 运行时桩见 test/llm-stub.mjs ✓ —— 这里只声明签名 ✓ */
  export function createUserMessage(input: UserMessageInput): unknown
}

declare module '@deepseek-ai/dsh-llm/types' {
  export interface GenerateOptions {
    provider?: string
    model?: string
    system?: string
    messages?: unknown[]
    maxTokens?: number
    temperature?: number
    [k: string]: unknown
  }
  export type StreamChunk =
    | { type: 'text-delta'; index?: number; text: string; [k: string]: unknown }
    | { type: 'reasoning-delta'; index?: number; text: string; [k: string]: unknown }
    | {
        type: 'finish'
        index?: number
        reason: {
          kind: string
          code?: string
          message?: string
          failure: { code?: string; message?: string; [k: string]: unknown }
          [k: string]: unknown
        }
        [k: string]: unknown
      }
}

declare module '@deepseek-ai/dsh-tools' {
  /** 运行时桩见 test/tools-stub.mjs ✓ —— 作用就是「原样返回定义」✓ */
  export function defineTool<T>(def: T): T
}
