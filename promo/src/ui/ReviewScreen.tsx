import React from 'react';
import { color, ipad, radius, text } from './shared';
import { reviewMarkdown, reviewQuestion } from '../content';
import { Renderer, type Action } from './Renderer';
import { Symbol } from './Symbol';
import { GlassCircle } from './Glass';

// 复习：App/Study/ReviewSessionView.swift。测验类错题用测验组件在本地判分，答完下面出现结果卡片。

type Props = {
  actions: Action[];
  /** 显示的档位（从 1 开始）。答对后从 1 变成 2。 */
  box: number;
  /** 0 到 1：结果卡片出现的进度。 */
  result: number;
};

export const ReviewScreen: React.FC<Props> = ({ actions, box, result }) => {
  const width = ipad.width - ipad.sidebar;
  const contentWidth = 820 - 32;
  return (
    <div style={{ position: 'absolute', left: ipad.sidebar, top: 0, width, bottom: 0, background: color.background }}>
      <div style={{ position: 'absolute', top: ipad.statusBar, left: 0, right: 0, height: 52, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <GlassCircle size={44} style={{ position: 'absolute', left: 16 }}><Symbol name="chevron.left" size={18} /></GlassCircle>
        <span style={{ ...text.headline }}>复习 1 / 3</span>
      </div>
      <div style={{ position: 'absolute', top: ipad.statusBar + 52 + 16, left: (width - contentWidth) / 2, width: contentWidth, display: 'flex', flexDirection: 'column', gap: 16 }}>
        <div style={{ display: 'flex', ...text.caption, color: color.secondary }}>
          <span style={{ flex: 1 }}>{reviewQuestion.subject} · {reviewQuestion.topic}</span>
          <span>第 {box} 档</span>
        </div>
        <Renderer markdown={reviewMarkdown} width={contentWidth} actions={actions} options={{ recordsMistakes: false }} />
        <div
          style={{
            opacity: result,
            transform: `translateY(${(1 - result) * 12}px)`,
            background: color.secondaryBackground,
            borderRadius: radius.card,
            padding: 16,
            display: 'flex',
            flexDirection: 'column',
            gap: 10,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, ...text.body }}>
            <Symbol name="checkmark.circle.fill" size={17} color={color.success} />
            答对了，下次在 11月25日 复习
          </div>
          <div style={{ display: 'flex', alignItems: 'center' }}>
            <span style={{ display: 'flex', alignItems: 'center', gap: 6, ...text.body, color: color.accent, background: color.tertiaryFill, borderRadius: 999, padding: '7px 14px' }}>
              <Symbol name="sparkles" size={15} />
              再来几道类似的
            </span>
            <div style={{ flex: 1 }} />
            <span style={{ ...text.body, fontWeight: 600, color: '#fff', background: color.accent, borderRadius: 999, padding: '7px 16px' }}>下一题</span>
          </div>
        </div>
      </div>
    </div>
  );
};
