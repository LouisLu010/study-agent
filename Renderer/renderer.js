/*
 * 消息渲染器。Swift 调用 window.StudyRenderer.render(text, streaming) 更新内容，
 * 渲染器通过 webkit.messageHandlers 回传：ready、height、formula（点按公式）、copy（复制代码）。
 */
(function () {
  'use strict';

  const root = document.getElementById('content');
  const core = window.StudyCore;

  function post(name, body) {
    const handlers = window.webkit && window.webkit.messageHandlers;
    if (handlers && handlers[name]) handlers[name].postMessage(body);
  }

  function escapeHTML(text) {
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // ---------- 公式 ----------

  // 生成过程中会反复渲染同一批公式，缓存 KaTeX 的结果。
  const mathCache = new Map();

  function renderMath(tex, display) {
    const key = (display ? 'D' : 'I') + tex;
    let html = mathCache.get(key);
    if (html === undefined) {
      try {
        html = window.katex.renderToString(tex, {
          displayMode: display,
          throwOnError: false,
          strict: 'ignore',
          output: 'html',
        });
      } catch (error) {
        html = '<code>' + escapeHTML(tex) + '</code>';
      }
      if (mathCache.size > 1000) mathCache.clear();
      mathCache.set(key, html);
    }
    const tag = display ? 'div' : 'span';
    return '<' + tag + ' class="sa-math" data-tex="' + escapeHTML(tex) + '">' + html + '</' + tag + '>';
  }

  // ---------- Markdown ----------

  const md = window.markdownit({ html: false, linkify: true, breaks: false });
  core.mathPlugin(md, { renderMath });
  core.citationPlugin(md);
  core.imagePlugin(md);

  md.renderer.rules.table_open = () => '<div class="table-wrap"><table>\n';
  md.renderer.rules.table_close = () => '</table></div>\n';

  // 每次渲染时收集代码块原文，供"复制"按钮使用。
  let codeBlocks = [];
  const highlightCache = new Map();

  function highlight(code, language) {
    if (!language || !window.hljs || !window.hljs.getLanguage(language)) return escapeHTML(code);
    const key = language + '\u0000' + code;
    let html = highlightCache.get(key);
    if (html === undefined) {
      try {
        html = window.hljs.highlight(code, { language, ignoreIllegals: true }).value;
      } catch (error) {
        html = escapeHTML(code);
      }
      if (highlightCache.size > 200) highlightCache.clear();
      highlightCache.set(key, html);
    }
    return html;
  }

  function renderCodeBlock(code, language) {
    const index = codeBlocks.push(code) - 1;
    const languageClass = language ? ' language-' + escapeHTML(language) : '';
    return (
      '<div class="code-block">' +
      '<div class="code-header"><span>' + escapeHTML(language || '代码') + '</span>' +
      '<button class="copy-code" data-index="' + index + '">复制</button></div>' +
      '<pre><code class="hljs' + languageClass + '">' + highlight(code, language) + '</code></pre>' +
      '</div>\n'
    );
  }

  // 其他模块（坐标图）可以在这里注册对特定语言代码块的处理。
  const fenceHandlers = {};

  md.renderer.rules.fence = (tokens, idx, options, env) => {
    const token = tokens[idx];
    const language = (token.info || '').trim().split(/\s+/)[0].toLowerCase();
    const handler = fenceHandlers[language];
    if (handler) {
      const html = handler(token.content, env);
      if (html !== null) return html;
    }
    return renderCodeBlock(token.content, language);
  };

  md.renderer.rules.code_block = (tokens, idx) => renderCodeBlock(tokens[idx].content, '');

  // ---------- 渲染 ----------

  const afterRenderHooks = [];

  /**
   * options：
   *   state         这条消息保存的组件状态，{ 组件键: 状态 }
   *   canRegenerate 是否显示"重新生成"按钮（只有最后一条消息可以）
   *   grouped       放在浅灰底的分组页面上（学习记录）：组件卡片改成白色
   */
  let options = { state: {}, canRegenerate: false };

  function setOptions(next) {
    options = Object.assign({}, options, next || {});
    document.body.classList.toggle('can-regenerate', !!options.canRegenerate);
    document.body.classList.toggle('on-grouped', !!options.grouped);
  }

  function render(text, streaming, nextOptions) {
    if (nextOptions) setOptions(nextOptions);
    if (streaming) {
      renderStreaming(text || '');
      return;
    }
    stream = null;
    codeBlocks = [];
    const env = { streaming: false, options, componentIndex: 0 };
    const html = md.render(text || '', env);
    const context = { before: afterRenderHooks.map((hook) => hook.beforeReplace && hook.beforeReplace(root)) };
    root.innerHTML = html;
    afterRenderHooks.forEach((hook, i) => hook.afterReplace && hook.afterReplace(root, context.before[i], env));
    reportHeight();
  }

  // ---------- 生成中的增量渲染 ----------
  //
  // 生成中每 80 毫秒渲染一次。以前每次都把整条回答从头排版，回答越长越卡。
  // 现在已经写完的段落（core.stableLength 切出来的部分）只排一次，之后只重排最后还在写的部分。
  // 组件编号和代码块编号跨段连续，和整段渲染时一样；生成结束时仍整条重新渲染一次。
  //
  // stream：{ text 已排好的部分, nodes 它占 root 的前几个子节点, componentIndex, codeCount }
  let stream = null;

  /** 把一组节点包成 hooks 能用的范围（只需要 querySelectorAll）。 */
  function nodeScope(nodes) {
    return {
      querySelectorAll(selector) {
        const found = [];
        nodes.forEach((node) => {
          if (node.nodeType !== 1) return;
          if (node.matches(selector)) found.push(node);
          found.push(...node.querySelectorAll(selector));
        });
        return found;
      },
    };
  }

  function htmlNodes(html) {
    const template = document.createElement('template');
    template.innerHTML = html;
    return Array.from(template.content.childNodes);
  }

  function renderStreaming(text) {
    const split = core.stableLength(text);
    if (!stream || !text.startsWith(stream.text) || split < stream.text.length) {
      // 第一次渲染，或者内容不是接着上次写的（例如重新生成）：清空重来。
      const before = afterRenderHooks.map((hook) => hook.beforeReplace && hook.beforeReplace(root));
      root.innerHTML = '';
      afterRenderHooks.forEach((hook, i) => hook.afterReplace && hook.afterReplace(root, before[i], {}));
      stream = { text: '', nodes: 0, componentIndex: 0, codeCount: 0 };
      codeBlocks = [];
    }

    // 摘下上次的"还在写的部分"，里面已经画好的组件交给 hooks 保留。
    const oldTail = Array.from(root.childNodes).slice(stream.nodes);
    const before = afterRenderHooks.map((hook) => hook.beforeReplace && hook.beforeReplace(nodeScope(oldTail)));
    oldTail.forEach((node) => node.remove());
    codeBlocks.length = stream.codeCount;

    const env = { streaming: true, options, componentIndex: stream.componentIndex };
    const inserted = [];
    if (split > stream.text.length) {
      const nodes = htmlNodes(md.render(text.slice(stream.text.length, split), env));
      root.append(...nodes);
      inserted.push(...nodes);
      stream = {
        text: text.slice(0, split),
        nodes: stream.nodes + nodes.length,
        componentIndex: env.componentIndex,
        codeCount: codeBlocks.length,
      };
    }
    const tail = htmlNodes(md.render(text.slice(split), env));
    root.append(...tail);
    inserted.push(...tail);
    afterRenderHooks.forEach((hook, i) => hook.afterReplace && hook.afterReplace(nodeScope(inserted), before[i], env));
    reportHeight();
  }

  // ---------- 高度 ----------

  let lastHeight = -1;
  function reportHeight() {
    const height = Math.ceil(root.getBoundingClientRect().height);
    if (height !== lastHeight) {
      lastHeight = height;
      post('height', height);
    }
  }
  new ResizeObserver(reportHeight).observe(root);

  // ---------- 点按 ----------

  document.addEventListener('click', (event) => {
    const copyButton = event.target.closest('.copy-code');
    if (copyButton) {
      post('copy', codeBlocks[Number(copyButton.dataset.index)] || '');
      copyButton.textContent = '已复制';
      setTimeout(() => { copyButton.textContent = '复制'; }, 1500);
      return;
    }
    const formula = event.target.closest('.sa-math');
    if (formula && !String(window.getSelection() || '')) {
      post('formula', formula.dataset.tex || '');
    }
  });

  window.StudyRenderer = {
    render,
    setOptions,
    getOptions: () => options,
    fenceHandlers,
    afterRenderHooks,
    post,
    escapeHTML,
    renderInline: (text) => md.renderInline(text || '', { streaming: false }),
    // 组件内部的文字（测验题目、分步讲解）：不能再嵌套组件，组件代码块按普通代码显示。
    renderMarkdown: (text) => md.render(text || '', { streaming: false, options, componentIndex: 0, noComponents: true }),
  };
  // 等后面的扩展脚本（组件）都注册完再通知 Swift。
  document.addEventListener('DOMContentLoaded', () => post('ready', true));
})();
