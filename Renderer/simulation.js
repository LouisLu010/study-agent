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
      fill: dark ? '#1c1c1e' : '#f2f2f7',
      accent: dark ? '#4d8eff' : '#2563eb',
      orange: '#ff9500',
      green: '#34c759',
      red: '#ff3b30',
      purple: '#af52de',
    };
  }

  /** 把世界坐标（米）映射到画布像素，保持等比例，四周留边距。 */
  function fit(bounds, rect, padding, equal) {
    const w = Math.max(bounds.xmax - bounds.xmin, 1e-6);
    const h = Math.max(bounds.ymax - bounds.ymin, 1e-6);
    let sx = (rect.w - 2 * padding) / w;
    let sy = (rect.h - 2 * padding) / h;
    if (equal !== false) sx = sy = Math.min(sx, sy);
    const ox = rect.x + (rect.w - sx * w) / 2;
    const oy = rect.y + (rect.h - sy * h) / 2;
    return {
      x: (x) => ox + (x - bounds.xmin) * sx,
      y: (y) => oy + (bounds.ymax - y) * sy,
      sx,
      sy,
    };
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

  kinds.projectile = (c, model, t, view) => {
    const { colors, rect, values } = view;
    const b = model.bounds;
    const bounds = { xmin: -b.xmax * 0.05, xmax: b.xmax * 1.08, ymin: -b.ymax * 0.08, ymax: b.ymax * 1.15 };
    const v = fit(bounds, rect, 24);
    // 地面和刻度
    c.strokeStyle = colors.line;
    c.lineWidth = 1.5;
    c.beginPath();
    c.moveTo(rect.x, v.y(0));
    c.lineTo(rect.x + rect.w, v.y(0));
    c.stroke();
    niceTicks(0, b.xmax, 5).forEach((x) => {
      c.beginPath();
      c.moveTo(v.x(x), v.y(0));
      c.lineTo(v.x(x), v.y(0) + 4);
      c.stroke();
      text(c, core.formatNumber(x, 1), v.x(x), v.y(0) + 13, colors.secondary, 'center', 10);
    });
    if (values.h > 0) {
      c.fillStyle = colors.grid;
      c.fillRect(v.x(0) - 14, v.y(values.h), 14, v.y(0) - v.y(values.h));
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
    // 速度分量箭头
    const k = 0.25 * Math.min(rect.w, rect.h) / Math.max(values.v0, 1);
    const px = v.x(s.x);
    const py = v.y(s.y);
    arrow(c, px, py, px + s.vx * k, py, colors.green, 1.5);
    arrow(c, px, py, px, py - s.vy * k, colors.orange, 1.5);
    arrow(c, px, py, px + s.vx * k, py - s.vy * k, colors.red, 2);
    c.fillStyle = colors.accent;
    c.beginPath();
    c.arc(px, py, 7, 0, Math.PI * 2);
    c.fill();
    legend(c, rect.x + 8, rect.y + 12, [[colors.red, '速度'], [colors.green, '水平分量'], [colors.orange, '竖直分量']], colors);
  };

  kinds.pendulum = (c, model, t, view) => {
    const { colors, rect, values } = view;
    const v = fit(model.bounds, rect, 18);
    const s = model.at(t);
    const pivot = [v.x(0), v.y(0)];
    // 天花板
    c.strokeStyle = colors.line;
    c.lineWidth = 2;
    c.beginPath();
    c.moveTo(pivot[0] - 40, pivot[1]);
    c.lineTo(pivot[0] + 40, pivot[1]);
    c.stroke();
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
    // 摆线和摆球
    const bob = [v.x(s.x), v.y(s.y)];
    c.strokeStyle = colors.text;
    c.lineWidth = 1.5;
    c.beginPath();
    c.moveTo(pivot[0], pivot[1]);
    c.lineTo(bob[0], bob[1]);
    c.stroke();
    c.fillStyle = colors.accent;
    c.beginPath();
    c.arc(bob[0], bob[1], 11, 0, Math.PI * 2);
    c.fill();
    // 速度方向
    const speed = s.omega * values.L;
    const k = 18 / Math.max(Math.sqrt(2 * values.g * values.L * (1 - Math.cos(a0))), 0.01);
    arrow(c, bob[0], bob[1], bob[0] + speed * Math.cos(s.theta) * k, bob[1] - speed * Math.sin(s.theta) * k, colors.red, 2);
    text(c, 'θ = ' + core.formatNumber(s.theta * 180 / Math.PI, 1) + '°', pivot[0] + 8, pivot[1] + 16, colors.secondary, 'left', 11);
  };

  kinds.spring = (c, model, t, view) => {
    const { colors, rect, values } = view;
    const top = { x: rect.x, y: rect.y, w: rect.w, h: rect.h * 0.5 };
    const v = fit(model.bounds, top, 16);
    const s = model.at(t);
    const groundY = v.y(-0.08);
    const wallX = v.x(-0.55);
    // 地面和墙
    c.strokeStyle = colors.line;
    c.lineWidth = 2;
    c.beginPath();
    c.moveTo(wallX, v.y(0.12));
    c.lineTo(wallX, groundY);
    c.lineTo(top.x + top.w - 10, groundY);
    c.stroke();
    // 平衡位置
    dashed(c, [[v.x(0), v.y(0.13)], [v.x(0), groundY]], colors.secondary);
    text(c, 'O', v.x(0), groundY + 10, colors.secondary, 'center', 10);
    // 弹簧（锯齿线）和物块
    const blockW = 0.14 * v.sx;
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
    c.fillStyle = colors.accent;
    c.fillRect(blockX, groundY - blockW, blockW, blockW);
    text(c, core.formatNumber(values.m, 1) + ' kg', blockX + blockW / 2, groundY - blockW / 2, '#fff', 'center', 10);
    // 回复力方向
    arrow(c, blockX + blockW / 2, groundY - blockW - 8, blockX + blockW / 2 - s.x * 120, groundY - blockW - 8, colors.red, 2);
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
    const [xmin, xmax] = model.xRange;
    const span = Math.max(xmax - xmin, 1);
    const v = fit({ xmin: xmin - span * 0.08, xmax: xmax + span * 0.08, ymin: 0, ymax: 1 }, top, 12, false);
    const trackY = top.y + top.h - 14;
    c.strokeStyle = colors.line;
    c.lineWidth = 1.5;
    c.beginPath();
    c.moveTo(top.x + 8, trackY);
    c.lineTo(top.x + top.w - 8, trackY);
    c.stroke();
    niceTicks(xmin, xmax, 5).forEach((x) => {
      c.beginPath();
      c.moveTo(v.x(x), trackY);
      c.lineTo(v.x(x), trackY + 4);
      c.stroke();
      text(c, core.formatNumber(x, 1), v.x(x), trackY + 11, colors.secondary, 'center', 9);
    });
    const carX = v.x(s.x);
    c.fillStyle = colors.accent;
    c.fillRect(carX - 16, trackY - 22, 32, 16);
    c.fillStyle = colors.text;
    [carX - 9, carX + 9].forEach((wx) => { c.beginPath(); c.arc(wx, trackY - 4, 4, 0, Math.PI * 2); c.fill(); });
    const k = 45 / Math.max(Math.abs(model.vRange[0]), Math.abs(model.vRange[1]), 0.1);
    arrow(c, carX, trackY - 30, carX + s.v * k, trackY - 30, colors.red, 2);
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
    const blockW = model.width * v.sx;
    const size = (m) => blockW * (0.55 + 0.45 * Math.cbrt(m / 10));
    const maxV = Math.max(Math.abs(values.v1), Math.abs(values.v2), 1);
    [[s.x1, values.m1, s.v1, colors.accent, '1'], [s.x2, values.m2, s.v2, colors.orange, '2']].forEach(([x, m, vel, color, name]) => {
      const h = size(m);
      const left = v.x(x) - blockW / 2;
      c.fillStyle = color;
      c.fillRect(left, trackY - h, blockW, h);
      text(c, 'm' + name + ' = ' + core.formatNumber(m, 1) + ' kg', left + blockW / 2, trackY + 12, colors.secondary, 'center', 10);
      arrow(c, left + blockW / 2, trackY - h - 14, left + blockW / 2 + (vel / maxV) * 50, trackY - h - 14, color, 2);
      text(c, core.formatNumber(vel, 2) + ' m/s', left + blockW / 2, trackY - h - 28, colors.text, 'center', 10);
    });
    const P = values.m1 * s.v1 + values.m2 * s.v2;
    const E = 0.5 * values.m1 * s.v1 * s.v1 + 0.5 * values.m2 * s.v2 * s.v2;
    text(c, (s.after ? '碰后' : '碰前') + '  总动量 ' + core.formatNumber(P, 2) + ' kg·m/s   总动能 ' + core.formatNumber(E, 2) + ' J',
      rect.x + 8, rect.y + 12, colors.secondary, 'left', 11);
  };

  // ---------- 组件框架 ----------

  const SPEEDS = [0.5, 1, 2];

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
    const playButton = el('button', 'sa-button', '暂停');
    const replayButton = el('button', 'sa-button', '重播');
    const speedButton = el('button', 'sa-button', '1×');
    const clock = el('span', 'simulation-clock');
    bar.append(playButton, replayButton, speedButton, clock);
    container.appendChild(bar);

    // 结果、实时读数、参数
    const panel = el('div', 'graph-controls');
    const results = el('div', 'graph-readouts');
    const live = el('div', 'graph-readouts simulation-live');
    panel.append(results, live);
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
      input.addEventListener('input', () => {
        values[p.name] = Number(input.value);
        rebuild();
      });
      input.addEventListener('change', save);
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
      if (model) readoutRows(results, model.results);
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
        return;
      }
      render(c, model, time, { colors: palette(), rect: { x: 0, y: 0, w: width, h: height }, values });
      readoutRows(live, model.live(time));
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
      time = 0;
      playing = true;
      paint();
      loop();
    });
    speedButton.addEventListener('click', () => {
      speed = SPEEDS[(SPEEDS.indexOf(speed) + 1) % SPEEDS.length];
      speedButton.textContent = speed + '×';
    });
    reset.addEventListener('click', () => {
      Object.assign(values, spec.defaults);
      spec.params.forEach((p) => { sliders[p.name].value = String(values[p.name]); });
      ctx.setState(null);
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
        frame = 0;
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
