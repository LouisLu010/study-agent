// 片子里的示例内容：回答的 Markdown（组件 JSON 是手写的，见 docs/promo/README.md 的 Q4）和界面里的演示数据。
// 组件 JSON 的格式和 App 的内置提示词要求的一样，由 App 的渲染器解析和绘制；scripts/check-content.mjs 会检查能不能解析。

export const model = 'DeepSeek-V4.1-Flash';

const fence = (kind: string, spec: object) => '```' + kind + '\n' + JSON.stringify(spec) + '\n```';

// ---------- 交互式回答 ----------

export const pendulum = {
  question: '摆长变长，单摆会摆得更慢吗？',
  answer: [
    '会。摆角不大时，单摆的周期 $T = 2\\pi\\sqrt{\\dfrac{L}{g}}$，只和摆长 $L$、重力加速度 $g$ 有关，和摆球质量无关。摆长变成原来的 4 倍，周期变成原来的 2 倍。',
    '',
    '拖一下摆长试试：',
    '',
    fence('simulation', { kind: 'pendulum', title: '单摆：摆长和周期', params: { L: 1, theta0: 25, g: 9.8 } }),
  ].join('\n'),
};

export const graph = {
  question: 'y = x² − 2ax + 1 的图像怎么随 a 变化？',
  answer: [
    '配方得 $y = (x - a)^2 + 1 - a^2$，对称轴是 $x = a$，顶点是 $(a,\\ 1 - a^2)$。$a$ 变大时，抛物线向右移，顶点往下走；$a > 1$ 时顶点在 $x$ 轴下方，和 $x$ 轴有两个交点。',
    '',
    fence('graph', {
      title: 'y = x² − 2ax + 1',
      xRange: [-3, 5],
      yRange: [-4, 6],
      functions: [{ expr: 'x^2 - 2*a*x + 1', label: 'y = x² − 2ax + 1' }],
      params: [{ name: 'a', min: 0, max: 3, step: 0.05, value: 0.5, label: '对称轴 x = a' }],
      formula: 'y = x^2 - 2 \\cdot {a}\\, x + 1',
      readouts: [
        { label: '顶点', value: ['a', '1 - a^2'] },
        { label: '判别式 Δ', value: '4*a^2 - 4' },
      ],
    }),
  ].join('\n'),
};

export const equilibrium = {
  question: '勒夏特列原理是什么？用化学平衡演示一下',
  answer: [
    '**勒夏特列原理**：改变影响平衡的一个条件（浓度、压强、温度），平衡就向能够**减弱这种改变**的方向移动。',
    '',
    '下面的模拟里，反应 A ⇌ B 先达到平衡，中途再加入一些 A：A 的浓度突然升高，正反应变快，平衡向生成 B 的方向移动，直到建立新的平衡。',
    '',
    fence('simulation', { kind: 'equilibrium', title: '化学平衡：中途加入反应物', params: { kf: 1, kr: 0.5, A0: 1, B0: 0, addA: 0.8 } }),
  ].join('\n'),
};

export const quizQuestions = [
  {
    question: '质量为 2 kg 的物体受到 10 N 的合力，它的加速度是多少？',
    options: ['2 m/s²', '5 m/s²', '10 m/s²', '20 m/s²'],
    answer: 'B',
    explanation: '由 $a = \\dfrac{F}{m} = \\dfrac{10}{2} = 5\\ \\text{m/s}^2$。',
    subject: '物理',
    topic: '牛顿第二定律',
  },
  {
    question: '光滑水平面上用恒力 F 拉一个木块，再把一个相同的木块叠放在上面一起运动，加速度变为原来的多少？',
    options: ['2 倍', '不变', '1/2', '1/4'],
    answer: 'C',
    explanation: '合力不变，质量变为 $2m$，所以 $a\' = \\dfrac{F}{2m} = \\dfrac{a}{2}$。',
    subject: '物理',
    topic: '牛顿第二定律',
  },
  {
    question: '电梯以 2 m/s² 的加速度加速上升，质量 50 kg 的人对地板的压力是多少？（g 取 10 m/s²）',
    options: ['400 N', '500 N', '600 N', '1000 N'],
    answer: 'C',
    explanation: '$N - mg = ma$，$N = m(g + a) = 50 \\times 12 = 600\\ \\text{N}$。由牛顿第三定律，人对地板的压力也是 600 N。',
    subject: '物理',
    topic: '牛顿第二定律',
  },
];

export const quiz = {
  question: '出 3 道牛顿第二定律的题考考我',
  answer: ['好，3 道题，由浅到深：', '', fence('quiz', { title: '牛顿第二定律', questions: quizQuestions })].join('\n'),
};

// ---------- 复习 ----------

/** 复习时这道错题按 App 的做法渲染成只有一道题的测验（Mistake.quizMarkdown）。 */
export const reviewQuestion = {
  question: '双曲线 $\\dfrac{x^2}{16} - \\dfrac{y^2}{9} = 1$ 的离心率是多少？',
  options: ['5/4', '5/3', '4/5', '3/4'],
  answer: 'A',
  explanation: '$a = 4$，$b = 3$，$c = \\sqrt{a^2 + b^2} = 5$，所以 $e = \\dfrac{c}{a} = \\dfrac{5}{4}$。',
  subject: '数学',
  topic: '双曲线的离心率',
};
export const reviewMarkdown = fence('quiz', { questions: [reviewQuestion] });

export type MistakeRowData = { title: string; subject: string; meta: string };

/** 错题本的列表行，标题按 App 修好以后的样子写成能读的文字（见 PR #63）。 */
export const mistakes: MistakeRowData[] = [
  { title: '光滑水平面上用恒力 F 拉一个木块，再把一个相同的木块叠放在上面一起运动，加速度变为原来的多少？', subject: '物理', meta: '牛顿第二定律 · 第 1 档 · 11月23日 复习' },
  { title: '双曲线 x²/16 − y²/9 = 1 的离心率是多少？', subject: '数学', meta: '双曲线的离心率 · 今天复习' },
  { title: 'f(x) = x³ − 3x 在 [−2, 2] 上的最大值是多少？', subject: '数学', meta: '导数与极值 · 今天复习' },
  { title: 'N₂ + 3H₂ ⇌ 2NH₃ 达到平衡后增大压强，平衡向哪个方向移动？', subject: '化学', meta: '化学平衡 · 今天复习' },
  { title: '带电粒子垂直进入匀强磁场后做什么运动？', subject: '物理', meta: '洛伦兹力 · 已掌握' },
];

// ---------- 侧栏和"今天" ----------

export const conversations = [
  { id: 'quiz', title: '牛顿第二定律小测', time: '现在' },
  { id: 'equilibrium', title: '勒夏特列原理', time: '2分钟前' },
  { id: 'graph', title: '二次函数的对称轴', time: '5分钟前' },
  { id: 'pendulum', title: '单摆的周期和摆长', time: '8分钟前' },
  { id: 'hyperbola', title: '双曲线的渐近线', time: '昨天' },
  { id: 'organic', title: '有机合成路线推断', time: '3天前' },
];

export const today = {
  date: '11月22日 星期日',
  due: 2,
  streak: 12,
  week: [4, 6, 3, 7, 5, 8, 4],
  weekdays: ['一', '二', '三', '四', '五', '六', '日'],
  continueTitle: '牛顿第二定律小测',
  continueTime: '现在',
};

// ---------- 汇编 ----------

export const compilation = {
  request: '近 3 年高考有机大题',
  papers: [
    { title: '2025 年高考北京卷化学', short: '2025 北京卷', year: '2025' },
    { title: '2025 年高考新课标卷理综', short: '2025 新课标卷（理综）', year: '2025' },
    { title: '2025 年高考全国甲卷理综', short: '2025 全国甲卷', year: '2025' },
    { title: '2024 年高考北京卷化学', short: '2024 北京卷', year: '2024' },
    { title: '2024 年高考新课标卷理综', short: '2024 新课标卷', year: '2024' },
    { title: '2024 年高考全国甲卷理综', short: '2024 全国甲卷', year: '2024' },
    { title: '2023 年高考北京卷化学', short: '2023 北京卷', year: '2023' },
    { title: '2023 年高考新课标卷理综', short: '2023 新课标卷', year: '2023' },
    { title: '2023 年高考全国甲卷理综', short: '2023 全国甲卷', year: '2023' },
  ],
  estimate: '已选 9 份，大约需要 4 分钟，预估费用约 ¥0.60。生成期间可以切到别的 App，进度会随时保存。',
};

export type LogKind = 'step' | 'search' | 'page' | 'success' | 'warning';
export type LogLine = { kind: LogKind; text: string; time: string };

/** 调用记录，文字格式和 App/Library/CompilationToolbox.swift 里的一样。 */
export const toolLog: LogLine[] = [
  { kind: 'step', text: '第 1/9 份：2025 北京卷', time: '晚上8:12:03' },
  { kind: 'search', text: '搜索：2025 北京卷 化学 有机 大题 原题', time: '晚上8:12:05' },
  { kind: 'page', text: '8 个网页：gaokao.cn、zxxk.com、gaotu.cn', time: '晚上8:12:06' },
  { kind: 'page', text: '读网页 gaotu.cn · 7,820 字', time: '晚上8:12:09' },
  { kind: 'success', text: '获取第 17 题 · 高途 · 完整 · 图 3/3 · 带网站解析', time: '晚上8:12:13' },
  { kind: 'success', text: '这份试卷完成：第 17 题有机推断', time: '晚上8:12:15' },
  { kind: 'step', text: '第 2/9 份：2025 新课标卷（理综）', time: '晚上8:12:16' },
  { kind: 'search', text: '搜索：2025 新课标卷 理综 化学 第 29 题', time: '晚上8:12:18' },
  { kind: 'page', text: '8 个网页：jyeoo.com、21cnjy.com、gaotu.cn', time: '晚上8:12:19' },
  { kind: 'success', text: '获取第 29 题 · 菁优网 · 完整 · 图 2/2 · 带网站解析', time: '晚上8:12:24' },
  { kind: 'step', text: '第 3/9 份：2025 全国甲卷', time: '晚上8:12:27' },
  { kind: 'search', text: '搜索：2025 全国甲卷 理综 第 36 题 有机', time: '晚上8:12:29' },
  { kind: 'success', text: '获取第 36 题 · 学科网 · 完整 · 图 2/2', time: '晚上8:12:35' },
  { kind: 'step', text: '第 4/9 份：2024 北京卷', time: '晚上8:12:38' },
  { kind: 'search', text: '搜索：2024 北京卷 化学 第 17 题', time: '晚上8:12:40' },
  { kind: 'success', text: '获取第 17 题 · 高途 · 完整 · 图 3/3 · 带网站解析', time: '晚上8:12:46' },
];
