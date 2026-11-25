import React from 'react';
import { Easing, interpolate, useCurrentFrame } from 'remotion';
import { color, font } from '../theme';
import { Symbol } from './Symbol';

// 左边一栏的字幕（1.0 版加了内容，左边不再空着）：小标题、大标题、一句说明、三个要点，底部是第几段。
// 前一段的字幕在两段交叠的前 10 帧淡出，这一段的字幕等交叠快结束时才上来，两段的字不会叠在一起。
export type CaptionData = {
  kicker?: string;
  title: string;
  detail?: string | null;
  points?: string[];
};

type Props = CaptionData & {
  /** 第几帧开始进场。 */
  enter: number;
  /** 第几帧开始离场（下一段开始交叠的那一帧）；没有下一段就不离场。 */
  exit?: number;
  /** 第几段、一共几段（只数有字幕的段）。 */
  index?: number;
  total?: number;
};

const ease = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic) } as const;

export const Caption: React.FC<Props> = ({ kicker, title, detail, points = [], enter, exit, index, total }) => {
  const frame = useCurrentFrame();
  const appear = (delay: number) => interpolate(frame, [enter + delay, enter + delay + 14], [0, 1], ease);
  const outP = exit === undefined ? 0 : interpolate(frame, [exit, exit + 10], [0, 1], ease);
  const piece = (delay: number): React.CSSProperties => {
    const p = appear(delay);
    return { opacity: p, transform: `translateY(${(1 - p) * 18}px)` };
  };
  return (
    <div
      style={{
        position: 'absolute',
        left: 96,
        top: 0,
        bottom: 0,
        width: 600,
        fontFamily: font,
        opacity: 1 - outP,
        transform: `translateY(${-outP * 16}px)`,
        zIndex: 20,
      }}
    >
      <div style={{ position: 'absolute', left: 0, right: 0, top: 0, bottom: 0, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 22 }}>
        {kicker && (
          <div style={{ ...piece(0), display: 'flex', alignItems: 'center', gap: 12, fontSize: 24, fontWeight: 600, letterSpacing: 2, color: color.accent }}>
            <span style={{ width: 28, height: 4, borderRadius: 2, background: color.accent }} />
            {kicker}
          </div>
        )}
        <div style={{ ...piece(2), fontSize: 60, lineHeight: 1.22, fontWeight: 700, color: color.label, letterSpacing: 1, whiteSpace: 'pre-line' }}>{title}</div>
        {detail && <div style={{ ...piece(8), fontSize: 29, lineHeight: 1.45, color: color.secondary, maxWidth: 560 }}>{detail}</div>}
        {points.length > 0 && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 16, marginTop: 14 }}>
            {points.map((point, i) => (
              <div
                key={point}
                style={{
                  ...piece(16 + i * 7),
                  display: 'flex',
                  alignItems: 'center',
                  gap: 14,
                  padding: '14px 20px',
                  borderRadius: 16,
                  background: 'rgba(77,142,255,0.08)',
                  border: '1px solid rgba(77,142,255,0.18)',
                  fontSize: 26,
                  lineHeight: 1.3,
                  color: 'rgba(255,255,255,0.88)',
                }}
              >
                <Symbol name="checkmark.circle.fill" size={22} color={color.accent} />
                {point}
              </div>
            ))}
          </div>
        )}
      </div>
      {index !== undefined && total !== undefined && (
        <div style={{ ...piece(4), position: 'absolute', left: 0, bottom: 72, display: 'flex', alignItems: 'center', gap: 14, fontSize: 22, color: color.tertiary, fontVariantNumeric: 'tabular-nums' }}>
          <span style={{ color: color.secondary, fontWeight: 600 }}>{String(index).padStart(2, '0')}</span>
          <span style={{ display: 'flex', gap: 6 }}>
            {Array.from({ length: total }, (_, i) => (
              <span key={i} style={{ width: i + 1 === index ? 26 : 10, height: 4, borderRadius: 2, background: i + 1 === index ? color.accent : color.quaternary }} />
            ))}
          </span>
          <span>{String(total).padStart(2, '0')}</span>
        </div>
      )}
    </div>
  );
};
