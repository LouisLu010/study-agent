import React from 'react';
import { interpolate, useCurrentFrame } from 'remotion';
import { color, font } from '../theme';

// 左边一栏的大字幕：进场 12 帧淡入上移，离场前 10 帧淡出。
export const Caption: React.FC<{ title: string; detail?: string | null; duration: number }> = ({ title, detail, duration }) => {
  const frame = useCurrentFrame();
  const enter = interpolate(frame, [4, 16], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
  const exit = interpolate(frame, [duration - 10, duration], [1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
  const opacity = Math.min(enter, exit);
  return (
    <div style={{ position: 'absolute', left: 96, top: 0, bottom: 0, width: 600, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 20, fontFamily: font, opacity, transform: `translateY(${(1 - enter) * 24}px)`, zIndex: 20 }}>
      <div style={{ fontSize: 54, lineHeight: 1.25, fontWeight: 700, color: color.label, letterSpacing: 1, whiteSpace: 'pre-line' }}>{title}</div>
      {detail && <div style={{ fontSize: 28, lineHeight: 1.4, color: color.secondary }}>{detail}</div>}
    </div>
  );
};
