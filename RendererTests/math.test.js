// 用 `node --test RendererTests/` 运行。
const test = require('node:test');
const assert = require('node:assert/strict');
const markdownit = require('../Renderer/vendor/markdown-it.min.js');
const core = require('../Renderer/core.js');

function makeRenderer() {
  const md = markdownit({ html: false, linkify: true });
  core.mathPlugin(md, {
    renderMath: (tex, display) => `<M${display ? 'D' : 'I'}>${tex}</M>`,
  });
  return (src, streaming = false) => md.render(src, { streaming });
}

const render = makeRenderer();

test('行内 $...$', () => {
  assert.equal(render('设 $x^2$ 为'), '<p>设 <MI>x^2</M> 为</p>\n');
});

test('行内 \\(...\\) 和 \\[...\\]', () => {
  assert.equal(render('由 \\(a+b\\) 得'), '<p>由 <MI>a+b</M> 得</p>\n');
  assert.equal(render('得 \\[x=1\\] 证毕'), '<p>得 <MD>x=1</M> 证毕</p>\n');
});

test('金额不是公式', () => {
  assert.equal(render('价格是 $5 和 $10'), '<p>价格是 $5 和 $10</p>\n');
});

test('转义的美元符号', () => {
  assert.equal(render('\\$x$'), '<p>$x$</p>\n');
});

test('块级 $$ 跨多行', () => {
  assert.equal(render('$$\n\\int_0^1 x\\,dx\n$$\n\n后文'), '<div class="math-block"><MD>\n\\int_0^1 x\\,dx\n</M></div>\n<p>后文</p>\n');
});

test('块级 \\[ 单行', () => {
  assert.equal(render('\\[ E=mc^2 \\]'), '<div class="math-block"><MD> E=mc^2 </M></div>\n');
});

test('公式内的下划线和星号不被当成 Markdown', () => {
  assert.equal(render('$a_1 * b_2 * c$'), '<p><MI>a_1 * b_2 * c</M></p>\n');
});

test('生成中未闭合的块级公式显示源码', () => {
  assert.equal(render('看：\n\n$$\n\\frac{1}{', true), '<p>看：</p>\n<pre class="math-pending">$$\n\\frac{1}{</pre>\n');
});

test('生成结束后仍未闭合的块级公式按普通文字显示', () => {
  assert.equal(render('$$\n\\frac{1}{', false), '<p>$$\n\\frac{1}{</p>\n');
});

test('列表中的公式', () => {
  assert.equal(render('- 第一步 $x=1$'), '<ul>\n<li>第一步 <MI>x=1</M></li>\n</ul>\n');
});

test('代码块里的美元符号不处理', () => {
  assert.equal(render('```sh\necho $HOME$\n```'), '<pre><code class="language-sh">echo $HOME$\n</code></pre>\n');
});
