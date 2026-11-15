// 用 `node --test RendererTests/*.test.js` 运行。
const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../Renderer/core.js');

function close(actual, expected, eps = 1e-9) {
  assert.ok(Math.abs(actual - expected) < eps, `${actual} ≠ ${expected}`);
}

const parse = (obj) => core.parseGeometrySpec(JSON.stringify(obj));

const triangle = {
  title: '三角形内角和',
  elements: [
    { type: 'point', id: 'A', x: 0, y: 0 },
    { type: 'point', id: 'B', x: 4, y: 0 },
    { type: 'point', id: 'C', x: 0, y: 3 },
    { type: 'polygon', id: 'T', vertices: ['A', 'B', 'C'] },
    { type: 'segment', id: 'AB', through: ['A', 'B'] },
    { type: 'segment', id: 'BC', through: ['B', 'C'] },
    { type: 'segment', id: 'CA', through: ['C', 'A'] },
    { type: 'angle', id: 'a', points: ['B', 'A', 'C'] },
    { type: 'angle', id: 'b', points: ['A', 'B', 'C'] },
    { type: 'angle', id: 'c', points: ['A', 'C', 'B'] },
    { type: 'midpoint', id: 'M', of: ['B', 'C'] },
    { type: 'foot', id: 'H', from: 'A', to: 'BC' },
  ],
  readouts: [
    { label: '内角和', value: 'a + b + c', unit: '°', decimals: 1 },
    { label: '面积', value: 'T' },
    { label: 'AB² + CA²', value: 'AB^2 + CA^2' },
    { label: '写错的', value: 'foo + 1' },
  ],
};

test('解析几何图并计算初始数值', () => {
  const result = parse(triangle);
  assert.equal(result.ok, true, result.error);
  const spec = result.value;
  const { points, measures } = core.computeGeometry(spec, null);
  close(measures.BC, 5);
  close(measures.a, 90);
  close(measures.a + measures.b + measures.c, 180);
  close(measures.T, 6);
  close(points.M.x, 2);
  close(points.M.y, 1.5);
  // 直角三角形斜边上的高：AH = 3×4/5 = 2.4
  close(Math.hypot(points.H.x, points.H.y), 2.4);
  assert.equal(spec.readouts.length, 3);
  assert.equal(spec.warnings.length, 1);
  close(spec.readouts[2].evaluate(measures), 25);
});

test('拖动点后重新计算', () => {
  const spec = parse(triangle).value;
  const { points, measures } = core.computeGeometry(spec, { C: [2, 4] });
  close(measures.a + measures.b + measures.c, 180);
  close(measures.T, 8);
  close(points.M.x, 3);
});

test('读数里两点连写表示距离，三点连写表示角度', () => {
  const result = parse({
    elements: [
      { type: 'point', id: 'A', x: 0, y: 0 },
      { type: 'point', id: 'B', x: 4, y: 0 },
      { type: 'point', id: 'C', x: 0, y: 3 },
      { type: 'midpoint', id: 'M', of: ['B', 'C'] },
      { type: 'segment', id: 'AB', through: ['A', 'B'] },
    ],
    readouts: [
      { label: 'AM', value: 'AM' },
      { label: 'BM', value: 'MB' },
      { label: 'AB', value: 'AB' },
      { label: '∠BAC', value: 'BAC' },
      { label: 'BC² 和', value: 'AB^2 + AC^2 - BC^2' },
    ],
  });
  assert.equal(result.ok, true, result.error);
  assert.deepEqual(result.value.warnings, []);
  const spec = result.value;
  const { measures } = core.computeGeometry(spec, null);
  const values = spec.readouts.map((r) => r.evaluate(measures));
  close(values[0], 2.5);
  close(values[1], 2.5);
  close(values[2], 4);
  close(values[3], 90);
  close(values[4], 0);
  // 拖动后重新计算
  const moved = core.computeGeometry(spec, { C: [0, 8] }).measures;
  close(spec.readouts[0].evaluate(moved), Math.hypot(2, 4));
});

test('交点和圆', () => {
  const result = parse({
    elements: [
      { type: 'point', id: 'O', x: 0, y: 0, fixed: true },
      { type: 'point', id: 'P', x: 2, y: 0 },
      { type: 'circle', id: 'c', center: 'O', through: 'P' },
      { type: 'point', id: 'Q', x: 0, y: 5, on: 'c' },
      { type: 'circle', id: 'd', center: 'Q', radius: 1 },
      { type: 'point', id: 'A', x: -1, y: -1 },
      { type: 'point', id: 'B', x: 1, y: 1 },
      { type: 'point', id: 'C', x: -1, y: 1 },
      { type: 'point', id: 'D', x: 1, y: -1 },
      { type: 'line', id: 'l1', through: ['A', 'B'] },
      { type: 'ray', id: 'l2', through: ['C', 'D'] },
      { type: 'intersection', id: 'X', of: ['l1', 'l2'] },
    ],
  });
  assert.equal(result.ok, true, result.error);
  const { points, measures } = core.computeGeometry(result.value, null);
  // Q 被放到圆 c 上
  close(points.Q.x, 0);
  close(points.Q.y, 2);
  close(measures.c, 2);
  close(measures.d, 1);
  close(points.X.x, 0);
  close(points.X.y, 0);
  // 自动确定的显示范围包含所有点和圆
  assert.ok(result.value.xRange[0] < -2 && result.value.xRange[1] > 2);
});

test('不合法的几何图报错', () => {
  const bad = [
    {},
    { elements: [] },
    { elements: [{ type: 'hexagon', id: 'H' }] },
    { elements: [{ type: 'point', id: '1A', x: 0, y: 0 }] },
    { elements: [{ type: 'point', id: 'A', x: 0, y: 0 }, { type: 'point', id: 'A', x: 1, y: 0 }] },
    { elements: [{ type: 'segment', id: 's', through: ['A', 'B'] }] },
    { elements: [{ type: 'point', id: 'A', x: 0, y: 0 }, { type: 'segment', id: 's', through: ['A', 'A'] }] },
    { elements: [{ type: 'point', id: 'A', x: 0, y: 0 }, { type: 'point', id: 'B', x: 1, y: 0 }, { type: 'polygon', id: 'p', vertices: ['A', 'B'] }] },
    // 平行线没有交点
    {
      elements: [
        { type: 'point', id: 'A', x: 0, y: 0 }, { type: 'point', id: 'B', x: 1, y: 0 },
        { type: 'point', id: 'C', x: 0, y: 1 }, { type: 'point', id: 'D', x: 1, y: 1 },
        { type: 'line', id: 'l', through: ['A', 'B'] }, { type: 'line', id: 'm', through: ['C', 'D'] },
        { type: 'intersection', id: 'X', of: ['l', 'm'] },
      ],
    },
  ];
  bad.forEach((obj) => assert.equal(parse(obj).ok, false, JSON.stringify(obj)));
});

test('几何图转成文字', () => {
  const md = '```geometry\n' + JSON.stringify(triangle) + '\n```';
  assert.equal(core.toPlainText(md), '[几何图：三角形内角和]');
});
