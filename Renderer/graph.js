/*
 * 坐标图：把 ```graph 代码块里的 JSON 画成可缩放、可拖动的 JSXGraph 坐标系（见 docs/adr/0002）。
 * JSXGraph 体积较大，第一次遇到坐标图时才加载。
 */
(function () {
  'use strict';

  const renderer = window.StudyRenderer;
  const core = window.StudyCore;

  const COLORS = ['#007aff', '#ff3b30', '#34c759', '#ff9500', '#af52de', '#5ac8fa'];

  // 同一段 JSON 只画一次：流式渲染每次替换 innerHTML 前把已画好的图摘下来，替换后再放回去。
  const specs = new Map();
  let boardCounter = 0;

  function hashKey(text) {
    let hash = 5381;
    for (let i = 0; i < text.length; i++) hash = ((hash << 5) + hash + text.charCodeAt(i)) | 0;
    return 'g' + (hash >>> 0).toString(36) + '-' + text.length;
  }

  renderer.fenceHandlers.graph = (content, env) => {
    const result = core.parseGraphSpec(content);
    if (result.ok) {
      const key = hashKey(content.trim());
      specs.set(key, result.value);
      return '<div class="graph" data-graph-key="' + key + '"></div>\n';
    }
    if (env.streaming) {
      return '<div class="graph-pending">正在绘制坐标图…</div>\n';
    }
    // 生成结束后仍然不合法：按普通代码块显示原文。
    return null;
  };

  // ---------- 按需加载 JSXGraph ----------

  let jsxLoading = null;
  function loadJSXGraph() {
    if (window.JXG) return Promise.resolve();
    if (!jsxLoading) {
      jsxLoading = new Promise((resolve, reject) => {
        const css = document.createElement('link');
        css.rel = 'stylesheet';
        css.href = 'vendor/jsxgraph/jsxgraph.css';
        // 放在 renderer.css 前面，让我们的样式覆盖 JSXGraph 的默认样式。
        document.head.insertBefore(css, document.head.querySelector('link[href="renderer.css"]'));
        const script = document.createElement('script');
        script.src = 'vendor/jsxgraph/jsxgraphcore.js';
        script.onload = resolve;
        script.onerror = () => reject(new Error('JSXGraph 加载失败'));
        document.head.appendChild(script);
      });
    }
    return jsxLoading;
  }

  // ---------- 绘制 ----------

  function isDark() {
    return window.matchMedia('(prefers-color-scheme: dark)').matches;
  }

  function drawBoard(container, spec) {
    const dark = isDark();
    const textColor = dark ? '#f2f2f7' : '#1c1c1e';
    const axisColor = dark ? '#8e8e93' : '#3a3a3c';
    const gridColor = dark ? '#3a3a3c' : '#e5e5ea';

    container.innerHTML = '';
    if (spec.title) {
      const title = document.createElement('div');
      title.className = 'graph-title';
      title.textContent = spec.title;
      container.appendChild(title);
    }
    const box = document.createElement('div');
    box.id = 'jxg-board-' + ++boardCounter;
    box.className = 'jxgbox graph-board';
    // JSXGraph 需要容器有明确的像素尺寸（CSS aspect-ratio 不行）。
    box.style.height = Math.round(Math.min(420, Math.max(200, container.clientWidth * 0.75))) + 'px';
    container.appendChild(box);

    const JXG = window.JXG;
    JXG.Options.text.strokeColor = textColor;
    JXG.Options.text.fontSize = 13;

    const [xmin, xmax] = spec.xRange;
    const [ymin, ymax] = spec.yRange;
    const board = JXG.JSXGraph.initBoard(box.id, {
      boundingbox: [xmin, ymax, xmax, ymin],
      keepAspectRatio: false,
      showCopyright: false,
      showNavigation: true,
      axis: true,
      grid: false,
      // 单指上下滑动交给外层列表滚动，双指拖动和缩放图形。
      pan: { enabled: true, needTwoFingers: true },
      zoom: { enabled: true, wheel: false, pinch: true, needShift: false, min: 0.05, max: 50 },
      defaultAxes: {
        x: { strokeColor: axisColor, ticks: { strokeColor: gridColor, majorHeight: -1, label: { strokeColor: axisColor } } },
        y: { strokeColor: axisColor, ticks: { strokeColor: gridColor, majorHeight: -1, label: { strokeColor: axisColor } } },
      },
    });
    box.style.touchAction = 'pan-y';
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
        strokeColor: axisColor,
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
        strokeColor: textColor,
        fillColor: textColor,
        highlight: false,
        showInfobox: false,
        label: { offset: [6, 8] },
      });
    });
  }

  function renderGraph(container) {
    const spec = specs.get(container.dataset.graphKey);
    if (!spec) return;
    container.classList.add('graph-loading');
    loadJSXGraph()
      .then(() => {
        // 加载期间容器可能正好被流式渲染摘下来了，等放回页面后再画，否则尺寸是 0。
        if (!container.isConnected) {
          container.needsDraw = true;
          return;
        }
        container.classList.remove('graph-loading');
        drawBoard(container, spec);
      })
      .catch((error) => {
        container.classList.remove('graph-loading');
        container.textContent = '坐标图加载失败：' + error.message;
      });
  }

  renderer.afterRenderHooks.push({
    beforeReplace(root) {
      const existing = new Map();
      root.querySelectorAll('.graph[data-graph-key]').forEach((element) => {
        if (element.board || element.classList.contains('graph-loading')) {
          existing.set(element.dataset.graphKey, element);
        }
      });
      existing.forEach((element) => element.remove());
      return existing;
    },
    afterReplace(root, existing) {
      root.querySelectorAll('.graph[data-graph-key]').forEach((placeholder) => {
        const key = placeholder.dataset.graphKey;
        const kept = existing.get(key);
        if (kept) {
          placeholder.replaceWith(kept);
          existing.delete(key);
          if (kept.needsDraw) {
            kept.needsDraw = false;
            kept.classList.remove('graph-loading');
            drawBoard(kept, specs.get(key));
          }
        } else {
          renderGraph(placeholder);
        }
      });
      // 不再出现的图释放掉。
      existing.forEach((element) => {
        if (element.board) window.JXG.JSXGraph.freeBoard(element.board);
      });
    },
  });

  // 切换深色和浅色模式时重画所有图。
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    document.querySelectorAll('.graph[data-graph-key]').forEach((element) => {
      if (!element.board) return;
      window.JXG.JSXGraph.freeBoard(element.board);
      element.board = null;
      drawBoard(element, specs.get(element.dataset.graphKey));
    });
  });
})();
