import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);
const m = require('../lib/memory.js')
m.forget()                                        // 干净起步（旧副本留 .bak ✓）
m.rememberStart('DEMO-00001', 'Trade', { goodName: 'Force Generator', attackChance: 0.07 }, '-403,77')
m.rememberOutcome('DEMO-00001', { at: new Date().toISOString(), action: 'Trade', goodName: 'Force Generator', sector: '-403,77', busySeconds: 1080, requestedHours: 0.6, endedEarly: false })
m.rememberOutcome('DEMO-00001', { at: new Date().toISOString(), action: 'Mine', sector: '-399,81', busySeconds: 60, requestedHours: 2, endedEarly: true })
m.rememberStart('DEMO-00001', 'Trade', { goodName: 'Drill' }, '-399,81')
console.log('--- 存储概况 ---'); console.log(m.describe())
const r = m.retrieve('DEMO-00001', ['-403,77', '-399,81'])
console.log('--- 模型这一轮会看到的历史（' + r.counts + '，压缩 ' + r.compressed + ' 条）---')
console.log(r.text)
console.log('--- 字符数: ' + r.text.length + ' / 预算 ' + m.MEMORY_BUDGET_CHARS + ' ---')
m.forget('DEMO-00001')
console.log('--- 清理后 ---'); console.log(m.describe())


