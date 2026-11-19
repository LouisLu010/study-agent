/*
 * 电磁类模拟的画法：电场偏转、磁场圆周运动、速度选择器和质谱仪、导体棒切割磁感线。
 * 物理计算在 core.js 里。
 */
(function () {
  'use strict';

  const sim = window.StudySimulation;
  const core = window.StudyCore;
  const { fit, arrow, text, dashed, plot } = sim;

  function polyline(c, points, view, color, width) {
    c.strokeStyle = color;
    c.lineWidth = width || 2.5;
    c.beginPath();
    points.forEach((p, i) => (i ? c.lineTo(view.x(p.x), view.y(p.y)) : c.moveTo(view.x(p.x), view.y(p.y))));
    c.stroke();
  }

  /** 磁场符号：× 表示垂直纸面向里，· 表示向外。 */
  function fieldMarks(c, area, into, color) {
    const step = 26;
    c.strokeStyle = color;
    c.fillStyle = color;
    c.lineWidth = 1;
    for (let x = area.x + step / 2; x < area.x + area.w; x += step) {
      for (let y = area.y + step / 2; y < area.y + area.h; y += step) {
        if (into) {
          c.beginPath();
          c.moveTo(x - 3.5, y - 3.5); c.lineTo(x + 3.5, y + 3.5);
          c.moveTo(x + 3.5, y - 3.5); c.lineTo(x - 3.5, y + 3.5);
          c.stroke();
        } else {
          c.beginPath();
          c.arc(x, y, 1.8, 0, Math.PI * 2);
          c.fill();
        }
      }
    }
  }

  function particle(c, x, y, positive, colors) {
    c.fillStyle = positive ? colors.red : colors.accent;
    c.beginPath();
    c.arc(x, y, 6, 0, Math.PI * 2);
    c.fill();
    text(c, positive ? '+' : '−', x, y + 0.5, '#fff', 'center', 10);
  }

  sim.kinds.electric_deflection = (c, model, t, view) => {
    const { colors, rect } = view;
    const v = fit(model.bounds, rect, 22);
    const top = model.d / 2;
    // 极板：上板接正极
    c.lineWidth = 4;
    c.strokeStyle = colors.red;
    c.beginPath(); c.moveTo(v.x(0), v.y(top)); c.lineTo(v.x(model.L), v.y(top)); c.stroke();
    c.strokeStyle = colors.accent;
    c.beginPath(); c.moveTo(v.x(0), v.y(-top)); c.lineTo(v.x(model.L), v.y(-top)); c.stroke();
    text(c, '+', v.x(model.L) + 8, v.y(top), colors.red, 'left', 14);
    text(c, '−', v.x(model.L) + 8, v.y(-top), colors.accent, 'left', 14);
    // 电场线（向下）
    for (let i = 1; i <= 4; i++) {
      const x = v.x((model.L * i) / 5);
      arrow(c, x, v.y(top) + 4, x, v.y(-top) - 4, colors.grid, 1);
    }
    text(c, 'E', v.x(model.L * 0.9), v.y(0), colors.secondary, 'center', 11);
    // 荧光屏
    if (!model.hits) {
      const screenX = v.x(model.L * 1.6);
      c.strokeStyle = colors.line;
      c.lineWidth = 2;
      c.beginPath(); c.moveTo(screenX, rect.y + 10); c.lineTo(screenX, rect.y + rect.h - 10); c.stroke();
    }
    const path = model.path(120);
    dashed(c, path.map((p) => [v.x(p.x), v.y(p.y)]), colors.secondary);
    const s = model.at(t);
    polyline(c, path.filter((p) => p.x <= s.x + 1e-12), v, model.sign > 0 ? colors.red : colors.accent);
    particle(c, v.x(s.x), v.y(s.y), model.sign > 0, colors);
  };

  sim.kinds.magnetic_circle = (c, model, t, view) => {
    const { colors, rect, values } = view;
    const v = fit(model.bounds, rect, 18);
    // 磁场区域
    const boundaryX = values.boundary ? v.x(0) : rect.x;
    c.fillStyle = colors.fill;
    c.fillRect(boundaryX, rect.y, rect.x + rect.w - boundaryX, rect.h);
    fieldMarks(c, { x: boundaryX, y: rect.y, w: rect.x + rect.w - boundaryX, h: rect.h }, true, colors.secondary);
    if (values.boundary) {
      c.strokeStyle = colors.line;
      c.lineWidth = 1.5;
      c.beginPath(); c.moveTo(boundaryX, rect.y); c.lineTo(boundaryX, rect.y + rect.h); c.stroke();
      text(c, 'B（垂直纸面向里）', boundaryX + 6, rect.y + 12, colors.secondary, 'left', 10);
      // 入射前的直线
      const back = model.r * 0.6;
      const dx = -Math.cos(model.phi) * back;
      const dy = -model.sign * Math.sin(model.phi) * back;
      polyline(c, [{ x: dx, y: dy }, { x: 0, y: 0 }], v, colors.secondary, 1.5);
    }
    const path = model.path(160);
    dashed(c, path.map((p) => [v.x(p.x), v.y(p.y)]), colors.secondary);
    const s = model.at(t);
    // 圆心和半径
    const cx = -model.r * Math.sin(model.phi);
    const cy = model.sign * model.r * Math.cos(model.phi);
    c.fillStyle = colors.secondary;
    c.beginPath(); c.arc(v.x(cx), v.y(cy), 2.5, 0, Math.PI * 2); c.fill();
    dashed(c, [[v.x(cx), v.y(cy)], [v.x(s.x), v.y(s.y)]], colors.orange);
    // 走过的部分
    const steps = 80;
    const traced = [];
    for (let i = 0; i <= steps; i++) traced.push(model.at((t * i) / steps));
    if (!values.boundary) traced.length = 0;
    if (traced.length) polyline(c, traced, v, model.sign > 0 ? colors.red : colors.accent);
    // 速度方向（切线）和洛伦兹力方向（指向圆心）
    const vx = -(s.y - cy) * model.sign;
    const vy = (s.x - cx) * model.sign;
    const len = Math.hypot(vx, vy) || 1;
    arrow(c, v.x(s.x), v.y(s.y), v.x(s.x) + (vx / len) * 30, v.y(s.y) - (vy / len) * 30, colors.green, 2);
    const fx = cx - s.x;
    const fy = cy - s.y;
    const flen = Math.hypot(fx, fy) || 1;
    arrow(c, v.x(s.x), v.y(s.y), v.x(s.x) + (fx / flen) * 22, v.y(s.y) - (fy / flen) * 22, colors.orange, 2);
    particle(c, v.x(s.x), v.y(s.y), model.sign > 0, colors);
    sim.legend(c, rect.x + 8, rect.y + rect.h - 10, [[colors.green, '速度'], [colors.orange, '洛伦兹力（指向圆心）']], colors);
  };

  sim.kinds.mass_spectrometer = (c, model, t, view) => {
    const { colors, rect } = view;
    const v = fit(model.bounds, rect, 16);
    const { Ls, gap } = model;
    // 速度选择器：上板正、下板负，磁场向里
    const selector = { x: v.x(0), y: v.y(gap), w: v.x(Ls) - v.x(0), h: v.y(-gap) - v.y(gap) };
    c.fillStyle = colors.fill;
    c.fillRect(selector.x, selector.y, selector.w, selector.h);
    c.lineWidth = 3;
    c.strokeStyle = colors.red;
    c.beginPath(); c.moveTo(v.x(0), v.y(gap)); c.lineTo(v.x(Ls), v.y(gap)); c.stroke();
    c.strokeStyle = colors.accent;
    c.beginPath(); c.moveTo(v.x(0), v.y(-gap)); c.lineTo(v.x(Ls), v.y(-gap)); c.stroke();
    text(c, '速度选择器（E 向下，B₁ 向里）', v.x(0), v.y(gap) - 10, colors.secondary, 'left', 10);
    // 质谱仪：选择器右侧、入射线下方是向外的磁场；粒子转半圈后打在左边竖直的底片上（x = Ls）
    const region = { x: v.x(Ls), y: v.y(0), w: rect.x + rect.w - v.x(Ls), h: rect.y + rect.h - v.y(0) };
    c.fillStyle = colors.fill;
    c.fillRect(region.x, region.y, region.w, region.h);
    fieldMarks(c, region, false, colors.secondary);
    c.strokeStyle = colors.line;
    c.lineWidth = 3;
    c.beginPath(); c.moveTo(v.x(Ls), v.y(-gap) + 4); c.lineTo(v.x(Ls), rect.y + rect.h); c.stroke();
    text(c, '底片', v.x(Ls) - 6, rect.y + rect.h - 10, colors.secondary, 'right', 10);
    text(c, 'B₂ 向外', region.x + region.w - 6, region.y + region.h - 10, colors.secondary, 'right', 10);

    const palette = [colors.red, colors.orange];
    const s = model.at(t);
    model.species.forEach((sp, i) => {
      const full = model.path(sp, 120);
      dashed(c, full.map((p) => [v.x(p.x), v.y(p.y)]), colors.secondary);
      const now = s.particles[i];
      const traced = [];
      for (let k = 0; k <= 60; k++) traced.push(sp.pos((sp.tEnd * Math.min(t, model.duration) * k) / (60 * model.duration)));
      polyline(c, traced, v, palette[i]);
      c.fillStyle = palette[i];
      c.beginPath(); c.arc(v.x(now.x), v.y(now.y), 5, 0, Math.PI * 2); c.fill();
      if (!sp.blocked) {
        // 打在底片上的位置：入射点下方 2r
        const hitY = v.y(-2 * sp.r);
        c.fillRect(v.x(Ls) - 6, hitY - 1.5, 12, 3);
        text(c, (i + 1) + ': 2r = ' + core.formatNumber(2 * sp.r * 100, 1) + ' cm', v.x(Ls) - 10, hitY, palette[i], 'right', 10);
      }
    });
  };

  sim.kinds.rod_induction = (c, model, t, view) => {
    const { colors, rect, values } = view;
    const s = model.at(t);
    const top = { x: rect.x + 10, y: rect.y + 10, w: rect.w - 20, h: rect.h * 0.48 };
    const railTop = top.y + 14;
    const railBottom = top.y + top.h - 6;
    const left = top.x + 30;
    const right = top.x + top.w;
    fieldMarks(c, { x: left, y: railTop, w: right - left, h: railBottom - railTop }, true, colors.grid);
    c.strokeStyle = colors.line;
    c.lineWidth = 2;
    c.beginPath();
    c.moveTo(right, railTop); c.lineTo(left, railTop);
    c.moveTo(right, railBottom); c.lineTo(left, railBottom);
    c.stroke();
    // 电阻
    const mid = (railTop + railBottom) / 2;
    c.beginPath();
    c.moveTo(left, railTop); c.lineTo(left, mid - 16);
    for (let i = 0; i <= 6; i++) c.lineTo(left + (i % 2 ? 6 : -6), mid - 16 + (32 * i) / 6);
    c.lineTo(left, mid + 16); c.lineTo(left, railBottom);
    c.stroke();
    text(c, 'R', left - 12, mid, colors.secondary, 'right', 11);
    text(c, 'B 向里', right - 4, top.y + 4, colors.secondary, 'right', 10);
    // 导体棒的位置按总位移缩放到导轨长度
    const rodX = left + 40 + ((right - left - 60) * s.x) / model.xMax;
    c.strokeStyle = colors.accent;
    c.lineWidth = 5;
    c.beginPath(); c.moveTo(rodX, railTop - 6); c.lineTo(rodX, railBottom + 6); c.stroke();
    const vmax = Math.max(Math.abs(model.vRange[0]), Math.abs(model.vRange[1]), 0.1);
    arrow(c, rodX + 6, mid, rodX + 6 + (s.v / vmax) * 50, mid, colors.green, 2);
    text(c, 'v', rodX + 10 + (s.v / vmax) * 50, mid - 9, colors.green, 'left', 11);
    if (values.F > 0) {
      arrow(c, rodX + 6, railTop + 12, rodX + 6 + 36, railTop + 12, colors.purple, 2);
      text(c, 'F', rodX + 46, railTop + 12, colors.purple, 'left', 11);
    }
    // 安培力向左，感应电流在棒中向上（右手定则）
    if (s.Fa > 1e-4) {
      arrow(c, rodX - 6, railBottom - 12, rodX - 6 - Math.min(40, 10 + (s.Fa / (s.Fa + 0.2)) * 30), railBottom - 12, colors.orange, 2);
      arrow(c, rodX, mid + 12, rodX, mid - 12, colors.red, 2);
      text(c, 'I', rodX - 8, mid - 14, colors.red, 'right', 11);
    }
    sim.legend(c, rect.x + 12, top.y + top.h + 14, [[colors.green, '速度'], [colors.red, '感应电流'], [colors.orange, '安培力']], colors);
    plot(c, { x: rect.x + 8, y: rect.y + rect.h * 0.62, w: rect.w - 16, h: rect.h * 0.36 }, {
      colors, tMax: model.duration, tNow: s.t, yRange: model.vRange, label: 'v-t（速度越来越慢地变化）',
      series: [{ fn: (tt) => model.at(tt).v, color: colors.green }],
    });
  };
})();
