/*
 * 电路和化学平衡模拟的画法。计算在 core.js 里。
 */
(function () {
  'use strict';

  const sim = window.StudySimulation;
  const core = window.StudyCore;
  const { text, plot } = sim;

  // ---------- 电路 ----------

  /** 画一段导线，返回它的长度，用来摆放表示电流的小点。 */
  function wire(c, points, color) {
    c.strokeStyle = color;
    c.lineWidth = 2;
    c.beginPath();
    points.forEach(([x, y], i) => (i ? c.lineTo(x, y) : c.moveTo(x, y)));
    c.stroke();
  }

  function resistor(c, x, y, w, h, label, colors, vertical) {
    c.fillStyle = colors.fill;
    c.strokeStyle = colors.text;
    c.lineWidth = 2;
    if (vertical) {
      c.fillRect(x - h / 2, y - w / 2, h, w);
      c.strokeRect(x - h / 2, y - w / 2, h, w);
      text(c, label, x + h / 2 + 6, y, colors.text, 'left', 11);
    } else {
      c.fillRect(x - w / 2, y - h / 2, w, h);
      c.strokeRect(x - w / 2, y - h / 2, w, h);
      text(c, label, x, y - h / 2 - 9, colors.text, 'center', 11);
    }
  }

  /** 沿折线移动的小点，速度和电流成正比（电子实际向反方向运动，这里按电流方向画）。 */
  function charges(c, points, offset, color) {
    const segments = [];
    let total = 0;
    for (let i = 1; i < points.length; i++) {
      const len = Math.hypot(points[i][0] - points[i - 1][0], points[i][1] - points[i - 1][1]);
      segments.push([points[i - 1], points[i], total, len]);
      total += len;
    }
    const spacing = 22;
    c.fillStyle = color;
    for (let d = ((offset % spacing) + spacing) % spacing; d < total; d += spacing) {
      const seg = segments.find((sg) => d >= sg[2] && d <= sg[2] + sg[3]);
      if (!seg) continue;
      const f = (d - seg[2]) / (seg[3] || 1);
      c.beginPath();
      c.arc(seg[0][0] + (seg[1][0] - seg[0][0]) * f, seg[0][1] + (seg[1][1] - seg[0][1]) * f, 2.6, 0, Math.PI * 2);
      c.fill();
    }
  }

  sim.kinds.circuit = (c, model, t, view) => {
    const { colors, rect, values } = view;
    const left = rect.x + 40;
    const right = rect.x + rect.w - 40;
    const top = rect.y + 40;
    const bottom = rect.y + rect.h - 40;
    const speed = 60; // 电流 1 A 时每秒移动的像素
    const flow = (I) => t * speed * Math.min(I, 3);

    // 电源在左侧：长线是正极（上）
    const midY = (top + bottom) / 2;
    c.strokeStyle = colors.text;
    c.lineWidth = 3;
    c.beginPath(); c.moveTo(left - 14, midY - 6); c.lineTo(left + 14, midY - 6); c.stroke();
    c.lineWidth = 5;
    c.beginPath(); c.moveTo(left - 7, midY + 6); c.lineTo(left + 7, midY + 6); c.stroke();
    text(c, core.formatNumber(values.U, 1) + ' V' + (values.r > 0 ? '，r = ' + core.formatNumber(values.r, 1) + ' Ω' : ''),
      left - 20, midY, colors.secondary, 'right', 10);
    text(c, '+', left + 18, midY - 12, colors.red, 'left', 12);

    const n = model.branches.length;
    if (!model.parallel) {
      // 串联：电阻排在上边
      const path = [[left, midY - 6], [left, top], [right, top], [right, bottom], [left, bottom], [left, midY + 6]];
      wire(c, path, colors.line);
      charges(c, path, flow(model.I), colors.orange);
      model.branches.forEach((b, i) => {
        const x = left + ((right - left) * (i + 1)) / (n + 1);
        resistor(c, x, top, 46, 16, b.name + ' ' + core.formatNumber(b.R, 0) + ' Ω', colors, false);
        text(c, core.formatNumber(b.U, 2) + ' V', x, top + 20, colors.secondary, 'center', 10);
      });
    } else {
      // 并联：每个电阻一条竖直支路
      const xs = model.branches.map((_, i) => left + ((right - left) * (i + 1)) / (n + 0.6));
      const lastX = xs[xs.length - 1];
      const main = [[left, midY - 6], [left, top], [lastX, top]];
      const back = [[lastX, bottom], [left, bottom], [left, midY + 6]];
      wire(c, main, colors.line);
      wire(c, back, colors.line);
      charges(c, [[left, midY - 6], [left, top], [xs[0], top]], flow(model.I), colors.orange);
      charges(c, [[xs[0], bottom], [left, bottom], [left, midY + 6]], flow(model.I), colors.orange);
      model.branches.forEach((b, i) => {
        const x = xs[i];
        const branch = [[x, top], [x, bottom]];
        wire(c, branch, colors.line);
        charges(c, branch, flow(b.I), colors.orange);
        resistor(c, x, midY, 46, 16, b.name + ' ' + core.formatNumber(b.R, 0) + ' Ω', colors, true);
        text(c, core.formatNumber(b.I, 3) + ' A', x + 14, bottom - 12, colors.secondary, 'left', 10);
      });
    }
    text(c, '干路电流 ' + core.formatNumber(model.I, 3) + ' A（橙色小点表示电流方向，越快电流越大）', rect.x + 8, rect.y + 14, colors.secondary, 'left', 10);
  };

  // ---------- 化学平衡 ----------

  /** 固定种子的伪随机数，让粒子的位置每次刷新都一样。 */
  function seeded(i) {
    const x = Math.sin(i * 12.9898 + 78.233) * 43758.5453;
    return x - Math.floor(x);
  }

  sim.kinds.equilibrium = (c, model, t, view) => {
    const { colors, rect } = view;
    const s = model.at(t);
    // 左边：容器里的粒子，蓝色是 A，橙色是 B
    const box = { x: rect.x + 10, y: rect.y + 24, w: rect.w * 0.36, h: rect.h - 40 };
    c.strokeStyle = colors.line;
    c.lineWidth = 1.5;
    c.strokeRect(box.x, box.y, box.w, box.h);
    const totalParticles = 80;
    const nA = Math.round((s.A / model.max) * totalParticles);
    const nB = Math.round((s.B / model.max) * totalParticles);
    for (let i = 0; i < nA + nB; i++) {
      const jitter = Math.sin(t * 3 + i) * 2;
      const x = box.x + 6 + seeded(i) * (box.w - 12) + jitter;
      const y = box.y + 6 + seeded(i + 500) * (box.h - 12) + Math.cos(t * 2.5 + i) * 2;
      c.fillStyle = i < nA ? colors.accent : colors.orange;
      c.beginPath();
      c.arc(x, y, 3.2, 0, Math.PI * 2);
      c.fill();
    }
    text(c, 'A ⇌ B', box.x + box.w / 2, rect.y + 12, colors.text, 'center', 12);
    sim.legend(c, box.x, box.y + box.h + 10, [[colors.accent, 'A'], [colors.orange, 'B']], colors);
    // 右边：浓度随时间变化
    const area = { x: box.x + box.w + 12, y: rect.y + 10, w: rect.x + rect.w - (box.x + box.w + 12) - 8, h: rect.h - 20 };
    plot(c, area, {
      colors, tMax: model.duration, tNow: s.t, yRange: [0, model.max], label: '浓度 c（mol/L）',
      series: [
        { fn: (tt) => model.at(tt).A, color: colors.accent },
        { fn: (tt) => model.at(tt).B, color: colors.orange },
      ],
    });
    if (Number.isFinite(model.tAdd)) {
      const x = area.x + (area.w * model.tAdd) / model.duration;
      sim.dashed(c, [[x, area.y + 16], [x, area.y + area.h]], colors.secondary);
      text(c, '加入 A', x + 4, area.y + 22, colors.secondary, 'left', 10);
    }
  };
})();
