// 只重新生成一个组件（第九版）：提示卡片上的行号来自 markdown-it 的 token.map，
// Swift 按这几行从消息原文里取出代码块（ComponentRepair.block），所以行号必须正好框住这个代码块。
const test = require('node:test');
const assert = require('node:assert/strict');
const markdownit = require('../Renderer/vendor/markdown-it.min.js');
const core = require('../Renderer/core.js');

function fenceLines(src) {
  const md = markdownit({ html: false, linkify: true });
  core.mathPlugin(md, { renderMath: (tex) => tex });
  const found = [];
  md.renderer.rules.fence = (tokens, idx) => {
    found.push({ language: tokens[idx].info.trim(), map: tokens[idx].map });
    return '';
  };
  md.render(src, { streaming: false });
  return found;
}

/** 和 Swift 的 ComponentRepair.block 一样：按 [开头, 结尾) 取行。 */
const slice = (src, [start, end]) => src.split('\n').slice(start, end).join('\n');

test('行号框住顶层的组件代码块', () => {
  const block = '```graph\n{"functions": [{"expr": "x^2",}]}\n```';
  const src = '先看图：\n\n$$\nx^2\n$$\n\n' + block + '\n\n顶点是原点。';
  const [fence] = fenceLines(src);
  assert.equal(fence.language, 'graph');
  assert.equal(slice(src, fence.map), block);
});

test('列表里的代码块也能取回，缩进保留在原文里', () => {
  const src = '1. 第一步\n   ```quiz\n   {bad}\n   ```\n2. 第二步';
  const [fence] = fenceLines(src);
  assert.equal(slice(src, fence.map), '   ```quiz\n   {bad}\n   ```');
});

test('多个代码块各自的行号', () => {
  const src = '```graph\n{}\n```\n\n文字\n\n```chart\n{"x":1}\n```';
  const fences = fenceLines(src);
  assert.deepEqual(fences.map((f) => slice(src, f.map)), ['```graph\n{}\n```', '```chart\n{"x":1}\n```']);
});

test('没写完的代码块到原文末尾为止', () => {
  const src = '前面\n\n```graph\n{"functions": [';
  const [fence] = fenceLines(src);
  assert.equal(slice(src, fence.map), '```graph\n{"functions": [');
});
