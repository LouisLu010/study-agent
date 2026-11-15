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

  function draw(container, spec) {
    const colors = palette(components.isDark());
    container.innerHTML = '';
    addTitle(container, spec.title);

    const [xmin, xmax] = spec.xRange;
    const [ymin, ymax] = spec.yRange;
    const board = createBoard(container, { board: { boundingbox: [xmin, ymax, xmax, ymin], axis: true } });
    container.board = board;

    let colorIndex = 0;
    const nextColor = () => COLORS[colorIndex++ % COLORS.length];

    const legend = document.createElement('div');
    legend.className = 'graph-legend';
    spec.functions.forEach((f) => {
      const color = nextColor();
      const args = [f.fn];
      if (f.domain) args.push(f.domain[0], f.domain[1]);
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

    spec.segments.forEach((s) => {
      board.create('segment', [s.from, s.to], {
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
      board.create('point', [p.x, p.y], {
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
