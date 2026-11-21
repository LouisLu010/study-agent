// 生成中的增量渲染：core.stableLength 切出"已经写完的部分"。
const test = require('node:test');
const assert = require('node:assert/strict');
const markdownit = require('../Renderer/vendor/markdown-it.min.js');
const core = require('../Renderer/core.js');

const md = markdownit({ html: false, linkify: true });
core.mathPlugin(md, { renderMath: (tex, display) => `<M${display ? 'D' : 'I'}>${tex}</M>` });
const render = (src) => md.render(src, { streaming: true });

test('还没有空行时不切', () => {
  assert.equal(core.stableLength(''), 0);
  assert.equal(core.stableLength('第一段还在写'), 0);
  assert.equal(core.stableLength('第一段\n\n'), 0);
});

test('空行之后、下一行开始时切开', () => {
  const text = '第一段。\n\n第二';
  assert.equal(core.stableLength(text), '第一段。\n\n'.length);
});

test('代码块和组件里面的空行不切', () => {
  const text = '说明\n\n```graph\n{\n\n"x": 1\n\n}\n';
  assert.equal(core.stableLength(text), '说明\n\n'.length);
  const closed = text + '```\n\n后面';
  assert.equal(core.stableLength(closed), closed.length - '后面'.length);
});

test('块级公式里面的空行不切', () => {
  const text = '推导：\n\n$$\na = b\n\nc = d\n';
  assert.equal(core.stableLength(text), '推导：\n\n'.length);
  assert.equal(core.stableLength('\\[\nx\n\ny\n'), 0);
  const oneLine = '$$x = 1$$\n\n下一段';
  assert.equal(core.stableLength(oneLine), oneLine.length - '下一段'.length);
});

test('列表项和缩进的续行前不切', () => {
  assert.equal(core.stableLength('1. 第一项\n\n2. 第二项'), 0);
  assert.equal(core.stableLength('- 一\n\n- 二'), 0);
  assert.equal(core.stableLength('- 一\n\n  续行'), 0);
  const after = '- 一\n- 二\n\n结论';
  assert.equal(core.stableLength(after), after.length - '结论'.length);
});

test('分开渲染和整段渲染结果相同', () => {
  const doc = [
    '# 单摆', '', '小角度时 $\\theta \\approx \\sin\\theta$。', '',
    '$$', 'T = 2\\pi\\sqrt{\\frac{L}{g}}', '', '$$', '',
    '| 位置 | 速度 |', '| --- | --- |', '| 最低点 | 最大 |', '',
    '```python', 'print(1)', '', 'print(2)', '```', '',
    '> 引用一段', '', '1. 第一', '', '2. 第二', '', '---', '',
    '结论：**周期与质量无关**。', '', '最后一段',
  ].join('\n');
  // 模拟一点一点生成：每个前缀都检查。
  for (let end = 1; end <= doc.length; end++) {
    const text = doc.slice(0, end);
    const split = core.stableLength(text);
    assert.equal(render(text.slice(0, split)) + render(text.slice(split)), render(text), '前缀长度 ' + end);
  }
});
