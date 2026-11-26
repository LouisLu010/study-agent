/*
 * 第十版：用真实模型测试"整理成知识卡"（run.js --cards 调用这里）。
 * 用 App 的提示词（Prompts/base.md + Prompts/cards.md，和 ConceptCardWriter.request 拼法一样）整理 cards-cases.json 里的材料，检查：
 *   - 能找到并解析 JSON；卡片 1 到 10 张（题目可以要求更窄的范围）；
 *   - 每张卡的标题不超过 12 个字，核心内容不超过 220 个字、不超过 5 句；不放组件和标题；
 *   - 关联只指向存在的卡，种类只有三种，不是两张旧卡之间的，每张卡不超过 6 条；
 *   - 题目要求的关联有没有给出（例如新的"用导数求极值"和旧卡"导数的定义"之间要有前置）；
 *   - 材料里已经有旧卡讲过的内容时，不要再写一张同名的卡。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..', '..');
const PROMPTS = path.join(ROOT, 'StudyKit', 'Sources', 'StudyKit', 'Prompts');
const KINDS = ['prerequisite', 'contrast', 'application'];
const KIND_ALIASES = { 前置: 'prerequisite', 对比: 'contrast', 应用: 'application' };
const COMPONENTS = ['graph', 'geometry', 'chart', 'simulation', 'quiz', 'steps'];

function systemPrompt() {
  const read = (name) => fs.readFileSync(path.join(PROMPTS, name), 'utf8').trim();
  return read('base.md') + '\n\n# 这个会话的说明\n' + read('cards.md');
}

/** 和 ConceptCardWriter.message 一样。 */
function userMessage(testCase) {
  let text = '【要整理的材料】\n' + testCase.material;
  const old = testCase.candidates || [];
  text += '\n\n【已有的知识卡】\n' + (old.length ? old.map((c, i) => `旧${i + 1} ${c}`).join('\n') : '（还没有）');
  return text;
}

function jsonText(raw) {
  const fence = raw.match(/```[a-zA-Z]*\s*\n([\s\S]*?)\n\s*```/);
  if (fence && fence[1].trim().startsWith('{')) return fence[1].trim();
  const open = raw.indexOf('{');
  const close = raw.lastIndexOf('}');
  return open >= 0 && close > open ? raw.slice(open, close + 1) : null;
}

const chars = (s) => Array.from(s || '').length;

function check(testCase, raw) {
  const problems = [];
  const warnings = [];
  const text = jsonText(raw);
  if (!text) return { problems: ['没有找到 JSON'], warnings, cards: 0, links: 0 };
  let root;
  try {
    root = JSON.parse(text);
  } catch (error) {
    return { problems: ['JSON 解析失败：' + error.message], warnings, cards: 0, links: 0 };
  }
  if (!raw.trim().startsWith('```') && !raw.trim().startsWith('{')) warnings.push('JSON 前面有多余的文字');
  const cards = (root.cards || []).filter((c) => c && c.title && c.content);
  const [min, max] = testCase.cardRange || [1, 10];
  if (cards.length < min || cards.length > max) problems.push(`卡片 ${cards.length} 张，应在 ${min} 到 ${max} 张之间`);
  const keys = new Map(cards.map((c, i) => [String(c.key), i]));
  cards.forEach((c) => {
    if (chars(c.title) > 12) problems.push(`标题超过 12 个字：${c.title}`);
    if (chars(c.content) > 220) warnings.push(`核心内容 ${chars(c.content)} 字：${c.title}`);
    const sentences = (c.content.match(/[。！？!?]/g) || []).length;
    if (sentences > 5) warnings.push(`核心内容 ${sentences} 句：${c.title}`);
    if (/^#{1,6}\s/m.test(c.content)) problems.push(`核心内容里用了标题：${c.title}`);
    if (COMPONENTS.some((t) => c.content.includes('```' + t) || (c.example || '').includes('```' + t))) problems.push(`卡片里放了组件：${c.title}`);
  });

  const oldCount = (testCase.candidates || []).length;
  const resolve = (ref) => {
    const s = String(ref || '');
    if (keys.has(s)) return { new: keys.get(s) };
    const m = s.match(/^(?:旧|old)\s*(\d+)$/i);
    if (m && Number(m[1]) >= 1 && Number(m[1]) <= oldCount) return { old: Number(m[1]) - 1 };
    return null;
  };
  const links = [];
  const perCard = new Map();
  (root.links || []).forEach((l) => {
    const from = resolve(l.from);
    const to = resolve(l.to);
    const kind = KINDS.includes(String(l.kind).toLowerCase()) ? String(l.kind).toLowerCase() : KIND_ALIASES[l.kind];
    if (!from || !to) return problems.push(`关联指向不存在的卡：${l.from} → ${l.to}`);
    if (!kind) return problems.push(`关联种类不对：${l.kind}`);
    if ('old' in from && 'old' in to) return problems.push(`两张旧卡之间的关联：${l.from} → ${l.to}`);
    if (!l.reason) warnings.push(`关联没有理由：${l.from} → ${l.to}`);
    else if (chars(l.reason) > 25) warnings.push(`理由超过 25 个字：${l.reason}`);
    links.push({ from, to, kind });
    [l.from, l.to].forEach((k) => perCard.set(String(k), (perCard.get(String(k)) || 0) + 1));
  });
  perCard.forEach((n, k) => {
    if (n > 6) problems.push(`${k} 有 ${n} 条关联，超过 6 条`);
  });

  // 题目要求的关联：一头用"旧n"，或者新卡标题里的关键字。
  const matches = (end, spec) => {
    if (spec.startsWith('旧')) return 'old' in end && end.old === Number(spec.slice(1)) - 1;
    return 'new' in end && cards[end.new].title.includes(spec);
  };
  (testCase.expectLinks || []).forEach((e) => {
    const ok = links.some((l) =>
      (!e.kind || l.kind === e.kind) &&
      ((matches(l.from, e.a) && matches(l.to, e.b)) || ((!e.directed || l.kind === 'contrast') && matches(l.from, e.b) && matches(l.to, e.a))),
    );
    if (!ok) problems.push(`缺少关联：${e.a} ${e.directed ? '→' : '—'} ${e.b}${e.kind ? '（' + e.kind + '）' : ''}`);
  });
  (testCase.noCardTitled || []).forEach((t) => {
    if (cards.some((c) => c.title.includes(t))) problems.push(`又写了一张已有的卡：${t}`);
  });
  return { problems, warnings, cards: cards.length, links: links.length, titles: cards.map((c) => c.title) };
}

async function ask(model, testCase) {
  const baseURL = process.env.STUDY_TEST_BASE_URL;
  const apiKey = process.env.STUDY_TEST_API_KEY;
  if (!baseURL || !apiKey) throw new Error('需要设置环境变量 STUDY_TEST_BASE_URL 和 STUDY_TEST_API_KEY');
  const started = Date.now();
  const response = await fetch(baseURL.replace(/\/$/, '') + '/chat/completions', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + apiKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model,
      messages: [
        { role: 'system', content: systemPrompt() },
        { role: 'user', content: userMessage(testCase) },
      ],
    }),
    signal: AbortSignal.timeout(240000),
  });
  const text = await response.text();
  if (!response.ok) throw new Error('HTTP ' + response.status + ': ' + text.slice(0, 200));
  const json = JSON.parse(text);
  return { content: json.choices[0].message.content || '', ms: Date.now() - started, usage: json.usage || {} };
}

async function run(args) {
  const cases = JSON.parse(fs.readFileSync(path.join(__dirname, 'cards-cases.json'), 'utf8'))
    .filter((c) => !args.only || c.id.includes(args.only));
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const outDir = path.join(__dirname, 'results', stamp + '-cards');
  console.log('知识卡：' + cases.length + ' 道\n');
  const summary = {};
  for (const model of args.models) {
    const dir = path.join(outDir, model.replace(/[^\w.-]/g, '_'));
    fs.mkdirSync(dir, { recursive: true });
    const results = await Promise.all(cases.map(async (testCase) => {
      try {
        const reply = await ask(model, testCase);
        fs.writeFileSync(path.join(dir, testCase.id + '.md'), reply.content);
        const result = check(testCase, reply.content);
        return Object.assign({ id: testCase.id, ms: reply.ms, tokens: (reply.usage.prompt_tokens || 0) + '/' + (reply.usage.completion_tokens || 0) }, result, { pass: result.problems.length === 0 });
      } catch (error) {
        return { id: testCase.id, problems: ['请求失败：' + error.message], warnings: [], pass: false };
      }
    }));
    console.log('== ' + model + ' ==');
    results.forEach((r) => {
      const notes = r.problems.concat(r.warnings.map((w) => '（警告）' + w));
      console.log((r.pass ? '  ✓ ' : '  ✗ ') + r.id.padEnd(22) + `${r.cards ?? '-'} 张 ${r.links ?? '-'} 条`.padEnd(10) +
        (r.ms ? (r.ms / 1000).toFixed(1) + 's ' + r.tokens : '').padEnd(16) + (notes.length ? notes.join('；') : '') +
        (r.titles ? '\n      ' + r.titles.join(' · ') : ''));
    });
    const passed = results.filter((r) => r.pass).length;
    console.log('  通过 ' + passed + '/' + results.length + '\n');
    summary[model] = { passed, cases: results.length, results };
  }
  fs.writeFileSync(path.join(outDir, 'summary.json'), JSON.stringify(summary, null, 2));
  console.log('结果：' + path.relative(ROOT, outDir));
}

module.exports = { run, check, userMessage, systemPrompt };
