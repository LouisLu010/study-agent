/*
 * 测验组件：选择题（单选、多选）和数值填空，在本地判分并显示解析。
 * 组件状态：{ answers: { 题号: { choice: [序号] } 或 { input: "用户输入" } } }
 */
(function () {
  'use strict';

  const components = window.StudyComponents;
  const core = window.StudyCore;
  const escapeHTML = window.StudyRenderer.escapeHTML;
  const LETTERS = 'ABCDEFGH';

  function el(tag, className, html) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (html !== undefined) element.innerHTML = html;
    return element;
  }

  function isCorrect(question, answer) {
    if (!answer) return false;
    if (question.type === 'choice') {
      const chosen = (answer.choice || []).slice().sort((a, b) => a - b);
      return chosen.length === question.answer.length && chosen.every((v, i) => v === question.answer[i]);
    }
    return core.isNumberCorrect(core.evaluateNumberInput(answer.input), question);
  }

  function restore(spec, saved) {
    const answers = {};
    const raw = saved && saved.answers;
    if (raw && typeof raw === 'object') {
      spec.questions.forEach((q, i) => {
        const a = raw[i];
        if (!a) return;
        if (q.type === 'choice' && Array.isArray(a.choice)) {
          const choice = a.choice.filter((k) => Number.isInteger(k) && k >= 0 && k < q.options.length);
          if (choice.length) answers[i] = { choice };
        } else if (q.type === 'number' && typeof a.input === 'string') {
          answers[i] = { input: a.input };
        }
      });
    }
    return answers;
  }

  function draw(container, spec, ctx) {
    let answers = restore(spec, ctx.state);
    container.innerHTML = '';
    container.classList.add('quiz');

    if (spec.title) container.appendChild(el('div', 'quiz-title', ctx.renderInline(spec.title)));
    const list = el('div', 'quiz-questions');
    container.appendChild(list);
    const footer = el('div', 'quiz-footer');
    container.appendChild(footer);

    function save() {
      // 多选题选了但还没提交的不保存。
      const submitted = {};
      Object.keys(answers).forEach((i) => {
        if (answers[i].submitted !== false) submitted[i] = answers[i];
      });
      ctx.setState(Object.keys(submitted).length ? { answers: submitted } : null);
    }

    function askAbout(index) {
      const q = spec.questions[index];
      const answer = answers[index];
      const correct = isCorrect(q, answer);
      let mine;
      let right;
      if (q.type === 'choice') {
        mine = (answer.choice || []).map((k) => LETTERS[k] + '（' + q.options[k] + '）').join('、');
        right = q.answer.map((k) => LETTERS[k]).join('、');
      } else {
        mine = answer.input + (q.unit ? ' ' + q.unit : '');
        right = core.formatNumber(q.answer, 4) + (q.unit ? ' ' + q.unit : '');
      }
      const head = '关于测验第 ' + (index + 1) + ' 题「' + q.question + '」：';
      ctx.ask(correct
        ? head + '我答的是 ' + mine + '，答对了，能再讲讲这道题考查的知识点吗？'
        : head + '我答的是 ' + mine + '，正确答案是 ' + right + '。我哪里想错了？请一步一步讲解。');
    }

    function renderQuestion(q, index) {
      const card = el('div', 'quiz-question');
      const answer = answers[index];
      const answered = !!answer && (q.type === 'number' || !q.multiple || answer.submitted !== false);
      const correct = answered && isCorrect(q, answer);
      if (answered) card.classList.add(correct ? 'is-correct' : 'is-wrong');

      const head = el('div', 'quiz-head');
      head.appendChild(el('span', 'quiz-number', String(index + 1)));
      head.appendChild(el('div', 'quiz-text', ctx.renderMarkdown(q.question)));
      card.appendChild(head);

      if (q.type === 'choice') {
        if (q.multiple) card.appendChild(el('div', 'quiz-hint', '多选题，可以选多个'));
        const options = el('div', 'quiz-options');
        const chosen = new Set(answer ? answer.choice : []);
        q.options.forEach((option, k) => {
          const button = el('button', 'quiz-option');
          button.innerHTML = '<span class="quiz-letter">' + LETTERS[k] + '</span><span class="quiz-option-text">' +
            ctx.renderInline(option) + '</span>';
          if (chosen.has(k)) button.classList.add('is-chosen');
          if (answered) {
            button.disabled = true;
            if (q.answer.includes(k)) button.classList.add('is-answer');
            else if (chosen.has(k)) button.classList.add('is-mistake');
          } else {
            button.addEventListener('click', () => {
              if (q.multiple) {
                const next = new Set(answers[index] ? answers[index].choice : []);
                if (next.has(k)) next.delete(k);
                else next.add(k);
                if (next.size) answers[index] = { choice: [...next].sort((a, b) => a - b), submitted: false };
                else delete answers[index];
              } else {
                answers[index] = { choice: [k] };
                save();
              }
              refresh();
            });
          }
          options.appendChild(button);
          if (answered && chosen.has(k) && q.optionExplanations[k]) {
            options.appendChild(el('div', 'quiz-option-explanation', ctx.renderMarkdown(q.optionExplanations[k])));
          }
        });
        card.appendChild(options);
        if (q.multiple && !answered) {
          const submit = el('button', 'sa-button quiz-submit', '提交');
          submit.disabled = !answer || !answer.choice.length;
          submit.addEventListener('click', () => {
            answers[index] = { choice: answers[index].choice };
            save();
            refresh();
          });
          card.appendChild(submit);
        }
      } else {
        const row = el('div', 'quiz-input-row');
        const input = el('input', 'quiz-input');
        input.type = 'text';
        input.inputMode = 'decimal';
        input.autocomplete = 'off';
        input.placeholder = '输入数值，可以写分数如 1/3';
        input.value = answer ? answer.input : '';
        row.appendChild(input);
        if (q.unit) row.appendChild(el('span', 'quiz-unit', escapeHTML(q.unit)));
        const submit = el('button', 'sa-button quiz-submit', '提交');
        row.appendChild(submit);
        card.appendChild(row);
        if (answered) {
          input.disabled = true;
          submit.hidden = true;
        } else {
          const doSubmit = () => {
            const text = input.value.trim();
            if (!text) return;
            if (!Number.isFinite(core.evaluateNumberInput(text))) {
              input.classList.add('is-invalid');
              return;
            }
            answers[index] = { input: text };
            save();
            refresh();
          };
          submit.addEventListener('click', doSubmit);
          input.addEventListener('keydown', (event) => {
            if (event.key === 'Enter') doSubmit();
          });
          input.addEventListener('input', () => input.classList.remove('is-invalid'));
        }
      }

      if (answered) {
        const result = el('div', 'quiz-result');
        let verdict = correct ? '✓ 回答正确' : '✗ 回答错误';
        if (!correct) {
          verdict += q.type === 'choice'
            ? '，正确答案是 ' + q.answer.map((k) => LETTERS[k]).join('、')
            : '，正确答案是 ' + core.formatNumber(q.answer, 4) + (q.unit ? ' ' + q.unit : '');
        }
        result.appendChild(el('div', 'quiz-verdict', escapeHTML(verdict)));
        if (q.explanation) result.appendChild(el('div', 'quiz-explanation', ctx.renderMarkdown(q.explanation)));
        const ask = el('button', 'quiz-ask', correct ? '问问 AI：再讲讲这道题' : '问问 AI：我哪里错了');
        ask.addEventListener('click', () => askAbout(index));
        result.appendChild(ask);
        card.appendChild(result);
      }
      return card;
    }

    function refresh() {
      list.innerHTML = '';
      spec.questions.forEach((q, i) => list.appendChild(renderQuestion(q, i)));

      footer.innerHTML = '';
      const done = spec.questions.filter((q, i) => answers[i] && (q.type === 'number' || answers[i].submitted !== false));
      if (done.length === spec.questions.length && spec.questions.length > 1) {
        const score = spec.questions.filter((q, i) => isCorrect(q, answers[i])).length;
        footer.appendChild(el('div', 'quiz-score', '答对 ' + score + ' / ' + spec.questions.length + ' 题'));
      }
      if (Object.keys(answers).length) {
        const reset = el('button', 'sa-button', '重做');
        reset.addEventListener('click', () => {
          answers = {};
          ctx.setState(null);
          refresh();
        });
        footer.appendChild(reset);
      }
    }

    refresh();
  }

  components.register('quiz', { draw });
})();
