// 生成宣传片的配乐和音效：一首 120 BPM 的纯音乐（电钢琴琶音、铺底、贝斯、轻鼓），按 timeline.json 的长度和段落编排，
// 音效按 timeline.json 的 cues 混进去。全部用代码合成，没有用任何现成的音乐或采样，所以可以随片子一起公开。
// 用法：node scripts/make-music.mjs [输出路径]，默认 public/music.wav（不进仓库，渲染前生成）。
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';

const here = dirname(fileURLToPath(import.meta.url));
const timeline = JSON.parse(readFileSync(join(here, '..', 'src', 'timeline.json'), 'utf8'));
const out = process.argv[2] ?? join(here, '..', 'public', 'music.wav');

const RATE = 44100;
const BPM = 120;
const BEAT = 60 / BPM;
const BAR = BEAT * 4;
const last = timeline.scenes[timeline.scenes.length - 1];
const total = (last.from + last.duration) / timeline.fps;
const length = Math.ceil((total + 0.2) * RATE);
const sceneStart = (id) => {
  const scene = timeline.scenes.find((s) => s.id === id);
  return scene ? scene.from / timeline.fps : null;
};

// 段落：开场只有铺底和几个音，第一段交互式回答进来时琶音、贝斯和底鼓进来，人格那段起加军鼓，片尾鼓停下、最后一个和弦慢慢淡出。
const grooveAt = sceneStart('pendulum') ?? BAR * 3;
const snareAt = sceneStart('persona') ?? grooveAt + BAR * 8;
const endingAt = sceneStart('ending') ?? total - BAR * 4;

// 随机数固定种子，每次生成一样的文件。
let seed = 20261124;
const random = () => {
  seed = (seed * 1664525 + 1013904223) >>> 0;
  return seed / 4294967296;
};

const dry = [new Float32Array(length), new Float32Array(length)];
const wet = new Float32Array(length); // 送混响的单声道总线

const midi = (n) => 440 * 2 ** ((n - 69) / 12);
const N = { C2: 36, D2: 38, E2: 40, F2: 41, G2: 43, A2: 45, C3: 48, D3: 50, E3: 52, F3: 53, G3: 55, A3: 57, B3: 59, C4: 60, D4: 62, E4: 64, F4: 65, G4: 67, A4: 69, B4: 71, C5: 72, D5: 74, E5: 76, G5: 79, A5: 81, B5: 83, E6: 88, B6: 95 };

// IV – V – iii – vi（F – G – Em – Am），每个和弦一小节。
const chords = [
  { bass: N.F2, pad: [N.F3, N.A3, N.C4, N.E4], arp: [N.F4, N.A4, N.C5, N.E5] },
  { bass: N.G2, pad: [N.G3, N.B3, N.D4, N.E4], arp: [N.G4, N.B4, N.D5, N.E5] },
  { bass: N.E2, pad: [N.E3, N.G3, N.B3, N.D4], arp: [N.E4, N.G4, N.B4, N.D5] },
  { bass: N.A2, pad: [N.A3, N.C4, N.E4, N.G4], arp: [N.A4, N.C5, N.E5, N.G5] },
];
const chordAt = (t) => chords[Math.floor(t / BAR) % chords.length];

function add(channel, index, value) {
  if (index >= 0 && index < length) dry[channel][index] += value;
}

/** 一个音：pan -1 左到 1 右，send 送混响的比例。voice(t) 返回 t 秒处的波形，env(t) 返回包络。 */
function note(start, duration, voice, env, { gain = 0.2, pan = 0, send = 0.3 } = {}) {
  const from = Math.max(0, Math.floor(start * RATE));
  const to = Math.min(length, Math.floor((start + duration) * RATE));
  const left = Math.cos(((pan + 1) * Math.PI) / 4);
  const right = Math.sin(((pan + 1) * Math.PI) / 4);
  for (let i = from; i < to; i++) {
    const t = i / RATE - start;
    const v = voice(t) * env(t) * gain;
    add(0, i, v * left);
    add(1, i, v * right);
    wet[i] += v * send;
  }
}

const sine = (f) => (t) => Math.sin(2 * Math.PI * f * t);

/** 电钢琴：基音加一点二次、三次谐波，开头带一下金属感的泛音，指数衰减。 */
function epiano(start, f, { gain = 0.13, decay = 0.9, pan = 0, send = 0.45 } = {}) {
  note(
    start,
    decay * 4,
    (t) => Math.sin(2 * Math.PI * f * t) + 0.25 * Math.sin(4 * Math.PI * f * t) * Math.exp(-t * 3) + 0.12 * Math.sin(2 * Math.PI * f * 7.01 * t) * Math.exp(-t * 18),
    (t) => Math.min(1, t / 0.004) * Math.exp(-t / decay),
    { gain, pan, send },
  );
}

/** 铺底：两个略微走调的三角波，慢起慢收。 */
function pad(start, duration, f, gain) {
  const tri = (x) => (2 / Math.PI) * Math.asin(Math.sin(x));
  note(
    start,
    duration + 1.2,
    (t) => 0.5 * tri(2 * Math.PI * f * 1.003 * t) + 0.5 * tri(2 * Math.PI * f * 0.997 * t + 1.3),
    (t) => Math.min(1, t / 0.6) * (t > duration ? Math.max(0, 1 - (t - duration) / 1.2) : 1),
    { gain, pan: f % 2 > 1 ? 0.3 : -0.3, send: 0.6 },
  );
}

function bass(start, duration, f) {
  note(start, duration, (t) => Math.sin(2 * Math.PI * f * t) + 0.3 * Math.sin(4 * Math.PI * f * t), (t) => Math.min(1, t / 0.01) * Math.exp(-t / 0.7) * Math.min(1, (duration - t) / 0.05), { gain: 0.22, send: 0.05 });
}

function kick(start) {
  let phase = 0;
  let last = 0;
  note(
    start,
    0.35,
    (t) => {
      const f = 45 + 95 * Math.exp(-t * 28);
      phase += 2 * Math.PI * f * (t - last);
      last = t;
      return Math.sin(phase);
    },
    (t) => Math.exp(-t / 0.13),
    { gain: 0.32, send: 0.02 },
  );
}

/** 噪声加一阶高通，做军鼓和踩镲。 */
function noise(start, duration, decay, highpass, gain, pan, send) {
  let previousIn = 0;
  let previousOut = 0;
  const a = 1 / (1 + 2 * Math.PI * highpass / RATE);
  note(
    start,
    duration,
    () => {
      const x = random() * 2 - 1;
      const y = a * (previousOut + x - previousIn);
      previousIn = x;
      previousOut = y;
      return y;
    },
    (t) => Math.exp(-t / decay),
    { gain, pan, send },
  );
}
const snare = (start) => {
  noise(start, 0.25, 0.07, 1200, 0.12, 0, 0.25);
  note(start, 0.12, sine(190), (t) => Math.exp(-t / 0.04), { gain: 0.08, send: 0.1 });
};
const hat = (start, accent) => noise(start, 0.06, 0.018, 7000, accent ? 0.05 : 0.03, 0.35, 0.05);

// ---------- 编排 ----------

const bars = Math.ceil(total / BAR);
for (let bar = 0; bar < bars; bar++) {
  const t0 = bar * BAR;
  const chord = chordAt(t0 + 0.01);
  const ending = t0 >= endingAt - 0.01;
  const groove = t0 >= grooveAt - 0.01 && !ending;

  // 铺底一直在，开场和片尾稍微响一点。
  chord.pad.forEach((n) => pad(t0, BAR, midi(n), groove ? 0.03 : 0.045));

  if (!groove && !ending) {
    // 开场：每拍一个音，从低往高。
    chord.arp.forEach((n, i) => epiano(t0 + i * BEAT, midi(n), { gain: 0.1, decay: 1.2, pan: -0.4 + i * 0.25 }));
    continue;
  }
  if (ending) continue;

  bass(t0, BEAT * 1.5, midi(chord.bass));
  bass(t0 + BEAT * 2, BEAT * 1.5, midi(chord.bass));
  bass(t0 + BEAT * 3.5, BEAT * 0.5, midi(chord.bass + 12));

  // 琶音：八分音符，上行再下行。
  const order = [0, 1, 2, 3, 2, 1, 2, 3];
  order.forEach((k, i) => {
    epiano(t0 + i * (BEAT / 2), midi(chord.arp[k]), { gain: i % 2 ? 0.075 : 0.095, decay: 0.55, pan: [-0.35, -0.1, 0.15, 0.35][k] });
  });

  for (let beat = 0; beat < 4; beat++) {
    const t = t0 + beat * BEAT;
    if (beat === 0 || beat === 2) kick(t);
    if ((beat === 1 || beat === 3) && t >= snareAt - 0.01) snare(t);
    hat(t, true);
    hat(t + BEAT / 2, false);
  }
}

// 片尾：落在 C 大调主和弦上，长音慢慢散开。
const finalChord = [N.C3, N.G3, N.E4, N.G4, N.C5];
bass(endingAt, 4, midi(N.C2));
finalChord.forEach((n, i) => {
  epiano(endingAt + i * 0.06, midi(n), { gain: 0.11, decay: 2.4, pan: -0.4 + i * 0.2, send: 0.6 });
  pad(endingAt, total - endingAt - 2, midi(n), 0.035);
});

// 开场到第一段之前的一小段上扬：噪声慢慢变响。
note(grooveAt - BAR, BAR, () => random() * 2 - 1, (t) => (t / BAR) ** 3, { gain: 0.04, send: 0.5 });

// ---------- 音效 ----------

function chime(start, notes, gain = 0.09) {
  notes.forEach((n, i) => note(start + i * 0.07, 1.2, sine(midi(n)), (t) => Math.min(1, t / 0.003) * Math.exp(-t / 0.35), { gain, pan: 0.2, send: 0.5 }));
}
function pop(start) {
  let phase = 0;
  let last = 0;
  note(start, 0.12, (t) => {
    const f = 500 + 700 * (t / 0.12);
    phase += 2 * Math.PI * f * (t - last);
    last = t;
    return Math.sin(phase);
  }, (t) => Math.exp(-t / 0.035), { gain: 0.09, send: 0.15 });
}
function thud(start) {
  note(start, 0.3, (t) => Math.sin(2 * Math.PI * (220 - 120 * t) * t), (t) => Math.exp(-t / 0.08), { gain: 0.12, send: 0.1 });
}
function tick(start) {
  note(start, 0.04, sine(2400), (t) => Math.exp(-t / 0.008), { gain: 0.05, pan: 0.1, send: 0.1 });
}
function whoosh(start) {
  noise(start, 0.5, 0.2, 2500, 0.05, 0, 0.4);
}

for (const cue of timeline.cues) {
  const t = cue.frame / timeline.fps;
  const s = cue.sound;
  if (/转场/.test(s)) continue;
  if (/答错/.test(s)) thud(t);
  else if (/答对|升到|变成/.test(s)) chime(t, [N.E5, N.B5]);
  else if (/开场|片尾/.test(s)) chime(t, [N.C5, N.G5, N.E6], 0.06);
  else if (/发送|点|松手|按住|选中/.test(s)) pop(t);
  else if (/PDF|翻|出现/.test(s)) whoosh(t);
  else tick(t);
}

// ---------- 混响（Schroeder：四个梳状滤波器并联，两个全通串联，左右声道用不同的延迟）----------

function reverb(input, delays) {
  const outBuffer = new Float32Array(length);
  for (const d of delays.combs) {
    const buffer = new Float32Array(d);
    let index = 0;
    let lowpass = 0;
    for (let i = 0; i < length; i++) {
      const y = buffer[index];
      lowpass = y * 0.7 + lowpass * 0.3;
      buffer[index] = input[i] + lowpass * 0.8;
      outBuffer[i] += y;
      index = (index + 1) % d;
    }
  }
  for (const d of delays.allpasses) {
    const buffer = new Float32Array(d);
    let index = 0;
    for (let i = 0; i < length; i++) {
      const delayed = buffer[index];
      const x = outBuffer[i];
      buffer[index] = x + delayed * 0.5;
      outBuffer[i] = delayed - x * 0.5;
      index = (index + 1) % d;
    }
  }
  return outBuffer;
}
const reverbL = reverb(wet, { combs: [1557, 1617, 1491, 1422], allpasses: [225, 556] });
const reverbR = reverb(wet, { combs: [1580, 1640, 1514, 1445], allpasses: [248, 579] });

// ---------- 混音、限幅、淡出 ----------

let peak = 0;
const mix = [new Float32Array(length), new Float32Array(length)];
const fadeOut = 3;
for (let i = 0; i < length; i++) {
  const t = i / RATE;
  const fade = Math.min(1, t / 0.05) * Math.min(1, Math.max(0, (total - t) / fadeOut));
  for (let c = 0; c < 2; c++) {
    const v = Math.tanh((dry[c][i] + (c ? reverbR[i] : reverbL[i]) * 0.12) * 1.4) * fade;
    mix[c][i] = v;
    peak = Math.max(peak, Math.abs(v));
  }
}
const gain = peak > 0 ? 0.89 / peak : 1; // -1 dBFS

const data = Buffer.alloc(44 + length * 4);
data.write('RIFF', 0);
data.writeUInt32LE(36 + length * 4, 4);
data.write('WAVE', 8);
data.write('fmt ', 12);
data.writeUInt32LE(16, 16);
data.writeUInt16LE(1, 20);
data.writeUInt16LE(2, 22);
data.writeUInt32LE(RATE, 24);
data.writeUInt32LE(RATE * 4, 28);
data.writeUInt16LE(4, 32);
data.writeUInt16LE(16, 34);
data.write('data', 36);
data.writeUInt32LE(length * 4, 40);
for (let i = 0; i < length; i++) {
  for (let c = 0; c < 2; c++) {
    const v = Math.max(-1, Math.min(1, mix[c][i] * gain));
    data.writeInt16LE(Math.round(v * 32767), 44 + i * 4 + c * 2);
  }
}
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, data);
console.log(`配乐 → ${out}（${total.toFixed(1)} 秒，${BPM} BPM，${timeline.cues.length} 个音效）`);
