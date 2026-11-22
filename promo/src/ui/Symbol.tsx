import React from 'react';
import { staticFile } from 'remotion';
import symbols from '../../symbols.json';

// SF Symbols：渲染前在 macOS 上用 scripts/export-symbols.swift 按 symbols.json 导出成 PNG（不进仓库），
// 这里当作遮罩用，颜色跟着 currentColor。不在 macOS 上预览时没有图片，图标位置是空的。
const known = new Set<string>(symbols.map((s) => s.name));

export type SymbolProps = {
  name: string;
  /** 图标的字号，和旁边的文字一样大。 */
  size: number;
  color?: string;
  style?: React.CSSProperties;
};

export const Symbol: React.FC<SymbolProps> = ({ name, size, color, style }) => {
  if (!known.has(name)) throw new Error(`symbols.json 里没有 ${name}，先加进去再导出`);
  const url = `url("${staticFile(`symbols/${name}.png`)}")`;
  // 导出的图片是 4 倍字号的正方形画布，符号居中；显示时画布边长取字号的 1.3 倍，和 SF Symbols 在文字旁的占位接近。
  const box = Math.round(size * 1.3);
  return (
    <span
      aria-hidden
      style={{
        display: 'inline-block',
        flex: 'none',
        width: box,
        height: box,
        backgroundColor: color ?? 'currentColor',
        WebkitMaskImage: url,
        maskImage: url,
        WebkitMaskSize: 'contain',
        maskSize: 'contain',
        WebkitMaskRepeat: 'no-repeat',
        maskRepeat: 'no-repeat',
        WebkitMaskPosition: 'center',
        maskPosition: 'center',
        ...style,
      }}
    />
  );
};
