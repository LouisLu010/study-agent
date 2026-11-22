import React from 'react';
import { color } from '../theme';

// iOS 26 的 Liquid Glass（glassEffect）只能用 CSS 仿：背景模糊加提亮、半透明底、细的亮边和上沿高光。
// App 里只有输入框、引导页底部按钮和"回到底部"按钮用玻璃（App/Design/Theme.swift 的 glassSurface），
// 导航栏和侧栏工具栏的圆形按钮是系统自己画的玻璃，也按这个样子画。
export const glass: React.CSSProperties = {
  background: 'rgba(44,44,48,0.52)',
  backdropFilter: 'blur(18px) saturate(170%) brightness(1.08)',
  WebkitBackdropFilter: 'blur(18px) saturate(170%) brightness(1.08)',
  boxShadow: 'inset 0 0.5px 0 rgba(255,255,255,0.28), inset 0 0 0 0.5px rgba(255,255,255,0.12), 0 8px 24px rgba(0,0,0,0.35)',
};

export const GlassCircle: React.FC<{ size: number; children: React.ReactNode; style?: React.CSSProperties }> = ({ size, children, style }) => (
  <div style={{ width: size, height: size, borderRadius: size / 2, display: 'flex', alignItems: 'center', justifyContent: 'center', color: color.label, flex: 'none', ...glass, ...style }}>
    {children}
  </div>
);
