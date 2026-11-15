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

  // ---------- 代码块 → HTML ----------

  function placeholderHTML(type, key, hash) {
    return '<div class="sa-component sa-component-loading" data-type="' + type + '" data-key="' + key +
      '" data-hash="' + hash + '"></div>\n';
  }

  function pendingHTML(type) {
    return '<div class="sa-component-pending">正在生成' + escapeHTML(core.componentLabel(type)) + '…</div>\n';
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

  // 深色和浅色模式切换时重画所有组件。
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    document.querySelectorAll('.sa-component[data-hash]').forEach((element) => {
      if (!element.drawn) return;
      destroy(element);
      draw(element);
    });
  });

  // 提示卡片上的"重新生成"按钮。
  document.addEventListener('click', (event) => {
    if (event.target.closest('.sa-regenerate')) renderer.post('regenerate', true);
  });

  window.StudyComponents = { register, loadAssets, isDark };
})();
