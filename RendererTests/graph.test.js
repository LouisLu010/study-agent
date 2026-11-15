// 用 `node --test RendererTests/*.test.js` 运行。
const test = require('node:test');
const assert = require('node:assert/strict');
const { compileExpression, parseGraphSpec } = require('../Renderer/core.js');

function close(actual, expected) {
  assert.ok(Math.abs(actual - expected) < 1e-9, `${actual} ≠ ${expected}`);
}

test('四则运算和优先级', () => {
  close(compileExpression('1 + 2 * 3')(0), 7);
  close(compileExpression('(1 + 2) * 3')(0), 9);
  close(compileExpression('2^3^2')(0), 512);
  close(compileExpression('-x^2')(3), -9);
  close(compileExpression('2^-1')(0), 0.5);
  close(compileExpression('x**2')(4), 16);
});

test('隐式乘法', () => {
  close(compileExpression('2x')(3), 6);
  close(compileExpression('3x^2')(2), 12);
  close(compileExpression('(x+1)(x-1)')(3), 8);
  close(compileExpression('2sin(x)')(Math.PI / 2), 2);
  close(compileExpression('2pi')(0), 2 * Math.PI);
  close(compileExpression('xsin(x)')(Math.PI / 2), Math.PI / 2);
});

test('函数和常数', () => {
  close(compileExpression('sin(pi/2)')(0), 1);
  close(compileExpression('sin x + 1')(0), 1);
  close(compileExpression('sin^2(x) + cos^2(x)')(1.234), 1);
  close(compileExpression('ln(e)')(0), 1);
  close(compileExpression('lg(100)')(0), 2);
  close(compileExpression('log(2, 8)')(0), 3);
  close(compileExpression('log(1000)')(0), 3);
  close(compileExpression('sqrt(x)')(9), 3);
  close(compileExpression('abs(x)')(-2), 2);
  close(compileExpression('e^x')(0), 1);
  close(compileExpression('exp(x)')(0), 1);
  close(compileExpression('max(x, 2)')(1), 2);
  close(compileExpression('tanh(0)')(0), 0);
  close(compileExpression('π')(0), Math.PI);
});

test('非法表达式报错', () => {
  assert.throws(() => compileExpression('alert(1)'));
  assert.throws(() => compileExpression('x +'));
  assert.throws(() => compileExpression('(x'));
  assert.throws(() => compileExpression('x; 1'));
  assert.throws(() => compileExpression(''));
});

test('解析完整的坐标图描述', () => {
  const result = parseGraphSpec(JSON.stringify({
    title: '正弦函数',
    xRange: ['-2pi', '2pi'],
    yRange: [-2, 2],
    functions: [{ expr: 'sin(x)', label: 'y=sin x' }, { expr: 'x/2', domain: [-4, 4], dashed: true }],
    points: [{ x: 0, y: 0, label: 'O' }, { x: 'pi/2', y: 1 }],
    segments: [{ from: [0, 0], to: ['pi/2', 1], dashed: true }],
  }));
  assert.equal(result.ok, true, result.error);
  const spec = result.value;
  close(spec.xRange[0], -2 * Math.PI);
  assert.deepEqual(spec.yRange, [-2, 2]);
  assert.equal(spec.functions.length, 2);
  close(spec.functions[0].fn(Math.PI / 2), 1);
  assert.deepEqual(spec.functions[1].domain, [-4, 4]);
  close(spec.points[1].x, Math.PI / 2);
  assert.equal(spec.segments[0].dashed, true);
});

test('没有 yRange 时自动计算并包含原点', () => {
  const result = parseGraphSpec('{"xRange":[0,3],"functions":[{"expr":"x^2+1"}]}');
  assert.equal(result.ok, true, result.error);
  const [low, high] = result.value.yRange;
  assert.ok(low <= 0 && high >= 10 * 0.97 && high < 13, `${low}, ${high}`);
});

test('有渐近线时自动范围不会被极端值撑大', () => {
  const result = parseGraphSpec('{"xRange":[-5,5],"functions":[{"expr":"1/x"}]}');
  assert.equal(result.ok, true, result.error);
  const [low, high] = result.value.yRange;
  assert.ok(high < 100 && low > -100, `${low}, ${high}`);
});

test('不合法的描述返回错误', () => {
  assert.equal(parseGraphSpec('{ "functions": [').ok, false);
  assert.equal(parseGraphSpec('{}').ok, false);
  assert.equal(parseGraphSpec('{"functions":[{"expr":"foo(x)"}]}').ok, false);
  assert.equal(parseGraphSpec('{"xRange":[5,1],"functions":[{"expr":"x"}]}').ok, false);
  assert.equal(parseGraphSpec('{"points":[{"x":"x","y":1}]}').ok, false);
});
