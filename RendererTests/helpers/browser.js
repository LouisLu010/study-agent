// 只模拟渲染器使用的 DOM 接口；Markdown、组件挂载和测验逻辑均加载项目源码。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const core = require('../../Renderer/core.js');
const markdownit = require('../../Renderer/vendor/markdown-it.min.js');

class Events {
  constructor() { this.listeners = new Map(); }
  addEventListener(type, handler) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(handler);
  }
  removeEventListener(type, handler) { this.listeners.get(type)?.delete(handler); }
  dispatchEvent(event) {
    if (!event.target) event.target = this;
    for (const handler of this.listeners.get(event.type) || []) handler(event);
  }
}

class TextNode {
  constructor(text) {
    this.nodeType = 3;
    this.textContent = text;
    this.parentNode = null;
  }
  remove() {
    if (!this.parentNode) return;
    const siblings = this.parentNode.childNodes;
    siblings.splice(siblings.indexOf(this), 1);
    this.parentNode = null;
  }
}

function decode(text) {
  return text.replace(/&(amp|lt|gt|quot|#39);/g, (entity, name) => ({
    amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'",
  })[name]);
}

class Element extends Events {
  constructor(tagName, document) {
    super();
    this.nodeType = 1;
    this.tagName = tagName.toUpperCase();
    this.ownerDocument = document;
    this.parentNode = null;
    this.childNodes = [];
    this.attributes = {};
    this.dataset = {};
    this.style = {};
    this.hidden = false;
    this.disabled = false;
    this.value = '';
    this.clientWidth = 320;
    this.clientHeight = 240;
    const classes = () => this.className.split(/\s+/).filter(Boolean);
    this.classList = {
      contains: (name) => classes().includes(name),
      add: (...names) => { this.className = [...new Set(classes().concat(names))].join(' '); },
      remove: (...names) => { this.className = classes().filter((name) => !names.includes(name)).join(' '); },
      toggle: (name, force) => {
        const enabled = force === undefined ? !classes().includes(name) : force;
        if (enabled) this.classList.add(name);
        else this.classList.remove(name);
        return enabled;
      },
    };
    if (tagName === 'template') this.content = new Element('fragment', document);
  }
  get className() { return this.attributes.class || ''; }
  set className(value) { this.attributes.class = value; }
  get id() { return this.attributes.id || ''; }
  set id(value) { this.attributes.id = value; }
  get firstChild() { return this.childNodes[0] || null; }
  get isConnected() {
    for (let node = this; node; node = node.parentNode) {
      if (node === this.ownerDocument) return true;
    }
    return false;
  }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
    if (name.startsWith('data-')) {
      this.dataset[name.slice(5).replace(/-([a-z])/g, (_, char) => char.toUpperCase())] = String(value);
    }
  }
  getAttribute(name) { return this.attributes[name] ?? null; }
  appendChild(node) {
    node.remove();
    node.parentNode = this;
    this.childNodes.push(node);
    return node;
  }
  append(...nodes) {
    nodes.forEach((node) => this.appendChild(typeof node === 'string' ? new TextNode(node) : node));
  }
  prepend(node) {
    node.remove();
    node.parentNode = this;
    this.childNodes.unshift(node);
  }
  remove() { TextNode.prototype.remove.call(this); }
  replaceWith(node) {
    const parent = this.parentNode;
    const index = parent.childNodes.indexOf(this);
    node.remove();
    parent.childNodes[index] = node;
    node.parentNode = parent;
    this.parentNode = null;
  }
  set innerHTML(html) {
    const root = this.content || this;
    root.childNodes.forEach((node) => { node.parentNode = null; });
    root.childNodes = [];
    const stack = [root];
    for (const token of html.match(/<[^>]+>|[^<]+/g) || []) {
      if (token.startsWith('</')) {
        if (stack.length > 1) stack.pop();
      } else if (token.startsWith('<')) {
        const tag = /^<([\w:-]+)/.exec(token);
        if (!tag) continue;
        const element = this.ownerDocument.createElement(tag[1]);
        const attrs = token.slice(tag[0].length).replace(/\/?\s*>$/, '');
        for (const attr of attrs.matchAll(/([\w:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s]+)))?/g)) {
          element.setAttribute(attr[1], decode(attr[2] ?? attr[3] ?? attr[4] ?? ''));
        }
        stack.at(-1).appendChild(element);
        if (!/\/>$/.test(token) && !['input', 'br', 'hr', 'img', 'link', 'meta'].includes(tag[1])) stack.push(element);
      } else {
        stack.at(-1).appendChild(new TextNode(decode(token)));
      }
    }
  }
  set textContent(text) {
    this.childNodes.forEach((node) => { node.parentNode = null; });
    this.childNodes = [];
    if (String(text)) this.appendChild(new TextNode(String(text)));
  }
  get textContent() { return this.childNodes.map((node) => node.textContent).join(''); }
  matches(selector) {
    const tag = /^[\w-]+/.exec(selector);
    if (tag && this.tagName !== tag[0].toUpperCase()) return false;
    for (const match of selector.matchAll(/\.([\w-]+)/g)) {
      if (!this.classList.contains(match[1])) return false;
    }
    for (const match of selector.matchAll(/\[([\w-]+)(?:=["']?([^\]"']+)["']?)?\]/g)) {
      const value = this.getAttribute(match[1]);
      if (value === null || (match[2] !== undefined && value !== match[2])) return false;
    }
    return true;
  }
  querySelectorAll(selector) {
    const found = [];
    for (const node of this.childNodes) {
      if (node.nodeType !== 1) continue;
      if (node.matches(selector)) found.push(node);
      found.push(...node.querySelectorAll(selector));
    }
    return found;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  closest(selector) {
    for (let node = this; node?.nodeType === 1; node = node.parentNode) {
      if (node.matches(selector)) return node;
    }
    return null;
  }
  click() { if (!this.disabled) this.dispatchEvent({ type: 'click' }); }
  getBoundingClientRect() { return { width: 320, height: 240, left: 0, top: 0 }; }
  insertAdjacentHTML(position, html) {
    if (position !== 'beforeend') throw new Error('未模拟的插入位置：' + position);
    const template = this.ownerDocument.createElement('template');
    template.innerHTML = html;
    this.append(...template.content.childNodes.slice());
  }
}

function createBrowser(scripts = ['renderer.js', 'components.js', 'quiz.js']) {
  const document = new Events();
  document.createElement = (tag) => new Element(tag, document);
  document.createTextNode = (text) => new TextNode(text);
  document.body = document.createElement('body');
  document.body.parentNode = document;
  document.head = document.createElement('head');
  document.querySelectorAll = (selector) => document.body.querySelectorAll(selector);
  const root = document.createElement('div');
  root.id = 'content';
  document.body.appendChild(root);
  document.getElementById = (id) => [root, ...root.querySelectorAll('*')].find((element) => element.id === id) || null;
  const messages = [];
  const window = new Events();
  Object.assign(window, {
    document,
    StudyCore: core,
    markdownit,
    katex: { renderToString: (text) => text },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    getSelection: () => '',
    webkit: { messageHandlers: new Proxy({}, {
      get: (_, name) => ({ postMessage: (body) => messages.push({ name, body }) }),
    }) },
  });
  const context = vm.createContext({
    window, document, Element,
    CustomEvent: class { constructor(type) { this.type = type; } },
    ResizeObserver: class { observe() {} },
    getComputedStyle: () => ({ position: 'static' }),
    requestAnimationFrame: () => 1,
    cancelAnimationFrame() {},
    setTimeout, clearTimeout,
  });
  function load(script) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '../../Renderer', script), 'utf8'), context, { filename: script });
  }
  scripts.forEach(load);
  return { window, document, root, messages, load };
}

module.exports = { createBrowser };
