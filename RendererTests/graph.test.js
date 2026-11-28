// 用 `node --test RendererTests/*.test.js` 运行。
const test = require('node:test');
const assert = require('node:assert/strict');
const { compileExpression, parseGraphSpec, toPlainText } = require('../Renderer/core.js');

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

// ---------- 参数 ----------

const { fillFormula, formatNumber } = require('../Renderer/core.js');

test('表达式里可以用参数', () => {
  const f = compileExpression('a(x - h)^2 + k', ['a', 'h', 'k']);
  close(f(3, { a: 2, h: 1, k: -1 }), 7);
  close(f(0, { a: 1, h: 0, k: 5 }), 5);
  // 没有声明的名字仍然报错
  assert.throws(() => compileExpression('a x', []));
  // 参数名不会和函数名混淆
  close(compileExpression('abs(x) + a', ['a'])(-2, { a: 1 }), 3);
  close(compileExpression('cos(x) + c', ['c'])(0, { c: 1 }), 2);
});

test('解析带参数的坐标图', () => {
  const result = parseGraphSpec(JSON.stringify({
    title: '二次函数的平移',
    xRange: [-5, 5],
    yRange: [-5, 10],
    params: [
      { name: 'a', min: -3, max: 3, step: 0.1, value: 1, label: '开口' },
      { name: 'h', min: -3, max: 3, value: 0 },
      { name: 'k', min: -3, max: 3, step: 1 },
    ],
    functions: [{ expr: 'a(x-h)^2 + k' }],
    points: [{ x: 'h', y: 'k', label: '顶点' }],
    segments: [{ from: ['h', -5], to: ['h', 10], dashed: true }],
    readouts: [{ label: '顶点', value: ['h', 'k'] }, { label: '开口方向（a 的符号）', value: 'sign(a)' }],
    formula: 'y = {a}(x - {h})^2 + {k}',
  }));
  assert.equal(result.ok, true, result.error);
  const spec = result.value;
  assert.deepEqual(spec.params.map((p) => p.name), ['a', 'h', 'k']);
  assert.equal(spec.params[1].step, 0.06);
  assert.equal(spec.params[2].value, 0);
  assert.deepEqual(spec.defaults, { a: 1, h: 0, k: 0 });
  close(spec.functions[0].fn(2), 4);
  close(spec.functions[0].at(2, { a: 2, h: 1, k: 3 }), 5);
  close(spec.points[0].xAt({ a: 1, h: 2, k: 3 }), 2);
  close(spec.segments[0].from[0].at({ h: -1 }), -1);
  assert.equal(spec.readouts[0].pair, true);
  close(spec.readouts[0].values[1]({ a: 1, h: 2, k: 3 }), 3);
});

test('参数名可以是希腊字母', () => {
  const result = parseGraphSpec(JSON.stringify({
    params: [{ name: 'A', min: 0, max: 3, value: 1 }, { name: 'ω', min: 0, max: 3, value: 2 }, { name: 'φ', min: -3, max: 3, value: 0 }],
    functions: [{ expr: 'A * sin(ω * x + φ)' }],
    formula: 'y = {A} \\sin({ω}x + {φ})',
  }));
  assert.equal(result.ok, true, result.error);
  close(result.value.functions[0].fn(Math.PI / 4), 1);
  assert.equal(fillFormula(result.value.formula, result.value.params, { A: 2, ω: 1, φ: -0.5 }), 'y = 2 \\sin(1x - 0.5)');
  // π 仍然是常数
  assert.equal(parseGraphSpec('{"params":[{"name":"π","min":0,"max":1}],"functions":[{"expr":"x"}]}').ok, false);
});

test('参数的初始值超出范围时取边界', () => {
  const result = parseGraphSpec('{"params":[{"name":"a","min":0,"max":2,"value":5}],"functions":[{"expr":"a x"}]}');
  assert.equal(result.ok, true, result.error);
  assert.equal(result.value.params[0].value, 2);
});

test('函数图继续支持名为 y 的参数', () => {
  const result = parseGraphSpec(JSON.stringify({
    params: [{ name: 'y', min: 0, max: 5, value: 2 }],
    functions: [{ expr: 'y*x' }],
  }));
  assert.equal(result.ok, true, result.error);
  close(result.value.functions[0].fn(3), 6);
  close(result.value.functions[0].at(3, { y: 4 }), 12);
});

test('不合法的参数报错', () => {
  const bad = [
    '{"params":[{"name":"x","min":0,"max":1}],"functions":[{"expr":"x"}]}',
    '{"params":[{"name":"pi","min":0,"max":1}],"functions":[{"expr":"x"}]}',
    '{"params":[{"name":"a","min":1,"max":0}],"functions":[{"expr":"a x"}]}',
    '{"params":[{"name":"a","min":0,"max":1},{"name":"a","min":0,"max":1}],"functions":[{"expr":"a x"}]}',
    '{"params":[{"name":"a","min":0,"max":1}],"functions":[{"expr":"b x"}]}',
  ];
  bad.forEach((source) => assert.equal(parseGraphSpec(source).ok, false, source));
});

test('写错的读数被跳过，坐标图照常显示', () => {
  const result = parseGraphSpec(JSON.stringify({
    params: [{ name: 'd', min: 0, max: 3 }],
    functions: [{ expr: 'sin(x + d)' }],
    readouts: [{ label: '好的', value: 'd' }, { label: '坏的', value: 'sin(x) = cos(x)' }, { label: '缺值' }],
  }));
  assert.equal(result.ok, true, result.error);
  assert.equal(result.value.readouts.length, 1);
  assert.equal(result.value.warnings.length, 2);
});

test('没有参数时忽略 formula', () => {
  const result = parseGraphSpec('{"functions":[{"expr":"x"}],"formula":"y = {a}x"}');
  assert.equal(result.ok, true, result.error);
  assert.equal(result.value.formula, '');
  assert.equal(result.value.warnings.length, 1);
});

test('定义域可以含参数', () => {
  const result = parseGraphSpec('{"params":[{"name":"v","min":1,"max":20,"value":5}],"functions":[{"expr":"20 - 5x^2/v^2","domain":[0,"2v"]}]}');
  assert.equal(result.ok, true, result.error);
  assert.deepEqual(result.value.functions[0].domain, [0, 10]);
  close(result.value.functions[0].domainAt[1]({ v: 8 }), 16);
});

test('物理图像里的 t 当作自变量', () => {
  const result = parseGraphSpec('{"functions":[{"expr":"2t"},{"expr":"t^2"}]}');
  assert.equal(result.ok, true, result.error);
  close(result.value.functions[0].fn(3), 6);
  close(result.value.functions[1].fn(3), 9);
  // t 被声明成参数时就是参数
  const asParam = parseGraphSpec('{"params":[{"name":"t","min":0,"max":5,"value":2}],"functions":[{"expr":"t x"}]}');
  assert.equal(asParam.ok, true, asParam.error);
  close(asParam.value.functions[0].fn(3), 6);
});

test('实时公式代入参数并整理正负号', () => {
  const params = [{ name: 'a', step: 0.1 }, { name: 'b', step: 1 }, { name: 'c', step: 0.01 }];
  assert.equal(fillFormula('y = {a}x^2 + {b}x + {c}', params, { a: 2.5, b: -3, c: 0.25 }), 'y = 2.5x^2 - 3x + 0.25');
  assert.equal(fillFormula('y = x - {b}', params, { b: -2 }), 'y = x + 2');
  assert.equal(fillFormula('{unknown} + {a}', params, { a: 1 }), '{unknown} + 1');
});

test('数字格式', () => {
  assert.equal(formatNumber(2.5, 2), '2.5');
  assert.equal(formatNumber(3, 2), '3');
  assert.equal(formatNumber(-0.0001, 2), '0');
  assert.equal(formatNumber(NaN), '—');
});

test('方程曲线：双曲线和椭圆写成方程（第十版 Beta 3）', () => {
  const result = parseGraphSpec(JSON.stringify({
    xRange: [-6, 6],
    yRange: [-4, 4],
    params: [{ name: 'a', min: 1, max: 5, value: 4 }],
    equations: [
      { expr: 'x^2/a^2 - y^2/9 = 1', label: '双曲线' },
      { expr: 'x^2/25 + y^2/9 = 1', dashed: true },
    ],
  }));
  assert.equal(result.ok, true, result.error);
  const [hyperbola, ellipse] = result.value.equations;
  // 顶点 (4, 0) 在双曲线上；(0, 3) 在椭圆上。
  assert.ok(Math.abs(hyperbola.at(4, 0, { a: 4 })) < 1e-9);
  assert.ok(Math.abs(ellipse.at(0, 3, {})) < 1e-9);
  // 参数变了，曲线跟着变：a = 2 时顶点在 (2, 0)。
  assert.ok(Math.abs(hyperbola.at(2, 0, { a: 2 })) < 1e-9);
  assert.equal(hyperbola.label, '双曲线');
  assert.equal(ellipse.dashed, true);
});

test('方程曲线：格式不对时报错', () => {
  const bad = (expr) => parseGraphSpec(JSON.stringify({ equations: [{ expr }] }));
  assert.equal(bad('x^2 + y^2').ok, false);
  assert.equal(bad('x = y = 1').ok, false);
  assert.equal(bad('x^2 + z^2 = 1').ok, false);
  assert.equal(parseGraphSpec(JSON.stringify({ params: [{ name: 'y', min: 0, max: 1 }], equations: [{ expr: 'x = y' }] })).ok, false);
  // 只有方程也算有内容。
  assert.equal(bad('x^2 + y^2 = 4').ok, true);
});

test('方程曲线允许采样原点之外的合法定义域', () => {
  for (const [expr, x, y] of [['sqrt(x-4)=y', 8, 2], ['ln(x-4)=y', 5, 0]]) {
    const result = parseGraphSpec(JSON.stringify({
      xRange: [4, 10],
      yRange: [0, 3],
      equations: [{ expr }],
    }));
    assert.equal(result.ok, true, result.error);
    close(result.value.equations[0].at(x, y, {}), 0);
    assert.equal(Number.isNaN(result.value.equations[0].at(0, 0, {})), true);
  }
});

test('方程曲线仍拒绝未声明变量和语法错误', () => {
  for (const expr of ['sqrt(z-4)=y', 'sqrt(x-4)+=y']) {
    const result = parseGraphSpec(JSON.stringify({ equations: [{ expr }] }));
    assert.equal(result.ok, false, expr);
  }
});

test('方程曲线的纯文本导出保留表达式', () => {
  const render = (spec) => toPlainText('```graph\n' + JSON.stringify(spec) + '\n```');
  assert.equal(render({ equations: [{ expr: 'x^2+y^2=4' }] }), '[坐标图：x^2+y^2=4]');
  assert.equal(render({
    functions: [{ expr: 'x', label: '直线' }],
    equations: [{ expr: 'x^2+y^2=4', label: '圆' }],
  }), '[坐标图：直线，圆：x^2+y^2=4]');
});
