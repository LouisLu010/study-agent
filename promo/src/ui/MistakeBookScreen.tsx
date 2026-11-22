import React from 'react';
import { color, ipad, text } from './shared';
import { mistakes } from '../content';
import { Symbol } from './Symbol';
import { glass } from './Glass';

// 错题本：App/Study/MistakeBookView.swift 和 App/Design/LibraryRow.swift。insetGrouped 列表。

export const SubjectTag: React.FC<{ text: string }> = ({ text: label }) => (
  <span style={{ ...text.caption2, fontWeight: 600, color: color.accent, background: color.accentFill, borderRadius: 999, padding: '2px 8px' }}>{label}</span>
);

const Chip: React.FC<{ label: string; selected?: boolean }> = ({ label, selected }) => (
  <span style={{ ...text.subheadline, padding: '6px 12px', borderRadius: 999, background: selected ? color.accent : color.secondaryFill, color: selected ? '#fff' : color.label }}>{label}</span>
);

type Props = {
  /** 0 到 1：第一行（刚加入的错题）插进来的进度。 */
  insert?: number;
  /** 0 到 1：第一行的淡蓝色高亮，插进来以后慢慢褪掉。 */
  flash?: number;
  /** "开始复习"那一行被按下。 */
  pressReview?: boolean;
};

export const MistakeBookScreen: React.FC<Props> = ({ insert = 1, flash = 0, pressReview }) => {
  const width = ipad.width - ipad.sidebar;
  const margin = 20;
  const rowHeight = 86;
  return (
    <div style={{ position: 'absolute', left: ipad.sidebar, top: 0, width, bottom: 0, background: color.groupedBackground }}>
      <div style={{ position: 'absolute', top: ipad.statusBar + 4, right: 16, width: 300, height: 44, borderRadius: 22, display: 'flex', alignItems: 'center', gap: 8, padding: '0 14px', ...glass, ...text.body, color: color.secondary }}>
        <Symbol name="magnifyingglass" size={16} />
        搜索题目、知识点或备注
      </div>
      <div style={{ position: 'absolute', top: ipad.statusBar + 52, left: margin, ...text.largeTitle }}>错题本</div>
      <div style={{ position: 'absolute', top: ipad.statusBar + 52 + 41 + 16, left: margin, right: margin, display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ height: 32, borderRadius: 16, background: color.tertiaryFill, display: 'flex', padding: 2 }}>
          {['待复习', '全部', '已掌握'].map((label) => (
            <div key={label} style={{ flex: 1, borderRadius: 14, display: 'flex', alignItems: 'center', justifyContent: 'center', ...text.footnote, fontWeight: label === '全部' ? 600 : 500, background: label === '全部' ? 'rgba(118,118,128,0.48)' : 'transparent' }}>
              {label}
            </div>
          ))}
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          {['全部科目', '数学', '物理', '化学'].map((label, i) => <Chip key={label} label={label} selected={i === 0} />)}
        </div>
        <div style={{ height: 8 }} />
        <div style={{ background: pressReview ? color.tertiaryBackground : color.groupedCard, borderRadius: 22, height: 52, display: 'flex', alignItems: 'center', padding: '0 16px', gap: 12 }}>
          <Symbol name="play.circle.fill" size={20} color={color.accent} />
          <span style={{ ...text.headline, flex: 1 }}>开始复习（今天 3 道）</span>
          <Symbol name="chevron.right" size={12} color={color.tertiary} />
        </div>
        <div style={{ height: 8 }} />
        <div style={{ background: color.groupedCard, borderRadius: 22, overflow: 'hidden', height: rowHeight * (mistakes.length - 1 + insert) }}>
          {mistakes.map((m, i) => (
            <div
              key={m.title}
              style={{
                position: 'relative',
                height: rowHeight,
                display: 'flex',
                alignItems: 'center',
                padding: '0 16px',
                gap: 12,
                marginTop: i === 0 ? -rowHeight * (1 - insert) : 0,
                opacity: i === 0 ? insert : 1,
                background: i === 0 ? `rgba(77,142,255,${0.18 * flash})` : 'transparent',
              }}
            >
              <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 4 }}>
                <span style={{ ...text.body, fontWeight: 500, display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden' }}>{m.title}</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <SubjectTag text={m.subject} />
                  <span style={{ ...text.caption, color: color.tertiary }}>{m.meta}</span>
                </div>
              </div>
              <Symbol name="chevron.right" size={12} color={color.tertiary} />
              {i < mistakes.length - 1 && <div style={{ position: 'absolute', left: 16, right: 0, bottom: 0, height: 0.5, background: color.separator }} />}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};
