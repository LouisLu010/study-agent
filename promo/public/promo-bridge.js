// 给 Remotion 调用的接口：载入一条回答、等组件画好、模拟手指的操作。
// 操作都通过渲染器自己的 DOM 事件完成，和用户在 App 里点、拖走的是同一条路。
(function () {
  'use strict';

  function component(index) {
    const all = document.querySelectorAll('#content .sa-component');
    const element = all[index];
    if (!element) throw new Error('没有第 ' + index + ' 个组件');
    return element;
  }

  function find(index, selector, nth) {
    const list = component(index).querySelectorAll(selector);
    const element = list[nth || 0];
    if (!element) throw new Error('组件 ' + index + ' 里没有 ' + selector + '[' + (nth || 0) + ']');
    return element;
  }

  function pointer(type, element) {
    const rect = element.getBoundingClientRect();
    const init = { bubbles: true, cancelable: true, clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2, pointerId: 1, isPrimary: true };
    element.dispatchEvent(typeof PointerEvent === 'function' ? new PointerEvent(type, init) : new MouseEvent(type, init));
  }

  window.__promo = {
    /** 载入整条回答的 Markdown，和 App 里生成结束后的那次渲染一样。 */
    render(markdown, options) {
      window.StudyRenderer.render(markdown, false, Object.assign({ recordsMistakes: true, canFullscreen: true }, options || {}));
    },

    /**
     * 汇编的 PDF：和 App 里一样用 print.js 排版。App 里由 UIPrintPageRenderer 分页，
     * 这里用 CSS 多栏代替：每栏是一页的可打印区域，浏览器按 print.js 写的 break-* 规则断页。
     */
    async print(doc, page) {
      await window.StudyRenderer.renderPrint(doc);
      if (page) {
        const style = document.createElement('style');
        style.textContent = '#content { column-width: ' + page.width + 'px; column-gap: ' + page.gap + 'px; column-fill: auto; height: ' +
          page.height + 'px; padding: 0; } html, body { background: #fff; }';
        document.head.appendChild(style);
      }
    },

    /** 组件都画好了（JSXGraph 这类库是按需加载的），字体也加载完了。 */
    ready() {
      return !document.querySelector('.sa-component-loading') && document.fonts.status === 'loaded';
    },

    height() {
      return Math.ceil(document.getElementById('content').getBoundingClientRect().height);
    },

    /** 每个组件在页面里的位置，Remotion 用来把镜头推到卡片上。 */
    rects() {
      return Array.from(document.querySelectorAll('#content .sa-component')).map((element) => {
        const r = element.getBoundingClientRect();
        return { x: r.left, y: r.top + window.scrollY, width: r.width, height: r.height };
      });
    },

    /** 拖滑块：phase 是 begin（按下）、move（拖到 value）、end（松手）。 */
    slider(index, selector, nth, value, phase) {
      const input = find(index, selector, nth);
      if (phase === 'begin') {
        pointer('pointerdown', input);
        return;
      }
      if (value !== undefined && value !== null) {
        input.value = String(value);
        input.dispatchEvent(new Event('input', { bubbles: true }));
      }
      if (phase === 'end') {
        input.dispatchEvent(new Event('change', { bubbles: true }));
        pointer('pointerup', input);
      }
    },

    click(index, selector, nth) {
      const element = find(index, selector, nth);
      pointer('pointerdown', element);
      pointer('pointerup', element);
      element.click();
    },

    /** 测验：第 question 题选第 option 个选项（从 0 开始）。点完以后整个列表会重建，所以每次都重新找。 */
    answer(index, question, option) {
      const q = find(index, '.quiz-question', question);
      const button = q.querySelectorAll('.quiz-option')[option];
      if (!button) throw new Error('第 ' + question + ' 题没有第 ' + option + ' 个选项');
      button.click();
    },
  };
})();
