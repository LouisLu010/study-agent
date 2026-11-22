/*
 * 组件框架（见 docs/adr/0006）。
 *
 * 每种组件调用 StudyComponents.register(type, definition)：
 *   load()                     可选，返回 Promise，加载第三方库（第一次用到时才加载）
 *   draw(element, spec, ctx)   把组件画进 element。ctx 见下面的 makeContext
 *   destroy(element)           可选，释放资源
 *
 * 框架负责：
 *   - 生成中代码块还不完整时显示占位框，生成结束后仍不合法时显示提示卡片
 *   - 流式渲染时保留已经画好的组件，不重复绘制
 *   - 组件状态：读取 Swift 传来的初始状态，变化时通过 state 消息回传
 *   - 深色模式切换时重画
 */
(function () {
  'use strict';

  const renderer = window.StudyRenderer;
  const core = window.StudyCore;
  const escapeHTML = renderer.escapeHTML;

  const definitions = {};
  const specs = new Map();
  // 组件代码块的原文，全屏时把这一个组件交给 Swift 单独显示。
  const sources = new Map();
  /** 可以全屏的组件（第八版）。图表不加全屏。 */
  const FULLSCREEN_TYPES = ['simulation', 'graph', 'geometry'];
  // 加载第三方库的 Promise，按组件种类缓存。
  const loading = {};

  function hashKey(text) {
    let hash = 5381;
    for (let i = 0; i < text.length; i++) hash = ((hash << 5) + hash + text.charCodeAt(i)) | 0;
    return (hash >>> 0).toString(36) + '-' + text.length;
  }

  function isDark() {
    return window.matchMedia('(prefers-color-scheme: dark)').matches;
  }

  /** 按需加载脚本和样式（样式放在 renderer.css 前面，让我们的样式能覆盖它）。 */
  function loadAssets(scripts, styles) {
    return Promise.all(
      (styles || []).map((href) => {
        const link = document.createElement('link');
        link.rel = 'stylesheet';
        link.href = href;
        document.head.insertBefore(link, document.head.querySelector('link[href="renderer.css"]'));
        return Promise.resolve();
      }).concat((scripts || []).map((src) => new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = src;
        script.onload = resolve;
        script.onerror = () => reject(new Error(src + ' 加载失败'));
        document.head.appendChild(script);
      }))),
    );
  }

  // ---------- 卡片顶上的一行：图标和组件种类 ----------

  // 每种组件一个小图标（第八版），用 currentColor 画，跟着主题色。
  const ICONS = {
    graph: '<path d="M2 14h12M2 14V2"/><path d="M3.5 11.5c1.6-5.5 3.4-6 4.6-2.8s2.8 3 4.4-4.2"/>',
    geometry: '<path d="M3 13L8 3.2 13 13z"/><circle cx="8" cy="3.2" r="1.3"/>',
    chart: '<path d="M3.5 13.5V8.5M8 13.5V3.5M12.5 13.5V10"/>',
    simulation: '<path d="M4 2.5h8M8 2.5l2.6 6.8"/><circle cx="11.2" cy="11" r="2.4"/>',
    quiz: '<rect x="2.5" y="2.5" width="11" height="11" rx="3"/><path d="M5.4 8.2l1.8 1.8 3.4-3.7"/>',
    steps: '<circle cx="4" cy="4" r="1.6"/><circle cx="4" cy="12" r="1.6"/><path d="M4 5.6v4.8M8 4h6M8 12h6"/>',
  };

  function kindHeaderHTML(type) {
    const icon = ICONS[type] || '<circle cx="8" cy="8" r="5"/>';
    return '<div class="sa-kind"><svg class="sa-kind-icon" viewBox="0 0 16 16" aria-hidden="true">' + icon + '</svg>' +
      '<span>' + escapeHTML(core.componentLabel(type)) + '</span></div>';
  }

  function kindHeader(type) {
    const template = document.createElement('template');
    template.innerHTML = kindHeaderHTML(type);
    return template.content.firstChild;
  }

  const EXPAND_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M9.5 2.5h4v4M13.5 2.5L9 7M6.5 13.5h-4v-4M2.5 13.5L7 9"/></svg>';

  /** 卡片右上角的全屏按钮：把这个组件的原文和当前状态交给 Swift，在原生的全屏页里单独显示。 */
  function fullscreenButton(element) {
    const button = document.createElement('button');
    button.className = 'sa-fullscreen';
    button.setAttribute('aria-label', '全屏');
    button.innerHTML = EXPAND_ICON;
    button.addEventListener('click', () => {
      const key = element.dataset.key;
      const type = element.dataset.type;
      const all = renderer.getOptions().state || {};
      renderer.post('fullscreen', {
        key,
        markdown: '```' + type + '\n' + (sources.get(element.dataset.hash) || '').trim() + '\n```\n',
        state: Object.prototype.hasOwnProperty.call(all, key) ? JSON.stringify(all[key]) : '',
      });
    });
    return button;
  }

  // ---------- 代码块 → HTML ----------

  // 占位框按组件种类给出接近最终大小的高度（见 renderer.css），带淡淡的闪光，组件出现时正文不跳。
  function placeholderHTML(type, key, hash) {
    return '<div class="sa-component sa-component-loading" data-type="' + type + '" data-key="' + key +
      '" data-hash="' + hash + '">' + kindHeaderHTML(type) + '<div class="sa-loading-text">正在加载…</div></div>\n';
  }

  function pendingHTML(type) {
    return '<div class="sa-component-pending" data-type="' + type + '">' + kindHeaderHTML(type) +
      '<div class="sa-loading-text">正在生成' + escapeHTML(core.componentLabel(type)) + '…</div></div>\n';
  }

  function errorHTML(type, source, error) {
    const label = escapeHTML(core.componentLabel(type));
    return (
      '<div class="sa-component-error">' +
      '<div class="sa-error-title">这个' + label + '的格式有误，无法显示</div>' +
      '<div class="sa-error-detail">' + escapeHTML(error || '') + '</div>' +
      '<details><summary>查看原文</summary><pre>' + escapeHTML(source) + '</pre></details>' +
      '<button class="sa-regenerate">重新生成</button>' +
      '</div>\n'
    );
  }

  function register(type, definition) {
    definitions[type] = definition;
    renderer.fenceHandlers[type] = (content, env) => {
      if (env.noComponents) return null;
      // 组件键按出现顺序编号，用来对应保存的组件状态。
      const key = 'c' + env.componentIndex++;
      const result = core.parseComponent(type, content);
      if (result.ok) {
        const hash = type + '-' + hashKey(content.trim());
        specs.set(hash, result.value);
        sources.set(hash, content);
        return placeholderHTML(type, key, hash);
      }
      return env.streaming ? pendingHTML(type) : errorHTML(type, content, result.error);
    };
  }

  // ---------- 状态 ----------

  function makeContext(element) {
    const key = element.dataset.key;
    return {
      key,
      dark: isDark(),
      /** 这个组件保存的状态；没有时为 null。 */
      get state() {
        const all = renderer.getOptions().state || {};
        return Object.prototype.hasOwnProperty.call(all, key) ? all[key] : null;
      },
      /** 保存状态。传 null 表示清除（复位）。 */
      setState(state) {
        const all = Object.assign({}, renderer.getOptions().state || {});
        if (state === null || state === undefined) delete all[key];
        else all[key] = state;
        renderer.setOptions({ state: all });
        renderer.post('state', { key, state: state === undefined ? null : state });
      },
      /** 把组件里发生的事告诉 Swift，例如测验的作答结果。 */
      report(name, body) {
        renderer.post(name, body);
      },
      /** 以用户的名义发一条消息给模型（"问问 AI"）。 */
      ask(text) {
        if (text) renderer.post('ask', String(text));
      },
      renderInline: renderer.renderInline,
      renderMarkdown: renderer.renderMarkdown,
    };
  }

  // ---------- 绘制 ----------

  function draw(element) {
    const definition = definitions[element.dataset.type];
    const spec = specs.get(element.dataset.hash);
    if (!definition || !spec) return;
    element.classList.remove('sa-component-loading');
    try {
      definition.draw(element, spec, makeContext(element));
      const header = kindHeader(element.dataset.type);
      const options = renderer.getOptions();
      if (FULLSCREEN_TYPES.includes(element.dataset.type) && options.canFullscreen && !options.fullscreen) {
        header.appendChild(fullscreenButton(element));
      }
      element.prepend(header);
      element.drawn = true;
    } catch (error) {
      element.innerHTML = errorHTML(element.dataset.type, '', error.message);
    }
  }

  function mount(element) {
    const type = element.dataset.type;
    const definition = definitions[type];
    if (!definition) return;
    if (!definition.load) {
      draw(element);
      return;
    }
    if (!loading[type]) loading[type] = definition.load();
    loading[type]
      .then(() => {
        // 加载期间元素可能正好被流式渲染摘下来了，放回页面后再画，否则尺寸是 0。
        if (element.isConnected) draw(element);
        else element.needsDraw = true;
      })
      .catch((error) => {
        element.classList.remove('sa-component-loading');
        element.textContent = core.componentLabel(type) + '加载失败：' + error.message;
      });
  }

  function destroy(element) {
    const definition = definitions[element.dataset.type];
    if (definition && definition.destroy && element.drawn) definition.destroy(element);
    element.drawn = false;
  }

  renderer.afterRenderHooks.push({
    // 替换 innerHTML 之前，把已经挂载的组件摘下来，按"键 + 内容"保存。
    beforeReplace(root) {
      const kept = new Map();
      root.querySelectorAll('.sa-component[data-hash]').forEach((element) => {
        kept.set(element.dataset.key + '|' + element.dataset.hash, element);
        element.remove();
      });
      return kept;
    },
    // 替换之后，内容没变的组件放回原处，新的组件开始绘制，消失的组件释放。
    afterReplace(root, kept) {
      root.querySelectorAll('.sa-component[data-hash]').forEach((placeholder) => {
        const id = placeholder.dataset.key + '|' + placeholder.dataset.hash;
        const element = kept.get(id);
        if (element) {
          placeholder.replaceWith(element);
          kept.delete(id);
          if (element.needsDraw) {
            element.needsDraw = false;
            draw(element);
          }
        } else {
          mount(placeholder);
        }
      });
      kept.forEach(destroy);
    },
  });

  function redrawAll(filter) {
    document.querySelectorAll('.sa-component[data-hash]').forEach((element) => {
      if (!element.drawn || (filter && !filter(element))) return;
      destroy(element);
      draw(element);
    });
  }

  // 深色和浅色模式切换时重画所有组件。
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => redrawAll());

  // 全屏页转屏时，坐标图和几何图按新的大小重画（模拟的画布自己会跟着变）。
  let resizeTimer = 0;
  window.addEventListener('resize', () => {
    if (!renderer.getOptions().fullscreen) return;
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => redrawAll((element) => element.dataset.type !== 'simulation'), 250);
  });

  /** 全屏页关掉后，Swift 把那边改过的组件状态交回来：换上新状态重画这个组件。 */
  function applyState(key, state) {
    const all = Object.assign({}, renderer.getOptions().state || {});
    if (state === null || state === undefined) delete all[key];
    else all[key] = state;
    renderer.setOptions({ state: all });
    redrawAll((element) => element.dataset.key === key);
  }

  // ---------- 手势和外层聊天列表 ----------
  //
  // 聊天列表是 WebView 外面的原生 UIScrollView，它会收到 WebView 里的所有触摸，
  // 网页里的 preventDefault 和 touch-action 都拦不住它。所以在组件开始处理手势时通知 Swift，
  // 由 Swift 暂停聊天列表的滚动，所有手指离开后再恢复：
  //   - 坐标图：两根手指（拖动、缩放）
  //   - 几何图：任意触摸（单指拖动点）
  //   - 滑块：任意触摸（左右拖动时列表不应该上下晃）
  let scrollLocked = false;

  function wantsLock(event) {
    const target = event.target;
    if (!(target instanceof Element)) return false;
    if (target.closest('input[type=range]')) return true;
    const component = target.closest('.sa-component');
    if (!component || !target.closest('.jxgbox')) return false;
    if (component.dataset.type === 'geometry') return true;
    return event.touches.length >= 2;
  }

  function setScrollLock(locked) {
    if (locked === scrollLocked) return;
    scrollLocked = locked;
    renderer.post('scrollLock', locked);
  }

  document.addEventListener('touchstart', (event) => {
    if (wantsLock(event)) setScrollLock(true);
  }, { passive: true, capture: true });

  // 两根手指在坐标图上移动时，不让 WebView 自己把它当成页面滚动（否则 JSXGraph 收不到后续事件）。
  document.addEventListener('touchmove', (event) => {
    if (scrollLocked && event.touches.length >= 2 && event.cancelable) event.preventDefault();
  }, { passive: false, capture: true });

  const release = (event) => {
    if (event.touches.length === 0) setScrollLock(false);
  };
  document.addEventListener('touchend', release, { capture: true });
  document.addEventListener('touchcancel', release, { capture: true });

  // 提示卡片上的"重新生成"按钮。
  document.addEventListener('click', (event) => {
    if (event.target.closest('.sa-regenerate')) renderer.post('regenerate', true);
  });

  window.StudyComponents = {
    register,
    loadAssets,
    isDark,
    /** 组件自己处理一个手势时（坐标图按住查看数值）暂停外层聊天列表的滚动，结束后恢复。 */
    lockScroll: setScrollLock,
    applyState,
  };
})();
