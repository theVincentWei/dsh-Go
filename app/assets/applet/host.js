// Applet host bridge (assets/applet/host.js), injected into every container
// page before its own scripts. Contract: docs/apps/container-contract.md.
//
// The page gets window.host: read/list/info/onBack. Standalone — opened in a
// desktop browser without the container — reads resolve to null and info to
// defaults, so a page can still render while the agent develops it.
// Idempotent, like assets/web/*.js.
(function () {
  'use strict';
  if (window.host) return;

  var seq = 0;
  var pending = Object.create(null);

  function has(name) {
    var channel = window[name];
    return typeof channel === 'object' && channel !== null &&
      typeof channel.postMessage === 'function';
  }

  function call(message, channel) {
    return new Promise(function (resolve) {
      if (!has(channel)) { resolve(null); return; }
      seq += 1;
      message.reqId = 'r' + seq;
      pending[message.reqId] = resolve;
      window[channel].postMessage(JSON.stringify(message));
      // Safety net: a lost reply must not hang the page forever.
      setTimeout(function () {
        if (pending[message.reqId]) {
          delete pending[message.reqId];
          resolve(null);
        }
      }, 10000);
    });
  }

  // Dart answers via runJavaScript('__hostResolve(reqId, payloadJson)').
  window.__hostResolve = function (reqId, payloadJson) {
    var resolver = pending[reqId];
    if (!resolver) return;
    delete pending[reqId];
    var payload = null;
    try { payload = JSON.parse(payloadJson); } catch (e) { /* lost cause */ }
    resolver(payload);
  };

  window.host = {
    version: 1,

    // Parsed JSON (or raw text for non-JSON files); null when the file is
    // missing, refused, or the container is absent.
    read: function (path) {
      return call({ op: 'read', path: path === undefined ? '' : path }, 'DshAppFs')
        .then(function (reply) {
          return reply && reply.ok === true ? reply.data : null;
        });
    },

    // Entry names of one data-dir level; [] when empty or refused.
    list: function (path) {
      return call({ op: 'list', path: path === undefined ? '' : path }, 'DshAppFs')
        .then(function (reply) {
          return reply && reply.ok === true && reply.entries ? reply.entries : [];
        });
    },

    // {theme:'light'|'dark', locale, safeArea:{top,bottom}, appId, name, version}
    info: function () {
      return call({ op: 'info' }, 'DshAppHost').then(function (reply) {
        if (reply && reply.ok === true && reply.info) return reply.info;
        return {
          theme: 'light', locale: 'zh', safeArea: { top: 0, bottom: 0 },
          appId: '', name: '', version: 0
        };
      });
    },

    // Multi-view apps register one handler: 'pop' when it consumed the back
    // press (it switched views itself), anything else exits the container.
    // Single-view apps skip this — back exits directly.
    onBack: function (handler) { window.__dshAppletBack = handler; },

    // Hand an intent text to the agent: fills the 新对话 composer, nothing is
    // sent until the person taps send. true = queued; null = no container
    // (standalone preview) — the page should fall back to showing the text.
    compose: function (text) {
      return call({ op: 'compose', text: text === undefined ? '' : String(text) }, 'DshAppHost')
        .then(function (reply) { return reply !== null && reply.ok === true; });
    }
  };

  // Dart's PopScope asks the page before popping the container.
  window.__dshHostBack = function () {
    var result = 'exit';
    try {
      var answer = window.__dshAppletBack ? window.__dshAppletBack() : null;
      if (answer === 'pop') result = 'pop';
    } catch (e) { /* a throwing handler must not trap the user */ }
    if (has('DshAppNav')) {
      window.DshAppNav.postMessage(JSON.stringify({ result: result }));
    }
  };

  // Capsule auto-hide: report page interaction, throttled; the container
  // collapses its capsule to the edge and re-expands on idle or tap.
  var lastReport = 0;
  function reportUi() {
    var now = Date.now();
    if (now - lastReport < 500) return;
    lastReport = now;
    if (has('DshAppUi')) {
      window.DshAppUi.postMessage(JSON.stringify({ event: 'touch' }));
    }
  }
  ['touchstart', 'touchmove', 'scroll', 'wheel'].forEach(function (type) {
    window.addEventListener(type, reportUi, { passive: true, capture: true });
  });

  // Keyboard: the container keeps the WebView at full size and pushes the
  // keyboard height here once per slide (a WebView that shrinks re-layouts
  // the whole page on every frame of the slide — the keyboard stutter the
  // containers avoid; same scheme as the 网页模式 host). The height lands in
  // a targeted stylesheet — marked elements end at the keyboard's top and
  // nothing else restyles (a variable on :root would restyle the whole
  // page). Focused fields scroll themselves above the keyboard edge, since
  // nothing shrinks to do it for them.
  window.__hostInsets = function (px) {
    var k = Number(px) || 0;
    window.__dshKeyboard = k;
    var s = document.getElementById('dsh-applet-keyboard');
    if (!s) {
      if (!(k > 0)) return;
      s = document.createElement('style');
      s.id = 'dsh-applet-keyboard';
      document.head.appendChild(s);
    }
    s.textContent = k > 0 ? '[data-dsh-keyboard]{bottom:' + k + 'px!important}' : '';
    if (!window.__dshAppReveal) {
      window.__dshAppReveal = function () {
        var kb = window.__dshKeyboard, a = document.activeElement;
        if (!(kb > 0) || !a || !(a.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName))) return;
        var r = a.getBoundingClientRect();
        if (r.bottom > window.innerHeight - kb) a.scrollIntoView({ block: 'nearest' });
      };
      document.addEventListener('focusin', function () {
        requestAnimationFrame(window.__dshAppReveal);
      });
    }
    if (k > 0) requestAnimationFrame(window.__dshAppReveal);
  };
  window.__hostInsets(0);
})();
