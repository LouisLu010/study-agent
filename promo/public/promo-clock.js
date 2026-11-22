// 渲染器的虚拟时钟：在渲染器的其他脚本之前加载。
// Remotion 逐帧截图，真实时间和画面时间对不上，所以把渲染器用到的计时都换成由外面推进的时钟：
// requestAnimationFrame、setTimeout/setInterval、performance.now、Date.now，以及 CSS 动画和过渡。
// IntersectionObserver 换成"总是看得见"，否则模拟不会开始播放。
(function () {
  'use strict';
  let now = 1000; // 从 1 秒开始：模拟的 tick 在时间为 0 时不会前进。
  const realDateNow = Date.now.bind(Date);
  const epoch = new Date('2026-11-22T20:00:00+08:00').getTime();

  let nextId = 1;
  const frames = new Map();
  const timers = new Map();

  window.requestAnimationFrame = (callback) => {
    const id = nextId++;
    frames.set(id, callback);
    return id;
  };
  window.cancelAnimationFrame = (id) => { frames.delete(id); };

  window.setTimeout = (callback, ms, ...args) => {
    const id = nextId++;
    if (typeof callback === 'function') timers.set(id, { at: now + Math.max(0, Number(ms) || 0), callback, args, every: 0 });
    return id;
  };
  window.clearTimeout = (id) => { timers.delete(id); };
  window.setInterval = (callback, ms, ...args) => {
    const id = nextId++;
    const every = Math.max(1, Number(ms) || 0);
    if (typeof callback === 'function') timers.set(id, { at: now + every, callback, args, every });
    return id;
  };
  window.clearInterval = window.clearTimeout;

  Object.defineProperty(performance, 'now', { value: () => now, configurable: true });
  Date.now = () => epoch + now;

  // 媒体查询：深色、不减弱动态效果。
  const realMatchMedia = window.matchMedia.bind(window);
  window.matchMedia = (query) => {
    if (/prefers-color-scheme:\s*dark/.test(query)) return fakeQuery(query, true);
    if (/prefers-color-scheme:\s*light/.test(query)) return fakeQuery(query, false);
    if (/prefers-reduced-motion/.test(query)) return fakeQuery(query, false);
    return realMatchMedia(query);
  };
  function fakeQuery(media, matches) {
    return { media, matches, onchange: null, addListener() {}, removeListener() {},
      addEventListener() {}, removeEventListener() {}, dispatchEvent() { return false; } };
  }

  window.IntersectionObserver = class {
    constructor(callback) { this.callback = callback; this.targets = []; }
    observe(target) {
      this.targets.push(target);
      window.setTimeout(() => this.callback([{ target, isIntersecting: true, intersectionRatio: 1 }], this), 0);
    }
    unobserve(target) { this.targets = this.targets.filter((t) => t !== target); }
    disconnect() { this.targets = []; }
    takeRecords() { return []; }
  };

  // CSS 动画和过渡：第一次见到时记下开始的时刻，之后按虚拟时间摆到对应的位置。
  const started = new WeakMap();
  function syncAnimations() {
    for (const animation of document.getAnimations()) {
      if (!started.has(animation)) started.set(animation, now);
      animation.pause();
      animation.currentTime = now - started.get(animation);
    }
  }

  function runTimersUntil(target) {
    for (;;) {
      let due = null;
      for (const [id, timer] of timers) {
        if (timer.at <= target && (!due || timer.at < due.timer.at)) due = { id, timer };
      }
      if (!due) return;
      now = Math.max(now, due.timer.at);
      if (due.timer.every) due.timer.at += due.timer.every;
      else timers.delete(due.id);
      try { due.timer.callback(...due.timer.args); } catch (error) { console.error(error); }
    }
  }

  function runFrames() {
    const callbacks = [...frames.values()];
    frames.clear();
    for (const callback of callbacks) {
      try { callback(now); } catch (error) { console.error(error); }
    }
  }

  window.__clock = {
    now: () => now,
    realNow: realDateNow,
    /** 往前走 ms 毫秒：先跑到期的定时器，再跑一轮动画帧，最后摆好 CSS 动画。 */
    advance(ms) {
      const target = now + ms;
      runTimersUntil(target);
      now = target;
      runFrames();
      runTimersUntil(now);
      syncAnimations();
    },
    syncAnimations,
  };
})();
