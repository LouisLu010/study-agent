#!/usr/bin/env node
/*
 * 用真实模型测试组件：用 App 的内置提示词提问，检查回答里的组件格式和使用是否恰当。
 *
 *   STUDY_TEST_BASE_URL=https://.../v1 STUDY_TEST_API_KEY=sk-... \
 *     node tools/eval/run.js --model deepseek-flash [--model grok-4.7] [--only graph-] [--simple]
 *
 * 只支持 OpenAI 兼容接口。结果写在 tools/eval/results/（已被 .gitignore 忽略）。
 * Key 只从环境变量读取，不要写进仓库。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const core = require('../../Renderer/core.js');

const ROOT = path.join(__dirname, '..', '..');
const PROMPTS = path.join(ROOT, 'StudyKit', 'Sources', 'StudyKit', 'Prompts');

// ---------- 参数 ----------

function parseArgs(argv) {
  const args = { models: [], only: null, simple: false, concurrency: 4, cases: path.join(__dirname, 'cases.json') };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--model') args.models.push(argv[++i]);
    else if (arg === '--only') args.only = argv[++i];
    else if (arg === '--simple') args.simple = true;
    else if (arg === '--concurrency') args.concurrency = Number(argv[++i]);
    else if (arg === '--cases') args.cases = argv[++i];
    else throw new Error('不认识的参数：' + arg);
  }
  if (!args.models.length) args.models.push('deepseek-flash');
  return args;
}

// ---------- 提示词（与 SystemPrompt.compose 保持一致）----------

function systemPrompt(simple) {
  const read = (name) => fs.readFileSync(path.join(PROMPTS, name + '.md'), 'utf8').trim();
  const parts = [read('base')];
  if (!simple) parts.push(read('components'));
  return parts.join('\n\n');
}

// ---------- 请求 ----------

async function ask(model, system, prompt) {
  const baseURL = process.env.STUDY_TEST_BASE_URL;
  const apiKey = process.env.STUDY_TEST_API_KEY;
  if (!baseURL || !apiKey) throw new Error('需要设置环境变量 STUDY_TEST_BASE_URL 和 STUDY_TEST_API_KEY');

  const body = JSON.stringify({
    model,
    messages: [
      { role: 'system', content: system },
      { role: 'user', content: prompt },
    ],
  });
  let lastError;
  for (let attempt = 0; attempt < 2; attempt++) {
    const started = Date.now();
    try {
      const response = await fetch(baseURL.replace(/\/$/, '') + '/chat/completions', {
        method: 'POST',
        headers: { Authorization: 'Bearer ' + apiKey, 'Content-Type': 'application/json' },
        body,
        signal: AbortSignal.timeout(240000),
      });
      const text = await response.text();
      if (!response.ok) throw new Error('HTTP ' + response.status + ': ' + text.slice(0, 200));
      const json = JSON.parse(text);
      const message = json.choices && json.choices[0] && json.choices[0].message;
      return { content: (message && message.content) || '', ms: Date.now() - started };
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

// ---------- 检查 ----------

/** 去掉代码块后的正文，用来检查公式分隔符。 */
function proseOnly(markdown) {
  const lines = markdown.split('\n');
  const fences = core.extractFences(markdown);
  for (let k = fences.length - 1; k >= 0; k--) lines.splice(fences[k].start, fences[k].end - fences[k].start);
  return lines.join('\n');
}

function check(testCase, content, available) {
  const fences = core.extractFences(content);
  const components = fences.filter((f) => available.includes(f.language));
  const blocks = components.map((f) => {
    const result = core.parseComponent(f.language, f.content);
    return { type: f.language, ok: result.ok, error: result.ok ? null : result.error };
  });
  const used = [...new Set(blocks.map((b) => b.type))];
  const expect = testCase.expect || [];
  const allowed = new Set(expect.concat(testCase.allow || []));

  const problems = [];
  expect.forEach((type) => {
    if (!used.includes(type)) problems.push('缺少 ' + type);
  });
  used.forEach((type) => {
    if (!allowed.has(type)) problems.push('不该用 ' + type);
  });
  blocks.forEach((b) => {
    if (!b.ok) problems.push(b.type + ' 格式有误：' + b.error);
  });
  const warnings = [];
  components.forEach((f) => {
    const result = core.parseComponent(f.language, f.content);
    if (result.ok && result.value.warnings) result.value.warnings.forEach((w) => warnings.push(f.language + ' ' + w));
  });
  // 测验的每道题都应该写 subject 和 topic，缺了记为警告。
  components.filter((f) => f.language === 'quiz').forEach((f) => {
    const result = core.parseComponent('quiz', f.content);
    if (!result.ok) return;
    const missing = result.value.questions.filter((q) => !q.subject || !q.topic).length;
    if (missing) warnings.push('quiz 有 ' + missing + ' 道题没写 subject 或 topic');
  });
  // 题目要求某种模拟时，要用对种类。
  if (testCase.simKind) {
    const kinds = components.filter((f) => f.language === 'simulation').map((f) => {
      const result = core.parseComponent('simulation', f.content);
      return result.ok ? result.value.kind : null;
    });
    if (!kinds.includes(testCase.simKind)) problems.push('没有 ' + testCase.simKind + ' 模拟（用了 ' + (kinds.join('、') || '无') + '）');
  }
  components.forEach((f) => {
    if (f.language !== 'simulation') return;
    const result = core.parseComponent('simulation', f.content);
    if (result.ok) result.value.warnings.forEach((w) => warnings.push('simulation ' + w));
  });
  // 题目要求能调参数时，至少一个坐标图要带参数。
  if (testCase.needsParams) {
    const withParams = components.some((f) => {
      const result = core.parseComponent(f.language, f.content);
      return result.ok && result.value.params && result.value.params.length > 0;
    });
    if (!withParams) problems.push('坐标图没有参数');
  }
  // 用 Python 等代码画图，说明模型没按提示词使用组件。
  fences
    .filter((f) => !available.includes(f.language))
    .forEach((f) => {
      if (/matplotlib|plt\.|pyplot|plotly|desmos/i.test(f.content)) problems.push('用 ' + (f.language || '代码') + ' 画图');
      if (f.language === 'json' && /"(functions|points|segments)"/.test(f.content)) problems.push('组件写成了 json 代码块');
    });
  // 渲染器也支持 \( \) 和 \[ \]，所以只记为警告，不算失败。
  const badDelimiters = (proseOnly(content).match(/\\\(|\\\[/g) || []).length;
  if (badDelimiters) warnings.push('用了 \\( 或 \\[ 分隔符 ' + badDelimiters + ' 处');

  return { blocks, used, problems, warnings, pass: problems.length === 0 };
}

// ---------- 主程序 ----------

async function runPool(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await worker(items[index], index);
    }
  }));
  return results;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const available = args.simple ? [] : core.componentTypes();
  const allCases = JSON.parse(fs.readFileSync(args.cases, 'utf8'));
  // 只跑当前已经实现的组件能覆盖的题。
  const cases = allCases.filter((c) =>
    (c.expect || []).every((type) => available.includes(type)) &&
    (!args.only || c.id.includes(args.only)),
  );
  const system = systemPrompt(args.simple);
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const outDir = path.join(__dirname, 'results', stamp);

  console.log('组件：' + (available.join(', ') || '（简洁模式）') + '；题目：' + cases.length + ' 道\n');
  const summary = {};

  for (const model of args.models) {
    const dir = path.join(outDir, model.replace(/[^\w.-]/g, '_'));
    fs.mkdirSync(dir, { recursive: true });

    const results = await runPool(cases, args.concurrency, async (testCase) => {
      try {
        const { content, ms } = await ask(model, system, testCase.prompt);
        fs.writeFileSync(path.join(dir, testCase.id + '.md'), content);
        return Object.assign({ id: testCase.id, ms }, check(testCase, content, available));
      } catch (error) {
        return { id: testCase.id, error: error.message, blocks: [], problems: ['请求失败：' + error.message], pass: false };
      }
    });

    const blocks = results.flatMap((r) => r.blocks);
    const validBlocks = blocks.filter((b) => b.ok).length;
    const passed = results.filter((r) => r.pass).length;
    summary[model] = {
      cases: results.length,
      passed,
      blocks: blocks.length,
      validBlocks,
      validRate: blocks.length ? validBlocks / blocks.length : null,
      results,
    };

    console.log('== ' + model + ' ==');
    results.forEach((r) => {
      const types = (r.blocks || []).map((b) => b.type + (b.ok ? '' : '✗')).join(' ') || '-';
      const time = r.ms ? (r.ms / 1000).toFixed(1) + 's' : '';
      const notes = r.problems.concat((r.warnings || []).map((w) => '（警告）' + w));
      console.log((r.pass ? '  ✓ ' : '  ✗ ') + r.id.padEnd(22) + types.padEnd(18) + time.padStart(7) +
        (notes.length ? '  ' + notes.join('；') : ''));
    });
    const rate = blocks.length ? ((100 * validBlocks) / blocks.length).toFixed(0) + '%' : '无组件';
    console.log('  通过 ' + passed + '/' + results.length + '，组件格式正确 ' + validBlocks + '/' + blocks.length + '（' + rate + '）\n');
  }

  fs.writeFileSync(path.join(outDir, 'summary.json'), JSON.stringify(summary, null, 2));
  console.log('结果：' + path.relative(ROOT, outDir));
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
