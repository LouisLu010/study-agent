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
  const BUILTIN_NAMES = Object.keys(FUNCTIONS).concat(Object.keys(MULTI_ARG_FUNCTIONS), Object.keys(CONSTANTS), ['x']);

  /** 可以用作参数名的名字：字母开头，不能和 x、常数、函数重名。 */
  // 参数名可以用希腊字母（ω、φ、θ…），π 是常数除外。
  const GREEK = 'α-ωΑ-Ω';
  const NAME_START = new RegExp('[A-Za-z' + GREEK + ']');
  const NAME_CHAR = new RegExp('[A-Za-z0-9' + GREEK + ']');
  const PARAM_NAME = new RegExp('^[A-Za-z' + GREEK + '][A-Za-z0-9' + GREEK + ']*$');
  const PLACEHOLDER = new RegExp('\\{([A-Za-z' + GREEK + '][A-Za-z0-9' + GREEK + ']*)\\}', 'g');

  function isValidParamName(name) {
    return typeof name === 'string' && PARAM_NAME.test(name) && !BUILTIN_NAMES.includes(name);
  }

  function tokenize(source, variables, aliases) {
    const aliasNames = Object.keys(aliases || {});
    const IDENTIFIERS = BUILTIN_NAMES.concat(variables || [], aliasNames).sort((a, b) => b.length - a.length);
    const tokens = [];
    const text = source
      .replace(/\*\*/g, '^')
      .replace(/[×·]/g, '*')
      .replace(/−/g, '-')
      // 模型偶尔把实时公式的写法 {a} 用到表达式里，当作 a。
      .replace(PLACEHOLDER, '($1)');
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
      } else if (NAME_START.test(ch)) {
        let j = i;
        while (j < text.length && NAME_CHAR.test(text[j])) j++;
        // 把连在一起的字母拆成已知的名字，例如 "xsin" → x、sin。
        let word = text.slice(i, j);
        while (word) {
          const name = IDENTIFIERS.find((id) => word.startsWith(id));
          if (!name) throw new Error('不认识的名字：' + word);
          tokens.push({ type: 'name', value: aliasNames.includes(name) ? aliases[name] : name });
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

  /**
   * 把表达式编译成函数 f(x, scope)。variables 是允许出现的参数名，scope 是 { 参数名: 值 }。
   * 参数通过下面的 scope 变量传给各个节点；JS 是单线程的，求值过程中不会被打断。
   */
  function compileExpression(source, variables, aliases) {
    if (typeof source !== 'string' || !source.trim()) throw new Error('表达式为空');
    const variableNames = variables || [];
    const tokens = tokenize(source, variableNames, aliases);
    let pos = 0;
    let scope = {};

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
        if (variableNames.includes(name)) return () => scope[name];
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
    return (x, values) => {
      scope = values || {};
      return node(x);
    };
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

  /**
   * 可以含参数的数值：数字，或者由常数和参数组成的表达式（如 "-b/(2a)"）。
   * 返回 { value: 参数取初始值时的值, at(scope): 任意参数下的值 }。
   */
  function toDynamic(value, what, names, defaults) {
    if (typeof value === 'number' && Number.isFinite(value)) {
      return { value, at: () => value };
    }
    if (typeof value === 'string') {
      const compiled = compileExpression(value, names);
      const initial = compiled(NaN, defaults);
      if (Number.isFinite(initial)) return { value: initial, at: (scope) => compiled(NaN, scope) };
    }
    throw new Error(what + ' 不是有效的数字');
  }

  /** 函数定义域，端点可以含参数，例如 [0, "2v"]。 */
  function toDomain(value, names, defaults) {
    if (!Array.isArray(value) || value.length !== 2) throw new Error('函数定义域 应该是 [最小值, 最大值]');
    const domain = [toDynamic(value[0], '函数定义域', names, defaults), toDynamic(value[1], '函数定义域', names, defaults)];
    if (!(domain[0].value < domain[1].value)) throw new Error('函数定义域 的最小值要小于最大值');
    return domain;
  }

  function toPoint(value, what, names, defaults) {
    if (!Array.isArray(value) || value.length !== 2) throw new Error(what + ' 应该是 [x, y]');
    return [toDynamic(value[0], what, names, defaults), toDynamic(value[1], what, names, defaults)];
  }

  /** 解析参数列表：名字、范围、步长、初始值。 */
  function parseParams(rawParams) {
    if (rawParams === undefined) return [];
    if (!Array.isArray(rawParams)) throw new Error('params 应该是数组');
    if (rawParams.length > 6) throw new Error('参数最多 6 个');
    const seen = new Set();
    return rawParams.map((p, i) => {
      const what = '第 ' + (i + 1) + ' 个参数';
      if (!p || !isValidParamName(p.name)) {
        throw new Error(what + '的名字无效（要用字母开头，不能是 x、e、pi 或函数名）');
      }
      if (seen.has(p.name)) throw new Error('参数 ' + p.name + ' 重复了');
      seen.add(p.name);
      const [min, max] = toRange([p.min, p.max], '参数 ' + p.name + ' 的范围');
      const step = p.step === undefined ? (max - min) / 100 : toNumber(p.step, '参数 ' + p.name + ' 的步长');
      if (!(step > 0)) throw new Error('参数 ' + p.name + ' 的步长要大于 0');
      const initial = p.value === undefined ? (min + max) / 2 : toNumber(p.value, '参数 ' + p.name + ' 的初始值');
      return {
        name: p.name,
        min,
        max,
        step,
        value: Math.min(max, Math.max(min, initial)),
        label: optionalLabel(p.label),
      };
    });
  }

  /** 读数：一个值，或者写成 [x, y] 的一对值（显示为坐标）。 */
  function parseReadouts(rawReadouts, names, defaults, warnings) {
    if (rawReadouts === undefined) return [];
    if (!Array.isArray(rawReadouts)) throw new Error('readouts 应该是数组');
    const readouts = [];
    rawReadouts.forEach((r, i) => {
      const what = '第 ' + (i + 1) + ' 个读数';
      // 读数只是辅助信息：某一个写错时跳过它，不让整个坐标图显示失败。
      try {
        if (!r || r.value === undefined) throw new Error(what + '缺少 value');
        const parts = Array.isArray(r.value) ? r.value : [r.value];
        if (parts.length < 1 || parts.length > 2) throw new Error(what + '的 value 应该是一个表达式或 [x, y]');
        const values = parts.map((part) => {
          const compiled = compileExpression(String(part), names);
          return (scope) => compiled(NaN, scope);
        });
        values.forEach((fn) => {
          if (!Number.isFinite(fn(defaults))) throw new Error(what + '在参数取初始值时无法计算');
        });
        readouts.push({ label: optionalLabel(r.label), values, pair: parts.length === 2 });
      } catch (error) {
        warnings.push('跳过了' + what + '：' + error.message);
      }
    });
    return readouts;
  }

  /** 按步长决定显示几位小数。 */
  function decimalsForStep(step) {
    if (!(step > 0)) return 2;
    return Math.min(4, Math.max(0, Math.ceil(-Math.log10(step) - 1e-9)));
  }

  function formatNumber(value, decimals) {
    if (!Number.isFinite(value)) return '—';
    const fixed = value.toFixed(decimals === undefined ? 2 : decimals);
    // 去掉多余的 0：2.50 → 2.5，3.00 → 3；-0 → 0
    const trimmed = fixed.includes('.') ? fixed.replace(/\.?0+$/, '') : fixed;
    return trimmed === '-0' ? '0' : trimmed;
  }

  /**
   * 实时公式：把模板里的 {a} 换成参数的当前值，并整理正负号，
   * 例如 "y = {a}x^2 + {b}x" 在 b = -2 时得到 "y = 1x^2 - 2x"。
   */
  function fillFormula(template, params, scope) {
    let text = template.replace(PLACEHOLDER, (match, name) => {
      const param = params.find((p) => p.name === name);
      if (!param) return match;
      return formatNumber(scope[name], decimalsForStep(param.step));
    });
    text = text.replace(/\+\s*-\s*/g, '- ').replace(/-\s*-\s*/g, '+ ');
    return text;
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
    segments.forEach((s) => values.push(s.from[1].value, s.to[1].value));
    if (!values.length) return [xRange[0], xRange[1]];

    values.sort((a, b) => a - b);
    const pick = (q) => values[Math.min(values.length - 1, Math.max(0, Math.round(q * (values.length - 1))))];
    let low = functions.length ? pick(0.03) : values[0];
    let high = functions.length ? pick(0.97) : values[values.length - 1];
    points.concat(segments.flatMap((s) => [{ y: s.from[1].value }, { y: s.to[1].value }])).forEach((p) => {
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
      const raw = parseJSONObject(source, '坐标图');

      const params = parseParams(raw.params);
      const names = params.map((p) => p.name);
      const defaults = {};
      params.forEach((p) => { defaults[p.name] = p.value; });

      // 物理图像（v-t、x-t）里模型常把自变量写成 t；t 不是参数时当作 x。
      const aliases = names.includes('t') ? {} : { t: 'x' };

      const functions = (raw.functions || []).map((f, i) => {
        if (!f || typeof f.expr !== 'string') throw new Error('第 ' + (i + 1) + ' 个函数缺少 expr');
        const compiled = compileExpression(f.expr, names, aliases);
        const domain = f.domain ? toDomain(f.domain, names, defaults) : null;
        return {
          expr: f.expr,
          /** 参数取初始值时的函数。 */
          fn: (x) => compiled(x, defaults),
          /** 任意参数下的函数值。 */
          at: (x, scope) => compiled(x, scope),
          label: optionalLabel(f.label),
          /** 参数取初始值时的定义域，[最小值, 最大值]。 */
          domain: domain && [domain[0].value, domain[1].value],
          /** 任意参数下的定义域端点。 */
          domainAt: domain && [domain[0].at, domain[1].at],
          dashed: f.dashed === true,
        };
      });
      const points = (raw.points || []).map((p) => {
        const x = toDynamic(p && p.x, '点的 x 坐标', names, defaults);
        const y = toDynamic(p && p.y, '点的 y 坐标', names, defaults);
        return { x: x.value, y: y.value, xAt: x.at, yAt: y.at, label: optionalLabel(p && p.label) };
      });
      const segments = (raw.segments || []).map((s) => ({
        from: toPoint(s && s.from, '线段起点', names, defaults),
        to: toPoint(s && s.to, '线段终点', names, defaults),
        label: optionalLabel(s && s.label),
        dashed: !!(s && s.dashed),
      }));
      if (!functions.length && !points.length && !segments.length) throw new Error('坐标图里没有任何内容');

      const warnings = [];
      const readouts = parseReadouts(raw.readouts, names, defaults, warnings);
      let formula = typeof raw.formula === 'string' && raw.formula.trim() ? raw.formula.trim() : '';
      if (formula && !params.length) {
        warnings.push('没有参数时忽略 formula');
        formula = '';
      }

      const xRange = raw.xRange ? toRange(raw.xRange, 'xRange') : [-10, 10];
      const yRange = raw.yRange ? toRange(raw.yRange, 'yRange') : autoYRange(functions, points, segments, xRange);

      return {
        ok: true,
        value: {
          title: optionalLabel(raw.title),
          xRange,
          yRange,
          functions,
          points,
          segments,
          params,
          defaults,
          readouts,
          formula,
          /** 不影响显示的小问题，测试工具会报告出来。 */
          warnings,
        },
      };
    } catch (error) {
      return { ok: false, error: error.message };
    }
  }

  // ---------- 测验 ----------

  // ---------- 宽松的 JSON ----------
  //
  // 模型写的 JSON 常见两类错误：
  //   1. 文字里直接用了英文双引号，例如 "这是"偶函数"的定义"；
  //   2. LaTeX 的反斜杠没有写成两个。"\;" 这类会直接报错，
  //      而 "\frac"、"\times"、"\rho" 不会报错，却被解析成换页符、制表符、回车。
  // 这里先修复第 2 类，解析失败时再逐个转义出错位置前面那个引号。

  const VALID_ESCAPES = '"\\/bfnrtu';
  // \n 后面跟这些字母时多半是 LaTeX 命令（\neq、\nabla、\nu…），而不是换行。
  const LATEX_AFTER_N = /^(eq|e\b|abla|u\b|ot|eg|i\b|exists|leq|geq|parallel|mid|subset|supset|sim|cong|rightarrow|leftarrow|Rightarrow|Leftarrow|ewline|ormalsize)/;

  function fixEscapes(source) {
    let out = '';
    let inString = false;
    for (let i = 0; i < source.length; i++) {
      const ch = source[i];
      if (!inString) {
        if (ch === '"') inString = true;
        out += ch;
        continue;
      }
      if (ch === '"') {
        inString = false;
        out += ch;
        continue;
      }
      if (ch !== '\\') {
        out += ch;
        continue;
      }
      const next = source[i + 1];
      const rest = source.slice(i + 2);
      let latex = false;
      if (next === undefined || !VALID_ESCAPES.includes(next)) latex = true;
      else if ((next === 'f' || next === 'b') && /^[a-zA-Z]/.test(rest)) latex = true; // \frac \beta
      else if ((next === 't' || next === 'r') && /^[a-zA-Z]/.test(rest)) latex = true; // \times \rho
      else if (next === 'n' && LATEX_AFTER_N.test(rest)) latex = true; // \neq \nabla
      else if (next === 'u' && !/^[0-9a-fA-F]{4}/.test(rest)) latex = true; // \underline
      if (latex) {
        out += '\\\\';
      } else {
        out += ch + next;
        i++;
      }
    }
    return out;
  }

  function parseLooseJSON(source) {
    let text = fixEscapes(String(source));
    for (let attempt = 0; attempt < 30; attempt++) {
      try {
        return JSON.parse(text);
      } catch (error) {
        const match = /position (\d+)/.exec(error.message);
        if (!match) throw error;
        const position = Number(match[1]);
        // 往前找最近的一个没转义的引号：它多半是文字里的引号，把字符串提前结束了。
        let quote = position - 1;
        while (quote >= 0 && !(text[quote] === '"' && text[quote - 1] !== '\\')) quote--;
        // 引号后面紧跟的是 JSON 结构符号时，说明它本来就是字符串的结尾，没法修复。
        if (quote <= 0 || /^\s*[,:}\]]/.test(text.slice(quote + 1))) throw error;
        text = text.slice(0, quote) + '\\"' + text.slice(quote + 1);
      }
    }
    return JSON.parse(text);
  }

  function requireText(value, what) {
    if (typeof value !== 'string' || !value.trim()) throw new Error(what + '不能为空');
    return value.trim();
  }

  function parseJSONObject(source, what) {
    const raw = parseLooseJSON(source);
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error(what + '描述应该是一个 JSON 对象');
    return raw;
  }

  /** 选择题的答案：字母 "B"、["A", "C"]，或从 0 开始的序号。返回排好序的序号数组。 */
  function parseChoiceAnswer(answer, optionCount, what) {
    const list = Array.isArray(answer) ? answer : [answer];
    if (!list.length) throw new Error(what + '缺少答案');
    const indexes = list.map((item) => {
      let index;
      if (typeof item === 'number' && Number.isInteger(item)) index = item;
      else if (typeof item === 'string' && /^[A-Za-z]$/.test(item.trim())) index = item.trim().toUpperCase().charCodeAt(0) - 65;
      else throw new Error(what + '的答案应该写成选项字母，例如 "B"');
      if (index < 0 || index >= optionCount) throw new Error(what + '的答案超出了选项范围');
      return index;
    });
    return [...new Set(indexes)].sort((a, b) => a - b);
  }

  /** 数值填空：用户可以写 0.5、1/2、sqrt(2) 这样的式子。 */
  function evaluateNumberInput(text) {
    if (typeof text !== 'string' || !text.trim()) return NaN;
    try {
      // 允许全角符号和中文逗号小数点之类的常见写法。
      const normalized = text.trim().replace(/，/g, ',').replace(/。/g, '.').replace(/／/g, '/').replace(/,/g, '');
      return compileExpression(normalized)(NaN);
    } catch (error) {
      return NaN;
    }
  }

  /** 数值答案是否正确。默认允许 1% 的相对误差。 */
  function isNumberCorrect(value, question) {
    if (!Number.isFinite(value)) return false;
    const tolerance = question.tolerance !== null
      ? question.tolerance
      : Math.max(1e-9, Math.abs(question.answer) * 0.01);
    return Math.abs(value - question.answer) <= tolerance + 1e-12;
  }

  function parseQuizSpec(source) {
    try {
      const raw = parseJSONObject(source, '测验');
      if (!Array.isArray(raw.questions) || !raw.questions.length) throw new Error('测验里没有题目');
      if (raw.questions.length > 10) throw new Error('测验最多 10 道题');
      const questions = raw.questions.map((q, i) => {
        const what = '第 ' + (i + 1) + ' 题';
        if (!q || typeof q !== 'object') throw new Error(what + '格式不对');
        const question = requireText(q.question, what + '的题目');
        const explanation = typeof q.explanation === 'string' ? q.explanation.trim() : '';
        const type = q.type || (Array.isArray(q.options) ? 'choice' : 'number');
        if (type === 'choice') {
          if (!Array.isArray(q.options) || q.options.length < 2 || q.options.length > 8) {
            throw new Error(what + '要有 2 到 8 个选项');
          }
          const options = q.options.map((o, k) => requireText(String(o === undefined || o === null ? '' : o), what + '的选项 ' + (k + 1)));
          const answer = parseChoiceAnswer(q.answer, options.length, what);
          const optionExplanations = Array.isArray(q.optionExplanations)
            ? options.map((_, k) => (typeof q.optionExplanations[k] === 'string' ? q.optionExplanations[k].trim() : ''))
            : options.map(() => '');
          return {
            type: 'choice',
            question,
            options,
            answer,
            multiple: answer.length > 1 || q.multiple === true,
            explanation,
            optionExplanations,
          };
        }
        if (type === 'number') {
          const answer = toNumber(q.answer, what + '的答案');
          const tolerance = q.tolerance === undefined ? null : toNumber(q.tolerance, what + '的误差');
          if (tolerance !== null && tolerance < 0) throw new Error(what + '的误差不能是负数');
          return {
            type: 'number',
            question,
            answer,
            tolerance,
            unit: typeof q.unit === 'string' ? q.unit.trim() : '',
            explanation,
          };
        }
        throw new Error(what + '的题型应该是 choice 或 number');
      });
      return { ok: true, value: { title: typeof raw.title === 'string' ? raw.title.trim() : '', questions } };
    } catch (error) {
      return { ok: false, error: error.message };
    }
  }

  const LETTERS = 'ABCDEFGH';

  function quizToText(spec) {
    const lines = ['【测验' + (spec.title ? '：' + spec.title : '') + '】'];
    spec.questions.forEach((q, i) => {
      lines.push((i + 1) + '. ' + q.question);
      if (q.type === 'choice') {
        q.options.forEach((o, k) => lines.push('   ' + LETTERS[k] + '. ' + o));
        lines.push('   答案：' + q.answer.map((k) => LETTERS[k]).join('、'));
      } else {
        lines.push('   答案：' + formatNumber(q.answer, 4) + (q.unit ? ' ' + q.unit : ''));
      }
      if (q.explanation) lines.push('   解析：' + q.explanation);
    });
    return lines.join('\n');
  }

  // ---------- 分步讲解 ----------

  function parseStepsSpec(source) {
    try {
      const raw = parseJSONObject(source, '分步讲解');
      if (!Array.isArray(raw.steps) || raw.steps.length < 2) throw new Error('分步讲解至少要有 2 步');
      if (raw.steps.length > 15) throw new Error('分步讲解最多 15 步');
      const steps = raw.steps.map((s, i) => {
        const what = '第 ' + (i + 1) + ' 步';
        // 允许直接写成字符串
        if (typeof s === 'string') return { title: '', content: requireText(s, what + '的内容') };
        if (!s || typeof s !== 'object') throw new Error(what + '格式不对');
        return {
          title: typeof s.title === 'string' ? s.title.trim() : '',
          content: requireText(s.content, what + '的内容'),
        };
      });
      return { ok: true, value: { title: typeof raw.title === 'string' ? raw.title.trim() : '', steps } };
    } catch (error) {
      return { ok: false, error: error.message };
    }
  }

  function stepsToText(spec) {
    const lines = ['【分步讲解' + (spec.title ? '：' + spec.title : '') + '】'];
    spec.steps.forEach((s, i) => {
      lines.push('第 ' + (i + 1) + ' 步' + (s.title ? '：' + s.title : ''));
      lines.push(s.content);
    });
    return lines.join('\n');
  }

  // ---------- 组件注册表 ----------
  //
  // 每种组件在这里登记：名称、解析校验函数、复制消息时的文字形式。
  // 浏览器里的绘制部分在 components.js 和各组件自己的文件里。

  const COMPONENTS = {
    graph: {
      label: '坐标图',
      parse: parseGraphSpec,
      toText(spec) {
        const parts = spec.functions.map((f) => f.label || 'y = ' + f.expr);
        const params = spec.params.length ? '（参数 ' + spec.params.map((p) => p.name).join('、') + '）' : '';
        return '[坐标图：' + (spec.title || parts.join('，') || '点和线段') + params + ']';
      },
    },
    quiz: { label: '测验', parse: parseQuizSpec, toText: quizToText },
    steps: { label: '分步讲解', parse: parseStepsSpec, toText: stepsToText },
  };

  function componentTypes() {
    return Object.keys(COMPONENTS);
  }

  function componentLabel(type) {
    return COMPONENTS[type] ? COMPONENTS[type].label : '组件';
  }

  /** 解析并校验一个组件代码块，返回 { ok: true, value } 或 { ok: false, error }。 */
  function parseComponent(type, source) {
    const component = COMPONENTS[type];
    if (!component) return { ok: false, error: '不认识的组件：' + type };
    return component.parse(source);
  }

  /**
   * 找出 Markdown 里所有围栏代码块，返回 { language, content, start, end }（start/end 是行号，end 不含）。
   * 只用于复制和测试工具；渲染时由 markdown-it 处理。
   */
  function extractFences(markdown) {
    const lines = String(markdown || '').split('\n');
    const fences = [];
    let i = 0;
    while (i < lines.length) {
      const open = /^ {0,3}(`{3,}|~{3,})\s*([^\s`]*)/.exec(lines[i]);
      if (!open) {
        i++;
        continue;
      }
      const marker = open[1];
      const closePattern = new RegExp('^ {0,3}' + marker[0] + '{' + marker.length + ',}\\s*$');
      let j = i + 1;
      while (j < lines.length && !closePattern.test(lines[j])) j++;
      fences.push({
        language: open[2].toLowerCase(),
        content: lines.slice(i + 1, j).join('\n'),
        start: i,
        end: Math.min(j + 1, lines.length),
        closed: j < lines.length,
      });
      i = j + 1;
    }
    return fences;
  }

  /** 复制消息时用：把组件代码块换成可读的文字，其余内容不变。 */
  function toPlainText(markdown) {
    const lines = String(markdown || '').split('\n');
    const fences = extractFences(markdown).filter((f) => COMPONENTS[f.language]);
    for (let k = fences.length - 1; k >= 0; k--) {
      const fence = fences[k];
      const result = parseComponent(fence.language, fence.content);
      const text = result.ok
        ? COMPONENTS[fence.language].toText(result.value)
        : '[' + componentLabel(fence.language) + ']';
      lines.splice(fence.start, fence.end - fence.start, text);
    }
    return lines.join('\n');
  }

  return {
    mathPlugin,
    compileExpression,
    parseGraphSpec,
    fillFormula,
    formatNumber,
    decimalsForStep,
    parseQuizSpec,
    parseStepsSpec,
    evaluateNumberInput,
    isNumberCorrect,
    componentTypes,
    componentLabel,
    parseComponent,
    extractFences,
    toPlainText,
  };
});
