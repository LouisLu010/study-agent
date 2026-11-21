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
        const subject = normalizeSubject(q.subject);
        const topic = typeof q.topic === 'string' ? q.topic.trim().slice(0, 40) : '';
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
            subject,
            topic,
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
            subject,
            topic,
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

  // 错题本的科目只有这几个；模型写成别的说法时尽量归到对应科目，归不上返回空字符串。
  const SUBJECTS = ['数学', '物理', '化学', '生物', '语文', '英语', '其他'];
  const SUBJECT_ALIASES = { math: '数学', mathematics: '数学', physics: '物理', chemistry: '化学', biology: '生物', chinese: '语文', english: '英语' };

  function normalizeSubject(value) {
    if (typeof value !== 'string') return '';
    const text = value.trim();
    if (!text) return '';
    const exact = SUBJECTS.find((s) => text.includes(s));
    if (exact) return exact;
    return SUBJECT_ALIASES[text.toLowerCase()] || '其他';
  }

  /** 把解析后的一道题还原成标准的 JSON 对象，用来单独保存进错题本，之后可以再用测验组件显示。 */
  function quizQuestionToJSON(q) {
    const base = { type: q.type, question: q.question };
    if (q.type === 'choice') {
      base.options = q.options;
      base.answer = q.answer.length > 1 ? q.answer.map((k) => LETTERS[k]) : LETTERS[q.answer[0]];
      if (q.optionExplanations.some(Boolean)) base.optionExplanations = q.optionExplanations;
    } else {
      base.answer = q.answer;
      if (q.tolerance !== null) base.tolerance = q.tolerance;
      if (q.unit) base.unit = q.unit;
    }
    if (q.explanation) base.explanation = q.explanation;
    if (q.subject) base.subject = q.subject;
    if (q.topic) base.topic = q.topic;
    return base;
  }

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

  // ---------- 几何图 ----------
  //
  // 元素按顺序定义，后面的元素只能引用前面已经定义的元素：
  //   点：point（可拖动或固定，可以用 on 限制在圆或直线上）、midpoint、intersection、foot
  //   线：segment、line、ray（都由 through 的两个点确定）
  //   其他：circle（center + through 或 radius）、polygon、angle（points 的中间一个是顶点）
  // 有数值的元素（线段长度、圆半径、多边形面积、角的度数）可以在读数表达式里按 id 引用。

  const POINT_KINDS = ['point', 'midpoint', 'intersection', 'foot'];
  const LINEAR_KINDS = ['segment', 'line', 'ray'];
  const GEOMETRY_KINDS = POINT_KINDS.concat(LINEAR_KINDS, ['circle', 'polygon', 'angle']);
  const MEASURABLE_KINDS = ['segment', 'circle', 'polygon', 'angle'];

  function dist(p, q) {
    return Math.hypot(p.x - q.x, p.y - q.y);
  }

  /** 点 p 在直线 ab 上的垂足。 */
  function projectToLine(p, a, b) {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return { x: NaN, y: NaN };
    const t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2;
    return { x: a.x + t * dx, y: a.y + t * dy };
  }

  /** 直线 ab 和直线 cd 的交点；平行时返回 NaN。 */
  function intersectLines(a, b, c, d) {
    const d1x = b.x - a.x;
    const d1y = b.y - a.y;
    const d2x = d.x - c.x;
    const d2y = d.y - c.y;
    const denom = d1x * d2y - d1y * d2x;
    if (Math.abs(denom) < 1e-12) return { x: NaN, y: NaN };
    const t = ((c.x - a.x) * d2y - (c.y - a.y) * d2x) / denom;
    return { x: a.x + t * d1x, y: a.y + t * d1y };
  }

  /** ∠ABC 的度数（0 到 180）。 */
  function angleDegrees(a, b, c) {
    const v1 = Math.atan2(a.y - b.y, a.x - b.x);
    const v2 = Math.atan2(c.y - b.y, c.x - b.x);
    let deg = Math.abs(v1 - v2) * 180 / Math.PI;
    if (deg > 180) deg = 360 - deg;
    return deg;
  }

  function polygonArea(points) {
    let sum = 0;
    for (let i = 0; i < points.length; i++) {
      const p = points[i];
      const q = points[(i + 1) % points.length];
      sum += p.x * q.y - q.x * p.y;
    }
    return Math.abs(sum) / 2;
  }

  /** 把点放到它所在的圆或直线上（用于 on 约束的初始位置）。 */
  function snapToObject(p, object, points, circles) {
    if (object.kind === 'circle') {
      const center = points[object.center];
      const r = circles[object.id];
      const angle = Math.atan2(p.y - center.y, p.x - center.x);
      return { x: center.x + r * Math.cos(angle), y: center.y + r * Math.sin(angle) };
    }
    return projectToLine(p, points[object.through[0]], points[object.through[1]]);
  }

  /**
   * 计算所有点的位置和所有元素的数值。
   * moved 是用户拖动后的点坐标 { 点id: [x, y] }，没给的用描述里的初始位置。
   */
  function computeGeometry(spec, moved) {
    const points = {};
    const circles = {};
    const measures = {};
    const byId = {};
    spec.elements.forEach((e) => {
      byId[e.id] = e;
      switch (e.kind) {
        case 'point': {
          const m = moved && moved[e.id];
          let p = m ? { x: m[0], y: m[1] } : { x: e.x, y: e.y };
          if (e.on) p = snapToObject(p, byId[e.on], points, circles);
          points[e.id] = p;
          break;
        }
        case 'midpoint': {
          const [a, b] = e.of.map((id) => points[id]);
          points[e.id] = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
          break;
        }
        case 'intersection': {
          const [l1, l2] = e.of.map((id) => byId[id]);
          points[e.id] = intersectLines(points[l1.through[0]], points[l1.through[1]], points[l2.through[0]], points[l2.through[1]]);
          break;
        }
        case 'foot': {
          const line = byId[e.to];
          points[e.id] = projectToLine(points[e.from], points[line.through[0]], points[line.through[1]]);
          break;
        }
        case 'segment':
          measures[e.id] = dist(points[e.through[0]], points[e.through[1]]);
          break;
        case 'circle':
          circles[e.id] = e.radius !== null ? e.radius : dist(points[e.center], points[e.through]);
          measures[e.id] = circles[e.id];
          break;
        case 'polygon':
          measures[e.id] = polygonArea(e.vertices.map((id) => points[id]));
          break;
        case 'angle':
          measures[e.id] = angleDegrees(points[e.points[0]], points[e.points[1]], points[e.points[2]]);
          break;
        default:
          break;
      }
    });
    Object.assign(measures, computeVirtual(spec, points));
    return { points, circles, measures };
  }

  /** 读数里用到的"两点距离"和"三点角度"。 */
  function computeVirtual(spec, points) {
    const result = {};
    (spec.virtualUsed || []).forEach((name) => {
      const v = spec.virtual[name];
      const p = v.points.map((id) => points[id]);
      result[name] = v.kind === 'distance' ? dist(p[0], p[1]) : angleDegrees(p[0], p[1], p[2]);
    });
    return result;
  }

  /** 元素引用到的其他元素 id。 */
  function dependenciesOf(e) {
    if (!e || typeof e !== 'object') return [];
    const ids = [];
    ['on', 'from', 'to', 'center'].forEach((field) => {
      if (typeof e[field] === 'string') ids.push(e[field]);
    });
    if (typeof e.through === 'string') ids.push(e.through);
    ['of', 'through', 'vertices', 'points'].forEach((field) => {
      if (Array.isArray(e[field])) e[field].forEach((id) => { if (typeof id === 'string') ids.push(id); });
    });
    return ids;
  }

  /**
   * 模型有时先引用、后定义（例如先写圆上的点，再写圆）。按依赖关系重新排序，
   * 尽量保持原来的顺序；有循环引用或引用不存在的元素时，交给后面的校验报错。
   */
  function sortByDependencies(rawElements) {
    const ids = new Set(rawElements.map((e) => e && e.id));
    const placed = new Set();
    const result = [];
    let remaining = rawElements.slice();
    while (remaining.length) {
      const next = remaining.findIndex((e) =>
        dependenciesOf(e).every((id) => placed.has(id) || !ids.has(id) || id === (e && e.id)));
      if (next < 0) return result.concat(remaining);
      const element = remaining[next];
      result.push(element);
      placed.add(element && element.id);
      remaining = remaining.slice(0, next).concat(remaining.slice(next + 1));
    }
    return result;
  }

  function parseGeometrySpec(source) {
    try {
      const raw = parseJSONObject(source, '几何图');
      if (!Array.isArray(raw.elements) || !raw.elements.length) throw new Error('几何图里没有任何元素');
      if (raw.elements.length > 40) throw new Error('几何图的元素最多 40 个');

      const kinds = {};
      const elements = sortByDependencies(raw.elements).map((e, i) => {
        if (!e || typeof e !== 'object') throw new Error('第 ' + (i + 1) + ' 个元素格式不对');
        const kind = e.type;
        if (!GEOMETRY_KINDS.includes(kind)) throw new Error('第 ' + (i + 1) + ' 个元素的 type 不认识：' + kind);
        const id = e.id;
        if (!isValidParamName(id)) throw new Error('元素的 id 无效：' + id + '（要用字母开头，只能包含字母和数字）');
        if (kinds[id]) throw new Error('元素 id 重复了：' + id);
        const what = kind + ' ' + id;

        const ref = (refId, allowed) => {
          if (!kinds[refId]) throw new Error(what + ' 引用的 ' + refId + ' 不存在（要先定义）');
          if (!allowed.includes(kinds[refId])) throw new Error(what + ' 引用的 ' + refId + ' 类型不对');
          return refId;
        };
        const refs = (list, count, allowed, field) => {
          if (!Array.isArray(list) || (count && list.length !== count)) {
            throw new Error(what + ' 的 ' + field + ' 应该是' + (count ? ' ' + count + ' 个' : '') + 'id 的数组');
          }
          return list.map((r) => ref(r, allowed));
        };

        const element = { kind, id, label: typeof e.label === 'string' ? e.label : null, hidden: e.hidden === true, dashed: e.dashed === true };
        switch (kind) {
          case 'point':
            element.x = toNumber(e.x, what + ' 的 x');
            element.y = toNumber(e.y, what + ' 的 y');
            element.fixed = e.fixed === true;
            element.on = e.on === undefined ? null : ref(e.on, ['circle'].concat(LINEAR_KINDS));
            break;
          case 'midpoint':
            element.of = refs(e.of, 2, POINT_KINDS, 'of');
            break;
          case 'intersection':
            element.of = refs(e.of, 2, LINEAR_KINDS, 'of');
            break;
          case 'foot':
            element.from = ref(e.from, POINT_KINDS);
            element.to = ref(e.to, LINEAR_KINDS);
            break;
          case 'segment':
          case 'line':
          case 'ray':
            element.through = refs(e.through, 2, POINT_KINDS, 'through');
            if (element.through[0] === element.through[1]) throw new Error(what + ' 的两个点不能相同');
            break;
          case 'circle':
            element.center = ref(e.center, POINT_KINDS);
            if (e.radius !== undefined) {
              element.radius = toNumber(e.radius, what + ' 的半径');
              if (!(element.radius > 0)) throw new Error(what + ' 的半径要大于 0');
              element.through = null;
            } else {
              element.radius = null;
              element.through = ref(e.through, POINT_KINDS);
            }
            break;
          case 'polygon':
            element.vertices = refs(e.vertices, 0, POINT_KINDS, 'vertices');
            if (element.vertices.length < 3) throw new Error(what + ' 至少要有 3 个顶点');
            break;
          case 'angle':
            element.points = refs(e.points, 3, POINT_KINDS, 'points');
            break;
          default:
            break;
        }
        kinds[id] = kind;
        return element;
      });

      const spec = { title: optionalLabel(raw.title), elements, grid: raw.grid === true };
      const initial = computeGeometry(spec, null);
      Object.keys(initial.points).forEach((id) => {
        const p = initial.points[id];
        if (!Number.isFinite(p.x) || !Number.isFinite(p.y)) throw new Error('点 ' + id + ' 算不出位置（例如两条平行线没有交点）');
      });

      // 读数：表达式里可以按 id 引用线段长度、圆半径、多边形面积、角的度数。
      // 另外，两个点的 id 连写（AB）表示两点间的距离，三个点连写（ABC）表示 ∠ABC 的度数。
      const measurable = elements.filter((e) => MEASURABLE_KINDS.includes(e.kind)).map((e) => e.id);
      const pointIds = elements.filter((e) => POINT_KINDS.includes(e.kind)).map((e) => e.id);
      const virtual = {};
      pointIds.forEach((a) => pointIds.forEach((b) => {
        if (a !== b && !kinds[a + b]) virtual[a + b] = { kind: 'distance', points: [a, b] };
        if (a !== b && pointIds.length <= 12) {
          pointIds.forEach((c) => {
            if (c !== a && c !== b && !kinds[a + b + c]) virtual[a + b + c] = { kind: 'angle', points: [a, b, c] };
          });
        }
      }));
      const virtualNames = Object.keys(virtual).filter(isValidParamName);
      spec.virtual = virtual;
      spec.virtualUsed = [];
      const warnings = [];
      const readouts = [];
      (Array.isArray(raw.readouts) ? raw.readouts : []).forEach((r, i) => {
        try {
          if (!r || r.value === undefined) throw new Error('缺少 value');
          const names = measurable.concat(virtualNames);
          tokenize(String(r.value), names).forEach((token) => {
            if (token.type === 'name' && virtual[token.value] && !spec.virtualUsed.includes(token.value)) {
              spec.virtualUsed.push(token.value);
            }
          });
          Object.assign(initial.measures, computeVirtual(spec, initial.points));
          const compiled = compileExpression(String(r.value), names);
          const evaluate = (measures) => compiled(NaN, measures);
          if (!Number.isFinite(evaluate(initial.measures))) throw new Error('无法计算');
          readouts.push({
            label: optionalLabel(r.label) || String(r.value),
            evaluate,
            unit: typeof r.unit === 'string' ? r.unit : '',
            decimals: Number.isInteger(r.decimals) ? Math.min(4, Math.max(0, r.decimals)) : 2,
          });
        } catch (error) {
          warnings.push('跳过了第 ' + (i + 1) + ' 个读数：' + error.message);
        }
      });
      spec.readouts = readouts;
      spec.warnings = warnings;

      // 显示范围：给了就用，没给就根据所有点和圆自动确定。
      if (raw.xRange && raw.yRange) {
        spec.xRange = toRange(raw.xRange, 'xRange');
        spec.yRange = toRange(raw.yRange, 'yRange');
      } else {
        let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
        const include = (x, y) => {
          minX = Math.min(minX, x); maxX = Math.max(maxX, x);
          minY = Math.min(minY, y); maxY = Math.max(maxY, y);
        };
        Object.values(initial.points).forEach((p) => include(p.x, p.y));
        elements.filter((e) => e.kind === 'circle').forEach((c) => {
          const center = initial.points[c.center];
          const r = initial.circles[c.id];
          include(center.x - r, center.y - r);
          include(center.x + r, center.y + r);
        });
        const size = Math.max(maxX - minX, maxY - minY, 1);
        const pad = size * 0.2;
        spec.xRange = [minX - pad, maxX + pad];
        spec.yRange = [minY - pad, maxY + pad];
      }
      return { ok: true, value: spec };
    } catch (error) {
      return { ok: false, error: error.message };
    }
  }

  // ---------- 图表 ----------

  const CHART_TYPES = ['bar', 'line', 'pie'];

  function parseChartSpec(source) {
    try {
      const raw = parseJSONObject(source, '图表');
      const type = raw.type || 'bar';
      if (!CHART_TYPES.includes(type)) throw new Error('图表的 type 应该是 bar、line 或 pie');
      if (!Array.isArray(raw.labels) || !raw.labels.length) throw new Error('图表缺少 labels');
      if (raw.labels.length > 60) throw new Error('图表的类别最多 60 个');
      const labels = raw.labels.map((l) => String(l === null || l === undefined ? '' : l));
      if (!Array.isArray(raw.datasets) || !raw.datasets.length) throw new Error('图表缺少 datasets');
      if (raw.datasets.length > 8) throw new Error('图表的数据组最多 8 组');
      if (type === 'pie' && raw.datasets.length !== 1) throw new Error('饼图只能有 1 组数据');

      const datasets = raw.datasets.map((d, i) => {
        const what = '第 ' + (i + 1) + ' 组数据';
        if (!d || !Array.isArray(d.data)) throw new Error(what + '缺少 data');
        if (d.data.length !== labels.length) {
          throw new Error(what + '有 ' + d.data.length + ' 个数，但 labels 有 ' + labels.length + ' 个');
        }
        const data = d.data.map((v) => {
          if (v === null) return null;
          const n = typeof v === 'number' ? v : Number(v);
          if (!Number.isFinite(n)) throw new Error(what + '里有不是数字的值：' + v);
          if (type === 'pie' && n < 0) throw new Error('饼图的数据不能是负数');
          return n;
        });
        return { label: typeof d.label === 'string' ? d.label.trim() : '', data };
      });

      return {
        ok: true,
        value: {
          type,
          title: optionalLabel(raw.title),
          labels,
          datasets,
          xLabel: optionalLabel(raw.xLabel),
          yLabel: optionalLabel(raw.yLabel),
          unit: optionalLabel(raw.unit),
          stacked: raw.stacked === true && type === 'bar',
        },
      };
    } catch (error) {
      return { ok: false, error: error.message };
    }
  }

  function chartToText(spec) {
    const unit = spec.unit ? '（' + spec.unit + '）' : '';
    const lines = ['【图表' + (spec.title ? '：' + spec.title : '') + '】'];
    const header = [spec.xLabel || '类别'].concat(spec.datasets.map((d, i) => (d.label || '数据 ' + (i + 1)) + unit));
    lines.push(header.join(' | '));
    spec.labels.forEach((label, k) => {
      lines.push([label].concat(spec.datasets.map((d) => (d.data[k] === null ? '—' : formatNumber(d.data[k], 4)))).join(' | '));
    });
    return lines.join('\n');
  }

  // ---------- 模拟 ----------
  //
  // 每种模拟在这里定义参数和物理计算（不依赖 DOM，可以测试），画法在 simulation.js 里。
  // build(p) 根据参数返回一个模型：
  //   duration   动画时长（秒）；Infinity 表示周期运动，一直播放
  //   results    和时间无关的结果，例如射程、周期：[{ label, value, unit }]
  //   at(t)      t 时刻的状态，供画图和实时读数使用
  //   live(t)    t 时刻的实时读数
  //   bounds     画面范围（米），{ xmin, xmax, ymin, ymax }

  const DEG = Math.PI / 180;

  function param(name, label, unit, min, max, step, value) {
    return { name, label, unit, min, max, step, value };
  }

  function reading(label, value, unit, decimals) {
    return { label, value, unit: unit || '', decimals: decimals === undefined ? 2 : decimals };
  }

  /** 单摆：用 RK4 积分一个完整周期，之后按周期取样（大角度时比小角度公式准确）。 */
  function pendulumTable(L, theta0, g) {
    const dt = 1 / 2000;
    let theta = theta0;
    let omega = 0;
    const samples = [{ t: 0, theta, omega }];
    const accel = (th) => (-g / L) * Math.sin(th);
    let t = 0;
    let crossings = 0;
    let prevOmega = 0;
    while (t < 60) {
      const k1t = omega, k1o = accel(theta);
      const k2t = omega + (dt / 2) * k1o, k2o = accel(theta + (dt / 2) * k1t);
      const k3t = omega + (dt / 2) * k2o, k3o = accel(theta + (dt / 2) * k2t);
      const k4t = omega + dt * k3o, k4o = accel(theta + dt * k3t);
      theta += (dt / 6) * (k1t + 2 * k2t + 2 * k3t + k4t);
      omega += (dt / 6) * (k1o + 2 * k2o + 2 * k3o + k4o);
      t += dt;
      samples.push({ t, theta, omega });
      // 从右端出发后角速度先变为负，到左端变正，回到右端时由正变负，正好一个周期。
      if (prevOmega > 0 && omega <= 0) crossings++;
      prevOmega = omega;
      if (crossings >= 1) break;
    }
    return { period: t, samples, dt };
  }

  const SIMULATIONS = {
    projectile: {
      label: '抛体运动',
      params: [
        param('v0', '初速度', 'm/s', 1, 50, 0.5, 10),
        param('angle', '抛射角', '°', 0, 90, 1, 45),
        param('h', '抛出点高度', 'm', 0, 100, 0.5, 0),
        param('g', '重力加速度', 'm/s²', 1, 20, 0.1, 9.8),
      ],
      build(p) {
        const vx = p.v0 * Math.cos(p.angle * DEG);
        const vy = p.v0 * Math.sin(p.angle * DEG);
        const T = (vy + Math.sqrt(vy * vy + 2 * p.g * p.h)) / p.g;
        const range = vx * T;
        const top = p.h + (vy > 0 ? (vy * vy) / (2 * p.g) : 0);
        const tTop = vy > 0 ? vy / p.g : 0;
        const at = (t) => {
          const time = Math.min(Math.max(t, 0), T);
          return { t: time, x: vx * time, y: Math.max(0, p.h + vy * time - 0.5 * p.g * time * time), vx, vy: vy - p.g * time };
        };
        return {
          duration: T,
          results: [
            reading('飞行时间', T, 's'),
            reading('水平射程', range, 'm'),
            reading('最高点高度', top, 'm'),
            reading('到达最高点用时', tTop, 's'),
          ],
          at,
          live(t) {
            const s = at(t);
            return [reading('时间 t', s.t, 's'), reading('水平位移 x', s.x, 'm'), reading('高度 y', s.y, 'm'),
              reading('速度大小', Math.hypot(s.vx, s.vy), 'm/s')];
          },
          bounds: { xmin: 0, xmax: Math.max(range, 1), ymin: 0, ymax: Math.max(top, 1) },
          path(n) {
            const points = [];
            for (let i = 0; i <= n; i++) points.push(at((T * i) / n));
            return points;
          },
        };
      },
    },

    pendulum: {
      label: '单摆',
      params: [
        param('L', '摆长', 'm', 0.2, 5, 0.1, 1),
        param('theta0', '初始角度', '°', 1, 80, 1, 20),
        param('g', '重力加速度', 'm/s²', 1, 20, 0.1, 9.8),
      ],
      build(p) {
        const table = pendulumTable(p.L, p.theta0 * DEG, p.g);
        const T = table.period;
        const at = (t) => {
          const local = ((t % T) + T) % T;
          const index = Math.min(table.samples.length - 1, Math.round(local / table.dt));
          const s = table.samples[index];
          return { t, theta: s.theta, omega: s.omega, x: p.L * Math.sin(s.theta), y: -p.L * Math.cos(s.theta) };
        };
        return {
          duration: Infinity,
          results: [
            reading('周期（实际）', T, 's', 3),
            reading('小角度公式 2π√(L/g)', 2 * Math.PI * Math.sqrt(p.L / p.g), 's', 3),
            reading('最低点速度', Math.sqrt(2 * p.g * p.L * (1 - Math.cos(p.theta0 * DEG))), 'm/s'),
          ],
          at,
          live(t) {
            const s = at(t);
            return [reading('当前角度', s.theta / DEG, '°', 1), reading('速度大小', Math.abs(s.omega) * p.L, 'm/s')];
          },
          bounds: { xmin: -p.L * 1.1, xmax: p.L * 1.1, ymin: -p.L * 1.15, ymax: p.L * 0.15 },
        };
      },
    },

    spring: {
      label: '弹簧振子',
      params: [
        param('k', '劲度系数', 'N/m', 1, 200, 1, 20),
        param('m', '质量', 'kg', 0.1, 10, 0.1, 1),
        param('A', '振幅', 'm', 0.05, 0.5, 0.01, 0.2),
      ],
      build(p) {
        const w = Math.sqrt(p.k / p.m);
        const at = (t) => ({ t, x: p.A * Math.cos(w * t), v: -p.A * w * Math.sin(w * t), a: -p.A * w * w * Math.cos(w * t) });
        return {
          duration: Infinity,
          results: [
            reading('周期 T = 2π√(m/k)', (2 * Math.PI) / w, 's', 3),
            reading('角频率 ω', w, 'rad/s'),
            reading('最大速度', p.A * w, 'm/s'),
            reading('最大加速度', p.A * w * w, 'm/s²'),
          ],
          at,
          live(t) {
            const s = at(t);
            return [reading('位移 x', s.x, 'm', 3), reading('速度 v', s.v, 'm/s'), reading('加速度 a', s.a, 'm/s²')];
          },
          bounds: { xmin: -0.6, xmax: 0.6, ymin: -0.15, ymax: 0.15 },
          period: (2 * Math.PI) / w,
        };
      },
    },

    uniform_acceleration: {
      label: '匀变速直线运动',
      params: [
        param('v0', '初速度', 'm/s', -10, 20, 0.5, 0),
        param('a', '加速度', 'm/s²', -5, 5, 0.1, 2),
        param('T', '运动时间', 's', 1, 10, 0.5, 5),
      ],
      // 刹车这类问题：速度减到 0 后停下，不会反向运动。
      flags: ['stopAtRest'],
      build(p) {
        const tStopRaw = p.a !== 0 ? -p.v0 / p.a : -1;
        const stops = p.stopAtRest && tStopRaw > 0;
        const at = (t) => {
          const time = Math.min(Math.max(t, 0), p.T);
          const moving = stops ? Math.min(time, tStopRaw) : time;
          return { t: time, v: stops && time >= tStopRaw ? 0 : p.v0 + p.a * moving, x: p.v0 * moving + 0.5 * p.a * moving * moving };
        };
        // 位移的范围：端点和速度为 0 的时刻
        const xs = [0, at(p.T).x];
        const tStop = tStopRaw;
        if (tStop > 0 && tStop < p.T) xs.push(at(tStop).x);
        const vs = [p.v0, at(p.T).v, 0];
        return {
          duration: p.T,
          results: (stops && tStopRaw < p.T ? [reading('停下的时刻', tStopRaw, 's')] : []).concat([
            reading('末速度 v = v₀ + at', at(p.T).v, 'm/s'),
            reading('位移 x = v₀t + ½at²', at(p.T).x, 'm'),
            reading('平均速度', at(p.T).x / p.T, 'm/s'),
          ]),
          at,
          live(t) {
            const s = at(t);
            return [reading('时间 t', s.t, 's'), reading('速度 v', s.v, 'm/s'), reading('位移 x', s.x, 'm')];
          },
          bounds: { xmin: Math.min(...xs), xmax: Math.max(...xs), ymin: 0, ymax: 1 },
          vRange: [Math.min(...vs), Math.max(...vs)],
          xRange: [Math.min(...xs), Math.max(...xs)],
        };
      },
    },

    collision: {
      label: '一维碰撞',
      params: [
        param('m1', '物块 1 质量', 'kg', 0.5, 10, 0.5, 1),
        param('v1', '物块 1 初速度', 'm/s', -10, 10, 0.5, 4),
        param('m2', '物块 2 质量', 'kg', 0.5, 10, 0.5, 1),
        param('v2', '物块 2 初速度', 'm/s', -10, 10, 0.5, 0),
        param('e', '恢复系数', '', 0, 1, 0.05, 1),
      ],
      build(p) {
        const width = 0.6;
        const x1 = -2;
        const x2 = 1;
        const gap = x2 - x1 - width;
        const approaching = p.v1 > p.v2;
        const tc = approaching ? gap / (p.v1 - p.v2) : Infinity;
        const total = p.m1 + p.m2;
        const P = p.m1 * p.v1 + p.m2 * p.v2;
        const u1 = approaching ? (P - p.m2 * p.e * (p.v1 - p.v2)) / total : p.v1;
        const u2 = approaching ? (P + p.m1 * p.e * (p.v1 - p.v2)) / total : p.v2;
        const ke = (m, v) => 0.5 * m * v * v;
        const keBefore = ke(p.m1, p.v1) + ke(p.m2, p.v2);
        const keAfter = ke(p.m1, u1) + ke(p.m2, u2);
        const duration = Math.min(6, Number.isFinite(tc) ? tc + 2 : 3);
        const at = (t) => {
          if (t <= tc) return { t, x1: x1 + p.v1 * t, x2: x2 + p.v2 * t, v1: p.v1, v2: p.v2, after: false };
          const d = t - tc;
          return { t, x1: x1 + p.v1 * tc + u1 * d, x2: x2 + p.v2 * tc + u2 * d, v1: u1, v2: u2, after: true };
        };
        // 画面要包含整个过程中两个物块到过的位置
        const xs = [0, Math.min(tc, duration), duration].flatMap((t) => [at(t).x1, at(t).x2]);
        const left = Math.min(...xs) - width;
        const right = Math.max(...xs) + width;
        const results = [
          reading('碰后物块 1 速度', u1, 'm/s'),
          reading('碰后物块 2 速度', u2, 'm/s'),
          reading('总动量（碰前 = 碰后）', P, 'kg·m/s'),
          reading('碰前总动能', keBefore, 'J'),
          reading('碰后总动能', keAfter, 'J'),
          reading('动能损失', keBefore - keAfter, 'J'),
        ];
        return {
          duration,
          results: approaching ? results : [reading('两物块不会相撞', NaN, '')].concat(results.slice(2, 4)),
          at,
          live(t) {
            const s = at(t);
            return [reading('时间 t', s.t, 's'), reading('物块 1 速度', s.v1, 'm/s'), reading('物块 2 速度', s.v2, 'm/s')];
          },
          bounds: { xmin: left, xmax: right, ymin: 0, ymax: 1 },
          width,
          collisionTime: tc,
        };
      },
    },

    electric_deflection: {
      label: '带电粒子在电场中偏转',
      params: [
        param('U', '板间电压', 'V', 10, 2000, 10, 200),
        param('d', '板间距离', 'cm', 0.5, 10, 0.1, 2),
        param('L', '极板长度', 'cm', 1, 20, 0.5, 8),
        param('v0', '初速度（×10⁶ m/s）', '', 1, 50, 0.5, 10),
        param('qm', '比荷（×10¹¹ C/kg）', '', 0.01, 2, 0.01, 1.76),
      ],
      // 默认是电子（带负电）；positive: true 时带正电
      flags: ['positive'],
      build(p) {
        const sign = p.positive ? 1 : -1;
        const d = p.d / 100;
        const L = p.L / 100;
        const v0 = p.v0 * 1e6;
        const a = (p.qm * 1e11 * p.U) / d; // 加速度大小
        // 正电荷受力向下（上板为正极），负电荷向上
        const ay = -sign * a;
        const tPlates = L / v0;
        const yExit = 0.5 * a * tPlates * tPlates;
        const hits = yExit > d / 2;
        const tHit = hits ? Math.sqrt(d / a) : tPlates;
        const vyExit = a * tPlates;
        // 离开极板后匀速直线运动，再走 0.6L
        const tEnd = hits ? tHit : tPlates + (0.6 * L) / v0;
        const pos = (time) => {
          if (time <= tHit) return { x: v0 * time, y: 0.5 * ay * time * time };
          const dt = time - tPlates;
          return { x: L + v0 * dt, y: Math.sign(ay) * (yExit + vyExit * dt) };
        };
        const ANIM = 3; // 动画秒数
        const at = (t) => {
          const time = (Math.min(Math.max(t, 0), ANIM) / ANIM) * tEnd;
          return Object.assign({ t, time }, pos(time));
        };
        const results = hits
          ? [reading('结果', NaN, ''), reading('打在极板上，离入口', v0 * tHit * 100, 'cm'), reading('加速度 a = qU/(md)', a, 'm/s²', 0)]
          : [
            reading('在板间运动时间 t = L/v₀', tPlates * 1e9, 'ns'),
            reading('离开时的偏移 y = qUL²/(2mdv₀²)', yExit * 100, 'cm', 3),
            reading('偏转角 tanθ = qUL/(mdv₀²)', Math.atan(vyExit / v0) * 180 / Math.PI, '°', 1),
            reading('加速度 a = qU/(md)', a, 'm/s²', 0),
          ];
        if (hits) results[0] = Object.assign(results[0], { label: '偏移超过 d/2，粒子打在极板上' });
        return {
          duration: ANIM,
          results,
          at,
          live(t) {
            const s = at(t);
            return [reading('真实时间', s.time * 1e9, 'ns', 2), reading('竖直偏移', Math.abs(s.y) * 100, 'cm', 3)];
          },
          clock: (t) => 't = ' + formatNumber(at(t).time * 1e9, 2) + ' ns（已放慢）',
          bounds: { xmin: -0.15 * L, xmax: 1.65 * L, ymin: -Math.max(d, yExit * 2.2), ymax: Math.max(d, yExit * 2.2) },
          d, L, hits, sign,
          path(n) {
            const points = [];
            for (let i = 0; i <= n; i++) points.push(pos((tEnd * i) / n));
            return points;
          },
        };
      },
    },

    magnetic_circle: {
      label: '带电粒子在匀强磁场中运动',
      params: [
        param('B', '磁感应强度', 'T', 0.01, 2, 0.01, 0.1),
        param('v', '速度（×10⁶ m/s）', '', 0.1, 10, 0.1, 1),
        param('qm', '比荷（×10⁸ C/kg）', '', 0.1, 20, 0.1, 1),
        param('angle', '入射方向与边界法线的夹角', '°', -80, 80, 1, 0),
      ],
      // positive：带正电（默认 true）。boundary：磁场只在边界右侧（默认 true）；false 时整个空间都有磁场，粒子一直做圆周运动。
      flags: ['positive', 'boundary'],
      flagDefaults: { positive: true, boundary: true },
      build(p) {
        const sign = p.positive ? 1 : -1;
        const qm = p.qm * 1e8;
        const v = p.v * 1e6;
        const r = v / (qm * p.B);
        const omega = (qm * p.B); // 角速度大小
        const T = (2 * Math.PI) / omega;
        const phi = p.angle * DEG;
        // 磁场垂直纸面向里：正电荷逆时针转，负电荷顺时针转（把 y 翻过来）
        const swept = p.boundary ? Math.PI - 2 * phi : 2 * Math.PI;
        const tField = swept / omega;
        const pos = (time) => {
          const alpha = phi + omega * time;
          const cx = -r * Math.sin(phi);
          const cy = r * Math.cos(phi);
          return { x: cx + r * Math.sin(alpha), y: sign * (cy - r * Math.cos(alpha)) };
        };
        const ANIM = p.boundary ? 3 : 4;
        const at = (t) => {
          const local = p.boundary ? Math.min(Math.max(t, 0), ANIM) : ((t % ANIM) + ANIM) % ANIM;
          const time = (local / ANIM) * (p.boundary ? tField : T);
          return Object.assign({ t, time }, pos(time));
        };
        const results = [
          reading('半径 r = mv/(qB)', r * 100, 'cm', 2),
          reading('周期 T = 2πm/(qB)', T * 1e9, 'ns', 1),
        ];
        if (p.boundary) {
          results.push(reading('在磁场中转过的角度', swept / DEG, '°', 1));
          results.push(reading('在磁场中的时间', tField * 1e9, 'ns', 1));
          results.push(reading('出射点到入射点的距离 2r·cosθ', 2 * r * Math.cos(phi) * 100, 'cm', 2));
        }
        const ys = [];
        for (let i = 0; i <= 60; i++) ys.push(pos((tField * i) / 60).y);
        return {
          duration: p.boundary ? ANIM : Infinity,
          results,
          at,
          live(t) {
            const s = at(t);
            return [reading('真实时间', s.time * 1e9, 'ns', 1)];
          },
          clock: (t) => 't = ' + formatNumber(at(t).time * 1e9, 1) + ' ns（已放慢）',
          bounds: p.boundary
            ? { xmin: -0.6 * r, xmax: 2.2 * r, ymin: Math.min(...ys, 0) - 0.3 * r, ymax: Math.max(...ys, 0) + 0.3 * r }
            : { xmin: -2.4 * r, xmax: 2.4 * r, ymin: -2.3 * r, ymax: 2.3 * r },
          r, sign, phi,
          path(n) {
            const points = [];
            for (let i = 0; i <= n; i++) points.push(pos((tField * i) / n));
            return points;
          },
        };
      },
    },

    mass_spectrometer: {
      label: '速度选择器和质谱仪',
      params: [
        param('E', '选择器电场（×10⁴ V/m）', '', 0.1, 10, 0.1, 2),
        param('B1', '选择器磁场', 'T', 0.05, 1, 0.01, 0.2),
        param('v', '入射速度（×10⁵ m/s）', '', 0.2, 5, 0.05, 1),
        param('B2', '质谱仪磁场', 'T', 0.05, 1, 0.01, 0.5),
        param('qm1', '粒子 1 比荷（×10⁶ C/kg）', '', 0.1, 10, 0.1, 1),
        param('qm2', '粒子 2 比荷（×10⁶ C/kg，0 表示没有）', '', 0, 10, 0.1, 0.5),
      ],
      build(p) {
        const E = p.E * 1e4;
        const v = p.v * 1e5;
        const vPass = E / p.B1;
        const Ls = 0.3; // 选择器长度
        const gap = 0.015; // 选择器板间半宽
        const species = [p.qm1, p.qm2].filter((q) => q > 0).map((qmRaw, index) => {
          const qm = qmRaw * 1e6;
          // 选择器里：电场力向下 qE，洛伦兹力向上 qvB1，净加速度 a = q(vB1 - E)/m（向上为正）
          const a = qm * (v * p.B1 - E);
          const tSel = Ls / v;
          const yOut = 0.5 * a * tSel * tSel;
          const blocked = Math.abs(yOut) > gap;
          const tBlock = blocked ? Math.sqrt((2 * gap) / Math.abs(a)) : tSel;
          const r = v / (qm * p.B2);
          // 进入质谱仪后在下方做半圆运动（逆时针向下转），打在 y = 0 的底片上
          const tHalf = Math.PI / (qm * p.B2);
          const tEnd = blocked ? tBlock : tSel + tHalf;
          const pos = (time) => {
            if (time <= tBlock) return { x: v * time, y: 0.5 * a * time * time };
            const dt = time - tSel;
            const angle = qm * p.B2 * dt;
            return { x: Ls + r * Math.sin(angle), y: -r + r * Math.cos(angle) };
          };
          return { index, qm, a, blocked, r, tEnd, pos, x: Ls, hitX: Ls + 0 };
        });
        const ANIM = 4;
        const at = (t) => {
          const f = Math.min(Math.max(t, 0), ANIM) / ANIM;
          return { t, particles: species.map((sp) => Object.assign({ blocked: sp.blocked }, sp.pos(f * sp.tEnd))) };
        };
        const results = [
          reading('能直线通过的速度 v = E/B₁', vPass, 'm/s', 0),
          reading(Math.abs(v - vPass) / vPass < 0.01 ? '当前速度等于 E/B₁，粒子直线通过' : (v > vPass ? '速度偏大，洛伦兹力大于电场力，粒子向上偏' : '速度偏小，电场力大于洛伦兹力，粒子向下偏'), NaN, ''),
        ];
        species.forEach((sp) => {
          if (sp.blocked) results.push(reading('粒子 ' + (sp.index + 1) + ' 没能通过选择器', NaN, ''));
          else results.push(reading('粒子 ' + (sp.index + 1) + ' 半径 r = mv/(qB₂)', sp.r * 100, 'cm', 2));
        });
        const maxR = Math.max(0.05, ...species.map((sp) => (sp.blocked ? 0 : sp.r)));
        return {
          duration: ANIM,
          results,
          at,
          live: () => [],
          clock: () => '（动画已放慢）',
          bounds: { xmin: -0.05, xmax: Ls + maxR * 1.15 + 0.02, ymin: -2 * maxR * 1.08 - 0.02, ymax: gap + 0.05 },
          Ls, gap, species,
          path(sp, n) {
            const points = [];
            for (let i = 0; i <= n; i++) points.push(sp.pos((sp.tEnd * i) / n));
            return points;
          },
        };
      },
    },

    rod_induction: {
      label: '导体棒切割磁感线',
      params: [
        param('B', '磁感应强度', 'T', 0.1, 2, 0.05, 0.5),
        param('L', '导轨间距（棒长）', 'm', 0.1, 2, 0.05, 0.5),
        param('R', '电阻', 'Ω', 0.1, 10, 0.1, 1),
        param('m', '棒的质量', 'kg', 0.05, 2, 0.05, 0.1),
        param('v0', '初速度', 'm/s', 0, 10, 0.1, 5),
        param('F', '水平恒力', 'N', 0, 5, 0.05, 0),
      ],
      build(p) {
        const k = (p.B * p.B * p.L * p.L) / p.R; // 安培力 = k·v
        const tau = p.m / k;
        const vt = p.F / k; // 终极速度
        const v = (time) => vt + (p.v0 - vt) * Math.exp(-time / tau);
        const x = (time) => vt * time + (p.v0 - vt) * tau * (1 - Math.exp(-time / tau));
        const duration = Math.min(12, Math.max(2, 5 * tau));
        const at = (t) => {
          const time = Math.min(Math.max(t, 0), duration);
          const speed = v(time);
          const emf = p.B * p.L * speed;
          return { t: time, v: speed, x: x(time), emf, I: emf / p.R, Fa: k * speed };
        };
        const results = [
          reading('初始感应电动势 E = BLv₀', p.B * p.L * p.v0, 'V'),
          reading('初始电流 I = BLv₀/R', (p.B * p.L * p.v0) / p.R, 'A'),
          reading('时间常数 τ = mR/(B²L²)', tau, 's'),
        ];
        if (p.F > 0) results.push(reading('最终速度 v = FR/(B²L²)', vt, 'm/s'));
        else results.push(reading('最终滑行距离 mv₀R/(B²L²)', p.v0 * tau, 'm'));
        const vs = [p.v0, vt, 0];
        return {
          duration,
          results,
          at,
          live(t) {
            const s = at(t);
            return [reading('时间 t', s.t, 's'), reading('速度 v', s.v, 'm/s'), reading('感应电流 I', s.I, 'A', 3),
              reading('安培力', s.Fa, 'N', 3)];
          },
          vRange: [Math.min(...vs), Math.max(...vs)],
          xMax: Math.max(x(duration), 0.1),
          bounds: { xmin: 0, xmax: 1, ymin: 0, ymax: 1 },
        };
      },
    },

    circuit: {
      label: '串联和并联电路',
      params: [
        param('U', '电源电压', 'V', 1, 24, 0.5, 6),
        param('R1', '电阻 R₁', 'Ω', 1, 100, 1, 10),
        param('R2', '电阻 R₂', 'Ω', 1, 100, 1, 20),
        param('R3', '电阻 R₃（0 表示没有）', 'Ω', 0, 100, 1, 0),
        param('r', '电源内阻', 'Ω', 0, 10, 0.1, 0),
      ],
      // parallel：电阻并联（默认串联）
      flags: ['parallel'],
      build(p) {
        const resistors = [p.R1, p.R2, p.R3].filter((r) => r > 0);
        const external = p.parallel ? 1 / resistors.reduce((sum, r) => sum + 1 / r, 0) : resistors.reduce((a, b) => a + b, 0);
        const I = p.U / (external + p.r);
        const terminal = I * external;
        const branches = resistors.map((R, i) => {
          const current = p.parallel ? terminal / R : I;
          return { name: 'R' + (i + 1), R, I: current, U: current * R, P: current * current * R };
        });
        const results = [
          reading(p.parallel ? '并联总电阻 1/R = Σ1/Rᵢ' : '串联总电阻 R = ΣRᵢ', external, 'Ω'),
          reading('干路电流 I = U/(R + r)', I, 'A', 3),
        ];
        if (p.r > 0) results.push(reading('路端电压', terminal, 'V'));
        branches.forEach((b) => results.push(reading(b.name + '：电流 ' + formatNumber(b.I, 3) + ' A，电压', b.U, 'V')));
        return {
          duration: Infinity,
          results,
          at: (t) => ({ t }),
          live: () => [],
          clock: () => '',
          bounds: { xmin: 0, xmax: 1, ymin: 0, ymax: 1 },
          I, branches, parallel: !!p.parallel, terminal,
        };
      },
    },

    equilibrium: {
      label: '化学平衡',
      params: [
        param('kf', '正反应速率常数', '', 0.1, 5, 0.1, 1),
        param('kr', '逆反应速率常数', '', 0.1, 5, 0.1, 0.5),
        param('A0', '反应物 A 初始浓度', 'mol/L', 0.1, 2, 0.05, 1),
        param('B0', '生成物 B 初始浓度', 'mol/L', 0, 2, 0.05, 0),
        param('addA', '中途加入的 A（0 表示不加）', 'mol/L', 0, 2, 0.05, 0.5),
      ],
      build(p) {
        // A ⇌ B，一级反应：d[A]/dt = −kf[A] + kr[B]，解析解
        const K = p.kf / p.kr;
        const k = p.kf + p.kr;
        const tau = 1 / k;
        const tAdd = p.addA > 0 ? 6 * tau : Infinity;
        const duration = Math.min(30, p.addA > 0 ? 12 * tau : 6 * tau);
        const evolve = (A, B, dt) => {
          const total = A + B;
          const Aeq = total / (1 + K);
          const A1 = Aeq + (A - Aeq) * Math.exp(-k * dt);
          return { A: A1, B: total - A1 };
        };
        const atAdd = Number.isFinite(tAdd) ? evolve(p.A0, p.B0, tAdd) : null;
        const at = (t) => {
          const time = Math.min(Math.max(t, 0), duration);
          if (time < tAdd) return Object.assign({ t: time, rf: 0, rr: 0 }, evolve(p.A0, p.B0, time));
          return Object.assign({ t: time }, evolve(atAdd.A + p.addA, atAdd.B, time - tAdd));
        };
        const withRates = (t) => {
          const s = at(t);
          s.rf = p.kf * s.A;
          s.rr = p.kr * s.B;
          return s;
        };
        const end = at(duration);
        const results = [
          reading('平衡常数 K = k正/k逆 = [B]/[A]', K, '', 3),
          reading('达到平衡大约需要（5τ）', 5 * tau, 's'),
          reading('最终 [A]', end.A, 'mol/L', 3),
          reading('最终 [B]', end.B, 'mol/L', 3),
        ];
        if (p.addA > 0) results.push(reading('加入 A 的时刻', tAdd, 's'));
        const max = Math.max(p.A0 + p.B0 + p.addA, 0.1);
        return {
          duration,
          results,
          at: withRates,
          live(t) {
            const s = withRates(t);
            return [reading('时间 t', s.t, 's'), reading('[A]', s.A, 'mol/L', 3), reading('[B]', s.B, 'mol/L', 3),
              reading('正反应速率 / 逆反应速率', s.rr > 1e-9 ? s.rf / s.rr : NaN, '', 3)];
          },
          bounds: { xmin: 0, xmax: 1, ymin: 0, ymax: 1 },
          max, tAdd, K,
        };
      },
    },
  };

  /** 解析 ```simulation 代码块：{ "kind": "...", "title": "...", "params": { ... } }。参数超出范围时取边界。 */
  function parseSimulationSpec(source) {
    try {
      const raw = parseJSONObject(source, '模拟');
      const kind = typeof raw.kind === 'string' ? raw.kind.trim() : '';
      const definition = SIMULATIONS[kind];
      if (!definition) {
        throw new Error('不认识的模拟种类：' + (kind || '（没写 kind）') + '，可用的有 ' + Object.keys(SIMULATIONS).join('、'));
      }
      // 参数可以写在 params 里，也可以直接写在外层
      const given = raw.params && typeof raw.params === 'object' ? raw.params : raw;
      const warnings = [];
      const known = definition.params.map((d) => d.name);
      Object.keys(raw.params && typeof raw.params === 'object' ? raw.params : {}).forEach((name) => {
        if (!known.includes(name) && !(definition.flags || []).includes(name)) warnings.push('忽略了不认识的参数 ' + name);
      });
      const params = definition.params.map((d) => {
        let value = d.value;
        if (given[d.name] !== undefined) {
          value = toNumber(given[d.name], '参数 ' + d.name);
          if (value < d.min || value > d.max) warnings.push('参数 ' + d.name + ' 超出范围，已调整到 ' + d.min + ' 到 ' + d.max + ' 之间');
          value = Math.min(d.max, Math.max(d.min, value));
        }
        return Object.assign({}, d, { value });
      });
      const values = {};
      params.forEach((d) => { values[d.name] = d.value; });
      // 开关类的选项（不是滑块），例如 stopAtRest
      (definition.flags || []).forEach((flag) => {
        const v = raw[flag] !== undefined ? raw[flag] : given[flag];
        const fallback = (definition.flagDefaults || {})[flag] === true;
        values[flag] = v === undefined ? fallback : v === true || v === 1 || v === 'true';
      });
      // 先算一次，确认参数组合能算出结果
      const model = definition.build(values);
      if (!(model.duration > 0)) throw new Error('这组参数下没有运动（例如初速度为 0 又没有高度）');
      return { ok: true, value: { kind, label: definition.label, title: optionalLabel(raw.title), params, defaults: values, warnings } };
    } catch (error) {
      return { ok: false, error: error.message };
    }
  }

  function buildSimulation(kind, values) {
    return SIMULATIONS[kind].build(values);
  }

  function simulationKinds() {
    return Object.keys(SIMULATIONS);
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
    geometry: {
      label: '几何图',
      parse: parseGeometrySpec,
      toText(spec) {
        const shapes = spec.elements.filter((e) => e.kind === 'polygon' || e.kind === 'circle').map((e) => e.id);
        return '[几何图：' + (spec.title || shapes.join('、') || '点和线') + ']';
      },
    },
    chart: { label: '图表', parse: parseChartSpec, toText: chartToText },
    simulation: {
      label: '模拟',
      parse: parseSimulationSpec,
      toText(spec) {
        const params = spec.params.map((p) => p.label + ' ' + formatNumber(p.value, 2) + (p.unit ? ' ' + p.unit : '')).join('，');
        return '[模拟：' + (spec.title || spec.label) + '（' + params + '）]';
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
    // 引用角标只留编号，链接在出处列表里。
    return lines.join('\n').replace(CITATION_MARKER, '[$1]');
  }

  // ---------- 引用角标 ----------

  // 联网搜索的引用在正文里写成 [[1]](<url>)，渲染成上标的 [1]。
  const CITATION_LABEL = /^\[\d{1,3}\]$/;
  const CITATION_MARKER = /\[\[(\d{1,3})\]\]\(<[^>\n]*>\)/g;

  function citationPlugin(md) {
    const fallback = md.renderer.rules.link_open ||
      ((tokens, idx, options, env, self) => self.renderToken(tokens, idx, options));
    md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
      const text = tokens[idx + 1];
      const close = tokens[idx + 2];
      if (text && text.type === 'text' && CITATION_LABEL.test(text.content) && close && close.type === 'link_close') {
        tokens[idx].attrJoin('class', 'sa-cite');
      }
      return fallback(tokens, idx, options, env, self);
    };
  }

  // ---------- 图片尺寸 ----------

  // 汇编里的原图写成 ![](sa-asset:id "w=554,h=255")：标题里是网页上的显示尺寸，转成宽度，不显示成提示文字。
  const IMAGE_SIZE = /^w=(\d{1,4})(?:,h=(\d{1,4}))?$/;

  function imagePlugin(md) {
    const fallback = md.renderer.rules.image;
    md.renderer.rules.image = (tokens, idx, options, env, self) => {
      const token = tokens[idx];
      const match = IMAGE_SIZE.exec(token.attrGet('title') || '');
      if (match) {
        const attrs = token.attrs.filter((a) => a[0] !== 'title');
        token.attrs = attrs;
        token.attrSet('width', match[1]);
        token.attrJoin('class', 'sa-figure');
      }
      return fallback(tokens, idx, options, env, self);
    };
  }

  return {
    mathPlugin,
    citationPlugin,
    imagePlugin,
    compileExpression,
    parseGraphSpec,
    fillFormula,
    formatNumber,
    decimalsForStep,
    parseQuizSpec,
    quizQuestionToJSON,
    normalizeSubject,
    parseStepsSpec,
    parseGeometrySpec,
    computeGeometry,
    parseChartSpec,
    parseSimulationSpec,
    buildSimulation,
    simulationKinds,
    evaluateNumberInput,
    isNumberCorrect,
    componentTypes,
    componentLabel,
    parseComponent,
    extractFences,
    toPlainText,
  };
});
