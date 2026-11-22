import React from 'react';
import { color, ipad, model, radius, text } from './shared';
import { Renderer, type Action, type Rect } from './Renderer';
import { Composer } from './Composer';
import { Symbol } from './Symbol';
import { Orb } from './Orb';
import { GlassCircle } from './Glass';

// 聊天页：App/Views/ChatView.swift、MessageRow.swift。内容最宽 820，四周留 16；回答没有气泡，上方写模型名。

export const chat = {
  left: ipad.sidebar,
  width: ipad.width - ipad.sidebar,
  navHeight: ipad.statusBar + 52,
  columnWidth: 820,
  get contentLeft() {
    return this.left + (this.width - this.columnWidth) / 2 + 16;
  },
  contentWidth: 820 - 32,
  /** 用户气泡（一行）+ 间距 + 模型名，回答正文从这里开始。 */
  get answerTop() {
    return this.navHeight + 16 + 42 + 24 + 16 + 8;
  },
};

type Props = {
  title: string;
  question: string;
  answer: string;
  actions?: Action[];
  /** 往上滚了多少 pt。 */
  scroll?: number;
  /** 回答还在生成：显示小球，不显示操作栏。 */
  thinking?: boolean;
  composer?: { value?: string; caret?: boolean; pressing?: boolean };
  onLayout?: (layout: { height: number; rects: Rect[] }) => void;
};

export const ChatScreen: React.FC<Props> = ({ title, question, answer, actions, scroll = 0, thinking, composer, onLayout }) => (
  <div style={{ position: 'absolute', left: chat.left, top: 0, width: chat.width, bottom: 0, background: color.background, overflow: 'hidden' }}>
    <div style={{ position: 'absolute', left: chat.contentLeft - chat.left, width: chat.contentWidth, top: chat.navHeight + 16 - scroll }}>
      <div style={{ display: 'flex', justifyContent: 'flex-end', paddingLeft: 48 }}>
        <div style={{ ...text.body, background: color.secondaryFill, borderRadius: radius.field, padding: '10px 14px' }}>{question}</div>
      </div>
      <div style={{ height: 24 }} />
      <div style={{ ...text.caption, fontWeight: 500, color: color.secondary, height: 16 }}>{model}</div>
      <div style={{ height: 8 }} />
      {thinking ? (
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, ...text.subheadline, color: color.secondary }}>
          <Orb state="reasoning" size={18} />
          正在思考…
        </div>
      ) : (
        <>
          <Renderer markdown={answer} width={chat.contentWidth} actions={actions} onLayout={onLayout} />
          <div style={{ display: 'flex', gap: 16, marginTop: 8, color: color.secondary }}>
            {['doc.on.doc', 'arrow.clockwise', 'bookmark', 'doc.text.magnifyingglass', 'square.and.arrow.up'].map((name) => (
              <Symbol key={name} name={name} size={15} />
            ))}
          </div>
          <div style={{ ...text.caption2, color: color.tertiary, marginTop: 8 }}>输入 2,310（缓存 1,840） · 输出 640 tokens · 约 ¥0.003</div>
        </>
      )}
    </div>

    {/* 顶部导航栏：iOS 26 滚到下面的内容渐渐模糊（scroll edge effect）。 */}
    <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: chat.navHeight + 20, background: 'linear-gradient(#000 55%, rgba(0,0,0,0))', backdropFilter: 'blur(6px)', WebkitMaskImage: 'linear-gradient(#000 60%, transparent)' }} />
    <div style={{ position: 'absolute', top: ipad.statusBar, left: 0, right: 0, height: 52, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6 }}>
      <span style={{ ...text.headline }}>{title}</span>
      <GlassCircle size={20}><Symbol name="chevron.down" size={9} /></GlassCircle>
    </div>

    {/* 底部：safeAreaBar 的渐变模糊，上面浮着输入框。 */}
    <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0, height: 150, background: 'linear-gradient(rgba(0,0,0,0), rgba(0,0,0,0.85) 60%)', backdropFilter: 'blur(4px)', WebkitMaskImage: 'linear-gradient(transparent, #000 45%)' }} />
    <div style={{ position: 'absolute', bottom: 8 + 20, left: (chat.width - chat.columnWidth) / 2 + 12, width: chat.columnWidth - 24 }}>
      <Composer placement="chat" width="100%" {...composer} />
    </div>
  </div>
);
