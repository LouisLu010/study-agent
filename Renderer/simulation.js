/*
 * 模拟组件（见 docs/adr/0010）：物理计算在 core.js，这里负责 Canvas 动画和交互。
 * 每种模拟在 window.StudySimulation.kinds 里登记一个 render(canvas, model, t, view) 函数，B2、B3 的文件会继续往里加。
 * 组件状态：{ params: { 参数名: 值 } }，只保存和初始值不同的参数。
 */
(function () {
  'use strict';

  const components = window.StudyComponents;
  const core = window.StudyCore;

  const kinds = {};

  // ---------- 画图工具 ----------

  function palette() {
    const dark = components.isDark();
    return {
      text: dark ? '#f2f2f7' : '#1c1c1e',
      secondary: dark ? '#98989d' : '#6e6e73',
      grid: dark ? '#3a3a3c' : '#e5e5ea',
      line: dark ? '#8e8e93' : '#3a3a3c',
      // 和组件卡片的底色一样（renderer.css 的 --card），画布是透明的。
      fill: dark ? '#1c1c1e' : '#f6f6f8',
      accent: dark ? '#4d8eff' : '#2563eb',
      orange: '#ff9500',
      green: dark ? '#4ade80' : '#16a34a',
      red: dark ? '#ff6b6b' : '#e5383b',
      purple: '#af52de',
    };
  }

  /** 这一帧里第一次等比例映射，用来画比例尺。每帧开始时清空。 */
  let frameFit = null;

  /** 把世界坐标（米）映射到画布像素，保持等比例，四周留边距。 */
  function fit(bounds, rect, padding, equal) {
    const w = Math.max(bounds.xmax - bounds.xmin, 1e-6);
    const h = Math.max(bounds.ymax - bounds.ymin, 1e-6);
    let sx = (rect.w - 2 * padding) / w;
    let sy = (rect.h - 2 * padding) / h;
    if (equal !== false) sx = sy = Math.min(sx, sy);
    const ox = rect.x + (rect.w - sx * w) / 2;
    const oy = rect.y + (rect.h - sy * h) / 2;
    const result = {
      x: (x) => ox + (x - bounds.xmin) * sx,
      y: (y) => oy + (bounds.ymax - y) * sy,
      sx,
      sy,
    };
    if (equal !== false && !frameFit) frameFit = result;
    return result;
  }

  /** 好看的刻度：1、2、5 × 10ⁿ。 */
  function niceTicks(min, max, count) {
    const span = max - min;
    if (!(span > 0)) return [min];
    const raw = span / (count || 5);
    const mag = Math.pow(10, Math.floor(Math.log10(raw)));
    const step = [1, 2, 5, 10].map((m) => m * mag).find((s) => s >= raw) || raw;
    const ticks = [];
    for (let v = Math.ceil(min / step) * step; v <= max + step * 1e-6; v += step) ticks.push(Math.abs(v) < step * 1e-6 ? 0 : v);
    return ticks;
  }

  function arrow(c, x1, y1, x2, y2, color, width) {
    const len = Math.hypot(x2 - x1, y2 - y1);
    if (len < 2) return;
    const angle = Math.atan2(y2 - y1, x2 - x1);
    const head = Math.min(9, len * 0.4);
    c.strokeStyle = color;
    c.fillStyle = color;
    c.lineWidth = width || 2;
    c.beginPath();
    c.moveTo(x1, y1);
    c.lineTo(x2 - head * Math.cos(angle) * 0.6, y2 - head * Math.sin(angle) * 0.6);
    c.stroke();
    c.beginPath();
    c.moveTo(x2, y2);
    c.lineTo(x2 - head * Math.cos(angle - 0.45), y2 - head * Math.sin(angle - 0.45));
    c.lineTo(x2 - head * Math.cos(angle + 0.45), y2 - head * Math.sin(angle + 0.45));
    c.closePath();
    c.fill();
  }

  function text(c, value, x, y, color, align, size) {
    c.fillStyle = color;
    c.font = (size || 12) + 'px -apple-system, system-ui, sans-serif';
    c.textAlign = align || 'left';
    c.textBaseline = 'middle';
    c.fillText(value, x, y);
  }

  /** 一行图例：色块加文字，按文字实际宽度排开。 */
  function legend(c, x, y, items, colors) {
    c.font = '10px -apple-system, system-ui, sans-serif';
    items.forEach(([color, label]) => {
      c.fillStyle = color;
      c.fillRect(x, y - 1, 14, 3);
      text(c, label, x + 18, y, colors.secondary, 'left', 10);
      x += 18 + c.measureText(label).width + 12;
    });
  }

  // ---------- 第八版的画法：渐变、柔和阴影、斜线阴影、箭头标注 ----------

  /** #rrggbb 调亮（amount > 0）或调暗（amount < 0）。 */
  function shade(hex, amount) {
    const n = parseInt(String(hex).slice(1), 16);
    if (!Number.isFinite(n)) return hex;
    const f = (v) => Math.round(amount >= 0 ? v + (255 - v) * amount : v * (1 + amount));
    return 'rgb(' + f(n >> 16) + ',' + f((n >> 8) & 255) + ',' + f(n & 255) + ')';
  }

  function softShadow(c) {
    c.shadowColor = 'rgba(0, 0, 0, 0.22)';
    c.shadowBlur = 8;
    c.shadowOffsetY = 2;
  }

  function roundRect(c, x, y, w, h, r) {
    const radius = Math.max(0, Math.min(r, w / 2, h / 2));
    c.beginPath();
    c.moveTo(x + radius, y);
    c.arcTo(x + w, y, x + w, y + h, radius);
    c.arcTo(x + w, y + h, x, y + h, radius);
    c.arcTo(x, y + h, x, y, radius);
    c.arcTo(x, y, x + w, y, radius);
    c.closePath();
  }

  /** 带高光渐变和柔和阴影的小球（摆球、抛出的小球）。 */
  function ball(c, x, y, r, color) {
    c.save();
    softShadow(c);
    const g = c.createRadialGradient(x - r * 0.35, y - r * 0.4, r * 0.1, x, y, r);
    g.addColorStop(0, shade(color, 0.5));
    g.addColorStop(1, shade(color, -0.12));
    c.fillStyle = g;
    c.beginPath();
    c.arc(x, y, r, 0, Math.PI * 2);
    c.fill();
    c.restore();
  }

  /** 带上下渐变、圆角和柔和阴影的物块。 */
  function block(c, x, y, w, h, color) {
    c.save();
    softShadow(c);
    const g = c.createLinearGradient(x, y, x, y + h);
    g.addColorStop(0, shade(color, 0.3));
    g.addColorStop(1, shade(color, -0.1));
    c.fillStyle = g;
    roundRect(c, x, y, w, h, 4);
    c.fill();
    c.restore();
  }

  /** 地面（side = 1，斜线画在下面）或天花板（side = -1，画在上面）的斜线阴影。 */
  function hatch(c, x1, x2, y, side, color) {
    c.save();
    c.strokeStyle = color;
    c.lineWidth = 1;
    c.globalAlpha = 0.55;
    c.beginPath();
    for (let x = x1 + 6; x <= x2; x += 7) {
      c.moveTo(x, y);
      c.lineTo(x - 6, y + side * 6);
    }
    c.stroke();
    c.restore();
  }

  /** 竖直的墙：斜线画在左边。 */
  function wallHatch(c, x, y1, y2, color) {
    c.save();
    c.strokeStyle = color;
    c.lineWidth = 1;
    c.globalAlpha = 0.55;
    c.beginPath();
    for (let y = y1; y <= y2 - 6; y += 7) {
      c.moveTo(x, y);
      c.lineTo(x - 6, y + 6);
    }
    c.stroke();
    c.restore();
  }

  /** 箭头，箭头尖外面写上名字（v、mg、F）。 */
  function labeledArrow(c, x1, y1, x2, y2, color, width, label) {
    arrow(c, x1, y1, x2, y2, color, width);
    const len = Math.hypot(x2 - x1, y2 - y1);
    if (!label || len < 6) return;
    const ux = (x2 - x1) / len;
    const uy = (y2 - y1) / len;
    c.save();
    c.fillStyle = color;
    c.font = 'italic 600 12px -apple-system, system-ui, sans-serif';
    c.textAlign = 'center';
    c.textBaseline = 'middle';
    c.fillText(label, x2 + ux * 10, y2 + uy * 10);
    c.restore();
  }

  /** 淡淡的背景网格（画布像素，每 24 px 一格）。 */
  function backgroundGrid(c, rect, colors) {
    c.save();
    c.strokeStyle = colors.grid;
    c.globalAlpha = 0.5;
    c.lineWidth = 1;
    c.beginPath();
    for (let x = rect.x + 24; x < rect.x + rect.w; x += 24) {
      c.moveTo(Math.round(x) + 0.5, rect.y);
      c.lineTo(Math.round(x) + 0.5, rect.y + rect.h);
    }
    for (let y = rect.y + 24; y < rect.y + rect.h; y += 24) {
      c.moveTo(rect.x, Math.round(y) + 0.5);
      c.lineTo(rect.x + rect.w, Math.round(y) + 0.5);
    }
    c.stroke();
    c.restore();
  }

  function dashed(c, points, color) {
    c.save();
    c.setLineDash([4, 4]);
    c.strokeStyle = color;
    c.lineWidth = 1;
    c.beginPath();
    points.forEach(([x, y], i) => (i ? c.lineTo(x, y) : c.moveTo(x, y)));
    c.stroke();
    c.restore();
  }

  /**
   * 小坐标图：横轴是时间。series = [{ fn(t), color, label }]，已经走过的部分画实线，没走到的画浅色。
   */
  function plot(c, rect, opts) {
    const colors = opts.colors;
    const [ymin, ymax] = opts.yRange[0] === opts.yRange[1] ? [opts.yRange[0] - 1, opts.yRange[1] + 1] : opts.yRange;
    const pad = (ymax - ymin) * 0.1;
    const view = fit({ xmin: 0, xmax: opts.tMax, ymin: ymin - pad, ymax: ymax + pad }, rect, 0, false);
    c.save();
    c.fillStyle = colors.fill;
    c.fillRect(rect.x, rect.y, rect.w, rect.h);
    c.beginPath();
    c.rect(rect.x, rect.y, rect.w, rect.h);
    c.clip();
    // 零线
    if (ymin - pad < 0 && ymax + pad > 0) {
      c.strokeStyle = colors.line;
      c.lineWidth = 1;
      c.beginPath();
      c.moveTo(rect.x, view.y(0));
      c.lineTo(rect.x + rect.w, view.y(0));
      c.stroke();
    }
    opts.series.forEach((s) => {
      const steps = 160;
      [[0, opts.tMax, 0.25], [0, Math.min(opts.tNow, opts.tMax), 1]].forEach(([from, to, alpha]) => {
        if (to <= from) return;
        c.globalAlpha = alpha;
        c.strokeStyle = s.color;
        c.lineWidth = 2;
        c.beginPath();
        for (let i = 0; i <= steps; i++) {
          const t = from + ((to - from) * i) / steps;
          const y = view.y(s.fn(t));
          i ? c.lineTo(view.x(t), y) : c.moveTo(view.x(t), y);
        }
        c.stroke();
      });
      c.globalAlpha = 1;
      const tn = Math.min(opts.tNow, opts.tMax);
      c.fillStyle = s.color;
      c.beginPath();
      c.arc(view.x(tn), view.y(s.fn(tn)), 3.5, 0, Math.PI * 2);
      c.fill();
    });
    c.restore();
    text(c, opts.label, rect.x + 6, rect.y + 10, colors.secondary, 'left', 11);
    text(c, 't', rect.x + rect.w - 6, rect.y + rect.h - 8, colors.secondary, 'right', 11);
  }

  // ---------- 各种模拟的画法 ----------

  // view：{ colors, rect, values, trail, hit }。trail 为 true 时画淡出的残影（打开"减弱动态效果"后为 false）；
  // hit(x, y, r, title, rows) 登记一个可以点的物体，点一下显示 rows() 返回的读数。

  /** 残影：往前取几个时刻，越早越淡。 */
  function trail(view, steps, dt, draw) {
    if (!view.trail) return;
    for (let k = steps; k >= 1; k--) draw(k * dt, 0.28 * (1 - k / (steps + 1)));
  }

  kinds.projectile = (c, model, t, view) => {
    const { colors, rect, values } = view;
    const b = model.bounds;
    const bounds = { xmin: -b.xmax * 0.05, xmax: b.xmax * 1.08, ymin: -b.ymax * 0.08, ymax: b.ymax * 1.15 };
    const v = fit(bounds, rect, 24);
    // 地面、斜线阴影和刻度
    c.strokeStyle = colors.line;
    c.lineWidth = 1.5;
    c.beginPath();
    c.moveTo(rect.x, v.y(0));
    c.lineTo(rect.x + rect.w, v.y(0));
    c.stroke();
    hatch(c, rect.x, rect.x + rect.w, v.y(0), 1, colors.line);
    c.strokeStyle = colors.line;
    niceTicks(0, b.xmax, 5).forEach((x) => {
      c.beginPath();
      c.moveTo(v.x(x), v.y(0));
      c.lineTo(v.x(x), v.y(0) - 4);
      c.stroke();
      text(c, core.formatNumber(x, 1), v.x(x), v.y(0) + 15, colors.secondary, 'center', 10);
    });
    if (values.h > 0) {
      block(c, v.x(0) - 14, v.y(values.h), 14, v.y(0) - v.y(values.h), colors.grid);
      text(c, core.formatNumber(values.h, 1) + ' m', v.x(0) - 18, v.y(values.h / 2), colors.secondary, 'right', 10);
    }
    // 完整轨迹（虚线）和走过的轨迹（实线）
    const full = model.path(120);
    dashed(c, full.map((p) => [v.x(p.x), v.y(p.y)]), colors.secondary);
    const s = model.at(t);
    c.strokeStyle = colors.accent;
    c.lineWidth = 2.5;
    c.beginPath();
    const steps = 80;
    for (let i = 0; i <= steps; i++) {
      const p = model.at((s.t * i) / steps);
      i ? c.lineTo(v.x(p.x), v.y(p.y)) : c.moveTo(v.x(p.x), v.y(p.y));
    }
    c.stroke();
    // 残影
    trail(view, 6, model.duration / 50, (back, alpha) => {
      if (s.t - back < 0) return;
      const p = model.at(s.t - back);
      c.save();
      c.globalAlpha = alpha;
      c.fillStyle = colors.accent;
      c.beginPath();
      c.arc(v.x(p.x), v.y(p.y), 7, 0, Math.PI * 2);
      c.fill();
      c.restore();
    });
    // 速度和它的两个分量
    const k = 0.25 * Math.min(rect.w, rect.h) / Math.max(values.v0, 1);
    const px = v.x(s.x);
    const py = v.y(s.y);
    labeledArrow(c, px, py, px + s.vx * k, py, colors.green, 1.5, 'vₓ');
    labeledArrow(c, px, py, px, py - s.vy * k, colors.orange, 1.5, 'vᵧ');
    labeledArrow(c, px, py, px + s.vx * k, py - s.vy * k, colors.red, 2, 'v');
    ball(c, px, py, 8, colors.accent);
    legend(c, rect.x + 8, rect.y + 12, [[colors.red, '速度'], [colors.green, '水平分量'], [colors.orange, '竖直分量']], colors);
    view.hit(px, py, 14, '小球', () => [
      core.reading('水平位移 x', s.x, 'm'), core.reading('高度 y', s.y, 'm'),
      core.reading('速度 v', Math.hypot(s.vx, s.vy), 'm/s'),
      core.reading('水平分量 vₓ', s.vx, 'm/s'), core.reading('竖直分量 vᵧ', s.vy, 'm/s'),
    ]);
  };

  kinds.pendulum = (c, model, t, view) => {
    const { colors, rect, values } = view;
    const v = fit(model.bounds, rect, 18);
    const s = model.at(t);
    const pivot = [v.x(0), v.y(0)];
    // 天花板和斜线阴影
    c.strokeStyle = colors.line;
    c.lineWidth = 2;
    c.beginPath();
    c.moveTo(pivot[0] - 40, pivot[1]);
    c.lineTo(pivot[0] + 40, pivot[1]);
    c.stroke();
    hatch(c, pivot[0] - 40, pivot[0] + 40, pivot[1], -1, colors.line);
    // 竖直参考线和摆动范围
    dashed(c, [pivot, [v.x(0), v.y(-values.L)]], colors.secondary);
    const a0 = values.theta0 * Math.PI / 180;
    c.save();
    c.setLineDash([3, 4]);
    c.strokeStyle = colors.grid;
    c.beginPath();
    c.arc(pivot[0], pivot[1], values.L * v.sx, Math.PI / 2 - a0, Math.PI / 2 + a0);
    c.stroke();
    c.restore();
    // 残影
    const r = 11;
    trail(view, 6, model.cycle / 40, (back, alpha) => {
      const p = model.at(t - back);
      c.save();
      c.globalAlpha = alpha;
      c.fillStyle = colors.accent;
      c.beginPath();
      c.arc(v.x(p.x), v.y(p.y), r, 0, Math.PI * 2);
      c.fill();
      c.restore();
    });
    // 摆线和摆球
    const bob = [v.x(s.x), v.y(s.y)];
    c.strokeStyle = colors.text;
    c.lineWidth = 1.5;
    c.beginPath();
    c.moveTo(pivot[0], pivot[1]);
    c.lineTo(bob[0], bob[1]);
    c.stroke();
    // 重力和速度
    labeledArrow(c, bob[0], bob[1], bob[0], bob[1] + 30, colors.green, 1.5, 'mg');
    const speed = s.omega * values.L;
    const k = 22 / Math.max(Math.sqrt(2 * values.g * values.L * (1 - Math.cos(a0))), 0.01);
    labeledArrow(c, bob[0], bob[1], bob[0] + speed * Math.cos(s.theta) * k, bob[1] - speed * Math.sin(s.theta) * k, colors.red, 2, 'v');
    ball(c, bob[0], bob[1], r, colors.accent);
    text(c, 'θ = ' + core.formatNumber(s.theta * 180 / Math.PI, 1) + '°', pivot[0] + 8, pivot[1] + 16, colors.secondary, 'left', 11);
    view.hit(bob[0], bob[1], r + 6, '摆球', () => [
      core.reading('角度 θ', s.theta * 180 / Math.PI, '°', 1),
      core.reading('速度 v', Math.abs(speed), 'm/s'),
      core.reading('离最低点的高度', values.L * (1 - Math.cos(s.theta)), 'm', 3),
    ]);
  };

  kinds.spring = (c, model, t, view) => {
    const { colors, rect, values } = view;
    const top = { x: rect.x, y: rect.y, w: rect.w, h: rect.h * 0.5 };
    const v = fit(model.bounds, top, 16);
    const s = model.at(t);
    const groundY = v.y(-0.08);
    const wallX = v.x(-0.55);
    // 地面、墙和斜线阴影
    c.strokeStyle = colors.line;
    c.lineWidth = 2;
    c.beginPath();
    c.moveTo(wallX, v.y(0.12));
    c.lineTo(wallX, groundY);
    c.lineTo(top.x + top.w - 10, groundY);
    c.stroke();
    hatch(c, wallX, top.x + top.w - 10, groundY, 1, colors.line);
    wallHatch(c, wallX, v.y(0.12), groundY, colors.line);
    // 平衡位置
    dashed(c, [[v.x(0), v.y(0.13)], [v.x(0), groundY]], colors.secondary);
    text(c, 'O', v.x(0), groundY + 14, colors.secondary, 'center', 10);
    // 残影
    const blockW = 0.14 * v.sx;
    trail(view, 5, model.cycle / 40, (back, alpha) => {
      const p = model.at(t - back);
      c.save();
      c.globalAlpha = alpha;
      c.fillStyle = colors.accent;
      roundRect(c, v.x(p.x) - blockW / 2, groundY - blockW, blockW, blockW, 4);
      c.fill();
      c.restore();
    });
    // 弹簧（锯齿线）和物块
    const blockX = v.x(s.x) - blockW / 2;
    const midY = v.y(0);
    const coils = 12;
    c.strokeStyle = colors.text;
    c.lineWidth = 1.5;
    c.beginPath();
    c.moveTo(wallX, midY);
    const end = blockX;
    for (let i = 1; i < coils * 2; i++) {
      const x = wallX + ((end - wallX) * i) / (coils * 2);
      c.lineTo(x, midY + (i % 2 ? -8 : 8));
    }
    c.lineTo(end, midY);
    c.stroke();
    block(c, blockX, groundY - blockW, blockW, blockW, colors.accent);
    text(c, core.formatNumber(values.m, 1) + ' kg', blockX + blockW / 2, groundY - blockW / 2, '#fff', 'center', 10);
    // 回复力
    labeledArrow(c, blockX + blockW / 2, groundY - blockW - 8, blockX + blockW / 2 - s.x * 120, groundY - blockW - 8, colors.red, 2, 'F');
    view.hit(blockX + blockW / 2, groundY - blockW / 2, blockW / 2 + 6, '物块', () => [
      core.reading('位移 x', s.x, 'm', 3), core.reading('速度 v', s.v, 'm/s'),
      core.reading('加速度 a', s.a, 'm/s²'), core.reading('回复力 F = −kx', -values.k * s.x, 'N'),
    ]);
    // x-t 图，显示最近两个周期
    const T = model.period;
    const windowStart = Math.max(0, t - 2 * T);
    plot(c, { x: rect.x + 8, y: rect.y + rect.h * 0.55, w: rect.w - 16, h: rect.h * 0.42 }, {
      colors,
      tMax: 2 * T,
      tNow: t - windowStart,
      yRange: [-values.A, values.A],
      label: '位移 x 随时间变化',
      series: [{ fn: (tt) => model.at(tt + windowStart).x, color: colors.accent }],
    });
  };

  kinds.uniform_acceleration = (c, model, t, view) => {
    const { colors, rect, values } = view;
    const s = model.at(t);
    // 上方：轨道和小车
    const top = { x: rect.x, y: rect.y, w: rect.w, h: rect.h * 0.34 };
    // 用 model.bounds（框架换成了当前镜头），拖动初速度时轨道比例不变。
    const { xmin, xmax } = model.bounds;
    const span = Math.max(xmax - xmin, 1);
    const v = fit({ xmin: xmin - span * 0.08, xmax: xmax + span * 0.08, ymin: 0, ymax: 1 }, top, 12, false);
    const trackY = top.y + top.h - 14;
    c.strokeStyle = colors.line;
    c.lineWidth = 1.5;
    c.beginPath();
    c.moveTo(top.x + 8, trackY);
    c.lineTo(top.x + top.w - 8, trackY);
    c.stroke();
    hatch(c, top.x + 8, top.x + top.w - 8, trackY, 1, colors.line);
    c.strokeStyle = colors.line;
    niceTicks(xmin, xmax, 5).forEach((x) => {
      c.beginPath();
      c.moveTo(v.x(x), trackY);
      c.lineTo(v.x(x), trackY - 4);
      c.stroke();
      text(c, core.formatNumber(x, 1), v.x(x), trackY + 12, colors.secondary, 'center', 9);
    });
    const carX = v.x(s.x);
    block(c, carX - 16, trackY - 22, 32, 15, colors.accent);
    c.fillStyle = colors.text;
    [carX - 9, carX + 9].forEach((wx) => { c.beginPath(); c.arc(wx, trackY - 4, 4, 0, Math.PI * 2); c.fill(); });
    const k = 45 / Math.max(Math.abs(model.vRange[0]), Math.abs(model.vRange[1]), 0.1);
    labeledArrow(c, carX, trackY - 30, carX + s.v * k, trackY - 30, colors.red, 2, 'v');
    view.hit(carX, trackY - 14, 22, '小车', () => [
      core.reading('时间 t', s.t, 's'), core.reading('位移 x', s.x, 'm'), core.reading('速度 v', s.v, 'm/s'),
      core.reading('加速度 a', values.a, 'm/s²'),
    ]);
    // 下方：v-t 图和 x-t 图
    const gap = 8;
    const plotH = rect.h * 0.6;
    const plotW = (rect.w - 16 - gap) / 2;
    const y = rect.y + rect.h * 0.38;
    plot(c, { x: rect.x + 8, y, w: plotW, h: plotH }, {
      colors, tMax: values.T, tNow: s.t, yRange: model.vRange, label: 'v-t',
      series: [{ fn: (tt) => model.at(tt).v, color: colors.red }],
    });
    plot(c, { x: rect.x + 8 + plotW + gap, y, w: plotW, h: plotH }, {
      colors, tMax: values.T, tNow: s.t, yRange: model.xRange, label: 'x-t',
      series: [{ fn: (tt) => model.at(tt).x, color: colors.accent }],
    });
  };

  kinds.collision = (c, model, t, view) => {
    const { colors, rect, values } = view;
    const v = fit(model.bounds, rect, 12, false);
    const s = model.at(t);
    const trackY = rect.y + rect.h * 0.62;
    c.strokeStyle = colors.line;
    c.lineWidth = 1.5;
    c.beginPath();
    c.moveTo(rect.x + 4, trackY);
    c.lineTo(rect.x + rect.w - 4, trackY);
    c.stroke();
    hatch(c, rect.x + 4, rect.x + rect.w - 4, trackY, 1, colors.line);
    const blockW = model.width * v.sx;
    const size = (m) => blockW * (0.55 + 0.45 * Math.cbrt(m / 10));
    const maxV = Math.max(Math.abs(values.v1), Math.abs(values.v2), 1);
    [[s.x1, values.m1, s.v1, colors.accent, '1', '₁'], [s.x2, values.m2, s.v2, colors.orange, '2', '₂']].forEach(([x, m, vel, color, name, sub]) => {
      const h = size(m);
      const left = v.x(x) - blockW / 2;
      block(c, left, trackY - h, blockW, h, color);
      text(c, 'm' + name + ' = ' + core.formatNumber(m, 1) + ' kg', left + blockW / 2, trackY + 18, colors.secondary, 'center', 10);
      labeledArrow(c, left + blockW / 2, trackY - h - 14, left + blockW / 2 + (vel / maxV) * 50, trackY - h - 14, color, 2, 'v' + sub);
      text(c, core.formatNumber(vel, 2) + ' m/s', left + blockW / 2, trackY - h - 30, colors.text, 'center', 10);
      view.hit(left + blockW / 2, trackY - h / 2, Math.max(blockW, h) / 2 + 6, '物块 ' + name, () => [
        core.reading('质量 m', m, 'kg', 1), core.reading('速度 v', vel, 'm/s'),
        core.reading('动量 p = mv', m * vel, 'kg·m/s'), core.reading('动能', 0.5 * m * vel * vel, 'J'),
      ]);
    });
    const P = values.m1 * s.v1 + values.m2 * s.v2;
    const E = 0.5 * values.m1 * s.v1 * s.v1 + 0.5 * values.m2 * s.v2 * s.v2;
    text(c, (s.after ? '碰后' : '碰前') + '  总动量 ' + core.formatNumber(P, 2) + ' kg·m/s   总动能 ' + core.formatNumber(E, 2) + ' J',
      rect.x + 8, rect.y + 12, colors.secondary, 'left', 11);
  };

  // ---------- 组件框架 ----------

  const SPEEDS = [0.5, 1, 2];
  /** 画比例尺的模拟：画面是等比例的真实尺寸。抛体运动有自己的刻度，不画。 */
  const RULER = new Set(['pendulum', 'electric_deflection', 'magnetic_circle', 'mass_spectrometer']);
  const CAMERA_MS = 400;

  function reducedMotion() {
    return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  }

  function lerpBounds(a, b, k) {
    const e = (1 - Math.cos(Math.PI * k)) / 2;
    const mix = (x, y) => x + (y - x) * e;
    return { xmin: mix(a.xmin, b.xmin), xmax: mix(a.xmax, b.xmax), ymin: mix(a.ymin, b.ymin), ymax: mix(a.ymax, b.ymax) };
  }

  function ruler(c, rect, colors) {
    if (!frameFit) return;
    const bar = core.scaleBar(frameFit.sx, Math.min(120, rect.w * 0.28));
    if (!bar || bar.px < 12) return;
    const x2 = rect.x + rect.w - 14;
    const x1 = x2 - bar.px;
    const y = rect.y + 18;
    c.save();
    c.strokeStyle = colors.secondary;
    c.lineWidth = 1.5;
    c.beginPath();
    c.moveTo(x1, y - 4);
    c.lineTo(x1, y);
    c.lineTo(x2, y);
    c.lineTo(x2, y - 4);
    c.stroke();
    c.restore();
    text(c, bar.label, (x1 + x2) / 2, y + 10, colors.secondary, 'center', 10);
  }

  function el(tag, className, content) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (content !== undefined) element.textContent = content;
    return element;
  }

  function draw(container, spec, ctx) {
    const render = kinds[spec.kind];
    if (!render) throw new Error('这个版本还不支持' + spec.label);

    const values = Object.assign({}, spec.defaults);
    const saved = ctx.state && ctx.state.params;
    if (saved && typeof saved === 'object') {
      spec.params.forEach((p) => {
        const value = Number(saved[p.name]);
        if (Number.isFinite(value)) values[p.name] = Math.min(p.max, Math.max(p.min, value));
      });
    }

    container.innerHTML = '';
    container.classList.add('simulation');
    container.appendChild(el('div', 'graph-title', spec.title || spec.label));
    const stage = el('div', 'simulation-stage');
    const canvas = document.createElement('canvas');
    stage.appendChild(canvas);
    container.appendChild(stage);

    // 播放控制
    const bar = el('div', 'simulation-bar');
    const playButton = el('button', 'sa-button is-primary', '暂停');
    const replayButton = el('button', 'sa-button', '重播');
    // 播放速度：分段选择。
    const speedGroup = el('div', 'sa-segmented');
    speedGroup.setAttribute('role', 'group');
    speedGroup.setAttribute('aria-label', '播放速度');
    const speedButtons = SPEEDS.map((s) => {
      const button = el('button', s === 1 ? 'is-selected' : '', s + '×');
      button.dataset.speed = String(s);
      speedGroup.appendChild(button);
      return button;
    });
    const clock = el('span', 'simulation-clock');
    bar.append(playButton, replayButton, speedGroup, clock);
    container.appendChild(bar);

    // 时间轴（第八版）：拖动就暂停并跳到那个时刻，松手停在那里，点播放继续。周期运动拖动一个周期。
    const timeline = document.createElement('input');
    timeline.type = 'range';
    timeline.className = 'simulation-timeline';
    timeline.min = '0';
    timeline.max = '1000';
    timeline.step = '1';
    timeline.value = '0';
    timeline.setAttribute('aria-label', '时间轴');
    container.appendChild(timeline);

    // 画面下方一行实时数值小标签，和力学模拟的能量柱
    const chips = el('div', 'simulation-chips');
    const energy = el('div', 'simulation-energy');
    container.append(chips, energy);

    // 点画面里的物体显示的读数
    const pop = el('div', 'simulation-pop');
    pop.hidden = true;
    stage.appendChild(pop);

    // 结果和参数
    const panel = el('div', 'graph-controls');
    const results = el('div', 'graph-readouts');
    panel.append(results);
    const sliders = {};
    const labels = {};
    spec.params.forEach((p) => {
      const row = el('label', 'graph-param');
      const name = el('span', 'graph-param-name', p.label);
      const input = document.createElement('input');
      input.type = 'range';
      input.min = String(p.min);
      input.max = String(p.max);
      input.step = String(p.step);
      input.value = String(values[p.name]);
      const value = el('span', 'graph-param-value');
      row.append(name, input, value);
      panel.appendChild(row);
      sliders[p.name] = input;
      labels[p.name] = value;
      input.addEventListener('pointerdown', beginDrag);
      input.addEventListener('touchstart', beginDrag, { passive: true });
      input.addEventListener('input', () => {
        beginDrag();
        values[p.name] = Number(input.value);
        rebuild();
      });
      input.addEventListener('change', () => {
        save();
        endDrag();
      });
      input.addEventListener('pointerup', endDrag);
      input.addEventListener('touchend', endDrag);
      input.addEventListener('touchcancel', endDrag);
    });
    const reset = el('button', 'sa-button graph-reset', '复位');
    panel.appendChild(reset);
    container.appendChild(panel);

    let model = null;
    let time = 0;
    let playing = true;
    let speed = 1;
    let visible = false;
    let frame = 0;
    let last = 0;
    // 镜头：camera 是要停下的范围，anim 是正在过去的动画。拖滑块期间 dragging 为 true，镜头不动；
    // ghost 是开始拖动前的样子，拖动时画成淡色虚影。
    let camera = null;
    let anim = null;
    let cameraFrame = 0;
    let dragging = false;
    let ghost = null;
    // 时间轴：正在拖动时不跟着播放更新。
    let scrubbing = false;
    // 这一帧画面里可以点的物体：{ x, y, r, title, rows }
    let hits = [];

    function beginDrag() {
      if (dragging) return;
      dragging = true;
      ghost = model ? { model, values: Object.assign({}, values) } : null;
    }

    function endDrag() {
      if (!dragging) return;
      dragging = false;
      ghost = null;
      updateCamera();
      paint();
    }

    function updateCamera() {
      if (!model || !model.bounds) return;
      const from = cameraNow(performance.now());
      const next = core.simulationCamera(from, model.bounds, dragging);
      if (next.animate && from && !reducedMotion()) {
        anim = { from, to: next.bounds, start: performance.now() };
        animateCamera();
      } else {
        anim = null;
      }
      camera = next.bounds;
    }

    function cameraNow(now) {
      if (!anim) return camera;
      const k = (now - anim.start) / CAMERA_MS;
      if (k >= 1) {
        anim = null;
        return camera;
      }
      return lerpBounds(anim.from, anim.to, Math.max(0, k));
    }

    // 暂停时动画循环不跑，镜头动画自己请求帧。
    function animateCamera() {
      if (cameraFrame) return;
      const step = () => {
        cameraFrame = 0;
        if (!anim) return;
        if (!(playing && visible)) paint();
        cameraFrame = requestAnimationFrame(step);
      };
      cameraFrame = requestAnimationFrame(step);
    }

    /** 时间轴的范围：有限时长的运动是整个过程，周期运动是一个周期。都没有时（电路）不显示。 */
    function timelineSpan() {
      if (!model) return 0;
      if (Number.isFinite(model.duration)) return model.duration;
      return model.cycle > 0 ? model.cycle : 0;
    }

    timeline.addEventListener('pointerdown', () => { scrubbing = true; });
    timeline.addEventListener('touchstart', () => { scrubbing = true; }, { passive: true });
    timeline.addEventListener('input', () => {
      const span = timelineSpan();
      if (!span) return;
      scrubbing = true;
      playing = false;
      hidePop();
      time = (Number(timeline.value) / 1000) * span;
      paint();
    });
    const endScrub = () => { scrubbing = false; };
    timeline.addEventListener('change', endScrub);
    timeline.addEventListener('pointerup', endScrub);
    timeline.addEventListener('touchend', endScrub);
    timeline.addEventListener('touchcancel', endScrub);

    function updateTimeline() {
      const span = timelineSpan();
      timeline.hidden = !span;
      if (!span || scrubbing) return;
      const local = Number.isFinite(model.duration) ? Math.min(time, span) : ((time % span) + span) % span;
      timeline.value = String(Math.round((local / span) * 1000));
    }

    /** 实时数值小标签。数量不变时只改文字，不每帧重建。 */
    function updateChips(items) {
      if (chips.childElementCount !== items.length) {
        chips.innerHTML = '';
        items.forEach(() => {
          const chip = el('span', 'simulation-chip');
          chip.append(el('span', 'simulation-chip-label'), el('span', 'simulation-chip-value'));
          chips.appendChild(chip);
        });
      }
      items.forEach((r, i) => {
        const chip = chips.children[i];
        chip.firstChild.textContent = r.label;
        chip.lastChild.textContent = Number.isNaN(r.value) ? '' : core.formatNumber(r.value, r.decimals) + (r.unit ? ' ' + r.unit : '');
      });
      chips.hidden = !items.length;
    }

    /** 能量柱：动能、势能、总能量，长度按总能量算。没有能量的模拟不显示。 */
    function updateEnergy() {
      const e = model && model.energy ? model.energy(time) : null;
      energy.hidden = !e;
      if (!e) return;
      const signature = e.bars.map((b) => b.label).join('|') + '|' + e.note;
      if (energy.dataset.signature !== signature) {
        energy.dataset.signature = signature;
        energy.innerHTML = '';
        e.bars.forEach((b) => {
          const row = el('div', 'simulation-energy-row');
          const track = el('span', 'simulation-energy-track');
          track.appendChild(el('span', 'simulation-energy-fill energy-' + b.key));
          row.append(el('span', 'simulation-energy-label', b.label), track, el('span', 'simulation-energy-value'));
          energy.appendChild(row);
        });
        if (e.note) energy.appendChild(el('div', 'simulation-energy-note', e.note));
      }
      e.bars.forEach((b, i) => {
        const row = energy.children[i];
        const fraction = Math.max(0, Math.min(1, b.value / e.max));
        row.children[1].firstChild.style.width = (fraction * 100).toFixed(1) + '%';
        row.children[2].textContent = core.formatNumber(b.value, 2) + ' ' + e.unit;
      });
    }

    function hidePop() {
      pop.hidden = true;
    }

    /** 点一下画面里的物体：暂停，在物体旁边显示它此刻的读数。点空白处收起。 */
    function showPop(target) {
      pop.innerHTML = '';
      pop.appendChild(el('div', 'simulation-pop-title', target.title));
      target.rows().forEach((r) => {
        const row = el('div');
        row.append(el('span', '', r.label), el('span', 'graph-readout-value',
          Number.isNaN(r.value) ? '' : core.formatNumber(r.value, r.decimals) + (r.unit ? ' ' + r.unit : '')));
        pop.appendChild(row);
      });
      pop.hidden = false;
      const w = stage.clientWidth;
      const h = stage.clientHeight;
      const left = Math.min(Math.max(8, target.x + target.r + 6), Math.max(8, w - pop.offsetWidth - 8));
      const top = Math.min(Math.max(8, target.y - pop.offsetHeight / 2), Math.max(8, h - pop.offsetHeight - 8));
      pop.style.left = left + 'px';
      pop.style.top = top + 'px';
    }

    canvas.addEventListener('click', (event) => {
      const box = canvas.getBoundingClientRect();
      const x = event.clientX - box.left;
      const y = event.clientY - box.top;
      let best = null;
      hits.forEach((h) => {
        const d = Math.hypot(h.x - x, h.y - y);
        if (d <= h.r + 8 && (!best || d < best.d)) best = { d, target: h };
      });
      if (!best) {
        hidePop();
        return;
      }
      playing = false;
      paint();
      showPop(best.target);
    });

    function readoutRows(target, items) {
      target.innerHTML = '';
      items.forEach((r) => {
        const row = el('div');
        row.append(el('span', '', r.label), el('span', 'graph-readout-value',
          Number.isNaN(r.value) ? '' : core.formatNumber(r.value, r.decimals) + (r.unit ? ' ' + r.unit : '')));
        target.appendChild(row);
      });
    }

    function isDefault() {
      return spec.params.every((p) => Math.abs(values[p.name] - spec.defaults[p.name]) < p.step / 2);
    }

    function save() {
      if (isDefault()) {
        ctx.setState(null);
        return;
      }
      const changed = {};
      spec.params.forEach((p) => {
        if (Math.abs(values[p.name] - spec.defaults[p.name]) >= p.step / 2) changed[p.name] = values[p.name];
      });
      ctx.setState({ params: changed });
    }

    function rebuild() {
      try {
        model = core.buildSimulation(spec.kind, values);
      } catch (error) {
        model = null;
      }
      spec.params.forEach((p) => {
        labels[p.name].textContent = core.formatNumber(values[p.name], core.decimalsForStep(p.step)) + (p.unit ? ' ' + p.unit : '');
      });
      reset.hidden = isDefault();
      if (!dragging) updateCamera();
      if (model) readoutRows(results, model.results);
      hidePop();
      time = 0;
      playing = true;
      paint();
      loop();
    }

    function paint() {
      const width = stage.clientWidth;
      const height = stage.clientHeight;
      if (!width || !height) return;
      const dpr = window.devicePixelRatio || 1;
      if (canvas.width !== Math.round(width * dpr) || canvas.height !== Math.round(height * dpr)) {
        canvas.width = Math.round(width * dpr);
        canvas.height = Math.round(height * dpr);
      }
      const c = canvas.getContext('2d');
      c.setTransform(dpr, 0, 0, dpr, 0, 0);
      c.clearRect(0, 0, width, height);
      if (!model || !(model.duration > 0)) {
        text(c, '这组参数下没有运动', width / 2, height / 2, palette().secondary, 'center', 13);
        hits = [];
        updateChips([]);
        energy.hidden = true;
        timeline.hidden = true;
        return;
      }
      const colors = palette();
      const rect = { x: 0, y: 0, w: width, h: height };
      const bounds = cameraNow(performance.now()) || model.bounds;
      // 渲染函数都按 model.bounds 定镜头，这里换成当前镜头的范围，其余照旧。
      const shown = (m) => (m.bounds ? Object.assign(Object.create(m), { bounds }) : m);
      backgroundGrid(c, rect, colors);
      frameFit = null;
      const ignore = () => {};
      if (ghost && ghost.model && ghost.model.duration > 0) {
        // 虚影：开始拖动前的样子，画在 t = 0，不画文字。
        c.save();
        c.globalAlpha = 0.22;
        c.fillText = () => {};
        try {
          render(c, shown(ghost.model), 0, { colors, rect, values: ghost.values, trail: false, hit: ignore });
        } catch (error) { /* 虚影画不出来就不画 */ }
        delete c.fillText;
        c.restore();
      }
      frameFit = null;
      const nextHits = [];
      render(c, shown(model), time, {
        colors, rect, values,
        // 打开"减弱动态效果"时不画残影。
        trail: !reducedMotion() && time > 0,
        hit: (x, y, r, title, rows) => nextHits.push({ x, y, r, title, rows }),
      });
      hits = nextHits;
      if (RULER.has(spec.kind)) ruler(c, rect, colors);
      updateChips(model.live(time));
      updateEnergy();
      updateTimeline();
      clock.textContent = model.clock ? model.clock(time) : 't = ' + core.formatNumber(time, 2) + ' s';
      playButton.textContent = playing ? '暂停' : (Number.isFinite(model.duration) && time >= model.duration ? '播放' : '继续');
    }

    function tick(now) {
      frame = 0;
      if (!playing || !visible || !model) return;
      const dt = last ? Math.min(0.05, (now - last) / 1000) : 0;
      last = now;
      time += dt * speed;
      if (Number.isFinite(model.duration) && time >= model.duration) {
        time = model.duration;
        playing = false;
      }
      paint();
      if (playing) frame = requestAnimationFrame(tick);
    }

    function loop() {
      if (frame || !playing || !visible) return;
      last = 0;
      frame = requestAnimationFrame(tick);
    }

    playButton.addEventListener('click', () => {
      if (!model) return;
      hidePop();
      if (playing) {
        playing = false;
      } else {
        if (Number.isFinite(model.duration) && time >= model.duration) time = 0;
        playing = true;
        loop();
      }
      paint();
    });
    replayButton.addEventListener('click', () => {
      hidePop();
      time = 0;
      playing = true;
      paint();
      loop();
    });
    speedButtons.forEach((button) => {
      button.addEventListener('click', () => {
        speed = Number(button.dataset.speed);
        speedButtons.forEach((b) => b.classList.toggle('is-selected', b === button));
      });
    });
    reset.addEventListener('click', () => {
      Object.assign(values, spec.defaults);
      spec.params.forEach((p) => { sliders[p.name].value = String(values[p.name]); });
      ctx.setState(null);
      // 复位：镜头直接回到默认参数的范围。
      camera = null;
      anim = null;
      rebuild();
    });

    // 只在出现在屏幕上时播放，滚出屏幕就停下来，省电。
    const observer = new IntersectionObserver((entries) => {
      visible = entries.some((e) => e.isIntersecting);
      if (visible) loop();
    });
    observer.observe(stage);
    const resize = new ResizeObserver(() => paint());
    resize.observe(stage);

    container.simulation = {
      stop() {
        if (frame) cancelAnimationFrame(frame);
        if (cameraFrame) cancelAnimationFrame(cameraFrame);
        frame = 0;
        cameraFrame = 0;
        observer.disconnect();
        resize.disconnect();
      },
    };
    rebuild();
  }

  components.register('simulation', {
    draw,
    destroy(container) {
      if (container.simulation) container.simulation.stop();
      container.simulation = null;
    },
  });

  window.StudySimulation = { kinds, fit, niceTicks, arrow, text, dashed, plot, palette, legend };
})();
