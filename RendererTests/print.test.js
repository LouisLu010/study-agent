// 用 `node --test RendererTests/*.test.js` 运行。
const test = require('node:test');
const assert = require('node:assert/strict');

// print.js 挂在 window.StudyRenderer 上，这里给一个最小的替身。
global.window = {
  StudyRenderer: {
    escapeHTML: (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'),
    renderMarkdown: (s) => '<p>' + s + '</p>',
  },
};
require('../Renderer/print.js');
const { buildPrintHTML } = global.window.StudyRenderer;

test('组名变了才印组标题，题号接着往下编', () => {
  const html = buildPrintHTML({
    title: '有机大题',
    includeAnswers: false,
    questions: [
      { label: 'A', content: '一', group: '合成路线' },
      { label: 'B', content: '二', group: '合成路线' },
      { label: 'C', content: '三', group: '同分异构' },
      { label: 'D', content: '四', group: '' },
    ],
  });
  assert.equal((html.match(/print-group/g) || []).length, 2);
  assert.ok(html.indexOf('合成路线') < html.indexOf('1．A'));
  assert.ok(html.indexOf('同分异构') > html.indexOf('2．B'));
  assert.ok(html.includes('3．C') && html.includes('4．D'));
});

test('没有分组时和以前一样', () => {
  const html = buildPrintHTML({ title: 't', questions: [{ label: 'A', content: '一' }] });
  assert.ok(!html.includes('print-group'));
  assert.ok(html.includes('1．A'));
});
