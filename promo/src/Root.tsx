import React from 'react';
import { Composition } from 'remotion';
import timeline from './timeline.json';
import { Promo } from './Promo';

const last = timeline.scenes[timeline.scenes.length - 1];

export const Root: React.FC = () => (
  <Composition
    id="Promo"
    component={Promo}
    durationInFrames={last.from + last.duration}
    fps={timeline.fps}
    width={timeline.width}
    height={timeline.height}
  />
);
