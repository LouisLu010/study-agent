/*
 * 几何图组件：没有坐标轴的平面几何图形，可以拖动点，读数随之更新。
 * 点的位置由 core.computeGeometry 计算（和测试共用），JSXGraph 只负责显示和拖动。
 * 组件状态：{ moved: { 点id: [x, y] } }，只记录被拖动过的自由点。
 */
(function () {
  'use strict';

  const components = window.StudyComponents;
  const core = window.StudyCore;
  const graph = window.StudyGraph;

  function restoreMoved(spec, saved) {
    const moved = {};
    const raw = saved && saved.moved;
    if (raw && typeof raw === 'object') {
      spec.elements.forEach((e) => {
        const value = raw[e.id];
        if (e.kind === 'point' && !e.fixed && Array.isArray(value) && value.every(Number.isFinite)) {
          moved[e.id] = value.slice(0, 2);
        }
      });
    }
    return moved;
  }

  function draw(container, spec, ctx) {
    const dark = components.isDark();
    const colors = graph.palette(dark);
    const accent = dark ? '#0a84ff' : '#007aff';
    container.innerHTML = '';
    graph.addTitle(container, spec.title);

    const [xmin, xmax] = spec.xRange;
    const [ymin, ymax] = spec.yRange;
    const board = graph.createBoard(container, {
      board: {
        boundingbox: [xmin, ymax, xmax, ymin],
        axis: false,
        grid: spec.grid,
        keepAspectRatio: true,
        showNavigation: false,
      },
    });
    container.board = board;
    // 几何图里单指要用来拖动点，所以不把单指滑动交给外层列表。
    board.containerObj.style.touchAction = 'none';

    const free = {};
    const jsx = {};

    // 自由点的当前位置 → 所有元素的位置和数值。同一次刷新里结果不变，缓存一下。
    let cacheKey = '';
    let cache = null;
    function current() {
      const moved = {};
      Object.keys(free).forEach((id) => { moved[id] = [free[id].X(), free[id].Y()]; });
      const key = JSON.stringify(moved);
      if (key !== cacheKey) {
        cacheKey = key;
        cache = core.computeGeometry(spec, moved);
      }
      return cache;
    }

    const initial = core.computeGeometry(spec, restoreMoved(spec, ctx.state));
    // 初始位置（限制在圆或直线上的点已经放到线上），复位和判断"是否拖动过"都以它为准。
    const defaults = core.computeGeometry(spec, null).points;
    const pointStyle = (e, draggable) => ({
      name: e.label !== null ? e.label : e.id,
      withLabel: !e.hidden,
      visible: !e.hidden,
      size: draggable ? 5 : 3,
      fixed: !draggable,
      strokeColor: draggable ? accent : colors.text,
      fillColor: draggable ? accent : colors.text,
      highlight: draggable,
      showInfobox: false,
      label: { offset: [7, 9], strokeColor: colors.text },
    });
    const lineStyle = (e) => ({
      strokeColor: colors.text,
      strokeWidth: 2,
      dash: e.dashed ? 2 : 0,
      fixed: true,
      highlight: false,
      visible: !e.hidden,
      name: e.label || '',
      withLabel: !!e.label,
    });

    spec.elements.forEach((e) => {
      switch (e.kind) {
        case 'point': {
          const p = initial.points[e.id];
          const draggable = !e.fixed;
          const object = e.on
            ? board.create('glider', [p.x, p.y, jsx[e.on]], pointStyle(e, draggable))
            : board.create('point', [p.x, p.y], pointStyle(e, draggable));
          jsx[e.id] = object;
          if (draggable) {
            free[e.id] = object;
            object.on('up', save);
          }
          break;
        }
        case 'midpoint':
        case 'intersection':
        case 'foot':
          jsx[e.id] = board.create('point', [() => current().points[e.id].x, () => current().points[e.id].y], pointStyle(e, false));
          break;
        case 'segment':
          jsx[e.id] = board.create('segment', e.through.map((id) => jsx[id]), lineStyle(e));
          break;
        case 'line':
          jsx[e.id] = board.create('line', e.through.map((id) => jsx[id]), lineStyle(e));
          break;
        case 'ray':
          jsx[e.id] = board.create('line', e.through.map((id) => jsx[id]),
            Object.assign(lineStyle(e), { straightFirst: false, straightLast: true }));
          break;
        case 'circle':
          jsx[e.id] = board.create('circle',
            e.radius !== null ? [jsx[e.center], e.radius] : [jsx[e.center], jsx[e.through]],
            Object.assign(lineStyle(e), { fillColor: 'none' }));
          break;
        case 'polygon':
          jsx[e.id] = board.create('polygon', e.vertices.map((id) => jsx[id]), {
            fillColor: accent,
            fillOpacity: e.hidden ? 0 : 0.1,
            highlight: false,
            fixed: true,
            vertices: { visible: false },
            borders: { strokeColor: colors.text, strokeWidth: e.hidden ? 0 : 2, highlight: false, fixed: true },
            name: e.label || '',
            withLabel: !!e.label,
          });
          break;
        case 'angle':
          jsx[e.id] = board.create('nonreflexangle', e.points.map((id) => jsx[id]), {
            radius: Math.min(xmax - xmin, ymax - ymin) * 0.08,
            fillColor: '#ff9500',
            fillOpacity: 0.25,
            strokeColor: '#ff9500',
            highlight: false,
            fixed: true,
            visible: !e.hidden,
            name: e.label || '',
            withLabel: !!e.label,
            label: { strokeColor: '#ff9500' },
          });
          break;
        default:
          break;
      }
    });

    // ---------- 读数和复位 ----------

    const panel = document.createElement('div');
    panel.className = 'graph-controls';
    const rows = spec.readouts.map((r) => {
      const row = document.createElement('div');
      row.className = 'geometry-readout';
      const label = document.createElement('span');
      label.innerHTML = ctx.renderInline(r.label);
      const value = document.createElement('span');
      value.className = 'graph-readout-value';
      row.append(label, value);
      panel.appendChild(row);
      return value;
    });

    const hint = document.createElement('div');
    hint.className = 'geometry-hint';
    hint.textContent = Object.keys(free).length ? '拖动蓝色的点，看看哪些量会变、哪些量不变。' : '';

    const reset = document.createElement('button');
    reset.className = 'sa-button graph-reset';
    reset.textContent = '复位';
    reset.addEventListener('click', () => {
      Object.keys(free).forEach((id) => {
        free[id].setPosition(window.JXG.COORDS_BY_USER, [defaults[id].x, defaults[id].y]);
      });
      board.update();
      ctx.setState(null);
      refresh();
    });

    const footer = document.createElement('div');
    footer.className = 'geometry-footer';
    footer.append(hint, reset);
    panel.appendChild(footer);
    container.appendChild(panel);

    function isMoved() {
      return Object.keys(free).some((id) =>
        Math.abs(free[id].X() - defaults[id].x) > 1e-4 || Math.abs(free[id].Y() - defaults[id].y) > 1e-4);
    }

    function refresh() {
      const { measures } = current();
      spec.readouts.forEach((r, i) => {
        rows[i].textContent = core.formatNumber(r.evaluate(measures), r.decimals) + (r.unit ? ' ' + r.unit : '');
      });
      reset.hidden = !isMoved();
    }

    function save() {
      if (!isMoved()) {
        ctx.setState(null);
        return;
      }
      const moved = {};
      Object.keys(free).forEach((id) => {
        moved[id] = [Number(free[id].X().toFixed(4)), Number(free[id].Y().toFixed(4))];
      });
      ctx.setState({ moved });
    }

    board.on('update', refresh);
    refresh();
  }

  components.register('geometry', {
    load: graph.loadJSXGraph,
    draw,
    destroy(container) {
      if (container.board) window.JXG.JSXGraph.freeBoard(container.board);
      container.board = null;
    },
  });
})();
