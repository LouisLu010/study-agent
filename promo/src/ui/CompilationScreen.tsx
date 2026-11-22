import React from 'react';
import { color, ipad, model, text } from './shared';
import { compilation, toolLog, type LogKind } from '../content';
import { Symbol } from './Symbol';
import { Orb } from './Orb';
import { GlassCircle, glass } from './Glass';

// 汇编：App/Library/CompilationsView.swift（新建、确认试卷、收集中的详情页）和 CollectionActivityView.swift（调用记录）。

const width = ipad.width - ipad.sidebar;
const margin = 20;

const Section: React.FC<{ header?: string; footer?: React.ReactNode; children: React.ReactNode }> = ({ header, footer, children }) => (
  <div style={{ display: 'flex', flexDirection: 'column' }}>
    {header && <div style={{ ...text.subheadline, fontWeight: 600, color: color.secondary, padding: '0 16px 8px' }}>{header}</div>}
    <div style={{ background: color.groupedCard, borderRadius: 22, overflow: 'hidden' }}>{children}</div>
    {footer && <div style={{ ...text.footnote, color: color.secondary, padding: '8px 16px 0' }}>{footer}</div>}
  </div>
);

const Row: React.FC<{ children: React.ReactNode; last?: boolean; pad?: string }> = ({ children, last, pad = '12px 16px' }) => (
  <div style={{ position: 'relative', padding: pad, display: 'flex', alignItems: 'center', gap: 12 }}>
    {children}
    {!last && <div style={{ position: 'absolute', left: 16, right: 0, bottom: 0, height: 0.5, background: color.separator }} />}
  </div>
);

const Toggle: React.FC<{ on: boolean }> = ({ on }) => (
  <div style={{ width: 64, height: 28, borderRadius: 14, background: on ? '#30D158' : color.fill, padding: 2, display: 'flex', justifyContent: on ? 'flex-end' : 'flex-start', flex: 'none' }}>
    <div style={{ width: 38, height: 24, borderRadius: 12, background: '#fff' }} />
  </div>
);

const NavBar: React.FC<{ title: string; back?: boolean }> = ({ title, back = true }) => (
  <div style={{ position: 'absolute', top: ipad.statusBar, left: 0, right: 0, height: 52, display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 2 }}>
    {back && <GlassCircle size={44} style={{ position: 'absolute', left: 16 }}><Symbol name="chevron.left" size={18} /></GlassCircle>}
    <span style={{ ...text.headline }}>{title}</span>
  </div>
);

// ---------- 新建汇编 ----------

export const NewCompilationSheet: React.FC<{ typed: string; caret: boolean; pressing: boolean; appear: number }> = ({ typed, caret, pressing, appear }) => (
  <div style={{ position: 'absolute', inset: 0, background: `rgba(0,0,0,${0.45 * appear})` }}>
    <div
      style={{
        position: 'absolute',
        left: (ipad.width - 620) / 2,
        top: 140 + (1 - appear) * 700,
        width: 620,
        height: 640,
        borderRadius: 32,
        background: color.secondaryBackground,
        padding: '0 20px',
        boxShadow: '0 30px 80px rgba(0,0,0,0.5)',
      }}
    >
      <div style={{ height: 64, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <span style={{ ...text.body, padding: '8px 16px', borderRadius: 999, ...glass }}>取消</span>
        <span style={{ ...text.headline }}>新建汇编</span>
        <span style={{ ...text.body, fontWeight: 600, padding: '8px 16px', borderRadius: 999, background: typed ? color.accent : color.tertiaryFill, color: typed ? '#fff' : color.tertiary, transform: pressing ? 'scale(0.92)' : 'none' }}>查找试卷</span>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 28, marginTop: 16 }}>
        <div>
          <div style={{ ...text.footnote, color: color.secondary, padding: '0 16px 8px' }}>要什么题</div>
          <div style={{ background: color.tertiaryBackground, borderRadius: 22, padding: '12px 16px', minHeight: 70, ...text.body, color: typed ? color.label : color.tertiary }}>
            {typed || (caret ? '' : '例如：近 3 年高考有机大题')}
            {caret && <span style={{ display: 'inline-block', width: 2, height: 21, marginLeft: 1, verticalAlign: -4, background: color.accent }} />}
          </div>
          <div style={{ ...text.footnote, color: color.secondary, padding: '8px 16px 0' }}>考试类型不限：高考、中考、各地模拟考都可以。说得越具体，找得越准，例如年份范围、地区、题型。</div>
        </div>
        <div>
          <div style={{ background: color.tertiaryBackground, borderRadius: 22, padding: '14px 16px', display: 'flex', ...text.body }}>
            <span style={{ flex: 1 }}>模型</span>
            <span style={{ color: color.secondary, display: 'flex', alignItems: 'center', gap: 4 }}>{model}<Symbol name="chevron.up.chevron.down" size={11} /></span>
          </div>
          <div style={{ ...text.footnote, color: color.secondary, padding: '8px 16px 0' }}>先列出试卷给你确认，确认后模型逐份试卷调用 App 的工具：搜索、读网页、取原题，最后整理顺序并生成 PDF。</div>
        </div>
      </div>
    </div>
  </div>
);

// ---------- 详情页 ----------

const logIcon: Record<LogKind, { name: string; color: string }> = {
  step: { name: 'arrow.right.circle', color: color.accent },
  search: { name: 'magnifyingglass', color: color.secondary },
  page: { name: 'globe', color: color.secondary },
  success: { name: 'checkmark.circle.fill', color: color.success },
  warning: { name: 'exclamationmark.circle', color: color.orange },
};

const questionsFound = [
  { label: '2025 · 北京卷 · 第 17 题', excerpt: '有机物 K 是合成一种药物的中间体，其合成路线如下（部分条件已略去）：……' },
  { label: '2025 · 新课标卷 · 第 29 题', excerpt: '化合物 H 是一种具有抗炎活性的药物，以 A 为原料合成 H 的路线如下：……' },
  { label: '2025 · 全国甲卷 · 第 36 题', excerpt: '[化学——选修 5：有机化学基础] 以芳香烃 A 为原料合成 G 的路线如下：……' },
  { label: '2024 · 北京卷 · 第 17 题', excerpt: '某抗病毒药物的中间体 J 的合成路线如下：……' },
];

type DetailProps = {
  phase: 'choosing' | 'collecting';
  /** 调用记录已经出现了几行。 */
  lines: number;
  searches: number;
  elapsed: string;
  cost: string;
  pressing?: boolean;
};

export const CompilationDetail: React.FC<DetailProps> = ({ phase, lines, searches, elapsed, cost, pressing }) => {
  const visible = toolLog.slice(0, lines);
  // 开始查第 k 份时，前面 k − 1 份已经查完。
  const done = Math.max(0, visible.filter((l) => l.kind === 'step').length - 1);
  const current = [...visible].reverse().find((l) => l.kind === 'step');
  const found = visible.filter((l) => l.text.startsWith('获取第')).length;
  const last = visible[visible.length - 1];
  return (
    <div style={{ position: 'absolute', left: ipad.sidebar, top: 0, width, bottom: 0, background: color.groupedBackground, overflow: 'hidden' }}>
      <NavBar title={compilation.request} />
      <div style={{ position: 'absolute', top: ipad.statusBar + 52 + 20, left: margin, right: margin, display: 'flex', flexDirection: 'column', gap: 28 }}>
        <Section>
          <Row last>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <span style={{ ...text.body }}>{compilation.request}</span>
              <span style={{ ...text.caption, color: color.secondary }}>{model} · 搜索 {searches} 次 · {cost}</span>
            </div>
          </Row>
        </Section>

        {phase === 'choosing' ? (
          <>
            <Section header={`找到 ${compilation.papers.length} 份试卷`} footer={compilation.estimate}>
              {compilation.papers.map((p, i) => (
                <Row key={p.title} last={i === compilation.papers.length - 1} pad="9px 16px">
                  <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
                    <span style={{ ...text.body }}>{p.title}</span>
                    <span style={{ ...text.caption, color: color.secondary }}>{p.year}</span>
                  </div>
                  <Toggle on />
                </Row>
              ))}
            </Section>
            <Section>
              <Row>
                <span style={{ display: 'flex', alignItems: 'center', gap: 10, ...text.body, color: color.accent, opacity: pressing ? 0.5 : 1 }}>
                  <Symbol name="play.fill" size={16} />
                  开始收集 {compilation.papers.length} 份试卷
                </span>
              </Row>
              <Row last>
                <span style={{ display: 'flex', alignItems: 'center', gap: 10, ...text.body, color: color.accent }}>
                  <Symbol name="arrow.clockwise" size={16} />
                  重新查找试卷
                </span>
              </Row>
            </Section>
          </>
        ) : (
          <>
            <Section>
              <Row pad="14px 16px">
                <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <div style={{ height: 4, borderRadius: 2, background: color.tertiaryFill, overflow: 'hidden' }}>
                    <div style={{ width: `${(done / compilation.papers.length) * 100}%`, height: '100%', background: color.accent, borderRadius: 2 }} />
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, ...text.callout, color: color.secondary }}>
                    <Orb state="background" size={20} />
                    正在查第 {Math.min(done + 1, compilation.papers.length)}/{compilation.papers.length} 份：{current ? current.text.replace(/^第 \d+\/\d+ 份：/, '') : '…'}
                  </div>
                </div>
              </Row>
              <Row>
                <span style={{ display: 'flex', alignItems: 'center', gap: 10, ...text.callout, color: color.secondary }}>
                  <Symbol name="location.fill" size={15} />
                  强力保活中，可以切到别的 App
                </span>
              </Row>
              <Row>
                <span style={{ display: 'flex', alignItems: 'center', gap: 10, ...text.body, color: color.red }}>
                  <Symbol name="stop.fill" size={15} />
                  停止
                </span>
              </Row>
              <Row pad="12px 16px">
                <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 8, padding: '4px 0' }}>
                  <div style={{ display: 'flex', alignItems: 'baseline' }}>
                    <span style={{ ...text.subheadline, fontWeight: 600, flex: 1 }}>调用记录</span>
                    <span style={{ ...text.caption, color: color.secondary, fontVariantNumeric: 'tabular-nums' }}>已搜索 {searches} 次 · {elapsed}</span>
                  </div>
                  {visible.slice(-6).map((line, i, shown) => {
                    const isLast = i === shown.length - 1;
                    const icon = logIcon[line.kind];
                    return (
                      <div key={line.text + line.time} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '3px 0' }}>
                        <div style={{ width: 16, display: 'flex', justifyContent: 'center' }}>
                          {isLast && line === last ? <Orb state={line.kind === 'search' ? 'searching' : 'background'} size={14} /> : <Symbol name={icon.name} size={12} color={icon.color} />}
                        </div>
                        <span style={{ ...text.footnote, color: isLast ? color.label : color.secondary, flex: 1 }}>{line.text}</span>
                        <span style={{ ...text.caption2, color: color.tertiary, fontVariantNumeric: 'tabular-nums' }}>{line.time}</span>
                      </div>
                    );
                  })}
                </div>
              </Row>
              <Row last>
                <span style={{ ...text.body, flex: 1 }}>试卷（{done}/{compilation.papers.length}）</span>
                <Symbol name="chevron.right" size={12} color={color.accent} />
              </Row>
            </Section>
            {found > 0 && (
              <Section header={`${found} 题`}>
                {questionsFound.slice(0, found).map((q, i) => (
                  <Row key={q.label} last={i === found - 1} pad="10px 16px">
                    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 4 }}>
                      <span style={{ ...text.callout, fontWeight: 700 }}>{q.label}</span>
                      <span style={{ ...text.caption, color: color.secondary }}>{q.excerpt}</span>
                    </div>
                    <Symbol name="chevron.right" size={12} color={color.tertiary} />
                  </Row>
                ))}
              </Section>
            )}
          </>
        )}
      </div>
    </div>
  );
};

export const pdfQuestions = questionsFound;
