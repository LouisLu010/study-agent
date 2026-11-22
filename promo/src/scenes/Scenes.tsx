import React from 'react';
import { AbsoluteFill, Sequence, interpolate, useCurrentFrame } from 'remotion';
import { color, font } from '../theme';
import { compilation, pendulum, toolLog } from '../content';
import { Orb } from '../ui/Orb';
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

// ---------- 开场（Q28）----------

export const Opening: React.FC = () => {
  const frame = useCurrentFrame();
  const title = interpolate(frame, [20, 40], [0, 1], clamp);
  const lift = smooth(frame, [58, 80]);
  const composerIn = smooth(frame, [64, 84]);
  const value = typed(pendulum.question, frame, 86, 2);
  const sent = frame >= 126;
  // 发送后输入框和小球稍微放大一点，接着下一段（iPad 上的这次提问）从上面淡入。
  const push = smooth(frame, [128, 165]);
  return (
    <AbsoluteFill style={{ background: '#000', fontFamily: font, transform: `scale(${1 + push * 0.06})` }}>
      <div style={{ position: 'absolute', left: '50%', top: interpolate(lift, [0, 1], [400, 250]), transform: 'translateX(-50%)' }}>
        <Orb state={sent ? 'reasoning' : 'idle'} size={interpolate(lift, [0, 1], [200, 120])} />
      </div>
      <div style={{ position: 'absolute', left: 0, right: 0, top: 640, textAlign: 'center', fontSize: 96, fontWeight: 700, color: color.label, letterSpacing: 12, opacity: title * (1 - lift) }}>格物</div>
      <div style={{ position: 'absolute', left: (video.width - 980) / 2, top: 470 + (1 - composerIn) * 60, width: 980, opacity: composerIn, transform: 'scale(1.25)', transformOrigin: '50% 0' }}>
        <Composer placement="inline" width="100%" value={value} caret={!sent && frame >= 84} pressing={frame >= 122 && frame < 127} />
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

// ---------- 片尾（Q29、Q7）----------

export const Ending: React.FC = () => {
  const frame = useCurrentFrame();
  const a = interpolate(frame, [10, 30], [0, 1], clamp);
  const b = interpolate(frame, [36, 54], [0, 1], clamp);
  const c = interpolate(frame, [70, 90], [0, 1], clamp);
  const d = interpolate(frame, [100, 120], [0, 1], clamp);
  return (
    <AbsoluteFill style={{ background: '#000', fontFamily: font, alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 24, marginTop: -60 }}>
        <div style={{ opacity: a }}><Orb state="idle" size={180} /></div>
        <div style={{ fontSize: 108, fontWeight: 700, letterSpacing: 14, color: color.label, opacity: a }}>格物</div>
        <div style={{ fontSize: 36, letterSpacing: 10, color: color.secondary, opacity: b }}>格物致知</div>
        <div style={{ fontSize: 34, color: color.accent, marginTop: 28, opacity: c, fontFamily: '"SF Mono", ui-monospace, Menlo, monospace' }}>github.com/LouisLu010/study-agent</div>
      </div>
      <div style={{ position: 'absolute', bottom: 56, fontSize: 20, color: color.tertiary, opacity: d }}>界面为按 App 还原的演示画面，示例内容为预设</div>
    </AbsoluteFill>
  );
};
