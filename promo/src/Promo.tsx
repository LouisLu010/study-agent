import React from 'react';
import { AbsoluteFill, Sequence } from 'remotion';
import timeline from './timeline.json';
import { equilibrium, graph, pendulum, quiz } from './content';
import { ChatScene, drag } from './scenes/ChatScene';
import { CompilationScene, Ending, Opening, ReviewScene } from './scenes/Scenes';
import { Caption } from './ui/Caption';

// 整部片子：每段的起止帧和字幕在 timeline.json 里，音效时间点也在那里（npm run cues 打印成表）。
// 交互式回答那几段的操作帧号是相对这一段开头的。

const sliders = '.graph-param input[type=range]';

const scenes: Record<string, React.ReactNode> = {
  opening: <Opening />,
  pendulum: (
    <ChatScene id="pendulum" question={pendulum.question} answer={pendulum.answer} zoomOut={[150, 190]} actions={drag(sliders, 45, 76, 1, 2.5)} />
  ),
  graph: <ChatScene id="graph" question={graph.question} answer={graph.answer} zoomOut={[150, 190]} actions={drag(sliders, 30, 111, 0.5, 2.2)} />,
  equilibrium: (
    <ChatScene id="equilibrium" question={equilibrium.question} answer={equilibrium.answer} zoomOut={[138, 175]} actions={[{ frame: 5, click: { selector: 'button[data-speed="2"]' } }]} />
  ),
  quiz: (
    <ChatScene
      id="quiz"
      question={quiz.question}
      answer={quiz.answer}
      zoomOut={[140, 175]}
      scrollBy={[50, 72, 300]}
      actions={[
        { frame: 35, answer: { question: 0, option: 1 } },
        { frame: 80, answer: { question: 1, option: 0 } },
      ]}
    />
  ),
  review: <ReviewScene />,
  compilation: <CompilationScene />,
  ending: <Ending />,
};

export const Promo: React.FC = () => (
  <AbsoluteFill style={{ background: '#000' }}>
    {timeline.scenes.map((scene) => (
      <Sequence key={scene.id} from={scene.from} durationInFrames={scene.duration} name={scene.id}>
        {scenes[scene.id]}
        {scene.caption && <Caption title={scene.caption[0]!} detail={scene.caption[1]} duration={scene.duration} />}
      </Sequence>
    ))}
  </AbsoluteFill>
);
