/*
 * 渲染器中不依赖 DOM 的部分：markdown-it 公式插件。
 * 在 WebView 里挂到 window.StudyCore；在 Node 里通过 require 加载，用于测试。
 */
(function (root, factory) {
  const core = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = core;
  } else {
    root.StudyCore = core;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function isSpace(ch) {
    return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r';
  }

  function isDigit(ch) {
    return ch >= '0' && ch <= '9';
  }

  /** 位置 pos 前面连续反斜杠的个数。 */
  function backslashesBefore(src, pos) {
    let count = 0;
    while (pos - 1 - count >= 0 && src[pos - 1 - count] === '\\') count++;
    return count;
  }

  /** 找到没有被反斜杠转义的 delimiter。 */
  function findUnescaped(src, delimiter, from, max) {
    let i = from;
    while (i < max) {
      const j = src.indexOf(delimiter, i);
      if (j < 0 || j + delimiter.length > max) return -1;
      if (backslashesBefore(src, j) % 2 === 0) return j;
      i = j + 1;
    }
    return -1;
  }

  /**
   * 找到行内公式 $...$ 的结束符，规则与 Pandoc 相同：
   * 结束的 $ 左边不能是空白，右边不能紧跟数字（避免把 "$5 和 $10" 当成公式）。
   */
  function findDollarClose(src, from, max) {
    let i = from;
    while (i < max) {
      const j = findUnescaped(src, '$', i, max);
      if (j < 0) return -1;
      if (src[j + 1] === '$') {
        i = j + 2;
        continue;
      }
      if (!isSpace(src[j - 1]) && !(j + 1 < max && isDigit(src[j + 1]))) return j;
      i = j + 1;
    }
    return -1;
  }

  const INLINE_DELIMITERS = [
    { open: '\\(', close: '\\)', display: false },
    { open: '\\[', close: '\\]', display: true },
    { open: '$$', close: '$$', display: true },
    { open: '$', close: '$', display: false },
  ];

  function mathInline(state, silent) {
    const src = state.src;
    const start = state.pos;
    const max = state.posMax;

    const delimiter = INLINE_DELIMITERS.find((d) => src.startsWith(d.open, start));
    if (!delimiter) return false;
    if (delimiter.open === '$' && backslashesBefore(src, start) % 2 === 1) return false;

    const contentStart = start + delimiter.open.length;
    let end;
    if (delimiter.open === '$') {
      if (contentStart >= max || isSpace(src[contentStart])) return false;
      end = findDollarClose(src, contentStart, max);
    } else if (delimiter.open === '$$') {
      end = findUnescaped(src, '$$', contentStart, max);
    } else {
      end = src.indexOf(delimiter.close, contentStart);
      if (end + delimiter.close.length > max) end = -1;
    }
    if (end < 0) return false;

    const content = src.slice(contentStart, end);
    if (!content.trim()) return false;

    if (!silent) {
      const token = state.push(delimiter.display ? 'math_inline_display' : 'math_inline', 'math', 0);
      token.content = content;
      token.markup = delimiter.open;
    }
    state.pos = end + delimiter.close.length;
    return true;
  }

  /**
   * 块级公式：以 $$ 或 \[ 开头的行。
   * 生成过程中（env.streaming 为 true）如果还没有闭合，就生成 math_pending，显示灰色源码。
   */
  function mathBlock(state, startLine, endLine, silent) {
    if (state.sCount[startLine] - state.blkIndent >= 4) return false;

    const firstStart = state.bMarks[startLine] + state.tShift[startLine];
    const firstEnd = state.eMarks[startLine];
    const firstText = state.src.slice(firstStart, firstEnd);

    let open;
    let close;
    if (firstText.startsWith('$$')) {
      open = '$$';
      close = '$$';
    } else if (firstText.startsWith('\\[')) {
      open = '\\[';
      close = '\\]';
    } else {
      return false;
    }

    const lines = [];
    let found = false;
    let nextLine = startLine;
    let rest = firstText.slice(open.length);

    for (;;) {
      const closeAt = close === '$$' ? findUnescaped(rest, '$$', 0, rest.length) : rest.indexOf(close);
      if (closeAt >= 0) {
        // 结束符后面还有文字时交给行内规则处理。
        if (rest.slice(closeAt + close.length).trim() !== '') return false;
        lines.push(rest.slice(0, closeAt));
        found = true;
        break;
      }
      lines.push(rest);
      nextLine++;
      if (nextLine >= endLine) break;
      if (state.sCount[nextLine] < state.blkIndent && !state.isEmpty(nextLine)) {
        nextLine--;
        break;
      }
      rest = state.src.slice(state.bMarks[nextLine] + state.tShift[nextLine], state.eMarks[nextLine]);
    }

    if (!found && !(state.env && state.env.streaming)) return false;
    if (silent) return true;

    const token = state.push(found ? 'math_block' : 'math_pending', 'math', 0);
    token.block = true;
    token.content = lines.join('\n');
    token.markup = open;
    token.map = [startLine, Math.min(nextLine + 1, endLine)];
    state.line = Math.min(nextLine + 1, endLine);
    return true;
  }

  /**
   * 给 markdown-it 加上 LaTeX 公式支持。
   * options.renderMath(tex, displayMode) 返回公式的 HTML。
   */
  function mathPlugin(md, options) {
    const renderMath = options.renderMath;
    md.inline.ruler.before('escape', 'math_inline', mathInline);
    md.block.ruler.before('fence', 'math_block', mathBlock, {
      alt: ['paragraph', 'reference', 'blockquote', 'list'],
    });
    md.renderer.rules.math_inline = (tokens, idx) => renderMath(tokens[idx].content, false);
    md.renderer.rules.math_inline_display = (tokens, idx) => renderMath(tokens[idx].content, true);
    md.renderer.rules.math_block = (tokens, idx) =>
      '<div class="math-block">' + renderMath(tokens[idx].content, true) + '</div>\n';
    md.renderer.rules.math_pending = (tokens, idx) =>
      '<pre class="math-pending">' + md.utils.escapeHtml(tokens[idx].markup + tokens[idx].content) + '</pre>\n';
  }

  return { mathPlugin };
});
