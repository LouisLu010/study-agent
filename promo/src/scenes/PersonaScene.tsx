import React from 'react';
import { useCurrentFrame } from 'remotion';
import { color, ipad, text } from '../theme';
import { conversations, persona } from '../content';
import { ChatScreen, chat } from '../ui/ChatScreen';
import { Sidebar } from '../ui/Sidebar';
import { IPadStage, smooth, type Focus } from '../ui/Stage';
import { Symbol } from '../ui/Symbol';
import personas from '../../../StudyKit/Sources/StudyKit/Prompts/personas.json';

// 人格（1.0 新增）：点会话标题弹出菜单，选"启发式"，回答变成一步步提问；回答下面出现快捷追问。
// 菜单照 App/Views/PersonaPicker.swift 的 ConversationPersonaMenu，快捷追问照 MessageRow.swift。

const thinkingUntil = 100;

const Menu: React.FC<{ open: number; selected: string; pressed: string | null }> = ({ open, selected, pressed }) => {
  if (open <= 0) return null;
  const width = 300;
  return (
    <div
      style={{
        position: 'absolute',
        left: chat.width / 2 - width / 2,
        top: chat.navHeight + 4,
        width,
        borderRadius: 16,
        overflow: 'hidden',
        background: 'rgba(37,37,40,0.94)',
        backdropFilter: 'blur(30px)',
        boxShadow: '0 18px 50px rgba(0,0,0,0.55), inset 0 0 0 0.5px rgba(255,255,255,0.12)',
        opacity: open,
        transform: `scale(${0.9 + open * 0.1})`,
        transformOrigin: '50% 0',
      }}
    >
      <div style={{ ...text.footnote, color: color.secondary, padding: '10px 16px 6px' }}>人格</div>
      {[{ id: '', name: '跟随默认（标准）', summary: '' }, ...personas].map((item, i) => {
        const isSelected = item.id === selected;
        return (
          <div
            key={item.id || 'default'}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 10,
              padding: '9px 16px',
              background: pressed === item.id ? 'rgba(255,255,255,0.12)' : 'transparent',
              borderTop: i === 1 ? `6px solid rgba(0,0,0,0.35)` : `0.5px solid ${color.separator}`,
            }}
          >
            <span style={{ width: 18, display: 'flex', justifyContent: 'center' }}>
              {isSelected && <Symbol name="checkmark" size={14} color={color.label} />}
            </span>
            <span style={{ display: 'flex', flexDirection: 'column' }}>
              <span style={{ ...text.body }}>{item.name}</span>
              {item.summary && <span style={{ ...text.caption, color: color.secondary }}>{item.summary}</span>}
            </span>
          </div>
        );
      })}
    </div>
  );
};

const FollowUps: React.FC<{ show: number; pressed: number | null }> = ({ show, pressed }) => (
  <div style={{ display: 'flex', gap: 8, marginTop: 14, opacity: show, transform: `translateY(${(1 - show) * 10}px)` }}>
    {persona.followUps.map((label, i) => (
      <span
        key={label}
        style={{
          ...text.subheadline,
          color: color.label,
          padding: '6px 14px',
          borderRadius: 999,
          background: pressed === i ? 'rgba(120,120,128,0.5)' : color.tertiaryFill,
          border: '0.5px solid rgba(255,255,255,0.12)',
          opacity: show > 0 ? Math.min(1, show * 3 - i * 0.6) : 0,
        }}
      >
        {label}
      </span>
    ))}
  </div>
);

export const PersonaScene: React.FC = () => {
  const frame = useCurrentFrame();
  const title = conversations.find((c) => c.id === 'persona')!.title;
  const answered = frame >= thinkingUntil;

  // 镜头：推近到聊天这一栏（菜单和回答都在里面），最后拉远回整台 iPad，接下一段。
  const focus: Focus = { x: chat.contentLeft - 40, y: 0, width: chat.contentWidth + 80, height: ipad.height - 140 };
  const zoom = smooth(frame, [16, 44]) * (1 - smooth(frame, [190, 222]));

  const open = smooth(frame, [26, 34]) * (1 - smooth(frame, [64, 72]));
  const selected = frame >= 54 ? 'socratic' : '';
  const pressed = frame >= 48 && frame < 60 ? 'socratic' : null;

  return (
    <>
      <IPadStage focus={focus} zoom={zoom}>
        <Sidebar selection="persona" due={3} generating={frame >= 72 && !answered ? 'persona' : undefined} />
        <ChatScreen
          title={title}
          question={persona.question}
          answer={persona.answer}
          // 先只有提问和菜单；选好人格后才开始"正在思考…"，再出回答。
          thinking={frame >= 72 && !answered}
          answerOpacity={answered ? smooth(frame, [thinkingUntil, thinkingUntil + 10]) : 0}
          overlay={<Menu open={open} selected={selected} pressed={pressed} />}
          footer={<FollowUps show={smooth(frame, [146, 162])} pressed={frame >= 176 && frame < 184 ? 2 : null} />}
        />
      </IPadStage>
      <div style={{ position: 'absolute', inset: 0, opacity: zoom, background: 'linear-gradient(90deg, #000 0, #000 620px, rgba(0,0,0,0.85) 700px, rgba(0,0,0,0) 790px)', zIndex: 10 }} />
    </>
  );
};
