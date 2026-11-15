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

  function render(text, streaming) {
    codeBlocks = [];
    const env = { streaming: !!streaming };
    const html = md.render(text || '', env);
    const context = { before: afterRenderHooks.map((hook) => hook.beforeReplace && hook.beforeReplace(root)) };
    root.innerHTML = html;
    afterRenderHooks.forEach((hook, i) => hook.afterReplace && hook.afterReplace(root, context.before[i], env));
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

  window.StudyRenderer = { render, fenceHandlers, afterRenderHooks, post, escapeHTML };
  // 等后面的扩展脚本（坐标图）都注册完再通知 Swift。
  document.addEventListener('DOMContentLoaded', () => post('ready', true));
})();
