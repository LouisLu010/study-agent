import React from 'react';
import { Img, staticFile } from 'remotion';
import { color, font } from '../theme';

// App 的图标。scripts/prepare-renderer.mjs 把 App/Assets.xcassets/AppIcon.appiconset/AppIcon.png 复制成 public/icon.png。
// iOS 的图标圆角约是边长的 22.5%（连续曲率，这里用普通圆角近似）。
export const AppIcon: React.FC<{ size: number; style?: React.CSSProperties }> = ({ size, style }) => (
  <Img
    src={staticFile('icon.png')}
    style={{
      width: size,
      height: size,
      borderRadius: size * 0.225,
      boxShadow: `0 ${size * 0.06}px ${size * 0.25}px rgba(37,99,235,0.35), 0 0 0 1px rgba(255,255,255,0.06)`,
      display: 'block',
      flex: 'none',
      ...style,
    }}
  />
);

/** "1.0 正式版"这样的小胶囊。 */
export const VersionPill: React.FC<{ label: string; size?: number; style?: React.CSSProperties }> = ({ label, size = 20, style }) => (
  <span
    style={{
      display: 'inline-flex',
      alignItems: 'center',
      fontFamily: font,
      fontSize: size,
      fontWeight: 600,
      color: color.accent,
      background: color.accentFill,
      border: '1px solid rgba(77,142,255,0.3)',
      borderRadius: 999,
      padding: `${size * 0.25}px ${size * 0.7}px`,
      letterSpacing: 1,
      ...style,
    }}
  >
    {label}
  </span>
);

/** 左上角的标志：图标、"格物"和版本号，开场以后一直在。 */
export const BrandMark: React.FC<{ opacity: number }> = ({ opacity }) => (
  <div style={{ position: 'absolute', left: 96, top: 64, display: 'flex', alignItems: 'center', gap: 16, opacity, zIndex: 30, fontFamily: font }}>
    <AppIcon size={56} />
    <span style={{ fontSize: 30, fontWeight: 700, letterSpacing: 4, color: color.label }}>格物</span>
    <VersionPill label="1.0" size={18} />
  </div>
);
