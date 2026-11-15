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

  // ---------- 函数表达式 ----------
  //
  // 坐标图里的函数由模型写成字符串，例如 "2x^2 - sin(x)/3"。这里自己解析，不用 eval。
  // 支持 + - * / ^、括号、隐式乘法（2x、3sin(x)、(x+1)(x-1)）、省略括号的函数（sin x）。

  const FUNCTIONS = {
    sin: Math.sin, cos: Math.cos, tan: Math.tan,
    cot: (v) => 1 / Math.tan(v), sec: (v) => 1 / Math.cos(v), csc: (v) => 1 / Math.sin(v),
    asin: Math.asin, acos: Math.acos, atan: Math.atan,
    arcsin: Math.asin, arccos: Math.acos, arctan: Math.atan,
    sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh,
    sqrt: Math.sqrt, cbrt: Math.cbrt, abs: Math.abs, exp: Math.exp,
    ln: Math.log, lg: Math.log10, log2: Math.log2,
    floor: Math.floor, ceil: Math.ceil, round: Math.round, sign: Math.sign,
  };
  // log 一个参数时是常用对数，两个参数 log(a, x) 时是以 a 为底。
  const MULTI_ARG_FUNCTIONS = {
    log: (args) => (args.length === 2 ? Math.log(args[1]) / Math.log(args[0]) : Math.log10(args[0])),
    min: (args) => Math.min(...args),
    max: (args) => Math.max(...args),
  };
  const CONSTANTS = { pi: Math.PI, 'π': Math.PI, e: Math.E };
  const IDENTIFIERS = Object.keys(FUNCTIONS)
    .concat(Object.keys(MULTI_ARG_FUNCTIONS), Object.keys(CONSTANTS), ['x'])
    .sort((a, b) => b.length - a.length);

  function tokenize(source) {
    const tokens = [];
    const text = source.replace(/\*\*/g, '^').replace(/[×·]/g, '*').replace(/−/g, '-');
    let i = 0;
    while (i < text.length) {
      const ch = text[i];
      if (isSpace(ch)) {
        i++;
      } else if (isDigit(ch) || (ch === '.' && isDigit(text[i + 1] || ''))) {
        let j = i;
        while (j < text.length && (isDigit(text[j]) || text[j] === '.')) j++;
        const value = Number(text.slice(i, j));
        if (Number.isNaN(value)) throw new Error('数字格式不对：' + text.slice(i, j));
        tokens.push({ type: 'number', value });
        i = j;
      } else if (/[A-Za-zπ]/.test(ch)) {
        let j = i;
        while (j < text.length && /[A-Za-z0-9π]/.test(text[j])) j++;
        // 把连在一起的字母拆成已知的名字，例如 "xsin" → x、sin。
        let word = text.slice(i, j);
        while (word) {
          const name = IDENTIFIERS.find((id) => word.startsWith(id));
          if (!name) throw new Error('不认识的名字：' + word);
          tokens.push({ type: 'name', value: name });
          word = word.slice(name.length);
          // 名字后面紧跟的数字，例如 "x2"，当作乘法。
          const digits = /^[0-9.]+/.exec(word);
          if (digits && !(name in FUNCTIONS) && !(name in MULTI_ARG_FUNCTIONS)) {
            tokens.push({ type: 'number', value: Number(digits[0]) });
            word = word.slice(digits[0].length);
          }
        }
        i = j;
      } else if ('+-*/^(),'.includes(ch)) {
        tokens.push({ type: ch });
        i++;
      } else {
        throw new Error('不支持的符号：' + ch);
      }
    }
    return tokens;
  }

  function compileExpression(source) {
    if (typeof source !== 'string' || !source.trim()) throw new Error('表达式为空');
    const tokens = tokenize(source);
    let pos = 0;

    const peek = () => tokens[pos];
    const accept = (type) => (tokens[pos] && tokens[pos].type === type ? tokens[pos++] : null);
    const expect = (type) => {
      if (!accept(type)) throw new Error('缺少 ' + type);
    };

    // 下一个记号能否开始一个新的因子（用于隐式乘法）。
    function startsFactor(token) {
      return token && (token.type === 'number' || token.type === 'name' || token.type === '(');
    }

    function parseExpression() {
      let node = parseTerm();
      for (;;) {
        if (accept('+')) {
          const left = node, right = parseTerm();
          node = (x) => left(x) + right(x);
        } else if (accept('-')) {
          const left = node, right = parseTerm();
          node = (x) => left(x) - right(x);
        } else {
          return node;
        }
      }
    }

    function parseTerm() {
      let node = parseUnary();
      for (;;) {
        if (accept('*')) {
          const left = node, right = parseUnary();
          node = (x) => left(x) * right(x);
        } else if (accept('/')) {
          const left = node, right = parseUnary();
          node = (x) => left(x) / right(x);
        } else if (startsFactor(peek())) {
          const left = node, right = parsePower();
          node = (x) => left(x) * right(x);
        } else {
          return node;
        }
      }
    }

    function parseUnary() {
      if (accept('-')) {
        const operand = parseUnary();
        return (x) => -operand(x);
      }
      if (accept('+')) return parseUnary();
      return parsePower();
    }

    function parsePower() {
      const base = parsePrimary();
      if (accept('^')) {
        const exponent = parseUnary();
        return (x) => Math.pow(base(x), exponent(x));
      }
      return base;
    }

    function parseArguments() {
      expect('(');
      const args = [parseExpression()];
      while (accept(',')) args.push(parseExpression());
      expect(')');
      return args;
    }

    function parsePrimary() {
      const token = tokens[pos++];
      if (!token) throw new Error('表达式不完整');
      if (token.type === 'number') {
        const value = token.value;
        return () => value;
      }
      if (token.type === '(') {
        const inner = parseExpression();
        expect(')');
        return inner;
      }
      if (token.type === 'name') {
        const name = token.value;
        if (name === 'x') return (x) => x;
        if (name in CONSTANTS) {
          const value = CONSTANTS[name];
          return () => value;
        }
        if (name in MULTI_ARG_FUNCTIONS) {
          const fn = MULTI_ARG_FUNCTIONS[name];
          const args = parseArguments();
          return (x) => fn(args.map((arg) => arg(x)));
        }
        const fn = FUNCTIONS[name];
        // sin^2(x) 表示 (sin x)^2
        if (accept('^')) {
          const exponent = parseUnary();
          const arg = peek() && peek().type === '(' ? parseArguments()[0] : parsePower();
          return (x) => Math.pow(fn(arg(x)), exponent(x));
        }
        // 有括号时只取括号里的内容；没有括号时（sin x）取后面一个因子。
        const arg = peek() && peek().type === '(' ? parseArguments()[0] : parsePower();
        return (x) => fn(arg(x));
      }
      throw new Error('表达式里有多余的 ' + token.type);
    }

    const node = parseExpression();
    if (pos < tokens.length) throw new Error('表达式里有多余的内容');
    return node;
  }

  // ---------- 坐标图描述 ----------

  /** 数字，或者只含常数的表达式（如 "pi/2"）。 */
  function toNumber(value, what) {
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (typeof value === 'string') {
      const result = compileExpression(value)(NaN);
      if (Number.isFinite(result)) return result;
    }
    throw new Error(what + ' 不是有效的数字');
  }

  function toRange(value, what) {
    if (!Array.isArray(value) || value.length !== 2) throw new Error(what + ' 应该是 [最小值, 最大值]');
    const range = [toNumber(value[0], what), toNumber(value[1], what)];
    if (!(range[0] < range[1])) throw new Error(what + ' 的最小值要小于最大值');
    return range;
  }

  function toPoint(value, what) {
    if (!Array.isArray(value) || value.length !== 2) throw new Error(what + ' 应该是 [x, y]');
    return [toNumber(value[0], what), toNumber(value[1], what)];
  }

  function optionalLabel(value) {
    return typeof value === 'string' && value.trim() ? value.trim() : '';
  }

  /** 根据函数取值自动确定 y 轴范围，去掉渐近线附近的极端值。 */
  function autoYRange(functions, points, segments, xRange) {
    const values = [];
    functions.forEach((f) => {
      const [a, b] = f.domain || xRange;
      for (let i = 0; i <= 200; i++) {
        const y = f.fn(a + ((b - a) * i) / 200);
        if (Number.isFinite(y)) values.push(y);
      }
    });
    points.forEach((p) => values.push(p.y));
    segments.forEach((s) => values.push(s.from[1], s.to[1]));
    if (!values.length) return [xRange[0], xRange[1]];

    values.sort((a, b) => a - b);
    const pick = (q) => values[Math.min(values.length - 1, Math.max(0, Math.round(q * (values.length - 1))))];
    let low = functions.length ? pick(0.03) : values[0];
    let high = functions.length ? pick(0.97) : values[values.length - 1];
    points.concat(segments.flatMap((s) => [{ y: s.from[1] }, { y: s.to[1] }])).forEach((p) => {
      low = Math.min(low, p.y);
      high = Math.max(high, p.y);
    });
    low = Math.min(low, 0);
    high = Math.max(high, 0);
    if (high - low < 1e-9) {
      low -= 1;
      high += 1;
    }
    const pad = (high - low) * 0.1;
    return [low - pad, high + pad];
  }

  /**
   * 解析并校验 ```graph 代码块里的 JSON，返回 { ok: true, value } 或 { ok: false, error }。
   * 格式见 docs/adr/0002 和 StudyKit 里的内置提示词。
   */
  function parseGraphSpec(source) {
    try {
      const raw = JSON.parse(source);
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('坐标图描述应该是一个 JSON 对象');

      const functions = (raw.functions || []).map((f, i) => {
        if (!f || typeof f.expr !== 'string') throw new Error('第 ' + (i + 1) + ' 个函数缺少 expr');
        return {
          expr: f.expr,
          fn: compileExpression(f.expr),
          label: optionalLabel(f.label),
          domain: f.domain ? toRange(f.domain, '函数定义域') : null,
          dashed: f.dashed === true,
        };
      });
      const points = (raw.points || []).map((p) => ({
        x: toNumber(p && p.x, '点的 x 坐标'),
        y: toNumber(p && p.y, '点的 y 坐标'),
        label: optionalLabel(p && p.label),
      }));
      const segments = (raw.segments || []).map((s) => ({
        from: toPoint(s && s.from, '线段起点'),
        to: toPoint(s && s.to, '线段终点'),
        label: optionalLabel(s && s.label),
        dashed: !!(s && s.dashed),
      }));
      if (!functions.length && !points.length && !segments.length) throw new Error('坐标图里没有任何内容');

      const xRange = raw.xRange ? toRange(raw.xRange, 'xRange') : [-10, 10];
      const yRange = raw.yRange ? toRange(raw.yRange, 'yRange') : autoYRange(functions, points, segments, xRange);

      return {
        ok: true,
        value: { title: optionalLabel(raw.title), xRange, yRange, functions, points, segments },
      };
    } catch (error) {
      return { ok: false, error: error.message };
    }
  }

  return { mathPlugin, compileExpression, parseGraphSpec };
});
