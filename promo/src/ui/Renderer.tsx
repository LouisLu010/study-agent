import React, { useEffect, useRef, useState } from 'react';
import { cancelRender, continueRender, delayRender, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';

// 在 iframe 里跑 App 的渲染器（Renderer/，由 scripts/prepare-renderer.mjs 复制成 public/renderer/promo.html）。
// 渲染器里的时间换成了虚拟时钟（public/promo-clock.js），这里每帧把时钟推进 1/fps 秒，
// 并在指定的帧做指定的操作（拖滑块、点按钮）。往回跳帧时重新载入页面，从头快进，所以任何一帧都能单独渲染。

export type Action =
  | { frame: number; slider: { component?: number; selector: string; nth?: number; value?: number; phase: 'begin' | 'move' | 'end' } }
  | { frame: number; click: { component?: number; selector: string; nth?: number } }
  | { frame: number; answer: { component?: number; question: number; option: number } };

export type Rect = { x: number; y: number; width: number; height: number };

export type PrintDoc = {
  title: string;
  subtitle?: string;
  includeAnswers: boolean;
  questions: { label: string; content: string; answer?: string; answerLabel?: string; group?: string }[];
};

type Bridge = {
  render(markdown: string, options?: object): void;
  print(doc: PrintDoc, page?: { width: number; height: number; gap: number }): Promise<void>;
  ready(): boolean;
  height(): number;
  rects(): Rect[];
  slider(i: number, s: string, nth: number, v: number | undefined, phase: string): void;
  click(i: number, s: string, nth: number): void;
  answer(i: number, q: number, o: number): void;
};
type RendererWindow = Window & { __promo?: Bridge; __clock?: { advance(ms: number): void } };

type Props = {
  /** 一条回答的 Markdown，或者汇编 PDF 的数据（二选一）。 */
  markdown?: string;
  print?: PrintDoc;
  /** 汇编 PDF 的分页：每页可打印区域的宽高，页与页之间的间隔。 */
  page?: { width: number; height: number; gap: number };
  width: number;
  /** 固定高度；不给就跟着内容的高度变。 */
  height?: number;
  actions?: Action[];
  options?: object;
  /** 每帧画完后报告内容高度和每个组件的位置（iframe 内的坐标）。 */
  onLayout?: (layout: { height: number; rects: Rect[] }) => void;
  style?: React.CSSProperties;
};

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export const Renderer: React.FC<Props> = ({ markdown, print, page, width, height, actions = [], options, onLayout, style }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const iframe = useRef<HTMLIFrameElement>(null);
  const progress = useRef({ frame: -1, busy: Promise.resolve() });
  const [contentHeight, setContentHeight] = useState(height ?? 200);
  const [src] = useState(() => staticFile('renderer/promo.html'));

  useEffect(() => {
    const handle = delayRender(`渲染器 第 ${frame} 帧`, { timeoutInMilliseconds: 120000 });
    const run = async () => {
      const element = iframe.current!;
      let win = element.contentWindow as RendererWindow | null;

      if (progress.current.frame < 0 || frame < progress.current.frame || !win?.__promo) {
        await new Promise<void>((resolve) => {
          element.onload = () => resolve();
          element.src = `${src}?load=${Date.now()}`;
        });
        win = element.contentWindow as RendererWindow;
        if (print) await win.__promo!.print(print, page);
        else win.__promo!.render(markdown ?? '', options);
        for (let i = 0; i < 400 && !win.__promo!.ready(); i++) await wait(25);
        if (!win.__promo!.ready()) throw new Error('渲染器 10 秒内没有画完组件');
        progress.current.frame = -1;
      }

      const bridge = win!.__promo!;
      for (let f = progress.current.frame + 1; f <= frame; f++) {
        if (f > 0) win!.__clock!.advance(1000 / fps);
        for (const action of actions) {
          if (action.frame !== f) continue;
          if ('slider' in action) {
            const a = action.slider;
            bridge.slider(a.component ?? 0, a.selector, a.nth ?? 0, a.value, a.phase);
          } else if ('click' in action) {
            bridge.click(action.click.component ?? 0, action.click.selector, action.click.nth ?? 0);
          } else {
            bridge.answer(action.answer.component ?? 0, action.answer.question, action.answer.option);
          }
        }
      }
      // 操作会新建 CSS 动画，摆到当前时刻再截图。
      win!.__clock!.advance(0);
      progress.current.frame = frame;

      const measured = bridge.height();
      if (height === undefined && measured !== contentHeight) setContentHeight(measured);
      onLayout?.({ height: measured, rects: bridge.rects() });
      // 等 iframe 把这一帧画出来。
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    };
    // 出错就让整次渲染失败，不要悄悄截一张没画好的图。
    progress.current.busy = progress.current.busy.then(run).then(
      () => continueRender(handle),
      (error) => cancelRender(error),
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [frame]);

  return (
    <iframe
      ref={iframe}
      title="renderer"
      scrolling="no"
      style={{ width, height: height ?? contentHeight, border: 0, display: 'block', background: 'transparent', colorScheme: 'dark', ...style }}
    />
  );
};
