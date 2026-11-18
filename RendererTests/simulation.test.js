// 用 `node --test RendererTests/*.test.js` 运行。
const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../Renderer/core.js');

function close(actual, expected, eps = 1e-6) {
  assert.ok(Math.abs(actual - expected) < eps, `${actual} ≠ ${expected}`);
}

const parse = (obj) => core.parseSimulationSpec(JSON.stringify(obj));
const result = (model, label) => model.results.find((r) => r.label.startsWith(label)).value;

test('抛体运动：斜抛和平抛', () => {
  const spec = parse({ kind: 'projectile', params: { v0: 20, angle: 30, g: 10 } }).value;
  const model = core.buildSimulation('projectile', spec.defaults);
  close(result(model, '飞行时间'), 2);
  close(result(model, '水平射程'), 20 * Math.cos(Math.PI / 6) * 2);
  close(result(model, '最高点高度'), 5);
  close(model.at(1).y, 5);
  close(model.at(99).y, 0);

  const flat = core.buildSimulation('projectile', { v0: 10, angle: 0, h: 20, g: 10 });
  close(result(flat, '飞行时间'), 2);
  close(result(flat, '水平射程'), 20);
});

test('单摆：小角度周期接近 2π√(L/g)，大角度周期更长', () => {
  const small = core.buildSimulation('pendulum', { L: 1, theta0: 5, g: 9.8 });
  const formula = 2 * Math.PI * Math.sqrt(1 / 9.8);
  close(result(small, '周期'), formula, 0.01);
  const big = core.buildSimulation('pendulum', { L: 1, theta0: 80, g: 9.8 });
  assert.ok(result(big, '周期') > formula * 1.1);
  // 半个周期时摆到另一侧
  const half = result(small, '周期') / 2;
  close(small.at(half).theta, -5 * Math.PI / 180, 0.002);
  close(small.at(result(small, '周期')).theta, 5 * Math.PI / 180, 0.002);
});

test('弹簧振子', () => {
  const model = core.buildSimulation('spring', { k: 100, m: 1, A: 0.2 });
  close(result(model, '周期'), 2 * Math.PI / 10);
  close(model.at(0).x, 0.2);
  close(model.at(Math.PI / 20).x, 0, 1e-9);
  close(Math.abs(model.at(Math.PI / 20).v), 2);
});

test('匀变速直线运动', () => {
  const model = core.buildSimulation('uniform_acceleration', { v0: 10, a: -2, T: 8 });
  close(model.at(8).v, -6);
  close(model.at(8).x, 16);
  // 速度为 0 时（t = 5）位移最大，范围要包含它
  close(model.xRange[1], 25);
});

test('刹车：速度减到 0 后停下', () => {
  const spec = parse({ kind: 'uniform_acceleration', params: { v0: 20, a: -4, T: 6 }, stopAtRest: true }).value;
  assert.equal(spec.defaults.stopAtRest, true);
  const model = core.buildSimulation('uniform_acceleration', spec.defaults);
  close(model.at(6).x, 50);
  close(model.at(6).v, 0);
  close(model.results[0].value, 5);
  // 不停下时会倒退：6 s 内位移 48 m
  close(core.buildSimulation('uniform_acceleration', { v0: 20, a: -4, T: 6, stopAtRest: false }).at(6).x, 48);
});

test('一维碰撞：弹性、完全非弹性和不相撞', () => {
  const elastic = core.buildSimulation('collision', { m1: 1, v1: 4, m2: 1, v2: 0, e: 1 });
  close(result(elastic, '碰后物块 1'), 0);
  close(result(elastic, '碰后物块 2'), 4);
  close(result(elastic, '动能损失'), 0);

  const sticky = core.buildSimulation('collision', { m1: 1, v1: 4, m2: 3, v2: 0, e: 0 });
  close(result(sticky, '碰后物块 1'), 1);
  close(result(sticky, '碰后物块 2'), 1);
  close(result(sticky, '动能损失'), 8 - 2);
  // 碰撞前后动量守恒
  const s = sticky.at(sticky.collisionTime + 1);
  close(1 * s.v1 + 3 * s.v2, 4);

  const apart = core.buildSimulation('collision', { m1: 1, v1: -1, m2: 1, v2: 2, e: 1 });
  assert.equal(apart.collisionTime, Infinity);
});

test('解析模拟描述', () => {
  const ok = parse({ kind: 'projectile', title: '平抛', params: { v0: 100, angle: '30', foo: 1 } });
  assert.equal(ok.ok, true, ok.error);
  assert.equal(ok.value.defaults.v0, 50);
  assert.equal(ok.value.defaults.angle, 30);
  assert.equal(ok.value.defaults.g, 9.8);
  assert.equal(ok.value.warnings.length, 2);
  // 参数也可以直接写在外层
  assert.equal(parse({ kind: 'spring', k: 50 }).value.defaults.k, 50);
  assert.equal(parse({ kind: 'rocket' }).ok, false);
  assert.equal(parse({ kind: 'projectile', params: { v0: 'abc' } }).ok, false);
  assert.equal(core.toPlainText('```simulation\n{"kind":"spring","params":{"k":50}}\n```').startsWith('[模拟：弹簧振子（劲度系数 50 N/m'), true);
});
