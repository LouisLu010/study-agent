/*
 * 汇编排版成 PDF：Swift 调用 window.StudyRenderer.renderPrint(doc)，等图片都加载完再返回。
 * doc：{ title, subtitle, includeAnswers, questions: [{ label, content, answer, answerLabel }] }
 * 分页、页眉页脚由 Swift 的 UIPrintPageRenderer 处理。
 */
(function () {
  'use strict';

  const R = window.StudyRenderer;

  function waitForImages(root, timeout) {
    const pending = Array.from(root.querySelectorAll('img')).filter((img) => !img.complete);
    const all = Promise.all(pending.map((img) => new Promise((resolve) => {
      img.addEventListener('load', resolve, { once: true });
      img.addEventListener('error', resolve, { once: true });
    })));
    return Promise.race([all, new Promise((resolve) => setTimeout(resolve, timeout))]);
  }

  function buildPrintHTML(doc) {
    const esc = R.escapeHTML;
    const questions = doc.questions || [];
    let html = '<h1 class="print-title">' + esc(doc.title || '') + '</h1>';
    if (doc.subtitle) html += '<p class="print-subtitle">' + esc(doc.subtitle) + '</p>';
    questions.forEach((q, i) => {
      html += '<section class="print-question">' +
        '<div class="print-label">' + (i + 1) + '．' + esc(q.label || '') + '</div>' +
        (q.content ? R.renderMarkdown(q.content) : '<p class="print-missing">（未能获取原文）</p>') +
        '<div class="print-space"></div></section>';
    });
    const answered = questions.filter((q) => q.answer);
    if (doc.includeAnswers && answered.length) {
      html += '<section class="print-answers"><h2>答案与解析</h2>';
      questions.forEach((q, i) => {
        if (!q.answer) return;
        html += '<div class="print-answer"><div class="print-label">' + (i + 1) + '．' + esc(q.label || '') +
          (q.answerLabel ? '<span class="print-kind">' + esc(q.answerLabel) + '</span>' : '') + '</div>' +
          R.renderMarkdown(q.answer) + '</div>';
      });
      html += '</section>';
    }
    return html;
  }

  async function renderPrint(doc) {
    document.body.classList.add('print');
    const root = document.getElementById('content');
    root.innerHTML = buildPrintHTML(doc);
    await waitForImages(root, 15000);
    return Math.ceil(root.getBoundingClientRect().height);
  }

  R.renderPrint = renderPrint;
  R.buildPrintHTML = buildPrintHTML;
})();
