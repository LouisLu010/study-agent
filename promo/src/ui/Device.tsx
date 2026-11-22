import React from 'react';
import { color, font, ipad, iphone } from '../theme';
import { Symbol } from './Symbol';

// 设备框是自己画的圆角矩形加细边框，不用 Apple 的产品图（见 docs/promo/README.md 的 Q23）。

const StatusIcons: React.FC<{ size: number }> = ({ size }) => (
  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
    <Symbol name="wifi" size={size} />
    <span style={{ fontSize: size, fontWeight: 600 }}>100%</span>
    <div style={{ position: 'relative', width: size * 1.9, height: size * 0.95, borderRadius: size * 0.28, border: `1.5px solid ${color.secondary}`, padding: 1.5 }}>
      <div style={{ width: '100%', height: '100%', borderRadius: size * 0.16, background: color.label }} />
      <div style={{ position: 'absolute', right: -4, top: '32%', width: 2, height: '36%', borderRadius: 1, background: color.secondary }} />
    </div>
  </div>
);

export const IPad: React.FC<{ children: React.ReactNode; scale: number; style?: React.CSSProperties }> = ({ children, scale, style }) => {
  const bezel = 18;
  return (
    <div
      style={{
        position: 'absolute',
        width: ipad.width + bezel * 2,
        height: ipad.height + bezel * 2,
        transform: `scale(${scale})`,
        transformOrigin: '0 0',
        borderRadius: 36 + bezel,
        background: '#0b0b0c',
        boxShadow: '0 0 0 2px #3a3a3e, 0 40px 120px rgba(0,0,0,0.6)',
        padding: bezel,
        ...style,
      }}
    >
      <Screen width={ipad.width} height={ipad.height} radius={36}>
        <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: ipad.statusBar, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 22px', fontSize: 14, fontWeight: 600, color: color.label, zIndex: 50, pointerEvents: 'none' }}>
          <span>晚上8:12&nbsp;&nbsp;11月22日周日</span>
          <StatusIcons size={13} />
        </div>
        {children}
      </Screen>
    </div>
  );
};

export const IPhone: React.FC<{ children: React.ReactNode; scale: number; style?: React.CSSProperties }> = ({ children, scale, style }) => {
  const bezel = 12;
  return (
    <div
      style={{
        position: 'absolute',
        width: iphone.width + bezel * 2,
        height: iphone.height + bezel * 2,
        transform: `scale(${scale})`,
        transformOrigin: '0 0',
        borderRadius: 55 + bezel,
        background: '#0b0b0c',
        boxShadow: '0 0 0 2px #3a3a3e, 0 40px 120px rgba(0,0,0,0.6)',
        padding: bezel,
        ...style,
      }}
    >
      <Screen width={iphone.width} height={iphone.height} radius={55}>
        <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: iphone.statusBar, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '4px 34px 0 46px', fontSize: 17, fontWeight: 600, color: color.label, zIndex: 50 }}>
          <span>20:12</span>
          <div style={{ position: 'absolute', left: '50%', top: 11, width: 124, height: 36, marginLeft: -62, borderRadius: 18, background: '#000' }} />
          <StatusIcons size={14} />
        </div>
        {children}
      </Screen>
    </div>
  );
};

const Screen: React.FC<{ width: number; height: number; radius: number; children: React.ReactNode }> = ({ width, height, radius, children }) => (
  <div
    style={{
      position: 'relative',
      width,
      height,
      borderRadius: radius,
      overflow: 'hidden',
      background: color.background,
      color: color.label,
      fontFamily: font,
      WebkitFontSmoothing: 'antialiased',
    }}
  >
    {children}
  </div>
);
