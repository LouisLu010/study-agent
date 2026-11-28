const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../Renderer/core.js');
const { createBrowser } = require('./helpers/browser.js');

// 标签只是普通文本样例；不包含事件处理器或脚本，也不执行 HTML。
const label = '<点 "A"> & 数值';
const escaped = '&lt;点 &quot;A&quot;&gt; &amp; 数值';

function setup() {
  const page = createBrowser(['renderer.js']);
  const definitions = {};
  page.window.StudyComponents = {
    register: (type, definition) => { definitions[type] = definition; },
    isDark: () => false,
    lockScroll() {},
  };
  const calls = [];
  page.window.JXG = {
    COORDS_BY_USER: 0,
    Options: { text: {} },
    JSXGraph: {
      initBoard(id, options) {
        return {
          containerObj: page.document.getElementById(id),
          origin: { scrCoords: [1, 160, 120] },
          unitX: 20,
          unitY: 20,
          getBoundingBox: () => options.boundingbox,
          create(type, parents, attributes) {
            calls.push({ type, parents, attributes });
            let coordinates = parents;
            return {
              visProp: { visible: !!attributes.visible },
              X: () => typeof coordinates[0] === 'function' ? coordinates[0]() : coordinates[0],
              Y: () => typeof coordinates[1] === 'function' ? coordinates[1]() : coordinates[1],
              setPosition(_, next) { coordinates = next; },
              setAttribute() {},
              on() {},
            };
          },
          on() {},
          update() {},
        };
      },
      freeBoard() {},
    },
  };
  page.load('graph.js');
  page.load('geometry.js');
  return { ...page, definitions, calls };
}

function assertPlainText(attributes) {
  assert.equal(attributes.name, escaped);
  assert.equal(attributes.withLabel, true);
  assert.equal(attributes.label.parse, false);
  assert.equal(attributes.label.useMathJax, false);
  assert.equal(attributes.label.useKatex, false);
}

const context = { state: null, setState() {}, renderInline: (text) => text };

test('坐标图实际绘制点和线段时将 JSXGraph 标签转为纯文本', () => {
  const page = setup();
  const parsed = core.parseGraphSpec(JSON.stringify({
    xRange: [-2, 4], yRange: [-2, 4],
    points: [{ x: 1, y: 1, label }],
    segments: [{ from: [0, 0], to: [1, 1], label }],
  }));
  assert.equal(parsed.ok, true, parsed.error);
  page.definitions.graph.draw(page.root, parsed.value, context);
  const labeled = page.calls.filter((call) => call.attributes.withLabel);
  assert.deepEqual(labeled.map((call) => call.type).sort(), ['point', 'segment']);
  labeled.forEach((call) => assertPlainText(call.attributes));
  assert.deepEqual(Array.from(labeled.find((call) => call.type === 'point').attributes.label.offset), [6, 8]);
});

test('几何图实际绘制的各类模型标签均使用纯文本配置', () => {
  const page = setup();
  const parsed = core.parseGeometrySpec(JSON.stringify({
    elements: [
      { type: 'point', id: 'A', x: 0, y: 0, label },
      { type: 'point', id: 'B', x: 4, y: 0, label },
      { type: 'point', id: 'C', x: 0, y: 3, label },
      { type: 'segment', id: 's', through: ['A', 'B'], label },
      { type: 'line', id: 'l', through: ['A', 'C'], label },
      { type: 'ray', id: 'r', through: ['B', 'C'], label },
      { type: 'circle', id: 'c', center: 'A', through: 'B', label },
      { type: 'polygon', id: 'p', vertices: ['A', 'B', 'C'], label },
      { type: 'angle', id: 'a', points: ['B', 'A', 'C'], label },
      { type: 'midpoint', id: 'M', of: ['B', 'C'], label },
      { type: 'intersection', id: 'X', of: ['l', 'r'], label },
      { type: 'foot', id: 'H', from: 'C', to: 's', label },
      { type: 'point', id: 'G', x: 2, y: 0, on: 's', label },
    ],
  }));
  assert.equal(parsed.ok, true, parsed.error);
  page.definitions.geometry.draw(page.root, parsed.value, context);
  const labeled = page.calls.filter((call) => call.attributes.withLabel);
  assert.equal(labeled.length, parsed.value.elements.length);
  labeled.forEach((call) => assertPlainText(call.attributes));
  const angle = labeled.find((call) => call.type === 'nonreflexangle');
  assert.equal(angle.attributes.label.strokeColor, '#ff9500');
  const point = labeled.find((call) => call.type === 'point');
  assert.deepEqual(Array.from(point.attributes.label.offset), [9, 11]);
});

test('未填写和隐藏的图形标签保持原有显示规则', () => {
  const page = setup();
  const parsed = core.parseGeometrySpec(JSON.stringify({ elements: [
    { type: 'point', id: 'A', x: 0, y: 0 },
    { type: 'point', id: 'B', x: 1, y: 0, hidden: true, label },
    { type: 'segment', id: 's', through: ['A', 'B'] },
  ] }));
  assert.equal(parsed.ok, true, parsed.error);
  page.definitions.geometry.draw(page.root, parsed.value, context);
  const [point, hidden, segment] = page.calls;
  assert.equal(point.attributes.name, 'A');
  assert.equal(point.attributes.withLabel, true);
  assert.equal(hidden.attributes.withLabel, false);
  assert.equal(hidden.attributes.visible, false);
  assert.equal(segment.attributes.name, '');
  assert.equal(segment.attributes.withLabel, false);
});
