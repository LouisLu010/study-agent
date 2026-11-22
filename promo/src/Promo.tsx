import React from 'react';
import { AbsoluteFill, Easing, Sequence, interpolate, useCurrentFrame } from 'remotion';
import timeline from './timeline.json';
import { equilibrium, graph, pendulum, quiz } from './content';
import { ChatScene, drag } from './scenes/ChatScene';
import { CompilationScene, Ending, Opening, ReviewScene } from './scenes/Scenes';
import { Caption } from './ui/Caption';

// 整部片子：每段的起点、长度和字幕在 timeline.json 里，音效时间点也在那里（npm run cues 打印成表）。
// 转场：每段往后多演 transition 帧，和下一段交叠；下一段在上面从透明淡到不透明，所以中间不会闪黑。
// 交叠时两段的机位一样（都是整台 iPad，或者都是黑底），看起来只是屏幕里的内容换了。
// 操作的帧号都是相对这一段开头的。

const sliders = '.graph-param input[type=range]';
const T = timeline.transition;

const scenes: Record<string, React.ReactNode> = {
  opening: <Opening />,
  pendulum: (
    <ChatScene
      id="pendulum"
      question={pendulum.question}
      answer={pendulum.answer}
      thinking={24}
      zoomIn={[28, 56]}
      zoomOut={[158, 192]}
      actions={drag(sliders, 66, 96, 1, 2.5)}
    />
  ),
  graph: <ChatScene id="graph" question={graph.question} answer={graph.answer} zoomOut={[158, 192]} actions={drag(sliders, 44, 120, 0.5, 2.2)} />,
  equilibrium: (
    <ChatScene id="equilibrium" question={equilibrium.question} answer={equilibrium.answer} zoomOut={[145, 178]} actions={[{ frame: 20, click: { selector: 'button[data-speed="2"]' } }]} />
  ),
  quiz: (
    <ChatScene
      id="quiz"
      question={quiz.question}
      answer={quiz.answer}
      zoomOut={[145, 178]}
      scrollBy={[70, 92, 300]}
      actions={[
        { frame: 46, answer: { question: 0, option: 1 } },
        { frame: 100, answer: { question: 1, option: 0 } },
      ]}
    />
  ),
  review: <ReviewScene />,
  compilation: <CompilationScene />,
  ending: <Ending />,
};

/** 这一段在开头的 T 帧里从透明淡入（第一段不淡）。 */
const FadeIn: React.FC<{ enabled: boolean; children: React.ReactNode }> = ({ enabled, children }) => {
  const frame = useCurrentFrame();
  const opacity = enabled ? interpolate(frame, [0, T], [0, 1], { easing: Easing.inOut(Easing.quad), extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }) : 1;
  // 淡入的这一段自己铺黑底，盖住下面那段的全部画面；否则透明的地方会透出上一段，淡完那一帧上一段才一下子消失。
  return <AbsoluteFill style={{ opacity, background: enabled ? '#000' : undefined }}>{children}</AbsoluteFill>;
};

export const Promo: React.FC = () => (
  <AbsoluteFill style={{ background: '#000' }}>
    {timeline.scenes.map((scene, i) => {
      const last = i === timeline.scenes.length - 1;
      return (
        <Sequence key={scene.id} from={scene.from} durationInFrames={scene.duration + (last ? 0 : T)} name={scene.id}>
          <FadeIn enabled={i > 0}>
            {scenes[scene.id]}
            {scene.caption && (
              <Caption title={scene.caption[0]!} detail={scene.caption[1]} enter={i > 0 && timeline.scenes[i - 1].caption ? T - 2 : 6} exit={last ? undefined : scene.duration} />
            )}
          </FadeIn>
        </Sequence>
      );
    })}
  </AbsoluteFill>
);
