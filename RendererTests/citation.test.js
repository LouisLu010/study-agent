// 联网搜索的引用角标。用 `node --test RendererTests/` 运行。
const test = require('node:test');
const assert = require('node:assert/strict');
const markdownit = require('../Renderer/vendor/markdown-it.min.js');
const core = require('../Renderer/core.js');

function makeRenderer() {
  const md = markdownit({ html: false, linkify: true });
  core.mathPlugin(md, { renderMath: (tex) => tex });
  core.citationPlugin(md);
  return (src) => md.render(src);
}

const render = makeRenderer();

test('角标渲染成带 sa-cite 的链接', () => {
  assert.equal(
    render('考了 36 题。[[1]](<https://a.com/x%20y>)[[2]](<https://b.cn/(p)>)'),
    '<p>考了 36 题。<a href="https://a.com/x%20y" class="sa-cite">[1]</a><a href="https://b.cn/(p)" class="sa-cite">[2]</a></p>\n'
  );
});

test('普通链接不加 sa-cite', () => {
  assert.equal(render('见 [官网](https://c.com)'), '<p>见 <a href="https://c.com">官网</a></p>\n');
  assert.equal(render('[第 1 题](https://c.com)'), '<p><a href="https://c.com">第 1 题</a></p>\n');
});

test('纯文字里角标只留编号', () => {
  assert.equal(core.toPlainText('答案是 B。[[1]](<https://a.com>)[[12]](<https://b.com/q?x=1>)'), '答案是 B。[1][12]');
  assert.equal(core.toPlainText('[官网](https://c.com)'), '[官网](https://c.com)');
});

test('图片标题里的尺寸转成宽度', () => {
  const md = markdownit({ html: false, linkify: true });
  core.imagePlugin(md);
  assert.equal(
    md.render('看图![](sa-asset:ABC "w=554,h=255")'),
    '<p>看图<img src="sa-asset:ABC" alt="" width="554" class="sa-figure"></p>\n'
  );
  assert.equal(md.render('![](x.png "说明")'), '<p><img src="x.png" alt="" title="说明"></p>\n');
});
