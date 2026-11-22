import React from 'react';
import { Easing, interpolate } from 'remotion';
import { ipad, iphone } from '../theme';
import { IPad, IPhone } from './Device';

// 16:9 画面里的设备位置和镜头。
// iPad 放在右边约 62% 的宽度里，左边一栏写字幕（docs/promo/README.md 的 Q27）。
// 镜头推近时把屏幕上的某个矩形（单位是屏幕上的 pt）放大到右边的一块区域里；推近程度 0 是整台 iPad，1 是特写。

export const video = { width: 1920, height: 1080 };
const ipadScale = 0.82;
const ipadOrigin = { x: video.width - (ipad.width + 36) * ipadScale - 70 + 18 * ipadScale, y: (video.height - (ipad.height + 36) * ipadScale) / 2 + 18 * ipadScale };
const closeUp = { cx: 1250, cy: 540, width: 1160, height: 960 };

export type Focus = { x: number; y: number; width: number; height: number };

/** 原生页面那几段的镜头：试过推近一点，iPad 会压到左边的字幕，所以保持整台 iPad（推近程度 0）。 */
export const detailFocus: Focus = { x: ipad.sidebar - 40, y: 40, width: ipad.width - ipad.sidebar + 40, height: 820 };
export const detailZoom = 0;

export function camera(focus: Focus | null, zoom: number) {
  if (!focus || zoom <= 0) return { k: ipadScale, x: ipadOrigin.x, y: ipadOrigin.y };
  const k1 = Math.min(closeUp.width / focus.width, closeUp.height / focus.height);
  const x1 = closeUp.cx - k1 * (focus.x + focus.width / 2);
  const y1 = closeUp.cy - k1 * (focus.y + focus.height / 2);
  // 缩放按对数插值，画面里的变化才均匀。
  const k = Math.exp(interpolate(zoom, [0, 1], [Math.log(ipadScale), Math.log(k1)]));
  const t = (k - ipadScale) / (k1 - ipadScale || 1);
  return { k, x: ipadOrigin.x + (x1 - ipadOrigin.x) * t, y: ipadOrigin.y + (y1 - ipadOrigin.y) * t };
}

export const smooth = (frame: number, range: [number, number], from = 0, to = 1) =>
  interpolate(frame, range, [from, to], { easing: Easing.inOut(Easing.cubic), extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });

export const IPadStage: React.FC<{ focus?: Focus | null; zoom?: number; opacity?: number; children: React.ReactNode }> = ({ focus = null, zoom = 0, opacity = 1, children }) => {
  const cam = camera(focus, zoom);
  return (
    <div style={{ position: 'absolute', left: 0, top: 0, transform: `translate(${cam.x}px, ${cam.y}px) scale(${cam.k})`, transformOrigin: '0 0', opacity }}>
      <IPad scale={1} style={{ left: -18, top: -18 }}>{children}</IPad>
    </div>
  );
};

const iphoneScale = 1.0;
export const IPhoneStage: React.FC<{ enter: number; children: React.ReactNode }> = ({ enter, children }) => {
  const x = video.width - (iphone.width + 24) * iphoneScale - 330;
  const y = (video.height - (iphone.height + 24) * iphoneScale) / 2;
  return (
    <div style={{ position: 'absolute', left: x, top: y + (1 - enter) * 120, opacity: enter, transform: `scale(${iphoneScale})`, transformOrigin: '0 0' }}>
      <IPhone scale={1} style={{ left: 0, top: 0 }}>{children}</IPhone>
    </div>
  );
};
