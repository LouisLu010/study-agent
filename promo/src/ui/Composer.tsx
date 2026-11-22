import React from 'react';
import { color, model, radius, text } from './shared';
import { Symbol } from './Symbol';
import { glass } from './Glass';

// 输入框：App/Views/ComposerView.swift。"今天"页上是实心卡片（inline），聊天页底部是浮起的玻璃卡片（chat）。

type Props = {
  placement: 'inline' | 'chat';
  /** 已经打出来的字；空的时候显示占位文字。 */
  value?: string;
  caret?: boolean;
  /** 按下发送键的那几帧：按钮缩小一点。 */
  pressing?: boolean;
  width: number | string;
};

export const Composer: React.FC<Props> = ({ placement, value = '', caret, pressing, width }) => {
  const placeholder = placement === 'inline' ? '问点什么' : '发消息';
  const canSend = value.trim().length > 0;
  const surface: React.CSSProperties =
    placement === 'inline'
      ? { background: color.groupedCard, boxShadow: '0 3px 10px rgba(0,0,0,0.06)' }
      : { ...glass, boxShadow: `${glass.boxShadow}, 0 4px 12px rgba(0,0,0,0.08)` };
  return (
    <div style={{ width, borderRadius: radius.field, padding: 8, display: 'flex', flexDirection: 'column', gap: 8, ...surface }}>
      <div style={{ ...text.body, padding: '4px 8px 0', minHeight: placement === 'inline' ? 44 : 22, color: value ? color.label : color.tertiary }}>
        {value || (caret ? '' : placeholder)}
        {caret && <span style={{ display: 'inline-block', width: 2, height: 21, marginLeft: 1, verticalAlign: -4, background: color.accent, borderRadius: 1 }} />}
        {caret && !value && <span style={{ color: color.tertiary }}>{placeholder}</span>}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
        <IconButton><Symbol name="plus" size={20} color={color.accent} /></IconButton>
        <IconButton><Symbol name="globe" size={20} color={color.accent} /></IconButton>
        <div style={{ display: 'flex', alignItems: 'center', gap: 4, ...text.subheadline, color: color.secondary, padding: '6px 12px', borderRadius: 999, background: color.tertiaryFill }}>
          <span>{model}</span>
          <Symbol name="chevron.up.chevron.down" size={10} />
        </div>
        <div style={{ flex: 1 }} />
        <div
          style={{
            width: 34,
            height: 34,
            borderRadius: 17,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            background: canSend ? color.accent : color.tertiaryFill,
            transform: pressing ? 'scale(0.86)' : 'none',
          }}
        >
          <Symbol name="arrow.up" size={16} color={canSend ? '#fff' : color.tertiary} />
        </div>
      </div>
    </div>
  );
};

const IconButton: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div style={{ width: 34, height: 34, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{children}</div>
);
