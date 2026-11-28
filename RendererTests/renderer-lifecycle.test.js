const test = require('node:test');
const assert = require('node:assert/strict');
const { createBrowser } = require('./helpers/browser.js');

function quiz(question, answer) {
  return '```quiz\n' + JSON.stringify({ questions: [{ type: 'number', question, answer }] }) + '\n```\n';
}

function submit(page, input) {
  page.root.querySelector('.quiz-input').value = input;
  page.root.querySelector('.quiz-submit').click();
}

function results(page) {
  return page.messages.filter((message) => message.name === 'quizResult').map((message) => message.body);
}

test('连续复习的独立渲染页面分别提交结果，第二题没有上一题答案', () => {
  const first = createBrowser();
  first.window.StudyRenderer.render(quiz('6×7 是多少？', 42), false);
  submit(first, '42');
  assert.equal(results(first).length, 1);
  assert.equal(results(first)[0].correct, true);
  assert.equal(first.root.querySelector('.quiz-input').disabled, true);

  const second = createBrowser();
  second.window.StudyRenderer.render(quiz('2×3 是多少？', 6), false);
  const input = second.root.querySelector('.quiz-input');
  assert.equal(input.value, '');
  assert.equal(input.disabled, false);
  assert.equal(second.root.querySelector('.quiz-submit').hidden, false);
  assert.equal(results(second).length, 0);
  submit(second, '6');
  assert.equal(results(second).length, 1);
  assert.equal(results(second)[0].question.question, '2×3 是多少？');
  assert.equal(results(second)[0].answer.input, '6');
  assert.equal(results(second)[0].correct, true);
  assert.equal(first.window.StudyRenderer.getOptions().state.c0.answers[0].input, '42');
});

test('同一消息在流式续写和最终渲染时保留已提交组件与答案', () => {
  const page = createBrowser();
  const markdown = quiz('6×7 是多少？', 42);
  page.window.StudyRenderer.render(markdown + '\n后续', true, { state: {} });
  submit(page, '42');
  const component = page.root.querySelector('.quiz');
  page.window.StudyRenderer.render(markdown + '\n后续说明', true);
  assert.ok(page.root.querySelector('.quiz') === component);
  page.window.StudyRenderer.render(markdown + '\n后续说明。', false);
  assert.ok(page.root.querySelector('.quiz') === component);
  assert.equal(page.root.querySelector('.quiz-input').value, '42');
  assert.equal(page.root.querySelector('.quiz-input').disabled, true);
  assert.equal(page.root.querySelector('.quiz-submit').hidden, true);
  assert.equal(results(page).length, 1);
});

test('保存的组件状态恢复答案，恢复过程不会重复上报作答结果', () => {
  const page = createBrowser();
  page.window.StudyRenderer.render(quiz('6×7 是多少？', 42), false, {
    state: { c0: { answers: { 0: { input: '41' } } } },
  });
  assert.equal(page.root.querySelector('.quiz-input').value, '41');
  assert.equal(page.root.querySelector('.quiz-input').disabled, true);
  assert.equal(page.root.querySelector('.quiz-question').classList.contains('is-wrong'), true);
  assert.equal(results(page).length, 0);
  page.root.querySelector('.quiz-footer').querySelector('button').click();
  assert.equal(page.root.querySelector('.quiz-input').value, '');
  assert.equal(page.root.querySelector('.quiz-input').disabled, false);
  assert.equal(page.window.StudyRenderer.getOptions().state.c0, undefined);
  submit(page, '42');
  assert.equal(results(page).length, 1);
  assert.equal(results(page)[0].correct, true);
});

test('数值格式错误不会锁定题目或发送作答结果', () => {
  const page = createBrowser();
  page.window.StudyRenderer.render(quiz('1/2 等于多少？', 0.5), false);
  submit(page, '不合法的数值');
  assert.equal(page.root.querySelector('.quiz-input').classList.contains('is-invalid'), true);
  assert.equal(page.root.querySelector('.quiz-input').disabled, false);
  assert.equal(results(page).length, 0);
  submit(page, '1/2');
  assert.equal(results(page).length, 1);
  assert.equal(results(page)[0].correct, true);
});
