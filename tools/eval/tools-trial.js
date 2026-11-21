#!/usr/bin/env node
/*
 * 第七版 C0 试验（见 docs/adr/0014）：汇编改成模型调用 App 内置工具，值不值得做。
 *
 *   STUDY_TEST_API_KEY=sk-... node tools/eval/tools-trial.js [--mode v5,model,api] [--only gk-] [--max-calls 40]
 *
 * 每道题（tools-cases.json 里的一份试卷里的一道有机大题）用三种方式各跑一遍：
 *   v5     第五版的流水线：一次带联网搜索的请求给出网址和定位用的几个字，再按网址取题。
 *   model  工具循环，找寻工具 = 同一个模型另发一次只开 deepseek_web_search 的请求。
 *   api    工具循环，找寻工具 = DeepSeek 的 Search API（每 1000 次 0.75 美元）。
 * 获取工具用简化的提取：下载网页、去掉标签，按题干开头的几个字定位，返回文字（不取图）。
 *
 * 通过的标准（README 第七版）：至少 4/5 定位到正确的原题，每道题的费用不超过第五版的 2 倍。
 * "正确的原题"自动判断两条：取到了文字、像有机大题（网页上有没有试卷名只记下来作参考）；
 * 结果另存一份 Markdown，方便人工复核。只支持 DeepSeek 官方接口。结果写在 tools/eval/results/。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..', '..');
const BASE_URL = (process.env.STUDY_TEST_BASE_URL || 'https://api.deepseek.com').replace(/\/$/, '').replace(/\/v1$/, '');
const API_KEY = process.env.STUDY_TEST_API_KEY;
const USER_AGENT = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const USD_TO_CNY = 7.2;
const SEARCH_API_USD = 0.75 / 1000;
// 第五版估算一份试卷查一次的用量（CompilationPlanner.tokensPerSearch*），来自 A0 试验。
const V5_ESTIMATE = { input: 70000, output: 5000 };

// ---------- 参数 ----------

function parseArgs(argv) {
  const args = { modes: ['v5', 'model', 'api'], only: null, maxCalls: 40, fetchFallback: false, model: 'deepseek-flash', cases: path.join(__dirname, 'tools-cases.json') };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--mode') args.modes = argv[++i].split(',');
    else if (arg === '--only') args.only = argv[++i];
    else if (arg === '--max-calls') args.maxCalls = Number(argv[++i]);
    else if (arg === '--fetch-fallback') args.fetchFallback = true;
    else if (arg === '--model') args.model = argv[++i];
    else if (arg === '--cases') args.cases = argv[++i];
    else throw new Error('不认识的参数：' + arg);
  }
  return args;
}

function price(model) {
  const table = JSON.parse(fs.readFileSync(path.join(ROOT, 'StudyKit/Sources/StudyKit/Pricing/prices.json'), 'utf8'));
  for (const provider of table.providers) {
    for (const entry of provider.models) {
      if (entry.ids.includes(model)) {
        const rate = provider.currency === 'USD' ? USD_TO_CNY : 1;
        return { input: (entry.input * rate) / 1e6, output: (entry.output * rate) / 1e6 };
      }
    }
  }
  throw new Error('价格表里没有 ' + model);
}

// ---------- 用量 ----------

class Meter {
  constructor(unit) {
    this.unit = unit;
    this.input = 0;
    this.output = 0;
    this.searches = 0;
    this.apiSearches = 0;
    this.apiFetches = 0;
    this.requests = 0;
  }
  addUsage(usage) {
    if (!usage) return;
    this.requests += 1;
    this.input += usage.prompt_tokens || 0;
    this.output += usage.completion_tokens || 0;
    this.searches += (usage.server_tool_use && usage.server_tool_use.tool_search) || 0;
  }
  get costCNY() {
    return this.input * this.unit.input + this.output * this.unit.output +
      (this.apiSearches + this.apiFetches) * SEARCH_API_USD * USD_TO_CNY;
  }
}

// ---------- 接口 ----------

async function post(url, body, timeout = 300000) {
  let lastError;
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt) await new Promise((r) => setTimeout(r, 2000 * attempt));
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: { Authorization: 'Bearer ' + API_KEY, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(timeout),
      });
      const text = await response.text();
      if (response.status === 429 || response.status >= 500) throw new Error('HTTP ' + response.status + ': ' + text.slice(0, 200));
      if (!response.ok) return { error: 'HTTP ' + response.status + ': ' + text.slice(0, 300) };
      return JSON.parse(text);
    } catch (error) {
      lastError = error;
    }
  }
  return { error: String(lastError && lastError.message) };
}

function chat(body) {
  return post(BASE_URL + '/chat/completions', body);
}

// ---------- 网页 ----------

async function download(url) {
  try {
    const response = await fetch(url, {
      headers: { 'User-Agent': USER_AGENT, 'Accept-Language': 'zh-CN,zh;q=0.9' },
      redirect: 'follow',
      signal: AbortSignal.timeout(25000),
    });
    const buffer = Buffer.from(await response.arrayBuffer());
    if (response.status === 403 || response.status === 401 || response.status === 429) return { status: 'refused', code: response.status };
    if (!response.ok) return { status: 'failed', code: response.status };
    const declared = ((response.headers.get('content-type') || '') + buffer.subarray(0, 4096).toString('latin1')).toLowerCase();
    const encoding = /gb2312|gbk|gb18030/.test(declared) ? 'gb18030' : 'utf-8';
    return { status: 'ok', html: new TextDecoder(encoding).decode(buffer) };
  } catch (error) {
    return { status: 'failed', code: error.name === 'TimeoutError' ? 'timeout' : error.message };
  }
}

function decodeEntities(text) {
  return text
    .replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&amp;/g, '&');
}

/** 网页正文：去掉脚本和标签，块级元素换行，图片写成 [图]。 */
function pageText(html) {
  const title = decodeEntities(((/<title[^>]*>([\s\S]*?)<\/title>/i.exec(html) || [])[1] || '').trim());
  const text = decodeEntities(html
    .replace(/<(script|style|noscript|svg|head)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<img[^>]*>/gi, '[图]')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|li|tr|h\d|section|article|dd|dt|table)>/gi, '\n')
    .replace(/<[^>]+>/g, ' '))
    .replace(/[ \t\u00a0]+/g, ' ')
    .replace(/\s*\n\s*/g, '\n')
    .replace(/\n{2,}/g, '\n')
    .trim();
  return { title, text };
}

const isHan = (ch) => /[\u4e00-\u9fff]/.test(ch);
const han = (text) => Array.from(text).filter(isHan).join('');

/**
 * 简化的获取：按题干开头 6 个汉字定位，取到最后一问开头之后约 400 字，或到下一道题号为止。
 * 和 App 的 QuestionExtractor 一样，汉字超过 1800 个就当作整卷。
 */
function locate(text, anchor, lastAnchor) {
  const chars = Array.from(text);
  const positions = [];
  chars.forEach((ch, i) => { if (isHan(ch)) positions.push(i); });
  const stream = positions.map((i) => chars[i]).join('');
  const first = han(anchor).slice(0, 6);
  if (!first) return { status: 'notFound' };
  const at = stream.indexOf(first);
  if (at < 0) return { status: 'notFound' };
  const start = positions[at];
  let end = chars.length;
  const last = han(lastAnchor || '').slice(0, 5);
  const lastAt = last ? stream.indexOf(last, at) : -1;
  if (lastAt >= 0) end = Math.min(chars.length, positions[lastAt] + 400);
  else end = Math.min(chars.length, start + 2500);
  let piece = chars.slice(start, end).join('');
  // 截到下一道题号（换行后紧跟"18."这类）为止。
  const next = /\n\s*\d{1,2}\s*[.．、]\s*[\u4e00-\u9fff（(]/.exec(piece.slice(30));
  if (next) piece = piece.slice(0, 30 + next.index);
  const length = han(piece).length;
  if (length > 1800) return { status: 'tooLong', text: piece.slice(0, 600) };
  return { status: lastAt >= 0 || !last ? 'complete' : 'partial', text: piece.trim() };
}

// ---------- 工具 ----------

const TOOLS = [
  {
    type: 'function',
    function: {
      name: 'search_web',
      description: '联网搜索，返回最多 8 个网页的标题、网址和摘要。',
      parameters: { type: 'object', properties: { query: { type: 'string', description: '搜索词' } }, required: ['query'] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'read_page',
      description: '下载一个网页，返回去掉标签后的正文（最多约 8000 字，图片写成[图]）。用来查看整卷页面上有哪些题、核对题号和题型。',
      parameters: { type: 'object', properties: { url: { type: 'string' } }, required: ['url'] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'fetch_question',
      description: 'App 从网页里取出一道原题并保存。anchor 是题干开头约 15 个字，last_anchor 是最后一问开头约 10 个字，都要逐字照抄网页上的文字。返回取到的文字和结果：complete 完整、partial 没找到最后一问、notFound 找不到这几个字、tooLong 像是整卷、refused 网站拒绝访问、failed 下载失败。取不到时可以换网址再试。',
      parameters: {
        type: 'object',
        properties: {
          number: { type: 'string', description: '题号' },
          url: { type: 'string' },
          anchor: { type: 'string' },
          last_anchor: { type: 'string' },
        },
        required: ['number', 'url', 'anchor'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'remove_question',
      description: '核对后发现题型或内容不符合要求时，去掉已经取到的一道题。',
      parameters: { type: 'object', properties: { number: { type: 'string' }, reason: { type: 'string' } }, required: ['number', 'reason'] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'finish_paper',
      description: '这份试卷查完了。没有符合要求的题也要调用，note 里说明。',
      parameters: { type: 'object', properties: { note: { type: 'string' } }, required: ['note'] },
    },
  },
];

function loopPrompt(testCase) {
  return [
    '你是一名严谨的教研员，正在为一份考试题汇编收集原题。原题必须由 App 从网页上取，你不能自己抄写或改写题目。',
    '可以用的工具：search_web 搜索；read_page 读网页正文；fetch_question 让 App 取一道题；remove_question 去掉取错的题；finish_paper 结束这份试卷。',
    '做法：',
    '1. 先搜索，确认这份试卷里哪几道题符合要求（题号和题型）。必要时用 read_page 读整卷页面核对。',
    '2. 每道题优先找"每道题单独一个页面"的题目详情页，例如 gaotu.cn/topic/…、zujuan.21cnjy.com/question/detail/…、菁优网的试题页；其次才是整卷页面。不要用需要下载文档、登录或付费才能看到题目的页面，也不要用公众号文章和小红书。',
    '3. 用 fetch_question 取题。看返回的文字核对题号和题型；结果不是 complete 就换一个网址再试。',
    '4. 题型不符合要求就不要取；取错了用 remove_question 去掉。没有符合要求的题不要编造。',
    '5. 全部取完后调用 finish_paper。',
    '',
    '要求：' + testCase.request,
    '试卷：' + testCase.paper.title,
  ].join('\n');
}

// ---------- 找寻工具的两种做法 ----------

async function searchByModel(query, model, meter) {
  const json = await chat({
    model,
    messages: [
      { role: 'system', content: '你是搜索助手。搜索用户给的词，只输出一个 JSON 数组，最多 8 项：[{"title":"…","url":"…","snippet":"一句话摘要"}]。只列搜索结果里真实出现的网页，不要编造网址，不要其他文字。' },
      { role: 'user', content: query },
    ],
    tools: [{ type: 'deepseek_web_search' }],
  });
  if (json.error) return { error: json.error };
  meter.addUsage(json.usage);
  const message = json.choices[0].message;
  let results = [];
  const raw = (message.content || '').trim();
  const start = raw.indexOf('[');
  const end = raw.lastIndexOf(']');
  if (start >= 0 && end > start) {
    try { results = JSON.parse(raw.slice(start, end + 1)); } catch (error) { results = []; }
  }
  if (!results.length) {
    results = (message.annotations || []).filter((a) => a.type === 'url_citation')
      .map((a) => ({ title: (a.url_citation || a).title, url: (a.url_citation || a).url, snippet: '' }));
  }
  return { results: results.slice(0, 8) };
}

async function searchByAPI(query, meter) {
  const json = await post(BASE_URL + '/v1/tools/search', { query: query.slice(0, 128), count: 8 }, 30000);
  if (json.error) return { error: json.error };
  const results = (json.results || []).map((r) => ({ title: r.title, url: r.url, snippet: r.snippet || r.summary || '' }));
  if (results.length) meter.apiSearches += 1;
  return { results };
}

/**
 * 直接下载被拒绝（403、405 等）或失败时，改用 DeepSeek 的 Fetch API 读网页（每 1000 次 0.75 美元）。
 * 它返回 Markdown，图片写成 ![](…)，这里换成 [图]。只在加了 --fetch-fallback 时用。
 */
async function readPage(url, options, meter) {
  const page = await download(url);
  if (page.status === 'ok') return Object.assign(pageText(page.html), { via: 'direct' });
  if (!options.fetchFallback) return { error: page.status, code: page.code };
  const json = await post(BASE_URL + '/v1/tools/fetch', { url }, 60000);
  if (json.error || !json.content) return { error: page.status, code: page.code, fallback: json.error || 'empty' };
  meter.apiFetches += 1;
  const text = json.content.replace(/!\[[^\]]*\]\([^)]*\)/g, '[图]').replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
  return { title: json.title || '', text, via: 'fetch-api' };
}

// ---------- 工具循环 ----------

async function runLoop(testCase, mode, options, meter) {
  const log = [];
  const questions = new Map();
  let finished = null;
  const messages = [
    { role: 'system', content: loopPrompt(testCase) },
    { role: 'user', content: '开始吧。' },
  ];
  let calls = 0;
  while (calls < options.maxCalls && !finished) {
    const json = await chat({ model: options.model, messages, tools: TOOLS, reasoning_effort: 'high' });
    if (json.error) {
      log.push('请求失败：' + json.error);
      break;
    }
    meter.addUsage(json.usage);
    const message = json.choices[0].message;
    const assistant = { role: 'assistant', content: message.content || '' };
    // 思考模式下调用工具，同一轮里要把思考内容原样传回去（ADR-0014）。
    if (message.reasoning_content) assistant.reasoning_content = message.reasoning_content;
    if (message.tool_calls && message.tool_calls.length) assistant.tool_calls = message.tool_calls;
    messages.push(assistant);
    if (!assistant.tool_calls) {
      log.push('模型没调用 finish_paper 就结束了：' + (message.content || '').slice(0, 120));
      break;
    }
    for (const call of assistant.tool_calls) {
      calls += 1;
      let input = {};
      try { input = JSON.parse(call.function.arguments || '{}'); } catch (error) { input = {}; }
      const result = await runTool(call.function.name, input, mode, options, meter, questions, testCase);
      if (call.function.name === 'finish_paper') finished = input.note || '';
      log.push(result.line);
      messages.push({ role: 'tool', tool_call_id: call.id, content: JSON.stringify(result.forModel) });
    }
  }
  if (!finished && calls >= options.maxCalls) log.push('到了 ' + options.maxCalls + ' 次工具调用的上限');
  return { log, questions: [...questions.values()], finished, calls };
}

async function runTool(name, input, mode, options, meter, questions, testCase) {
  switch (name) {
    case 'search_web': {
      const found = mode === 'api' ? await searchByAPI(input.query || '', meter) : await searchByModel(input.query || '', options.model, meter);
      if (found.error) return { line: '搜索失败：' + input.query, forModel: { error: found.error } };
      return { line: '搜索：' + input.query + ' → ' + found.results.length + ' 个网页', forModel: found };
    }
    case 'read_page': {
      const page = await readPage(input.url || '', options, meter);
      if (page.error) return { line: '读网页 ' + host(input.url) + ' · ' + page.error, forModel: { status: page.error, code: page.code } };
      return {
        line: '读网页 ' + host(input.url) + ' · ' + page.text.length + ' 字' + (page.via === 'fetch-api' ? '（Fetch API）' : ''),
        forModel: { title: page.title, text: page.text.slice(0, 8000) },
      };
    }
    case 'fetch_question': {
      const page = await readPage(input.url || '', options, meter);
      let result;
      let title = '';
      if (page.error) result = { status: page.error };
      else {
        title = page.title;
        result = locate(page.text, input.anchor || '', input.last_anchor || '');
        result.pageHasPaper = paperOnPage(testCase, page.title + '\n' + page.text.slice(0, 3000));
        if (page.via === 'fetch-api') result.via = 'fetch-api';
      }
      const number = String(input.number || '');
      const old = questions.get(number);
      const rank = { complete: 3, partial: 2, tooLong: 1 };
      if ((rank[result.status] || 0) > (old ? rank[old.status] || 0 : 0)) {
        questions.set(number, { number, url: input.url, title, status: result.status, text: result.text || '', pageHasPaper: result.pageHasPaper });
      }
      return {
        line: '获取第 ' + number + ' 题 · ' + host(input.url) + ' · ' + result.status + (result.via ? '（Fetch API）' : ''),
        forModel: { status: result.status, text: (result.text || '').slice(0, 2500) },
      };
    }
    case 'remove_question': {
      questions.delete(String(input.number || ''));
      return { line: '去掉第 ' + input.number + ' 题：' + (input.reason || ''), forModel: { ok: true } };
    }
    case 'finish_paper':
      return { line: '这份试卷完成：' + (input.note || ''), forModel: { ok: true } };
    default:
      return { line: '不认识的工具：' + name, forModel: { error: '没有这个工具' } };
  }
}

// ---------- 第五版流水线（对照）----------

/** 与 CompilationPlanner.findQuestionsRequest 的提示词保持一致。 */
function v5Prompt() {
  return [
    '你是一名严谨的教研员，负责在网上找到考试原题所在的网页。必须联网搜索并打开网页核对。',
    '要求：',
    '1. 优先找"每道题单独一个页面"的题目详情页，例如 gaotu.cn/topic/…、zujuan.21cnjy.com/question/detail/…、菁优网的试题页；其次才是整卷的资料页。不要选需要下载文档、登录或付费才能看到题目的页面，也不要选公众号文章和小红书。',
    '2. 每道题尽量给出 3 个以上不同网站的候选网址，按可靠程度排序。只列你实际打开过、确认是这道题的网址。',
    '3. anchor 是题干开头约 15 个字，last_anchor 是最后一问开头约 10 个字，都逐字照抄网页上的文字，用来在网页里定位这道题。',
    '4. 题型和内容都要符合要求，例如要"大题"就不要选择题。这份试卷里没有符合要求的题，就返回空数组，不要编造。',
    '5. 只输出一个 JSON 对象，不要其他文字：',
    '{"questions":[{"number":"题号","anchor":"…","last_anchor":"…","urls":["…"]}]}',
  ].join('\n');
}

async function runV5(testCase, options, meter) {
  const log = [];
  const json = await chat({
    model: options.model,
    messages: [
      { role: 'system', content: v5Prompt() },
      { role: 'user', content: '要求：' + testCase.request + '\n试卷：' + testCase.paper.title + '\n找出这份试卷里所有符合要求的题。' },
    ],
    tools: [{ type: 'deepseek_web_search' }],
    reasoning_effort: 'high',
  });
  if (json.error) return { log: ['请求失败：' + json.error], questions: [], finished: null, calls: 0 };
  meter.addUsage(json.usage);
  const raw = json.choices[0].message.content || '';
  let found = [];
  try { found = JSON.parse(raw.slice(raw.indexOf('{'), raw.lastIndexOf('}') + 1)).questions || []; } catch (error) { log.push('回答看不懂'); }
  log.push('模型给出 ' + found.length + ' 道题，搜索 ' + meter.searches + ' 次');
  const questions = [];
  for (const item of found) {
    let best = null;
    for (const url of item.urls || []) {
      const page = await download(url);
      if (page.status !== 'ok') { log.push('第 ' + item.number + ' 题 · ' + host(url) + ' · ' + page.status); continue; }
      const parsed = pageText(page.html);
      const result = locate(parsed.text, item.anchor || '', item.last_anchor || '');
      log.push('第 ' + item.number + ' 题 · ' + host(url) + ' · ' + result.status);
      if (result.status === 'complete' || (result.status === 'partial' && !best)) {
        best = { number: String(item.number), url, title: parsed.title, status: result.status, text: result.text, pageHasPaper: paperOnPage(testCase, parsed.title + '\n' + parsed.text.slice(0, 3000)) };
        if (result.status === 'complete') break;
      }
    }
    if (best) questions.push(best);
  }
  return { log, questions, finished: 'v5', calls: 0 };
}

// ---------- 判断 ----------

function host(url) {
  try { return new URL(url).host; } catch (error) { return String(url); }
}

function paperOnPage(testCase, text) {
  return text.includes(testCase.paper.year) && testCase.keywords.some((k) => text.includes(k));
}

/**
 * 像有机推断大题：有合成、结构、官能团一类的词，并且够长。
 * 不要求"（1）（2）"：高途这类网站把小问的编号去掉了。
 */
function looksOrganic(text) {
  const words = ['合成', '结构简式', '官能团', '反应类型', '同分异构', '有机', '路线'].filter((w) => text.includes(w)).length;
  return words >= 2 && han(text).length >= 120;
}

function judge(testCase, outcome) {
  const checked = outcome.questions.map((q) => ({
    number: q.number,
    status: q.status,
    host: host(q.url),
    located: q.status === 'complete' || q.status === 'partial',
    organic: looksOrganic(q.text),
    paper: !!q.pageHasPaper,
  }));
  // 网页上有没有试卷名只作参考：题目详情页的标题常常是知识点，不写哪份试卷。
  const good = checked.filter((q) => q.located && q.organic);
  const expected = testCase.expectNumber ? good.some((q) => q.number === testCase.expectNumber) : good.length > 0;
  return { checked, pass: expected };
}

// ---------- 主程序 ----------

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!API_KEY) throw new Error('需要设置环境变量 STUDY_TEST_API_KEY（DeepSeek 的 Key）');
  const unit = price(args.model);
  const v5Estimate = V5_ESTIMATE.input * unit.input + V5_ESTIMATE.output * unit.output;
  const cases = JSON.parse(fs.readFileSync(args.cases, 'utf8')).filter((c) => !args.only || c.id.includes(args.only));
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const outDir = path.join(__dirname, 'results', 'tools-' + stamp);
  fs.mkdirSync(outDir, { recursive: true });

  const rows = [];
  for (const testCase of cases) {
    await Promise.all(args.modes.map(async (mode) => {
      const meter = new Meter(unit);
      const started = Date.now();
      let outcome;
      try {
        outcome = mode === 'v5' ? await runV5(testCase, args, meter) : await runLoop(testCase, mode, args, meter);
      } catch (error) {
        outcome = { log: ['出错：' + error.message], questions: [], finished: null, calls: 0 };
      }
      const verdict = judge(testCase, outcome);
      const row = {
        id: testCase.id, mode, pass: verdict.pass, calls: outcome.calls,
        input: meter.input, output: meter.output, searches: meter.searches, apiSearches: meter.apiSearches,
        costCNY: meter.costCNY, seconds: Math.round((Date.now() - started) / 1000), checked: verdict.checked,
      };
      rows.push(row);
      const md = [
        '# ' + testCase.id + ' · ' + mode + (verdict.pass ? ' · 通过' : ' · 不通过'),
        '', testCase.paper.title + ' · ' + testCase.request, '',
        '费用 ' + meter.costCNY.toFixed(3) + ' 元 · 输入 ' + meter.input + ' · 输出 ' + meter.output +
          ' · 模型搜索 ' + meter.searches + ' 次 · Search API ' + meter.apiSearches + ' 次 · Fetch API ' + meter.apiFetches + ' 次 · 工具调用 ' + outcome.calls + ' 次 · ' + row.seconds + ' 秒',
        '', '## 调用记录', '', ...outcome.log.map((l) => '- ' + l),
        '', '## 取到的题', '',
        ...outcome.questions.flatMap((q) => ['### 第 ' + q.number + ' 题 · ' + q.status + ' · ' + q.url, '', q.text, '']),
      ].join('\n');
      fs.writeFileSync(path.join(outDir, testCase.id + '-' + mode + '.md'), md);
      console.log((verdict.pass ? '✓' : '✗') + ' ' + testCase.id.padEnd(14) + mode.padEnd(6) +
        ' ' + meter.costCNY.toFixed(3) + ' 元 · 工具 ' + outcome.calls + ' 次 · ' + row.seconds + ' 秒');
    }));
  }

  const summary = { model: args.model, v5EstimateCNY: v5Estimate, modes: {} };
  for (const mode of args.modes) {
    const mine = rows.filter((r) => r.mode === mode);
    const passed = mine.filter((r) => r.pass).length;
    const avg = mine.reduce((s, r) => s + r.costCNY, 0) / Math.max(mine.length, 1);
    summary.modes[mode] = { passed, total: mine.length, avgCostCNY: avg };
  }
  // 第五版的实际费用作为基准；没跑 v5 时用估算值。
  const base = summary.modes.v5 ? summary.modes.v5.avgCostCNY : v5Estimate;
  console.log('\n第五版基准：' + base.toFixed(3) + ' 元/题' + (summary.modes.v5 ? '（实测）' : '（估算）') + '；2 倍上限 ' + (2 * base).toFixed(3) + ' 元');
  for (const [mode, s] of Object.entries(summary.modes)) {
    const ok = mode === 'v5' ? null : s.passed >= Math.ceil(s.total * 0.8) && s.avgCostCNY <= 2 * base;
    s.meetsBar = ok;
    console.log(mode.padEnd(6) + ' ' + s.passed + '/' + s.total + ' 通过 · 平均 ' + s.avgCostCNY.toFixed(3) + ' 元/题' +
      (ok === null ? '' : ok ? ' · 达标' : ' · 不达标'));
  }
  fs.writeFileSync(path.join(outDir, 'summary.json'), JSON.stringify({ summary, rows }, null, 2));
  console.log('\n结果：' + path.relative(ROOT, outDir));
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}

module.exports = { pageText, locate, looksOrganic, han };
