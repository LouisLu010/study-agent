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

// ---------- 电磁 ----------

test('电场偏转：偏移量和打在极板上', () => {
  // 电子：U = 200 V，d = 2 cm，L = 8 cm，v0 = 1e7 m/s，q/m = 1.76e11
  const model = core.buildSimulation('electric_deflection', { U: 200, d: 2, L: 8, v0: 30, qm: 1.76, positive: false });
  const a = 1.76e11 * 200 / 0.02;
  const t = 0.08 / 3e7;
  close(result(model, '离开时的偏移'), 0.5 * a * t * t * 100, 1e-9);
  assert.equal(model.hits, false);
  // 电子向上偏（朝正极板）
  assert.ok(model.at(3).y > 0);
  const slow = core.buildSimulation('electric_deflection', { U: 200, d: 2, L: 8, v0: 2, qm: 1.76, positive: false });
  assert.equal(slow.hits, true);
});

test('磁场圆周运动：半径、周期和出射点', () => {
  const model = core.buildSimulation('magnetic_circle', { B: 0.1, v: 1, qm: 1, angle: 0, positive: true, boundary: true });
  close(result(model, '半径'), 10);
  close(result(model, '周期'), 2 * Math.PI / 1e7 * 1e9, 1e-6);
  close(result(model, '在磁场中转过的角度'), 180);
  // 垂直入射转半圈，从入射点上方 2r 处射出
  const end = model.at(3);
  close(end.x, 0, 1e-9);
  close(end.y, 0.2, 1e-9);
  // 30° 斜射入：转过 120°，弦长 2r·cos30°
  const tilted = core.buildSimulation('magnetic_circle', { B: 0.1, v: 1, qm: 1, angle: 30, positive: true, boundary: true });
  close(result(tilted, '在磁场中转过的角度'), 120);
  close(Math.hypot(tilted.at(3).x, tilted.at(3).y), 0.2 * Math.cos(Math.PI / 6), 1e-9);
  // 负电荷向另一边转
  assert.ok(core.buildSimulation('magnetic_circle', { B: 0.1, v: 1, qm: 1, angle: 0, positive: false, boundary: true }).at(1.5).y < 0);
  // 默认带正电、有边界
  assert.deepEqual([parse({ kind: 'magnetic_circle' }).value.defaults.positive, parse({ kind: 'magnetic_circle' }).value.defaults.boundary], [true, true]);
});

test('速度选择器和质谱仪', () => {
  const pass = core.buildSimulation('mass_spectrometer', { E: 2, B1: 0.2, v: 1, B2: 0.5, qm1: 1, qm2: 0.5 });
  close(result(pass, '能直线通过'), 1e5);
  assert.deepEqual(pass.species.map((s) => s.blocked), [false, false]);
  close(pass.species[0].r, 0.2);
  close(pass.species[1].r, 0.4);
  const fast = core.buildSimulation('mass_spectrometer', { E: 2, B1: 0.2, v: 3, B2: 0.5, qm1: 1, qm2: 0 });
  assert.equal(fast.species.length, 1);
  assert.equal(fast.species[0].blocked, true);
});

test('导体棒切割磁感线', () => {
  const coast = core.buildSimulation('rod_induction', { B: 0.5, L: 0.5, R: 1, m: 0.1, v0: 5, F: 0 });
  close(result(coast, '时间常数'), 0.1 / 0.0625);
  close(result(coast, '最终滑行距离'), 5 * 1.6);
  close(result(coast, '初始感应电动势'), 1.25);
  assert.ok(coast.at(coast.duration).v < 0.05);
  const pulled = core.buildSimulation('rod_induction', { B: 0.5, L: 0.5, R: 1, m: 0.1, v0: 0, F: 0.5 });
  close(result(pulled, '最终速度'), 8);
  close(pulled.at(pulled.duration).v, 8, 0.1);
});

// ---------- 电路和化学平衡 ----------

test('串联和并联电路', () => {
  const series = core.buildSimulation('circuit', { U: 6, R1: 10, R2: 20, R3: 0, r: 0, parallel: false });
  close(series.I, 0.2);
  close(series.branches[1].U, 4);
  const parallel = core.buildSimulation('circuit', { U: 6, R1: 10, R2: 20, R3: 0, r: 0, parallel: true });
  close(result(parallel, '并联总电阻'), 20 / 3);
  close(parallel.branches[0].I, 0.6);
  close(parallel.I, 0.9);
  // 有内阻时路端电压小于电动势
  const internal = core.buildSimulation('circuit', { U: 6, R1: 10, R2: 20, R3: 30, r: 2, parallel: false });
  close(internal.I, 6 / 62);
  close(result(internal, '路端电压'), 6 * 60 / 62);
});

test('化学平衡：趋向 K 并且加入反应物后重新平衡', () => {
  const model = core.buildSimulation('equilibrium', { kf: 1, kr: 0.5, A0: 1, B0: 0, addA: 0 });
  const end = model.at(model.duration);
  close(end.B / end.A, 2, 0.02);
  close(end.A + end.B, 1);
  const add = core.buildSimulation('equilibrium', { kf: 1, kr: 0.5, A0: 1, B0: 0, addA: 0.6 });
  const before = add.at(add.tAdd - 1e-6);
  const after = add.at(add.tAdd + 1e-6);
  close(after.A - before.A, 0.6, 1e-3);
  const last = add.at(add.duration);
  close(last.A + last.B, 1.6, 1e-9);
  close(last.B / last.A, 2, 0.02);
  // 平衡时正逆反应速率相等
  close(last.rf / last.rr, 1, 0.02);
});
