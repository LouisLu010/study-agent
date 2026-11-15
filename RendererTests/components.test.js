// 用 `node --test RendererTests/*.test.js` 运行。
const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../Renderer/core.js');

test('注册表里有坐标图', () => {
  assert.ok(core.componentTypes().includes('graph'));
  assert.equal(core.componentLabel('graph'), '坐标图');
  assert.equal(core.componentLabel('unknown'), '组件');
});

test('parseComponent 拒绝不认识的种类', () => {
  assert.equal(core.parseComponent('foo', '{}').ok, false);
  assert.equal(core.parseComponent('graph', '{"functions":[{"expr":"x"}]}').ok, true);
});

test('extractFences 找出代码块和语言', () => {
  const md = '前文\n\n```graph\n{"a":1}\n```\n\n~~~python\nprint(1)\n~~~\n\n```\n无语言\n```';
  const fences = core.extractFences(md);
  assert.deepEqual(fences.map((f) => [f.language, f.content, f.closed]), [
    ['graph', '{"a":1}', true],
    ['python', 'print(1)', true],
    ['', '无语言', true],
  ]);
});

test('extractFences 处理没闭合的代码块和更长的围栏', () => {
  const fences = core.extractFences('````md\n```graph\n内层\n```\n````\n\n```graph\n{"x"');
  assert.equal(fences.length, 2);
  assert.equal(fences[0].language, 'md');
  assert.equal(fences[0].content, '```graph\n内层\n```');
  assert.equal(fences[1].closed, false);
});

test('toPlainText 把组件换成文字，其他代码块不变', () => {
  const md = [
    '看下面的图：',
    '',
    '```graph',
    '{"title":"抛物线","functions":[{"expr":"x^2"}]}',
    '```',
    '',
    '```graph',
    '{"functions":[{"expr":"sin(x)","label":"y=sin x"},{"expr":"x"}]}',
    '```',
    '',
    '```graph',
    '{ 坏的',
    '```',
    '',
    '```python',
    'print(1)',
    '```',
  ].join('\n');
  assert.equal(
    core.toPlainText(md),
    ['看下面的图：', '', '[坐标图：抛物线]', '', '[坐标图：y=sin x，y = x]', '', '[坐标图]', '', '```python', 'print(1)', '```'].join('\n'),
  );
});

test('toPlainText 对没有组件的文字原样返回', () => {
  const md = '公式 $x^2$\n\n- 列表';
  assert.equal(core.toPlainText(md), md);
});
