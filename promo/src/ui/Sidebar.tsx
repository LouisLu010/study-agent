import React from 'react';
import { color, ipad, model, text } from './shared';
import { conversations } from '../content';
import { Symbol } from './Symbol';
import { Orb } from './Orb';
import { GlassCircle } from './Glass';

// 侧栏：App/Views/ConversationListView.swift。insetGrouped 列表，入口图标用主题色。

export type SidebarSelection = 'today' | 'mistakes' | 'review' | 'compilations' | string;

const entries = [
  { section: '学习', items: [
    { id: 'mistakes', title: '错题本', icon: 'exclamationmark.bubble' },
    { id: 'review', title: '复习', icon: 'arrow.counterclockwise.circle', badge: true },
    { id: 'bookmarks', title: '收藏', icon: 'bookmark' },
    { id: 'stats', title: '学习记录', icon: 'chart.bar' },
  ] },
  { section: '资料库', items: [
    { id: 'notes', title: '资料', icon: 'doc.text.magnifyingglass' },
    { id: 'compilations', title: '汇编', icon: 'books.vertical' },
  ] },
];

const Card: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div style={{ margin: '0 16px', background: color.sidebarCard, borderRadius: 22, overflow: 'hidden' }}>{children}</div>
);

const Header: React.FC<{ title: string }> = ({ title }) => (
  <div style={{ ...text.subheadline, fontWeight: 600, color: color.secondary, padding: '22px 32px 8px' }}>{title}</div>
);

const Row: React.FC<{ selected?: boolean; last?: boolean; children: React.ReactNode; height?: number }> = ({ selected, last, children, height = 48 }) => (
  <div style={{ position: 'relative', minHeight: height, display: 'flex', alignItems: 'center', padding: '0 16px', background: selected ? color.sidebarSelected : 'transparent' }}>
    {children}
    {!last && !selected && <div style={{ position: 'absolute', left: 56, right: 0, bottom: 0, height: 0.5, background: color.separator }} />}
  </div>
);

export const Sidebar: React.FC<{ selection: SidebarSelection; due?: number; generating?: string }> = ({ selection, due = 0, generating }) => (
  <div style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: ipad.sidebar, background: color.sidebar, paddingTop: ipad.statusBar }}>
    <div style={{ height: 60, display: 'flex', alignItems: 'center', padding: '0 12px', gap: 10 }}>
      <GlassCircle size={44}><Symbol name="gearshape" size={20} /></GlassCircle>
      <div style={{ flex: 1, textAlign: 'center', ...text.headline }}>格物</div>
      <GlassCircle size={44}><Symbol name="square.and.pencil" size={20} /></GlassCircle>
      <GlassCircle size={44}><Symbol name="sidebar.left" size={20} /></GlassCircle>
    </div>
    <div style={{ height: 12 }} />
    <Card>
      <Row selected={selection === 'today'} last>
        <Symbol name="sun.max" size={20} color={color.accent} style={{ width: 28 }} />
        <span style={{ ...text.body, marginLeft: 12 }}>今天</span>
      </Row>
    </Card>
    {entries.map((group) => (
      <React.Fragment key={group.section}>
        <Header title={group.section} />
        <Card>
          {group.items.map((item, i) => (
            <Row key={item.id} selected={selection === item.id} last={i === group.items.length - 1}>
              <Symbol name={item.icon} size={20} color={color.accent} style={{ width: 28 }} />
              <span style={{ ...text.body, marginLeft: 12, flex: 1 }}>{item.title}</span>
              {item.badge && due > 0 && <span style={{ ...text.body, color: color.secondary }}>{due}</span>}
            </Row>
          ))}
        </Card>
      </React.Fragment>
    ))}
    <Header title="会话" />
    <Card>
      {conversations.map((c, i) => (
        <Row key={c.id} selected={selection === c.id} last={i === conversations.length - 1} height={60}>
          <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2, padding: '9px 0' }}>
            <span style={{ ...text.body, fontWeight: 500, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{c.title}</span>
            <span style={{ ...text.caption2, color: color.secondary }}>{model} · {c.time}</span>
          </div>
          {generating === c.id && <Orb state="working" size={16} />}
        </Row>
      ))}
    </Card>
  </div>
);
