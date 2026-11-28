// 用 `node --test RendererTests/*.test.js` 运行。
const test = require('node:test');
const assert = require('node:assert/strict');
const { createBrowser } = require('./helpers/browser.js');
const katex = require('../Renderer/vendor/katex/katex.min.js');

function printPage(doc) {
  const page = createBrowser(['renderer.js', 'print.js']);
  page.window.katex = katex;
  page.root.innerHTML = page.window.StudyRenderer.buildPrintHTML(doc);
  return page;
}

test('组名变了才印组标题，题号接着往下编', () => {
  const { root } = printPage({
    title: '有机大题',
    includeAnswers: false,
    questions: [
      { label: 'A', content: '一', group: '合成路线' },
      { label: 'B', content: '二', group: '合成路线' },
      { label: 'C', content: '三', group: '同分异构' },
      { label: 'D', content: '四', group: '' },
    ],
  });
  assert.equal(root.querySelectorAll('.print-group').length, 2);
  assert.ok(root.textContent.indexOf('合成路线') < root.textContent.indexOf('1．A'));
  assert.ok(root.textContent.indexOf('同分异构') > root.textContent.indexOf('2．B'));
  assert.ok(root.textContent.includes('3．C') && root.textContent.includes('4．D'));
});

test('没有分组时和以前一样', () => {
  const { root } = printPage({ title: 't', questions: [{ label: 'A', content: '一' }] });
  assert.equal(root.querySelector('.print-group'), null);
  assert.ok(root.textContent.includes('1．A'));
});

test('所有题目排完后才附答案，缺答案保持原题号且不显示来源标签', () => {
  const { root } = printPage({
    title: '化学专题', includeAnswers: true,
    questions: [
      { label: '北京卷第 17 题', content: '第一题原文', answer: '第一题答案', answerLabel: '网站解析 · 题库' },
      { label: '北京卷第 18 题', content: '第二题原文', answer: ' \n ', answerLabel: 'AI 解析' },
      { label: '全国卷第 19 题', content: '第三题原文', answer: '第三题答案', answerLabel: '官方答案' },
    ],
  });
  const questions = root.querySelectorAll('.print-question');
  const appendix = root.querySelector('.print-answers');
  assert.equal(questions.length, 3);
  assert.equal(appendix.querySelector('h2').textContent, '答案与解析');
  assert.ok(root.childNodes.indexOf(appendix) > root.childNodes.indexOf(questions.at(-1)));
  assert.ok(questions.every((question) => !question.textContent.includes('答案')));
  const answers = appendix.querySelectorAll('.print-answer');
  assert.equal(answers.length, 3);
  assert.deepEqual(answers.map((answer) => answer.querySelector('.print-label').textContent), [
    '1．北京卷第 17 题网站解析 · 题库', '2．北京卷第 18 题', '3．全国卷第 19 题官方答案',
  ]);
  assert.ok(answers[0].textContent.includes('第一题答案'));
  assert.equal(answers[1].querySelector('.print-missing').textContent, '（暂无答案）');
  assert.equal(answers[1].querySelector('.print-kind'), null);
  assert.ok(answers[2].textContent.includes('第三题答案'));
});

test('答案附录保留真实 Markdown、公式、原图和 AI 来源标签', () => {
  const { root } = printPage({
    title: '数学题', includeAnswers: true,
    questions: [{
      label: '第 17 题', content: '求 $x^2$。\n\n![](sa-asset:question-image)',
      answer: '**解析**：$x=2$，因此 $x^2=4$。\n\n![](sa-asset:answer-image)', answerLabel: 'AI 解析',
    }],
  });
  const question = root.querySelector('.print-question');
  const answer = root.querySelector('.print-answer');
  assert.equal(question.querySelector('img').getAttribute('src'), 'sa-asset:question-image');
  assert.equal(answer.querySelector('img').getAttribute('src'), 'sa-asset:answer-image');
  assert.equal(answer.querySelector('strong').textContent, '解析');
  assert.equal(answer.querySelector('.print-kind').textContent, 'AI 解析');
  assert.deepEqual(answer.querySelectorAll('.sa-math').map((math) => math.getAttribute('data-tex')), ['x=2', 'x^2=4']);
  assert.equal(answer.querySelectorAll('.katex').length, 2);
  assert.equal(question.querySelectorAll('.katex').length, 1);
});

test('关闭答案选项时仅打印题目', () => {
  const { root } = printPage({
    title: '题目', includeAnswers: false,
    questions: [{ label: 'A', content: '题干', answer: '已有答案', answerLabel: '官方答案' }],
  });
  assert.equal(root.querySelectorAll('.print-question').length, 1);
  assert.equal(root.querySelector('.print-answers'), null);
  assert.ok(!root.textContent.includes('已有答案'));
});

test('整份没有有效答案时不产生空附录', () => {
  for (const questions of [[], [
    { label: 'A', content: '题干甲', answer: '' },
    { label: 'B', content: '题干乙', answer: ' \n\t ' },
    { label: 'C', content: '题干丙' },
  ]]) {
    const { root } = printPage({ title: '题目', includeAnswers: true, questions });
    assert.equal(root.querySelector('.print-answers'), null);
    assert.equal(root.querySelectorAll('.print-question').length, questions.length);
  }
});

test('打印接口等题目与末尾答案中的图片都加载结束才返回排版高度', async () => {
  const page = createBrowser(['renderer.js', 'print.js']);
  let finished = false;
  const rendering = page.window.StudyRenderer.renderPrint({
    title: '图题', includeAnswers: true,
    questions: [{ label: 'A', content: '![](sa-asset:question)', answer: '![](sa-asset:answer)' }],
  }).then((height) => { finished = true; return height; });
  const images = page.root.querySelectorAll('img');
  assert.equal(images.length, 2);
  assert.ok(page.document.body.classList.contains('print'));
  images[0].dispatchEvent({ type: 'load' });
  await new Promise(setImmediate);
  assert.equal(finished, false);
  images[1].dispatchEvent({ type: 'load' });
  assert.ok(await rendering > 0);
  assert.equal(finished, true);
});
