// 用 `node --test RendererTests/*.test.js` 运行。
const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../Renderer/core.js');

const parse = (obj) => core.parseChartSpec(JSON.stringify(obj));

test('解析柱状图、折线图和饼图', () => {
  const bar = parse({
    type: 'bar',
    title: '各班平均分',
    labels: ['一班', '二班', '三班'],
    datasets: [{ label: '语文', data: [85, 90, 78] }, { label: '数学', data: ['88', null, 92] }],
    yLabel: '分数',
    unit: '分',
  });
  assert.equal(bar.ok, true, bar.error);
  assert.deepEqual(bar.value.datasets[1].data, [88, null, 92]);
  assert.equal(bar.value.unit, '分');

  const line = parse({ type: 'line', labels: [1, 2, 3], datasets: [{ data: [1, 4, 9] }] });
  assert.equal(line.ok, true, line.error);
  assert.deepEqual(line.value.labels, ['1', '2', '3']);

  const pie = parse({ type: 'pie', labels: ['N₂', 'O₂', '其他'], datasets: [{ data: [78, 21, 1] }] });
  assert.equal(pie.ok, true, pie.error);

  // 没写 type 时默认是柱状图
  assert.equal(parse({ labels: ['a'], datasets: [{ data: [1] }] }).value.type, 'bar');
});

test('不合法的图表报错', () => {
  const bad = [
    { type: 'radar', labels: ['a'], datasets: [{ data: [1] }] },
    { labels: [], datasets: [{ data: [] }] },
    { labels: ['a', 'b'], datasets: [{ data: [1] }] },
    { labels: ['a'], datasets: [{ data: ['x'] }] },
    { type: 'pie', labels: ['a', 'b'], datasets: [{ data: [1, 2] }, { data: [3, 4] }] },
    { type: 'pie', labels: ['a', 'b'], datasets: [{ data: [1, -2] }] },
    { labels: ['a'] },
  ];
  bad.forEach((obj) => assert.equal(parse(obj).ok, false, JSON.stringify(obj)));
});

test('图表转成表格文字', () => {
  const md = '```chart\n' + JSON.stringify({
    title: '各班平均分',
    labels: ['一班', '二班'],
    datasets: [{ label: '语文', data: [85, 90.5] }, { label: '数学', data: [88, null] }],
    unit: '分',
  }) + '\n```';
  assert.equal(core.toPlainText(md), [
    '【图表：各班平均分】',
    '类别 | 语文（分） | 数学（分）',
    '一班 | 85 | 88',
    '二班 | 90.5 | —',
  ].join('\n'));
});
