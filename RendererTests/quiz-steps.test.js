// 用 `node --test RendererTests/*.test.js` 运行。
const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../Renderer/core.js');

const quiz = (obj) => core.parseQuizSpec(JSON.stringify(obj));

test('解析选择题和数值填空', () => {
  const result = quiz({
    title: '导数小测',
    questions: [
      { question: '$(x^2)\'$ 等于？', options: ['$x$', '$2x$', '$x^2$'], answer: 'B', explanation: '幂函数求导' },
      { question: '哪些是奇函数？', options: ['$\\sin x$', '$\\cos x$', '$x^3$'], answer: ['A', 'C'] },
      { type: 'number', question: '$\\int_0^1 x^2 dx$ = ?', answer: '1/3', explanation: '…' },
      { type: 'number', question: '速度是多少？', answer: 20, tolerance: 0.5, unit: 'm/s' },
    ],
  });
  assert.equal(result.ok, true, result.error);
  const [q1, q2, q3, q4] = result.value.questions;
  assert.deepEqual(q1.answer, [1]);
  assert.equal(q1.multiple, false);
  assert.deepEqual(q2.answer, [0, 2]);
  assert.equal(q2.multiple, true);
  assert.ok(Math.abs(q3.answer - 1 / 3) < 1e-12);
  assert.equal(q3.tolerance, null);
  assert.equal(q4.unit, 'm/s');
});

test('选择题答案也可以写成序号', () => {
  const result = quiz({ questions: [{ question: 'q', options: ['a', 'b'], answer: 0 }] });
  assert.equal(result.ok, true, result.error);
  assert.deepEqual(result.value.questions[0].answer, [0]);
});

test('不合法的测验报错', () => {
  const bad = [
    {},
    { questions: [] },
    { questions: [{ question: '', options: ['a', 'b'], answer: 'A' }] },
    { questions: [{ question: 'q', options: ['a'], answer: 'A' }] },
    { questions: [{ question: 'q', options: ['a', 'b'], answer: 'C' }] },
    { questions: [{ question: 'q', options: ['a', 'b'], answer: 'AB' }] },
    { questions: [{ type: 'number', question: 'q', answer: 'abc' }] },
    { questions: [{ type: 'essay', question: 'q' }] },
  ];
  bad.forEach((obj) => assert.equal(quiz(obj).ok, false, JSON.stringify(obj)));
});

test('数值填空判分', () => {
  const q = { answer: 1 / 3, tolerance: null };
  assert.equal(core.isNumberCorrect(core.evaluateNumberInput('1/3'), q), true);
  assert.equal(core.isNumberCorrect(core.evaluateNumberInput('0.333'), q), true);
  assert.equal(core.isNumberCorrect(core.evaluateNumberInput('0.33'), q), true);
  assert.equal(core.isNumberCorrect(core.evaluateNumberInput('0.3'), q), false);
  assert.equal(core.isNumberCorrect(core.evaluateNumberInput('abc'), q), false);
  assert.equal(core.isNumberCorrect(core.evaluateNumberInput('1,000'), { answer: 1000, tolerance: null }), true);
  assert.equal(core.isNumberCorrect(core.evaluateNumberInput('sqrt(2)'), { answer: 1.414, tolerance: 0.01 }), true);
  assert.equal(core.isNumberCorrect(0, { answer: 0, tolerance: null }), true);
});

test('解析分步讲解', () => {
  const result = core.parseStepsSpec(JSON.stringify({
    title: '解方程',
    steps: [{ title: '移项', content: '$2x = 6$' }, '两边除以 2：$x = 3$'],
  }));
  assert.equal(result.ok, true, result.error);
  assert.deepEqual(result.value.steps, [{ title: '移项', content: '$2x = 6$' }, { title: '', content: '两边除以 2：$x = 3$' }]);
  assert.equal(core.parseStepsSpec('{"steps":[{"content":"只有一步"}]}').ok, false);
  assert.equal(core.parseStepsSpec('{"steps":[{"title":"t"},{"content":"b"}]}').ok, false);
});

test('测验和分步讲解转成文字', () => {
  const md = [
    '```quiz',
    JSON.stringify({ questions: [{ question: '1+1=?', options: ['1', '2'], answer: 'B', explanation: '加法' }] }),
    '```',
    '',
    '```steps',
    JSON.stringify({ title: '解方程', steps: [{ title: '移项', content: '2x = 6' }, { content: 'x = 3' }] }),
    '```',
  ].join('\n');
  assert.equal(core.toPlainText(md), [
    '【测验】',
    '1. 1+1=?',
    '   A. 1',
    '   B. 2',
    '   答案：B',
    '   解析：加法',
    '',
    '【分步讲解：解方程】',
    '第 1 步：移项',
    '2x = 6',
    '第 2 步',
    'x = 3',
  ].join('\n'));
});

// ---------- 宽松的 JSON ----------

test('LaTeX 的反斜杠没写成两个时也能正确解析', () => {
  // 模型常见的写法：\frac \times \rho \neq \; 都只写了一个反斜杠
  const source = String.raw`{"steps":[{"title":"t","content":"$\frac{1}{2} \times \rho \neq 0\;$"},{"content":"第二行\n$\\frac{a}{b}$"}]}`;
  const result = core.parseStepsSpec(source);
  assert.equal(result.ok, true, result.error);
  assert.equal(result.value.steps[0].content, String.raw`$\frac{1}{2} \times \rho \neq 0\;$`);
  // 真正的换行和已经写对的双反斜杠保持不变
  assert.equal(result.value.steps[1].content, '第二行\n' + String.raw`$\frac{a}{b}$`);
});

test('文字里的英文双引号也能正确解析', () => {
  const source = '{"steps":[{"title":"定义","content":"这是"偶函数"的定义"},{"content":"他说："好的"。"}]}';
  const result = core.parseStepsSpec(source);
  assert.equal(result.ok, true, result.error);
  assert.equal(result.value.steps[0].content, '这是"偶函数"的定义');
  assert.equal(result.value.steps[1].content, '他说："好的"。');
});

test('真正损坏的 JSON 仍然报错', () => {
  assert.equal(core.parseStepsSpec('{"steps":[{"content":"a"},').ok, false);
  assert.equal(core.parseGraphSpec('{ "functions": [').ok, false);
});
