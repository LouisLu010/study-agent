import React from 'react';
import { Easing, interpolate, useCurrentFrame } from 'remotion';
import { color, font } from '../theme';

// 左边一栏的大字幕。前一段的字幕在两段交叠的前 10 帧淡出，这一段的字幕等交叠快结束时才上来，
// 两句话不会叠在一起。
type Props = {
  title: string;
  detail?: string | null;
  /** 第几帧开始进场。 */
  enter: number;
  /** 第几帧开始离场（下一段开始交叠的那一帧）；没有下一段就不离场。 */
  exit?: number;
};

const clamp = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic) } as const;

export const Caption: React.FC<Props> = ({ title, detail, enter, exit }) => {
  const frame = useCurrentFrame();
  const inP = interpolate(frame, [enter, enter + 14], [0, 1], clamp);
  const outP = exit === undefined ? 0 : interpolate(frame, [exit, exit + 10], [0, 1], clamp);
  const detailIn = interpolate(frame, [enter + 6, enter + 20], [0, 1], clamp);
  return (
    <div
      style={{
        position: 'absolute',
        left: 96,
        top: 0,
        bottom: 0,
        width: 600,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'center',
        gap: 20,
        fontFamily: font,
        opacity: inP * (1 - outP),
        transform: `translateY(${(1 - inP) * 24 - outP * 16}px)`,
        zIndex: 20,
      }}
    >
      <div style={{ fontSize: 54, lineHeight: 1.25, fontWeight: 700, color: color.label, letterSpacing: 1, whiteSpace: 'pre-line' }}>{title}</div>
      {detail && <div style={{ fontSize: 28, lineHeight: 1.4, color: color.secondary, opacity: detailIn }}>{detail}</div>}
    </div>
  );
};
