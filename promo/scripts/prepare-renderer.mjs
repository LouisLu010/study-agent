// 渲染前的准备：
// 1. 把仓库里的 Renderer/ 复制到 public/renderer/，生成 promo.html：
//    - 最前面加载 promo-clock.js（虚拟时钟），最后加载 promo-bridge.js（给 Remotion 调用的接口）；
//    - 深色模式写死：把 prefers-color-scheme 的媒体查询改成恒真或恒假；
//    - 字体改成苹果系统字体（Chrome 不认 -apple-system-body）。
// 2. 把 Thinking Orbs 的 orb-core.js 复制到 src/vendor/，加一个按毫秒绘制的入口，让小球跟着帧走。
// 3. 把 App 的图标复制成 public/icon.png。
// 生成的文件都不进仓库（见 .gitignore）。
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const promo = join(here, '..');
const source = join(promo, '..', 'Renderer');
const target = join(promo, 'public', 'renderer');

rmSync(target, { recursive: true, force: true });
cpSync(source, target, { recursive: true });

const DARK = /\(\s*prefers-color-scheme:\s*dark\s*\)/g;
const LIGHT = /\(\s*prefers-color-scheme:\s*light\s*\)/g;
function forceDark(text) {
  return text.replace(DARK, '(min-width: 0px)').replace(LIGHT, '(max-width: 0px)');
}

function walk(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path);
    else if (/\.(css|js|html)$/.test(name) && !path.includes(`${join('vendor', 'katex')}`)) {
      const text = readFileSync(path, 'utf8');
      const next = forceDark(text);
      if (next !== text) writeFileSync(path, next);
    }
  }
}
walk(target);

const index = readFileSync(join(target, 'index.html'), 'utf8');
const head = [
  '<script src="../promo-clock.js"></script>',
  '<style>',
  ':root { color-scheme: dark; }',
  'html, body { background: #000; }',
  'body { font: 17px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif;',
  '  -webkit-font-smoothing: antialiased; margin: 0; overflow: hidden; }',
  '</style>',
].join('\n');
const html = index
  .replace('<head>', '<head>\n' + head)
  .replace('</body>', '  <script src="../promo-bridge.js"></script>\n</body>');
if (html === index) throw new Error('index.html 的结构变了，promo.html 没能生成');
writeFileSync(join(target, 'promo.html'), html);

// ---------- Thinking Orbs ----------
const orbSource = join(promo, 'node_modules', '@yogesharc', 'thinking-orbs', 'dist', 'orb-core.js');
const orb = readFileSync(orbSource, 'utf8');
const hook = '    draw(tick(look, performance.now(), speed));';
if (!orb.includes(hook)) throw new Error('thinking-orbs 的 orb-core.js 和 0.1.2 不一样，补丁对不上');
const patched = '// 来自 @yogesharc/thinking-orbs 0.1.2（MIT）。本地改动：加了 svg.__drawAt(ms)，按给定的时间画一帧，让 Remotion 逐帧驱动。\n' +
  orb.replace(hook, hook + '\n    svg.__drawAt = (ms) => draw(ms * speed);');
mkdirSync(join(promo, 'src', 'vendor'), { recursive: true });
writeFileSync(join(promo, 'src', 'vendor', 'orb-core.js'), patched);
writeFileSync(join(promo, 'src', 'vendor', 'orb-core.d.ts'),
  "export type OrbState = 'idle' | 'working' | 'reasoning' | 'searching' | 'background' | 'retrying';\n" +
  'export declare function mountOrb(svg: SVGSVGElement, options?: { state?: OrbState; size?: number; speed?: number; label?: string }): { pause(): void; play(): void; destroy(): void };\n');

// 3. App 的图标（1.0 版的开场、片尾和左上角的标志）。
cpSync(join(promo, '..', 'App', 'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon.png'), join(promo, 'public', 'icon.png'));

console.log('renderer → public/renderer/promo.html；orb → src/vendor/orb-core.js；icon → public/icon.png');
