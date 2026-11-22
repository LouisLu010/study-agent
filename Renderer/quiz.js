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

  const CHECK = '<svg class="quiz-mark" viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7"/></svg>';
  const CROSS = '<svg class="quiz-mark" viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/></svg>';

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
    // 顶上一条细进度条："已答 2/5"（只有一道题时不显示）。
    const progress = el('div', 'quiz-progress');
    const progressText = el('span', 'quiz-progress-text');
    const progressTrack = el('span', 'quiz-progress-track');
    const progressFill = el('span', 'quiz-progress-fill');
    progressTrack.appendChild(progressFill);
    progress.append(progressText, progressTrack);
    if (spec.questions.length > 1) container.appendChild(progress);
    const list = el('div', 'quiz-questions');
    container.appendChild(list);
    const footer = el('div', 'quiz-footer');
    container.appendChild(footer);
    // 刚答完的那道题（不是从保存的状态恢复的）：只有它播放对错的动画。
    let justAnswered = null;
    // 上一次刷新时是否已经全部答完。从没答完变成答完时，分数圆环从 0 画到得分；恢复的状态不播放。
    let wasFinished = null;

    function save() {
      // 多选题选了但还没提交的不保存。
      const submitted = {};
      Object.keys(answers).forEach((i) => {
        if (answers[i].submitted !== false) submitted[i] = answers[i];
      });
      ctx.setState(Object.keys(submitted).length ? { answers: submitted } : null);
    }

    /** 用户刚答完一道题（不是从保存的状态恢复），告诉 Swift，答错时会加入错题本。 */
    function report(index) {
      const q = spec.questions[index];
      const answer = answers[index];
      ctx.report('quizResult', {
        question: core.quizQuestionToJSON(q),
        answer: q.type === 'choice' ? { choice: answer.choice } : { input: answer.input },
        correct: isCorrect(q, answer),
      });
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
      if (answered && justAnswered === index) card.classList.add('just-answered');

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
            if (q.answer.includes(k)) {
              button.classList.add('is-answer');
              button.insertAdjacentHTML('beforeend', CHECK);
            } else if (chosen.has(k)) {
              button.classList.add('is-mistake');
              button.insertAdjacentHTML('beforeend', CROSS);
            }
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
                justAnswered = index;
                save();
                report(index);
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
          const submit = el('button', 'sa-button is-primary quiz-submit', '提交');
          submit.disabled = !answer || !answer.choice.length;
          submit.addEventListener('click', () => {
            answers[index] = { choice: answers[index].choice };
            justAnswered = index;
            save();
            report(index);
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
        const submit = el('button', 'sa-button is-primary quiz-submit', '提交');
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
            justAnswered = index;
            save();
            report(index);
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
        if (!correct && window.StudyRenderer.getOptions().recordsMistakes) {
          result.appendChild(el('span', 'quiz-mistake-note', '已加入错题本'));
        }
        if (q.explanation) result.appendChild(el('div', 'quiz-explanation', ctx.renderMarkdown(q.explanation)));
        const ask = el('button', 'quiz-ask', correct ? '问问 AI：再讲讲这道题' : '问问 AI：我哪里错了');
        ask.addEventListener('click', () => askAbout(index));
        result.appendChild(ask);
        card.appendChild(result);
      }
      return card;
    }

    const isDone = (q, i) => !!answers[i] && (q.type === 'number' || !q.multiple || answers[i].submitted !== false);

    /** 分数圆环：答对的比例。刚答完时从 0 画过去（打开"减弱动态效果"时直接画好）。 */
    function scoreRing(score, total, animate) {
      const r = 22;
      const circumference = 2 * Math.PI * r;
      const ring = el('div', 'quiz-ring');
      ring.innerHTML = '<svg viewBox="0 0 56 56" aria-hidden="true"><circle class="quiz-ring-track" cx="28" cy="28" r="' + r +
        '"/><circle class="quiz-ring-fill" cx="28" cy="28" r="' + r + '" transform="rotate(-90 28 28)"/></svg>' +
        '<span class="quiz-ring-text">' + Math.round((100 * score) / total) + '%</span>';
      const fill = ring.querySelector('.quiz-ring-fill');
      const target = circumference * (1 - score / total);
      fill.style.strokeDasharray = String(circumference);
      fill.style.strokeDashoffset = String(animate ? circumference : target);
      if (score === total) ring.classList.add('is-perfect');
      if (animate) requestAnimationFrame(() => requestAnimationFrame(() => { fill.style.strokeDashoffset = String(target); }));
      return ring;
    }

    function refresh() {
      list.innerHTML = '';
      spec.questions.forEach((q, i) => list.appendChild(renderQuestion(q, i)));

      const total = spec.questions.length;
      const doneCount = spec.questions.filter(isDone).length;
      progressText.textContent = '已答 ' + doneCount + '/' + total;
      progressFill.style.width = ((100 * doneCount) / total).toFixed(1) + '%';

      footer.innerHTML = '';
      const finished = doneCount === total;
      const justFinished = finished && wasFinished === false;
      wasFinished = finished;
      const wrong = spec.questions.map((q, i) => i).filter((i) => isDone(spec.questions[i], i) && !isCorrect(spec.questions[i], answers[i]));
      if (finished && total > 1) {
        const score = total - wrong.length;
        const summary = el('div', 'quiz-score');
        summary.appendChild(scoreRing(score, total, justFinished));
        summary.appendChild(el('span', '', '答对 ' + score + ' / ' + total + ' 题'));
        footer.appendChild(summary);
      }
      if (finished && wrong.length && total > 1) {
        // 只清空答错的题，答对的保留。
        const redoWrong = el('button', 'sa-button is-primary', '重做答错的题');
        redoWrong.addEventListener('click', () => {
          wrong.forEach((i) => { delete answers[i]; });
          justAnswered = null;
          save();
          refresh();
        });
        footer.appendChild(redoWrong);
      }
      if (Object.keys(answers).length) {
        const reset = el('button', 'sa-button', '重做');
        reset.addEventListener('click', () => {
          answers = {};
          justAnswered = null;
          ctx.setState(null);
          refresh();
        });
        footer.appendChild(reset);
      }
      justAnswered = null;
    }

    refresh();
  }

  components.register('quiz', { draw });
})();
