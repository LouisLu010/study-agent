import React from 'react';
import { Renderer, type PrintDoc } from './Renderer';
import { compilation } from '../content';

// 汇编的 PDF：正文用渲染器的 print.js 排版（App 里也是），页眉页脚照 App/Library/CompilationPDF.swift 画：
// A4（595.2 × 841.8 pt），页边距上下 54、左右 50；页眉居中写汇编标题、下面一条细线，页脚写"第 1 页 / 共 2 页"。

export const a4 = { width: 595.2, height: 841.8, top: 54, side: 50 };
const printable = { width: a4.width - a4.side * 2, height: a4.height - a4.top * 2, gap: 100 };

const img = (name: string, w: number, h: number) => `![](../promo-assets/${name}.svg "w=${w},h=${h}")`;

// 题目文字是示例，不是真实试卷的原文（见 docs/promo/README.md 的"待替换"）。
export const pdfDoc: PrintDoc = {
  title: compilation.request,
  subtitle: '共 4 题',
  includeAnswers: true,
  questions: [
    {
      label: '2025 · 北京卷 · 第 17 题',
      content: ['有机物 K 是合成一种药物的中间体，其合成路线如下（部分条件已略去）：', '', img('route-1', 495, 134), '', '（1）A 的名称是______。', '', '（2）B → C 的反应类型是______。', '', '（3）D 中含氧官能团的名称是______。', '', '（4）写出 C → D 的化学方程式：______。'].join('\n'),
      answer: '（1）甲苯　（2）取代反应（水解反应）　（3）醛基　（4）$2\\,\\ce{C6H5CH2OH + O2 ->[Cu][\\Delta] 2C6H5CHO + 2H2O}$',
      answerLabel: '网站解析 · 高途',
    },
    {
      label: '2025 · 新课标卷 · 第 29 题',
      content: ['化合物 G 是一种解热镇痛药，以 E 为原料合成 G 的路线如下：', '', img('route-2', 495, 116), '', '（1）E 的化学名称是______。', '', '（2）F 中官能团的名称是______。', '', '（3）G 的分子式为 $\\ce{C9H8O4}$，写出 G 的结构简式______。'].join('\n'),
      answer: '（1）苯酚　（2）酯基　（3）邻乙酰氧基苯甲酸',
      answerLabel: '网站解析 · 菁优网',
    },
    {
      label: '2025 · 全国甲卷 · 第 36 题',
      content: '[化学——选修 5：有机化学基础] 以芳香烃 A 为原料合成 G 的路线如下：……',
      answer: '略',
      answerLabel: 'AI 解析',
    },
    {
      label: '2024 · 北京卷 · 第 17 题',
      content: '某抗病毒药物的中间体 J 的合成路线如下：……',
      answer: '略',
      answerLabel: '网站解析 · 高途',
    },
  ],
};

export const PdfPage: React.FC<{ index: number; pages: number; style?: React.CSSProperties }> = ({ index, pages, style }) => (
  <div style={{ position: 'relative', width: a4.width, height: a4.height, background: '#fff', boxShadow: '0 20px 60px rgba(0,0,0,0.45)', overflow: 'hidden', ...style }}>
    <div style={{ position: 'absolute', top: 11, left: 0, right: 0, textAlign: 'center', fontSize: 8.5, color: '#555', fontFamily: '-apple-system, "PingFang SC", sans-serif' }}>{compilation.request}</div>
    <div style={{ position: 'absolute', top: 26, left: a4.side, right: a4.side, height: 0.5, background: '#aaa' }} />
    <div style={{ position: 'absolute', top: a4.top, left: a4.side, width: printable.width, height: printable.height, overflow: 'hidden' }}>
      <div style={{ position: 'absolute', top: 0, left: -index * (printable.width + printable.gap) }}>
        <Renderer print={pdfDoc} page={printable} width={(printable.width + printable.gap) * pages} height={printable.height} />
      </div>
    </div>
    <div style={{ position: 'absolute', bottom: 11, left: 0, right: 0, textAlign: 'center', fontSize: 8.5, color: '#555', fontFamily: '-apple-system, "PingFang SC", sans-serif' }}>
      第 {index + 1} 页 / 共 {pages} 页
    </div>
  </div>
);
