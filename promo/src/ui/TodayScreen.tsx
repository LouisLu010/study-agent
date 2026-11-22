import React from 'react';
import { color, ipad, iphone, radius, text } from './shared';
import { today } from '../content';
import { Composer } from './Composer';
import { Symbol } from './Symbol';
import { GlassCircle } from './Glass';

// "今天"：App/Study/TodayView.swift。内容最宽 720，卡片之间 16，卡片内边距 16，圆角 12。

const Card: React.FC<{ children: React.ReactNode; style?: React.CSSProperties }> = ({ children, style }) => (
  <div style={{ background: color.groupedCard, borderRadius: radius.card, padding: 16, display: 'flex', flexDirection: 'column', gap: 12, ...style }}>{children}</div>
);

const CardTitle: React.FC<{ icon: string; title: string }> = ({ icon, title }) => (
  <div style={{ display: 'flex', alignItems: 'center', gap: 6, ...text.subheadline, fontWeight: 600, color: color.secondary }}>
    <Symbol name={icon} size={15} />
    {title}
  </div>
);

const WeekBars: React.FC<{ counts: number[]; grow: number }> = ({ counts, grow }) => {
  const max = Math.max(...counts);
  return (
    <div style={{ height: 52, display: 'flex', alignItems: 'flex-end', gap: 4 }}>
      {counts.map((count, i) => (
        <div key={i} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2 }}>
          <div style={{ width: 8, height: Math.max(4, (36 * count * grow) / max), borderRadius: 4, background: count > 0 ? color.accent : color.tertiaryFill }} />
          <span style={{ fontSize: 9, lineHeight: '11px', color: i === counts.length - 1 ? color.label : color.tertiary }}>{today.weekdays[i]}</span>
        </div>
      ))}
    </div>
  );
};

type Props = {
  compact?: boolean;
  composer?: { value?: string; caret?: boolean; pressing?: boolean };
  /** 0 到 1：数字和柱子长出来的进度。 */
  grow?: number;
  /** 连续学习天数（可以做成从 11 跳到 12）。 */
  streak?: number;
  due?: number;
};

export const TodayScreen: React.FC<Props> = ({ compact, composer, grow = 1, streak = today.streak, due = today.due }) => {
  const total = today.week.reduce((a, b) => a + b, 0);
  const area = compact
    ? { left: 0, width: iphone.width, top: iphone.statusBar }
    : { left: ipad.sidebar, width: ipad.width - ipad.sidebar, top: ipad.statusBar };
  return (
    <div style={{ position: 'absolute', left: area.left, top: 0, width: area.width, bottom: 0, background: color.groupedBackground }}>
      <div style={{ position: 'absolute', top: area.top, left: 0, right: 0, height: 52, display: 'flex', alignItems: 'center', padding: '0 16px' }}>
        {compact && <GlassCircle size={44}><Symbol name="chevron.left" size={18} /></GlassCircle>}
      </div>
      <div style={{ position: 'absolute', top: area.top + 52, left: 16, ...text.largeTitle }}>今天</div>
      <div
        style={{
          position: 'absolute',
          top: area.top + 52 + 41 + 12,
          left: compact ? 16 : (area.width - 720) / 2 + 16,
          width: compact ? area.width - 32 : 720 - 32,
          display: 'flex',
          flexDirection: 'column',
          gap: 16,
        }}
      >
        <div style={{ ...text.subheadline, color: color.secondary }}>{today.date}</div>
        <Composer placement="inline" width="100%" {...composer} />
        <Card>
          <CardTitle icon="arrow.counterclockwise.circle" title="复习" />
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 4 }}>
            <span style={{ ...text.largeTitle, fontVariantNumeric: 'tabular-nums' }}>{due}</span>
            <span style={{ ...text.body, color: color.secondary }}>道题今天要复习</span>
          </div>
          <div style={{ height: 50, borderRadius: 25, background: color.accent, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6, ...text.headline }}>
            <Symbol name="play.fill" size={15} />
            开始复习
          </div>
        </Card>
        <Card>
          <CardTitle icon="flame" title="学习" />
          <div style={{ display: 'flex', alignItems: 'flex-end', gap: 24 }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
              <span style={{ ...text.largeTitle, fontVariantNumeric: 'tabular-nums' }}>{streak}</span>
              <span style={{ ...text.caption, color: color.secondary }}>连续学习天数</span>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
              <span style={{ ...text.largeTitle, fontVariantNumeric: 'tabular-nums' }}>{Math.round(total * grow)}</span>
              <span style={{ ...text.caption, color: color.secondary }}>最近 7 天答题</span>
            </div>
            <div style={{ flex: 1 }} />
            <WeekBars counts={today.week} grow={grow} />
          </div>
        </Card>
        <Card style={{ flexDirection: 'row', alignItems: 'center' }}>
          <div style={{ width: 32, display: 'flex', justifyContent: 'center' }}>
            <Symbol name="bubble.left.and.text.bubble.right" size={20} color={color.accent} />
          </div>
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
            <span style={{ ...text.caption, color: color.secondary }}>继续上次的会话</span>
            <span style={{ ...text.body, fontWeight: 500 }}>{today.continueTitle}</span>
            <span style={{ ...text.caption2, color: color.tertiary }}>{today.continueTime}</span>
          </div>
          <Symbol name="chevron.right" size={12} color={color.tertiary} />
        </Card>
      </div>
    </div>
  );
};
