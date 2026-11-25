// 打印段落和音效时间表（Markdown）。配乐和音效已经由 scripts/make-music.mjs 合成进片子，这张表用来在剪映里换音乐或补音效时对照。用法：node scripts/cues.mjs > out/cues.md
import { readFileSync } from 'node:fs';

const timeline = JSON.parse(readFileSync(new URL('../src/timeline.json', import.meta.url), 'utf8'));
const time = (frame) => {
  const seconds = frame / timeline.fps;
  return `${Math.floor(seconds / 60)}:${(seconds % 60).toFixed(2).padStart(5, '0')}`;
};

const lines = ['# 格物宣传片：音效时间表', '', `${timeline.fps} fps，镜头切换都对齐 120 BPM（每拍 0.5 秒）。`, '', '## 段落', '', '| 开始 | 结束 | 段落 | 字幕 |', '|---|---|---|---|'];
for (const s of timeline.scenes) {
  lines.push(`| ${time(s.from)} | ${time(s.from + s.duration)} | ${s.id} | ${s.caption ? [s.caption.title, s.caption.detail].filter(Boolean).join(' / ').replace(/\n/g, '') : ''} |`);
}
lines.push('', '## 音效', '', '| 时间 | 帧 | 音效 |', '|---|---|---|');
for (const c of timeline.cues) lines.push(`| ${time(c.frame)} | ${c.frame} | ${c.sound} |`);
console.log(lines.join('\n'));
