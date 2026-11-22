import React, { useState } from 'react';
import { useCurrentFrame } from 'remotion';
import { ipad } from '../theme';
import { conversations } from '../content';
import { ChatScreen, chat } from '../ui/ChatScreen';
import { Sidebar } from '../ui/Sidebar';
import { IPadStage, smooth, type Focus } from '../ui/Stage';
import type { Action, Rect } from '../ui/Renderer';

// 交互式回答的一段：一开始镜头贴在组件卡片上，演示完拉远，露出整台 iPad（Q16）。

type Props = {
  id: string;
  question: string;
  answer: string;
  actions: Action[];
  /** 从哪一帧开始拉远，拉多久。 */
  zoomOut: [number, number];
  /** 一开始从整台 iPad 推近（第一段用，接在开场后面）。 */
  zoomIn?: [number, number];
  /** 演示中途再往下滚一段，像手指往上推：[开始帧, 结束帧, 多滚几 pt]。 */
  scrollBy?: [number, number, number];
};

export const ChatScene: React.FC<Props> = ({ id, question, answer, actions, zoomOut, zoomIn, scrollBy }) => {
  const frame = useCurrentFrame();
  const [rect, setRect] = useState<Rect | null>(null);
  const title = conversations.find((c) => c.id === id)!.title;

  // 往上滚到卡片顶边停在导航栏下面（上面那段文字滚走），镜头只拍导航栏和输入框之间露出来的部分。
  const visibleTop = chat.navHeight + 8;
  const visibleBottom = ipad.height - 140;
  const extra = scrollBy ? smooth(frame, [scrollBy[0], scrollBy[1]], 0, scrollBy[2]) : 0;
  const scroll = rect ? Math.max(0, chat.answerTop + rect.y - visibleTop) + extra : 0;
  const focus: Focus | null = rect
    ? {
        x: chat.contentLeft + rect.x - 12,
        y: chat.answerTop + rect.y - scroll - 8 + extra,
        width: rect.width + 24,
        height: Math.min(rect.height, visibleBottom - visibleTop) + 16,
      }
    : null;
  const zoom = Math.min(zoomIn ? smooth(frame, zoomIn) : 1, 1 - smooth(frame, zoomOut));

  return (
    <>
      <IPadStage focus={focus} zoom={zoom}>
        <Sidebar selection={id} due={3} />
        <ChatScreen title={title} question={question} answer={answer} actions={actions} scroll={scroll} onLayout={(l) => setRect(l.rects[0] ?? null)} />
      </IPadStage>
      {/* 特写时侧栏会被推到字幕底下，用一层渐黑盖住，字幕才看得清。 */}
      <div style={{ position: 'absolute', inset: 0, opacity: zoom, background: 'linear-gradient(90deg, #000 0, #000 620px, rgba(0,0,0,0.85) 700px, rgba(0,0,0,0) 790px)', zIndex: 10 }} />
    </>
  );
};

/** 从 from 到 to 帧把滑块从 a 拖到 b：按下、逐帧移动（先快后慢）、松手。 */
export function drag(selector: string, from: number, to: number, a: number, b: number, nth = 0): Action[] {
  const actions: Action[] = [{ frame: from, slider: { selector, nth, phase: 'begin' } }];
  for (let f = from + 1; f < to; f++) {
    const t = (f - from) / (to - from);
    const eased = t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2;
    actions.push({ frame: f, slider: { selector, nth, value: Math.round((a + (b - a) * eased) * 100) / 100, phase: 'move' } });
  }
  actions.push({ frame: to, slider: { selector, nth, value: b, phase: 'end' } });
  return actions;
}
