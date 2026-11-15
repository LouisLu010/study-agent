/*
 * 坐标图组件：把 ```graph 代码块里的 JSON 画成可缩放、可拖动的 JSXGraph 坐标系（见 docs/adr/0002）。
 */
(function () {
  'use strict';

  const components = window.StudyComponents;

  const COLORS = ['#007aff', '#ff3b30', '#34c759', '#ff9500', '#af52de', '#5ac8fa'];
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
    spec.functions.forEach((f) => {
      const color = nextColor();
      const args = [(x) => f.at(x, values)];
      if (f.domainAt) args.push(() => f.domainAt[0](values), () => f.domainAt[1](values));
      board.create('functiongraph', args, {
        strokeColor: color,
        strokeWidth: 2.5,
        dash: f.dashed ? 2 : 0,
        highlight: false,
        withLabel: false,
      });
      // 函数名放在图下方的图例里，避免标签被坐标系边缘截断。
      const item = document.createElement('span');
      item.className = 'graph-legend-item';
      const swatch = document.createElement('i');
      swatch.style.borderTop = '3px ' + (f.dashed ? 'dashed ' : 'solid ') + color;
      item.appendChild(swatch);
      item.appendChild(document.createTextNode(f.label || 'y = ' + f.expr));
      legend.appendChild(item);
    });
    if (legend.childNodes.length) container.appendChild(legend);

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
  }

  function loadJSXGraph() {
    if (window.JXG) return Promise.resolve();
    return components.loadAssets(['vendor/jsxgraph/jsxgraphcore.js'], ['vendor/jsxgraph/jsxgraph.css']);
  }

  components.register('graph', {
    load: loadJSXGraph,
    draw,
    destroy(container) {
      if (container.board) window.JXG.JSXGraph.freeBoard(container.board);
      container.board = null;
    },
  });

  window.StudyGraph = { loadJSXGraph, createBoard, addTitle, palette, COLORS };
})();
