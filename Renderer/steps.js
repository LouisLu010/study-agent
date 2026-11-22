/*
 * 分步讲解组件：一步一步展开，每一步可以单独问"这一步没看懂"。
 * 组件状态：{ revealed: 已展开的步数 }
 */
(function () {
  'use strict';

  const components = window.StudyComponents;

  function el(tag, className, html) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (html !== undefined) element.innerHTML = html;
    return element;
  }

  /** 把一步的内容压成一行纯文字，放进"这一步没看懂"的提问里。 */
  function summarize(text) {
    const flat = text.replace(/\s+/g, ' ').trim();
    return flat.length > 160 ? flat.slice(0, 160) + '…' : flat;
  }

  function draw(container, spec, ctx) {
    const total = spec.steps.length;
    const saved = ctx.state && Number(ctx.state.revealed);
    let revealed = Number.isInteger(saved) ? Math.min(total, Math.max(1, saved)) : 1;

    container.innerHTML = '';
    container.classList.add('steps');
    // 顶上一行：标题和"第 3 / 7 步"。
    const top = el('div', 'steps-top');
    if (spec.title) top.appendChild(el('div', 'steps-title', ctx.renderInline(spec.title)));
    const count = el('span', 'steps-count');
    top.appendChild(count);
    container.appendChild(top);
    const list = el('ol', 'steps-list');
    container.appendChild(list);
    const controls = el('div', 'steps-controls');
    container.appendChild(controls);
    // 这次刷新前展开到第几步。比它多出来的步是新展开的，从下方淡入。
    let shownBefore = revealed;

    function setRevealed(next) {
      shownBefore = revealed;
      revealed = Math.min(total, Math.max(1, next));
      ctx.setState(revealed > 1 ? { revealed } : null);
      refresh();
    }

    /** 新展开的一步不在屏幕里时，请 Swift 把外面的聊天列表滚过去。 */
    function reveal(item) {
      requestAnimationFrame(() => {
        const rect = item.getBoundingClientRect();
        window.StudyRenderer.post('reveal', { top: rect.top + window.scrollY, bottom: rect.bottom + window.scrollY });
      });
    }

    function refresh() {
      list.innerHTML = '';
      count.textContent = '第 ' + revealed + ' / ' + total + ' 步';
      let newest = null;
      spec.steps.slice(0, revealed).forEach((step, i) => {
        const item = el('li', 'steps-item');
        const current = i === revealed - 1;
        if (current) item.classList.add('is-current');
        else item.classList.add('is-done');
        if (i >= shownBefore) {
          item.classList.add('is-new');
          newest = item;
        }
        const head = el('div', 'steps-head');
        // 看过的步变成勾，当前这一步的圆点高亮。
        head.appendChild(el('span', 'steps-number', current ? String(i + 1)
          : '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7"/></svg>'));
        head.appendChild(el('span', 'steps-name', step.title ? ctx.renderInline(step.title) : '第 ' + (i + 1) + ' 步'));
        item.appendChild(head);
        item.appendChild(el('div', 'steps-content', ctx.renderMarkdown(step.content)));
        const ask = el('button', 'steps-ask', '这一步没看懂');
        ask.addEventListener('click', () => {
          const name = step.title ? '「' + step.title + '」' : '';
          ctx.ask('分步讲解' + (spec.title ? '「' + spec.title + '」' : '') + '的第 ' + (i + 1) + ' 步' + name +
            '我没看懂：' + summarize(step.content) + '\n能换一种方式，再详细讲讲这一步吗？');
        });
        item.appendChild(ask);
        list.appendChild(item);
      });

      if (newest) reveal(newest);
      shownBefore = revealed;

      controls.innerHTML = '';
      if (revealed < total) {
        const next = el('button', 'sa-button is-primary steps-next', '下一步');
        next.addEventListener('click', () => setRevealed(revealed + 1));
        const all = el('button', 'sa-button', '全部展开');
        all.addEventListener('click', () => setRevealed(total));
        controls.append(all, next);
      }
      if (revealed > 1) {
        const collapse = el('button', 'sa-button', '收起');
        collapse.addEventListener('click', () => setRevealed(1));
        controls.appendChild(collapse);
      }
    }

    refresh();
  }

  components.register('steps', { draw });
})();
