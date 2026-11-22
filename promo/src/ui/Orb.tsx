import React, { useLayoutEffect, useRef } from 'react';
import { useCurrentFrame, useVideoConfig } from 'remotion';
import { mountOrb, type OrbState } from '../vendor/orb-core.js';
import { color as palette } from '../theme';

// 小球：App 用的是 Thinking Orbs 0.1.2 的 SwiftUI 版，这里用同一版本的原版（JS）。
// 原版按真实时间转动，这里停掉它自己的循环，每帧按视频时间画一次。
export const Orb: React.FC<{ state: OrbState; size: number; color?: string; style?: React.CSSProperties }> = ({
  state,
  size,
  color,
  style,
}) => {
  const ref = useRef<SVGSVGElement>(null);
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  useLayoutEffect(() => {
    const svg = ref.current!;
    const orb = mountOrb(svg, { state, size });
    orb.pause();
    return () => orb.destroy();
  }, [state, size]);

  useLayoutEffect(() => {
    const svg = ref.current as (SVGSVGElement & { __drawAt?: (ms: number) => void }) | null;
    svg?.__drawAt?.((frame / fps) * 1000);
  }, [frame, fps, state, size]);

  return (
    <svg
      ref={ref}
      width={size}
      height={size}
      style={{ color: color ?? palette.accent, display: 'block', flex: 'none', overflow: 'visible', ...style }}
    />
  );
};
