import React from 'react';
import { AbsoluteFill, Sequence, interpolate, useCurrentFrame } from 'remotion';
import { color, font } from '../theme';
import { compilation, pendulum, toolLog } from '../content';
import { Orb } from '../ui/Orb';
import { AppIcon, VersionPill } from '../ui/Brand';
import { Symbol } from '../ui/Symbol';
import { Composer } from '../ui/Composer';
import { Sidebar } from '../ui/Sidebar';
import { TodayScreen } from '../ui/TodayScreen';
import { MistakeBookScreen } from '../ui/MistakeBookScreen';
import { ReviewScreen } from '../ui/ReviewScreen';
import { CompilationDetail, NewCompilationSheet } from '../ui/CompilationScreen';
import { PdfPage, a4 } from '../ui/PdfPage';
import { IPadStage, IPhoneStage, detailFocus, detailZoom, smooth, video } from '../ui/Stage';

const clamp = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;

/** 打字：从 start 帧开始每 perChar 帧出一个字。 */
export function typed(full: string, frame: number, start: number, perChar = 2.2) {
  const chars = Array.from(full);
  return chars.slice(0, Math.max(0, Math.floor((frame - start) / perChar))).join('');
}

// ---------- 开场 ----------
// 1.0 版：先是图标、"格物"、一句介绍和"1.0 正式版"，然后图标的位置换成小球，输入框上来，打出第一个问题并发送。

export const Opening: React.FC = () => {
  const frame = useCurrentFrame();
  const icon = smooth(frame, [8, 30]);
  const title = interpolate(frame, [22, 40], [0, 1], clamp);
  const tagline = interpolate(frame, [36, 54], [0, 1], clamp);
  const pill = interpolate(frame, [48, 64], [0, 1], clamp);
  const lift = smooth(frame, [82, 104]);
  const composerIn = smooth(frame, [88, 108]);
  const value = typed(pendulum.question, frame, 110, 2);
  const sent = frame >= 150;
  // 发送后输入框和小球稍微放大一点，接着下一段（iPad 上的这次提问）从上面淡入。
  const push = smooth(frame, [152, 189]);
  const intro = 1 - lift;
  return (
    <AbsoluteFill style={{ background: 'radial-gradient(ellipse at 50% 38%, rgba(37,99,235,0.18), #000 62%)', fontFamily: font, transform: `scale(${1 + push * 0.06})` }}>
      <div style={{ position: 'absolute', left: '50%', top: 150 - lift * 40, transform: `translateX(-50%) scale(${(0.8 + icon * 0.2) * (1 - lift * 0.4)})`, opacity: icon * intro }}>
        <AppIcon size={240} />
      </div>
      <div style={{ position: 'absolute', left: 0, right: 0, top: 440, textAlign: 'center', opacity: intro }}>
        <div style={{ fontSize: 110, fontWeight: 700, color: color.label, letterSpacing: 14, opacity: title, transform: `translateY(${(1 - title) * 20}px)` }}>格物</div>
        <div style={{ fontSize: 38, color: color.secondary, letterSpacing: 4, marginTop: 18, opacity: tagline, transform: `translateY(${(1 - tagline) * 16}px)` }}>为学习做的大模型 App</div>
        <div style={{ marginTop: 34, opacity: pill }}><VersionPill label="1.0 正式版" size={26} /></div>
      </div>
      <div style={{ position: 'absolute', left: '50%', top: 250, transform: 'translateX(-50%)', opacity: lift }}>
        <Orb state={sent ? 'reasoning' : 'idle'} size={120} />
      </div>
      <div style={{ position: 'absolute', left: (video.width - 980) / 2, top: 470 + (1 - composerIn) * 60, width: 980, opacity: composerIn, transform: 'scale(1.25)', transformOrigin: '50% 0' }}>
        <Composer placement="inline" width="100%" value={value} caret={!sent && frame >= 108} pressing={frame >= 146 && frame < 151} />
      </div>
    </AbsoluteFill>
  );
};

// ---------- 错题本 → 复习 → "今天"（iPhone）----------

export const ReviewScene: React.FC = () => {
  const frame = useCurrentFrame();
  // 错题本 → 复习：右边的页面淡入淡出 10 帧；iPad → iPhone：iPad 往左退，iPhone 从右边进来，中间有交叠。
  const reviewIn = smooth(frame, [100, 110]);
  const ipadOut = smooth(frame, [212, 238]);
  const phoneIn = smooth(frame, [206, 234]);
  return (
    <>
      {frame < 238 && (
        <div style={{ position: 'absolute', inset: 0, opacity: 1 - ipadOut, transform: `translateX(${-ipadOut * 140}px)` }}>
          <IPadStage focus={detailFocus} zoom={detailZoom}>
            <Sidebar selection={frame < 100 ? 'mistakes' : 'review'} due={frame >= 150 ? 2 : 3} />
            {frame < 110 && (
              // 刚加入的错题等上一段淡完（第 15 帧）再插进来。
              <MistakeBookScreen insert={smooth(frame, [18, 40])} flash={interpolate(frame, [18, 36, 96], [0, 1, 0], clamp)} pressReview={frame >= 85 && frame < 95} />
            )}
            {frame >= 100 && (
              // 渲染器按这一小段自己的帧数走：第 40 帧点选项（整段的第 140 帧）。
              <Sequence from={100} layout="none">
                <div style={{ position: 'absolute', inset: 0, opacity: reviewIn }}>
                  <ReviewScreen
                    actions={[{ frame: 40, answer: { question: 0, option: 0 } }]}
                    box={frame - 100 >= 50 ? 2 : 1}
                    result={smooth(frame - 100, [50, 64])}
                  />
                </div>
              </Sequence>
            )}
          </IPadStage>
        </div>
      )}
      {frame >= 206 && (
        <IPhoneStage enter={phoneIn}>
          <TodayScreen compact streak={frame >= 250 ? 12 : 11} grow={smooth(frame, [228, 262])} due={2} />
        </IPhoneStage>
      )}
    </>
  );
};

// ---------- 汇编 ----------

const searchesBefore = 6;
export const CompilationScene: React.FC = () => {
  const frame = useCurrentFrame();
  const lines = frame < 105 ? 0 : Math.min(toolLog.length, Math.floor((frame - 105) / 8) + 1);
  const searches = searchesBefore + toolLog.slice(0, lines).filter((l) => l.kind === 'search').length;
  const seconds = Math.round(interpolate(frame, [105, 240], [8, 250], clamp));
  const elapsed = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
  const cost = frame < 105 ? '约 ¥0.02' : `约 ¥${interpolate(frame, [105, 240], [0.02, 0.31], clamp).toFixed(2)}`;
  // 列出试卷 → 开始收集：页面淡入淡出 10 帧。iPad → PDF：iPad 缩小淡出，PDF 从同一个位置放大出来。
  const collectIn = smooth(frame, [104, 114]);
  const ipadOut = smooth(frame, [234, 258]);
  const pdfIn = smooth(frame, [236, 262]);
  const flip = smooth(frame, [296, 316]);
  const detail = { lines, searches, elapsed, cost };
  return (
    <>
      {frame < 258 && (
        <div style={{ position: 'absolute', inset: 0, opacity: 1 - ipadOut, transform: `scale(${1 - ipadOut * 0.06})`, transformOrigin: '1270px 540px' }}>
          <IPadStage focus={detailFocus} zoom={detailZoom}>
            <Sidebar selection="compilations" due={2} />
            {frame < 114 && <CompilationDetail phase="choosing" {...detail} lines={0} pressing={frame >= 95 && frame < 101} />}
            {frame >= 104 && (
              <div style={{ position: 'absolute', inset: 0, opacity: collectIn }}>
                <CompilationDetail phase="collecting" {...detail} />
              </div>
            )}
            {frame < 78 && (
              // 等上一段淡完再弹出新建汇编的面板。
              <NewCompilationSheet appear={smooth(frame, [14, 28]) * (1 - smooth(frame, [64, 78]))} typed={typed(compilation.request, frame, 28, 2.5)} caret={frame >= 22 && frame < 58} pressing={frame >= 58 && frame < 64} />
            )}
          </IPadStage>
        </div>
      )}
      {frame >= 236 && (
        <Sequence from={236} layout="none">
        <div style={{ position: 'absolute', left: 660, top: 0, width: 1240, height: video.height, opacity: pdfIn, transform: `scale(${0.92 + pdfIn * 0.08})`, transformOrigin: '610px 540px' }}>
          {[0, 1].map((index) => {
            // 先是第 1 页居中，翻页时第 1 页往左让，第 2 页从右边进来，两页并排。
            const x = index === 0 ? interpolate(flip, [0, 1], [(1240 - a4.width) / 2, 10]) : interpolate(flip, [0, 1], [760, 635]);
            const shown = index === 0 || flip > 0;
            return shown ? (
              <div key={index} style={{ position: 'absolute', left: x, top: (video.height - a4.height) / 2, opacity: index === 0 ? 1 : flip }}>
                <PdfPage index={index} pages={2} />
              </div>
            ) : null;
          })}
        </div>
        </Sequence>
      )}
    </>
  );
};

// ---------- 还有这些（1.0 版新增）----------

const features: { icon: string; title: string; text: string }[] = [
  { icon: 'camera', title: '拍题、PDF、手写', text: '拍下练习册上的题，选 PDF 里的几页，或者用 Apple Pencil 写' },
  { icon: 'globe', title: '联网搜索', text: '回答上方列出出处，点开就是原网页' },
  { icon: 'doc.text.magnifyingglass', title: '资料', text: '联网查一个主题，整理成带出处的总结' },
  { icon: 'bookmark', title: '收藏', text: '整条回答存下来，删掉会话也还在' },
  { icon: 'sparkles', title: '快捷追问', text: '讲简单点、换个思路、出道练习题，点一下就行' },
  { icon: 'arrow.clockwise', title: '只重做出错的部分', text: '组件出错时只重新生成那一块，其他内容不动' },
  { icon: 'ipad.and.iphone', title: 'iPhone 和 iPad', text: 'iPad 分栏，iPhone 长按图标就能拍题、复习' },
  { icon: 'lock.shield', title: '自带 API Key', text: '直连服务商，没有服务器，数据只在本机' },
];

export const Features: React.FC = () => {
  const frame = useCurrentFrame();
  const head = smooth(frame, [16, 32]);
  const providers = smooth(frame, [92, 110]);
  return (
    <AbsoluteFill style={{ background: '#000', fontFamily: font }}>
      <div style={{ position: 'absolute', left: 96, top: 150, opacity: head, transform: `translateY(${(1 - head) * 18}px)` }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, fontSize: 24, fontWeight: 600, letterSpacing: 2, color: color.accent }}>
          <span style={{ width: 28, height: 4, borderRadius: 2, background: color.accent }} />
          还有这些
        </div>
        <div style={{ fontSize: 60, fontWeight: 700, color: color.label, marginTop: 18 }}>学习要用的，基本都在一个 App 里</div>
      </div>
      <div style={{ position: 'absolute', left: 96, right: 96, top: 360, display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 24 }}>
        {features.map((item, i) => {
          const p = smooth(frame, [30 + i * 5, 44 + i * 5]);
          return (
            <div
              key={item.title}
              style={{
                height: 230,
                padding: '28px 28px',
                borderRadius: 24,
                background: color.secondaryBackground,
                border: '1px solid rgba(255,255,255,0.06)',
                opacity: p,
                transform: `translateY(${(1 - p) * 28}px) scale(${0.97 + p * 0.03})`,
                display: 'flex',
                flexDirection: 'column',
                gap: 14,
              }}
            >
              <div style={{ width: 60, height: 60, flex: 'none', borderRadius: 16, background: color.accentFill, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <Symbol name={item.icon} size={30} color={color.accent} />
              </div>
              <div style={{ fontSize: 30, fontWeight: 700, color: color.label }}>{item.title}</div>
              <div style={{ fontSize: 22, lineHeight: 1.45, color: color.secondary }}>{item.text}</div>
            </div>
          );
        })}
      </div>
      <div style={{ position: 'absolute', left: 96, right: 96, top: 900, display: 'flex', alignItems: 'center', gap: 18, fontSize: 24, color: color.secondary, opacity: providers }}>
        <span style={{ color: color.tertiary }}>支持</span>
        {['DeepSeek', 'OpenAI', 'Claude', 'Gemini', 'OpenRouter', '通义千问、Kimi 等兼容 OpenAI 接口的服务商'].map((name) => (
          <span key={name} style={{ padding: '8px 18px', borderRadius: 999, background: color.tertiaryFill, color: 'rgba(255,255,255,0.85)' }}>{name}</span>
        ))}
      </div>
    </AbsoluteFill>
  );
};

// ---------- 片尾 ----------

export const Ending: React.FC = () => {
  const frame = useCurrentFrame();
  const a = smooth(frame, [10, 34]);
  const b = interpolate(frame, [30, 48], [0, 1], clamp);
  const c = interpolate(frame, [52, 70], [0, 1], clamp);
  const d = interpolate(frame, [76, 94], [0, 1], clamp);
  const e = interpolate(frame, [104, 122], [0, 1], clamp);
  const rise = (p: number): React.CSSProperties => ({ opacity: p, transform: `translateY(${(1 - p) * 16}px)` });
  return (
    <AbsoluteFill style={{ background: 'radial-gradient(ellipse at 50% 34%, rgba(37,99,235,0.2), #000 60%)', fontFamily: font, alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 20, marginTop: -40 }}>
        <div style={{ opacity: a, transform: `scale(${0.85 + a * 0.15})` }}><AppIcon size={200} /></div>
        <div style={{ ...rise(a), fontSize: 104, fontWeight: 700, letterSpacing: 14, color: color.label, marginTop: 8 }}>格物</div>
        <div style={{ ...rise(b), fontSize: 34, letterSpacing: 10, color: color.secondary }}>格物致知</div>
        <div style={{ ...rise(c), display: 'flex', gap: 14, marginTop: 22 }}>
          <VersionPill label="1.0 正式版" size={24} />
          {['iPhone · iPad · iOS 18 及以上', '免费 · 开源（MIT）'].map((label) => (
            <span key={label} style={{ fontSize: 24, color: 'rgba(255,255,255,0.85)', background: color.tertiaryFill, borderRadius: 999, padding: '6px 18px' }}>{label}</span>
          ))}
        </div>
        <div style={{ ...rise(d), fontSize: 26, color: color.secondary, marginTop: 10 }}>在 GitHub 的 Releases 页面下载安装包</div>
        <div style={{ ...rise(d), fontSize: 36, color: color.accent, fontFamily: '"SF Mono", ui-monospace, Menlo, monospace' }}>github.com/LouisLu010/study-agent</div>
      </div>
      <div style={{ position: 'absolute', bottom: 52, fontSize: 20, color: color.tertiary, opacity: e }}>界面为按 App 还原的演示画面，示例内容为预设 · 配乐由代码合成</div>
    </AbsoluteFill>
  );
};
