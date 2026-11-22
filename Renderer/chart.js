/*
 * 图表组件：柱状图、折线图、饼图，用 Chart.js 绘制。点按数据可以看具体数值，点图例可以隐藏某组数据。
 * 图表没有需要保存的组件状态。
 */
(function () {
  'use strict';

  const components = window.StudyComponents;
  const core = window.StudyCore;
  const graph = window.StudyGraph;

  // 第八版：和坐标图用同一组颜色。
  const COLORS = graph.COLORS;

  /**
   * 柱顶直接写数值（第八版）：只有一组数据、柱子不超过 12 根时。其他情况仍然点按查看。
   */
  function valueLabels(unit, colors) {
    return {
      id: 'saValueLabels',
      afterDatasetsDraw(chart) {
        const meta = chart.getDatasetMeta(0);
        if (!meta || meta.hidden) return;
        const c = chart.ctx;
        c.save();
        c.font = '600 11px -apple-system, system-ui, sans-serif';
        c.fillStyle = colors.text;
        c.textAlign = 'center';
        meta.data.forEach((bar, i) => {
          const value = chart.data.datasets[0].data[i];
          if (value === null || value === undefined || !Number.isFinite(Number(value))) return;
          const negative = Number(value) < 0;
          c.textBaseline = negative ? 'top' : 'bottom';
          c.fillText(core.formatNumber(Number(value), 2), bar.x, bar.y + (negative ? 4 : -4));
        });
        c.restore();
      },
    };
  }

  function withAlpha(hex, alpha) {
    const n = parseInt(hex.slice(1), 16);
    return 'rgba(' + (n >> 16) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + alpha + ')';
  }

  function load() {
    if (window.Chart) return Promise.resolve();
    return components.loadAssets(['vendor/chartjs/chart.umd.min.js'], []);
  }

  function draw(container, spec) {
    const dark = components.isDark();
    const colors = graph.palette(dark);
    container.innerHTML = '';
    graph.addTitle(container, spec.title);

    const box = document.createElement('div');
    box.className = 'chart-box chart-' + spec.type;
    const canvas = document.createElement('canvas');
    box.appendChild(canvas);
    container.appendChild(box);

    const Chart = window.Chart;
    Chart.defaults.color = colors.axis;
    Chart.defaults.borderColor = colors.grid;
    Chart.defaults.font.family = '-apple-system, system-ui, sans-serif';

    const pie = spec.type === 'pie';
    const unit = spec.unit ? ' ' + spec.unit : '';
    const datasets = spec.datasets.map((d, i) => {
      const color = COLORS[i % COLORS.length];
      if (pie) {
        return {
          label: d.label,
          data: d.data,
          backgroundColor: spec.labels.map((_, k) => COLORS[k % COLORS.length]),
          borderColor: dark ? '#1c1c1e' : '#ffffff',
          borderWidth: 2,
        };
      }
      return {
        label: d.label || (spec.datasets.length > 1 ? '数据 ' + (i + 1) : ''),
        data: d.data,
        backgroundColor: spec.type === 'line' ? color : withAlpha(color, 0.8),
        borderColor: color,
        borderWidth: spec.type === 'line' ? 2.5 : 0,
        borderRadius: spec.type === 'bar' ? 4 : 0,
        pointRadius: spec.type === 'line' ? 3 : 0,
        tension: 0,
        spanGaps: true,
      };
    });

    const total = pie ? spec.datasets[0].data.reduce((s, v) => s + (v || 0), 0) : 0;
    const axisTitle = (text) => ({ display: !!text, text, color: colors.axis });

    const labelled = spec.type === 'bar' && spec.datasets.length === 1 && spec.labels.length <= 12;
    container.chart = new Chart(canvas, {
      type: spec.type,
      data: { labels: spec.labels, datasets },
      plugins: labelled ? [valueLabels(unit, colors)] : [],
      options: {
        responsive: true,
        maintainAspectRatio: false,
        // 打开"减弱动态效果"后柱子直接出现。
        animation: { duration: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : 300 },
        layout: { padding: { top: labelled ? 16 : 0 } },
        plugins: {
          legend: {
            display: pie || spec.datasets.length > 1,
            position: 'bottom',
            labels: { boxWidth: 12, boxHeight: 12 },
          },
          tooltip: {
            callbacks: {
              label(context) {
                const value = context.parsed && typeof context.parsed === 'object' ? context.parsed.y : context.parsed;
                const name = pie ? context.label : context.dataset.label;
                let text = (name ? name + '：' : '') + core.formatNumber(value, 4) + unit;
                if (pie && total > 0) text += '（' + core.formatNumber((100 * value) / total, 1) + '%）';
                return text;
              },
            },
          },
        },
        scales: pie ? {} : {
          x: { stacked: spec.stacked, title: axisTitle(spec.xLabel), grid: { display: false } },
          y: {
            stacked: spec.stacked,
            beginAtZero: spec.type === 'bar',
            title: axisTitle(spec.yLabel ? spec.yLabel + (spec.unit ? '（' + spec.unit + '）' : '') : ''),
          },
        },
      },
    });
  }

  components.register('chart', {
    load,
    draw,
    destroy(container) {
      if (container.chart) container.chart.destroy();
      container.chart = null;
    },
  });
})();
