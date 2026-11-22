// 原生界面的样式常量。App 自己定的值抄自 App/Design/Theme.swift 和 AccentColor.colorset（深色模式），
// 系统颜色按 iOS 深色模式的标准值，字号按 iOS 默认的"大"号动态字体。
export const color = {
  accent: '#4D8EFF',
  accentFill: 'rgba(77,142,255,0.12)',
  success: '#4ADE80',
  orange: '#FF9F0A',
  red: '#FF453A',
  background: '#000000',
  secondaryBackground: '#1C1C1E',
  tertiaryBackground: '#2C2C2E',
  groupedBackground: '#000000',
  groupedCard: '#1C1C1E',
  sidebar: '#1C1C1E',
  sidebarCard: '#2C2C2E',
  sidebarSelected: '#3A3A3C',
  label: '#FFFFFF',
  secondary: 'rgba(235,235,245,0.6)',
  tertiary: 'rgba(235,235,245,0.3)',
  quaternary: 'rgba(235,235,245,0.16)',
  separator: 'rgba(84,84,88,0.6)',
  fill: 'rgba(120,120,128,0.36)',
  secondaryFill: 'rgba(120,120,128,0.32)',
  tertiaryFill: 'rgba(118,118,128,0.24)',
};

export const radius = { card: 12, field: 20 };
export const space = { xs: 4, s: 8, m: 12, l: 16, xl: 24 };

/** iOS 文字样式（默认字号）：[字号, 行高]。 */
export const text = {
  largeTitle: { fontSize: 34, lineHeight: '41px', fontWeight: 700 },
  title3: { fontSize: 20, lineHeight: '25px' },
  headline: { fontSize: 17, lineHeight: '22px', fontWeight: 600 },
  body: { fontSize: 17, lineHeight: '22px' },
  callout: { fontSize: 16, lineHeight: '21px' },
  subheadline: { fontSize: 15, lineHeight: '20px' },
  footnote: { fontSize: 13, lineHeight: '18px' },
  caption: { fontSize: 12, lineHeight: '16px' },
  caption2: { fontSize: 11, lineHeight: '13px' },
} as const;

export const font = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif';

/** 设备的逻辑尺寸（pt）。iPad 按 13 英寸横屏，iPhone 按 6.3 英寸竖屏。 */
export const ipad = { width: 1376, height: 1032, sidebar: 320, statusBar: 24 };
export const iphone = { width: 402, height: 874, statusBar: 54 };
