// 检查 src/content.ts 里手写的组件 JSON 能被 App 的渲染器解析（用 Renderer/core.js 的同一个解析函数）。
// 用法：node scripts/check-content.mjs
import { createRequire } from 'node:module';
import * as content from '../src/content.ts';

const require = createRequire(import.meta.url);
const core = require('../../Renderer/core.js');

let failed = 0;
for (const [name, value] of Object.entries(content)) {
  const markdown = typeof value === 'string' ? value : value && typeof value.answer === 'string' ? value.answer : null;
  if (!markdown) continue;
  for (const fence of core.extractFences(markdown)) {
    const result = core.parseComponent(fence.language, fence.content);
    const warnings = (result.warnings || []).join('；');
    if (result.ok) console.log(`✓ ${name} · ${fence.language}${warnings ? '（提示：' + warnings + '）' : ''}`);
    else {
      failed++;
      console.log(`✗ ${name} · ${fence.language}：${result.error}`);
    }
  }
}
process.exit(failed ? 1 : 0);
