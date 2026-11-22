/*
 * 坐标图组件：把 ```graph 代码块里的 JSON 画成可缩放、可拖动的 JSXGraph 坐标系（见 docs/adr/0002）。
 */
(function () {
  'use strict';

  const components = window.StudyComponents;

  // 第八版：配色调柔和一些。图表用同一组颜色。
  const COLORS = ['#3b82f6', '#ef4444', '#22c55e', '#f59e0b', '#a855f7', '#14b8a6', '#ec4899', '#a16207'];
  /** 当前视野里最多自动标出几个关键点。 */
  const MAX_KEY_POINTS = 6;
  const KIND_NAMES = { max: '极大值', min: '极小值', zero: '零点', intersection: '交点' };
  let boardCounter = 0;

  function palette(dark) {
    return {
      text: dark ? '#f2f2f7' : '#1c1c1e',
      axis: dark ? '#8e8e93' : '#3a3a3c',
      grid: dark ? '#3a3a3c' : '#e5e5ea',
    };
  }

  /** 新建一个 JSXGraph 画板。几何图也会用到。 */
  function createBoard(container, options) {
    const colors = palette(components.isDark());
    const box = document.createElement('div');
    box.id = 'jxg-board-' + ++boardCounter;
    box.className = 'jxgbox graph-board';
    // JSXGraph 需要容器有明确的像素尺寸（CSS aspect-ratio 不行）。
    box.style.height = Math.round(Math.min(420, Math.max(200, container.clientWidth * (options.aspect || 0.75)))) + 'px';
    container.appendChild(box);

    const JXG = window.JXG;
    JXG.Options.text.strokeColor = colors.text;
    JXG.Options.text.fontSize = 13;

    const board = JXG.JSXGraph.initBoard(box.id, Object.assign({
      keepAspectRatio: false,
      showCopyright: false,
      showNavigation: true,
      grid: false,
      // 单指上下滑动交给外层列表滚动，双指拖动和缩放图形。
      pan: { enabled: true, needTwoFingers: true },
      zoom: { enabled: true, wheel: false, pinch: true, needShift: false, min: 0.05, max: 50 },
      defaultAxes: {
        x: { strokeColor: colors.axis, ticks: { strokeColor: colors.grid, majorHeight: -1, label: { strokeColor: colors.axis } } },
        y: { strokeColor: colors.axis, ticks: { strokeColor: colors.grid, majorHeight: -1, label: { strokeColor: colors.axis } } },
      },
    }, options.board));
    box.style.touchAction = 'pan-y';
    return board;
  }

  function addTitle(container, title) {
    if (!title) return;
    const element = document.createElement('div');
    element.className = 'graph-title';
    element.textContent = title;
    container.appendChild(element);
  }

  const core = window.StudyCore;

  function tex(source) {
    return window.katex.renderToString(source, { throwOnError: false, strict: 'ignore' });
  }

  /** 保存的状态里取出参数值，只认识已声明的参数，并限制在范围内。 */
  function restoreValues(spec, saved) {
    const values = Object.assign({}, spec.defaults);
    if (saved && typeof saved === 'object') {
      spec.params.forEach((p) => {
        const v = Number(saved[p.name]);
        if (Number.isFinite(v)) values[p.name] = Math.min(p.max, Math.max(p.min, v));
      });
    }
    return values;
  }

  /** 参数滑块、实时公式、读数和复位按钮。 */
  function buildControls(container, spec, values, board, ctx) {
    const panel = document.createElement('div');
    panel.className = 'graph-controls';

    let formula = null;
    if (spec.formula) {
      formula = document.createElement('div');
      formula.className = 'graph-formula';
      panel.appendChild(formula);
    }

    const valueLabels = {};
    const inputs = {};
    spec.params.forEach((p) => {
      const row = document.createElement('label');
      row.className = 'graph-param';
      const name = document.createElement('span');
      name.className = 'graph-param-name';
      name.innerHTML = tex(p.name) + (p.label ? '<small>' + window.StudyRenderer.escapeHTML(p.label) + '</small>' : '');
      const input = document.createElement('input');
      input.type = 'range';
      input.min = String(p.min);
      input.max = String(p.max);
      input.step = String(p.step);
      input.value = String(values[p.name]);
      const value = document.createElement('span');
      value.className = 'graph-param-value';
      row.append(name, input, value);
      panel.appendChild(row);
      valueLabels[p.name] = value;
      inputs[p.name] = input;

      input.addEventListener('input', () => {
        values[p.name] = Number(input.value);
        refresh();
      });
      // 松手时才保存，拖动过程中不反复写入。
      input.addEventListener('change', save);
    });

    let readoutRows = [];
    if (spec.readouts.length) {
      const list = document.createElement('div');
      list.className = 'graph-readouts';
      readoutRows = spec.readouts.map((r) => {
        const row = document.createElement('div');
        const label = document.createElement('span');
        label.textContent = r.label || '读数';
        const value = document.createElement('span');
        value.className = 'graph-readout-value';
        row.append(label, value);
        list.appendChild(row);
        return value;
      });
      panel.appendChild(list);
    }

    const reset = document.createElement('button');
    reset.className = 'sa-button graph-reset';
    reset.textContent = '复位';
    reset.addEventListener('click', () => {
      Object.assign(values, spec.defaults);
      spec.params.forEach((p) => { inputs[p.name].value = String(values[p.name]); });
      refresh();
      ctx.setState(null);
    });
    panel.appendChild(reset);
    container.appendChild(panel);

    function isDefault() {
      return spec.params.every((p) => Math.abs(values[p.name] - spec.defaults[p.name]) < p.step / 2);
    }

    function save() {
      ctx.setState(isDefault() ? null : Object.assign({}, values));
      reset.hidden = isDefault();
    }

    function refresh() {
      board.update();
      spec.params.forEach((p) => {
        valueLabels[p.name].textContent = core.formatNumber(values[p.name], core.decimalsForStep(p.step));
      });
      if (formula) formula.innerHTML = tex(core.fillFormula(spec.formula, spec.params, values));
      spec.readouts.forEach((r, i) => {
        const parts = r.values.map((fn) => core.formatNumber(fn(values), 2));
        readoutRows[i].textContent = r.pair ? '(' + parts.join(', ') + ')' : parts[0];
      });
      reset.hidden = isDefault();
    }

    refresh();
  }

  function draw(container, spec, ctx) {
    const colors = palette(components.isDark());
    container.innerHTML = '';
    addTitle(container, spec.title);
    // 每个坐标图有自己的一份参数值，同一段描述出现两次也互不影响。
    const values = restoreValues(spec, ctx && ctx.state);

    // 范围的边界正好是坐标轴（例如 x 从 0 开始）时留出一点边距，否则刻度数字会被裁掉。
    let [xmin, xmax] = spec.xRange;
    let [ymin, ymax] = spec.yRange;
    if (xmin === 0) xmin = -(xmax - xmin) * 0.06;
    if (ymin === 0) ymin = -(ymax - ymin) * 0.08;
    if (xmax === 0) xmax = (xmax - xmin) * 0.06;
    if (ymax === 0) ymax = (ymax - ymin) * 0.08;
    const board = createBoard(container, { board: { boundingbox: [xmin, ymax, xmax, ymin], axis: true } });
    container.board = board;

    let colorIndex = 0;
    const nextColor = () => COLORS[colorIndex++ % COLORS.length];

    const legend = document.createElement('div');
    legend.className = 'graph-legend';
    // 每条曲线：取值函数（定义域外是 NaN）、颜色、JSXGraph 对象、是否显示。
    const curves = [];
    spec.functions.forEach((f) => {
      const color = nextColor();
      const args = [(x) => f.at(x, values)];
      if (f.domainAt) args.push(() => f.domainAt[0](values), () => f.domainAt[1](values));
      const jsx = board.create('functiongraph', args, {
        strokeColor: color,
        strokeWidth: 3,
        dash: f.dashed ? 2 : 0,
        highlight: false,
        withLabel: false,
      });
      const curve = {
        color,
        jsx,
        visible: true,
        name: f.label || 'y = ' + f.expr,
        fn(x) {
          if (f.domainAt && (x < f.domainAt[0](values) || x > f.domainAt[1](values))) return NaN;
          return f.at(x, values);
        },
      };
      curves.push(curve);
      // 函数名放在图下方的图例里，避免标签被坐标系边缘截断。点一下隐藏或显示这条曲线。
      const item = document.createElement('button');
      item.className = 'graph-legend-item';
      item.setAttribute('aria-pressed', 'true');
      const swatch = document.createElement('i');
      swatch.style.borderTop = '3px ' + (f.dashed ? 'dashed ' : 'solid ') + color;
      item.appendChild(swatch);
      item.appendChild(document.createTextNode(curve.name));
      item.addEventListener('click', () => {
        curve.visible = !curve.visible;
        jsx.setAttribute({ visible: curve.visible });
        item.classList.toggle('is-hidden', !curve.visible);
        item.setAttribute('aria-pressed', String(curve.visible));
        scheduleKeyPoints();
      });
      legend.appendChild(item);
    });
    if (spec.functions.length > 1) container.appendChild(legend);
    else if (legend.childNodes.length) {
      // 只有一条曲线时图例只是说明，不用来隐藏。
      legend.querySelector('button').disabled = true;
      container.appendChild(legend);
    }

    // 端点可能含参数，用不可见的点承载，参数变化时线段跟着动。
    const hiddenPoint = (coord) => board.create('point', [() => coord[0].at(values), () => coord[1].at(values)], {
      visible: false,
      fixed: true,
      withLabel: false,
    });

    spec.segments.forEach((s) => {
      board.create('segment', [hiddenPoint(s.from), hiddenPoint(s.to)], {
        strokeColor: colors.axis,
        strokeWidth: 1.5,
        dash: s.dashed ? 2 : 0,
        fixed: true,
        highlight: false,
        name: s.label,
        withLabel: !!s.label,
      });
    });

    spec.points.forEach((p) => {
      board.create('point', [() => p.xAt(values), () => p.yAt(values)], {
        name: p.label,
        withLabel: !!p.label,
        fixed: true,
        size: 3,
        strokeColor: colors.text,
        fillColor: colors.text,
        highlight: false,
        showInfobox: false,
        label: { offset: [6, 8] },
      });
    });

    if (spec.params.length || spec.readouts.length) {
      buildControls(container, spec, values, board, ctx);
    }

    // ---------- 自动标出的关键点（第八版） ----------
    //
    // 极值点、零点和两条曲线的交点。离模型自己画的点很近的跳过，当前视野里最多 6 个，
    // 平时只画小点，点一下显示坐标。拖参数、缩放和平移后重新计算。

    const box = board.containerObj;
    if (getComputedStyle(box).position === 'static') box.style.position = 'relative';
    const pool = [];
    for (let i = 0; i < MAX_KEY_POINTS; i++) {
      pool.push(board.create('point', [0, 0], {
        name: '',
        withLabel: false,
        visible: false,
        fixed: true,
        size: 3,
        strokeColor: components.isDark() ? '#1c1c1e' : '#ffffff',
        strokeWidth: 1.5,
        highlight: false,
        showInfobox: false,
      }));
    }
    let shown = [];
    let keySignature = '';
    let keyFrame = 0;
    const tip = document.createElement('div');
    tip.className = 'graph-tip';
    tip.hidden = true;
    box.appendChild(tip);

    function toScreen(x, y) {
      return [board.origin.scrCoords[1] + x * board.unitX, board.origin.scrCoords[2] - y * board.unitY];
    }

    function scheduleKeyPoints() {
      if (keyFrame) return;
      keyFrame = requestAnimationFrame(() => {
        keyFrame = 0;
        updateKeyPoints();
      });
    }

    function updateKeyPoints() {
      if (!container.board) return;
      const [x1, y1, x2, y2] = board.getBoundingBox();
      const signature = [x1, y1, x2, y2].map((v) => v.toPrecision(6)).join(',') + '|' +
        JSON.stringify(values) + '|' + curves.map((c) => c.visible).join(',');
      if (signature === keySignature) return;
      keySignature = signature;
      tip.hidden = true;
      const visible = curves.filter((c) => c.visible);
      const found = core.graphKeyPoints(visible.map((c) => c.fn), x1, x2)
        .filter((p) => p.y <= y1 && p.y >= y2)
        .map((p) => Object.assign(p, { curve: visible[p.curves[0]] }));
      const modelPoints = spec.points.map((p) => toScreen(p.xAt(values), p.yAt(values)));
      const cx = (x1 + x2) / 2;
      const order = { max: 0, min: 0, intersection: 1, zero: 2 };
      shown = found
        .filter((p) => {
          const [sx, sy] = toScreen(p.x, p.y);
          return !modelPoints.some(([mx, my]) => Math.hypot(mx - sx, my - sy) < 12);
        })
        .sort((a, b) => order[a.kind] - order[b.kind] || Math.abs(a.x - cx) - Math.abs(b.x - cx))
        .slice(0, MAX_KEY_POINTS);
      pool.forEach((point, i) => {
        const p = shown[i];
        if (p) {
          point.setPosition(window.JXG.COORDS_BY_USER, [p.x, p.y]);
          point.setAttribute({ visible: true, fillColor: p.kind === 'intersection' ? colors.text : p.curve.color });
        } else if (point.visProp.visible) {
          point.setAttribute({ visible: false });
        }
      });
      board.update();
    }

    function showTip(p) {
      const [sx, sy] = toScreen(p.x, p.y);
      tip.textContent = KIND_NAMES[p.kind] + '  (' + core.formatNumber(p.x, 2) + ', ' + core.formatNumber(p.y, 2) + ')';
      tip.hidden = false;
      const w = box.clientWidth;
      tip.style.left = Math.min(Math.max(4, sx - tip.offsetWidth / 2), w - tip.offsetWidth - 4) + 'px';
      tip.style.top = Math.max(4, sy - tip.offsetHeight - 10) + 'px';
    }

    /** 点一下关键点显示坐标，点别处收起。 */
    box.addEventListener('click', (event) => {
      if (tracing) return;
      const rect = box.getBoundingClientRect();
      const x = event.clientX - rect.left;
      const y = event.clientY - rect.top;
      let best = null;
      shown.forEach((p) => {
        const [sx, sy] = toScreen(p.x, p.y);
        const d = Math.hypot(sx - x, sy - y);
        if (d < 18 && (!best || d < best.d)) best = { d, p };
      });
      if (best) showTip(best.p);
      else tip.hidden = true;
    });

    // ---------- 按住拖动：沿曲线查看数值（第八版） ----------
    //
    // 按住不动约 0.35 秒后出现一条跟手的竖线，显示每条曲线在这个 x 的值。
    // 快速滑动仍然交给外层列表（单指）和坐标图的平移缩放（双指），不受影响。

    const traceLine = document.createElement('div');
    traceLine.className = 'graph-trace-line';
    const traceInfo = document.createElement('div');
    traceInfo.className = 'graph-trace-info';
    const traceDots = curves.map((c) => {
      const dot = document.createElement('i');
      dot.className = 'graph-trace-dot';
      dot.style.background = c.color;
      return dot;
    });
    traceLine.hidden = true;
    traceInfo.hidden = true;
    traceDots.forEach((d) => { d.hidden = true; box.appendChild(d); });
    box.append(traceLine, traceInfo);

    let tracing = false;
    let holdTimer = 0;
    let holdStart = null;

    function traceAt(clientX) {
      const rect = box.getBoundingClientRect();
      const sx = Math.min(Math.max(clientX - rect.left, 0), rect.width);
      const x = (sx - board.origin.scrCoords[1]) / board.unitX;
      traceLine.style.left = sx + 'px';
      const rows = ['x = ' + core.formatNumber(x, 2)];
      curves.forEach((c, i) => {
        const y = c.visible ? c.fn(x) : NaN;
        const dot = traceDots[i];
        if (!Number.isFinite(y)) {
          dot.hidden = true;
          return;
        }
        const [, sy] = toScreen(x, y);
        dot.hidden = sy < 0 || sy > rect.height;
        dot.style.left = sx + 'px';
        dot.style.top = sy + 'px';
        rows.push('<span style="color:' + c.color + '">●</span> ' + window.StudyRenderer.escapeHTML(c.name) + '：' + core.formatNumber(y, 3));
      });
      traceInfo.innerHTML = rows.map((r, i) => (i ? r : '<b>' + r + '</b>')).join('<br>');
      const w = traceInfo.offsetWidth;
      traceInfo.style.left = (sx + 12 + w > rect.width ? sx - 12 - w : sx + 12) + 'px';
    }

    function beginTrace(clientX) {
      tracing = true;
      tip.hidden = true;
      components.lockScroll(true);
      traceLine.hidden = false;
      traceInfo.hidden = false;
      traceAt(clientX);
    }

    function endTrace() {
      clearTimeout(holdTimer);
      holdTimer = 0;
      holdStart = null;
      if (!tracing) return;
      tracing = false;
      traceLine.hidden = true;
      traceInfo.hidden = true;
      traceDots.forEach((d) => { d.hidden = true; });
      components.lockScroll(false);
    }

    function holdBegin(x, y) {
      clearTimeout(holdTimer);
      holdStart = { x, y };
      holdTimer = setTimeout(() => {
        holdTimer = 0;
        if (holdStart) beginTrace(holdStart.x);
      }, 350);
    }

    function holdMove(x, y, event) {
      if (tracing) {
        if (event.cancelable) event.preventDefault();
        traceAt(x);
      } else if (holdStart && Math.hypot(x - holdStart.x, y - holdStart.y) > 8) {
        // 手指动了：是滑动，不是按住。
        clearTimeout(holdTimer);
        holdTimer = 0;
        holdStart = null;
      }
    }

    box.addEventListener('touchstart', (event) => {
      if (event.touches.length !== 1) {
        endTrace();
        return;
      }
      holdBegin(event.touches[0].clientX, event.touches[0].clientY);
    }, { passive: true });
    box.addEventListener('touchmove', (event) => {
      if (event.touches.length !== 1) {
        endTrace();
        return;
      }
      holdMove(event.touches[0].clientX, event.touches[0].clientY, event);
    }, { passive: false });
    box.addEventListener('touchend', endTrace);
    box.addEventListener('touchcancel', endTrace);
    // 鼠标（iPad 触控板、浏览器里检查时）：按住左键同样可以查看。
    box.addEventListener('mousedown', (event) => {
      if (event.button === 0 && !('ontouchstart' in window)) holdBegin(event.clientX, event.clientY);
    });
    box.addEventListener('mousemove', (event) => {
      if (holdStart || tracing) holdMove(event.clientX, event.clientY, event);
    });
    window.addEventListener('mouseup', endTrace);

    board.on('update', scheduleKeyPoints);
    board.on('boundingbox', scheduleKeyPoints);
    container.graph = {
      stop() {
        if (keyFrame) cancelAnimationFrame(keyFrame);
        keyFrame = 0;
        endTrace();
        window.removeEventListener('mouseup', endTrace);
      },
    };
    updateKeyPoints();
  }

  function loadJSXGraph() {
    if (window.JXG) return Promise.resolve();
    return components.loadAssets(['vendor/jsxgraph/jsxgraphcore.js'], ['vendor/jsxgraph/jsxgraph.css']);
  }

  components.register('graph', {
    load: loadJSXGraph,
    draw,
    destroy(container) {
      if (container.graph) container.graph.stop();
      container.graph = null;
      if (container.board) window.JXG.JSXGraph.freeBoard(container.board);
      container.board = null;
    },
  });

  window.StudyGraph = { loadJSXGraph, createBoard, addTitle, palette, COLORS };
})();
