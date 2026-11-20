(function () {
  'use strict';

  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editor;

  function post(type, payload) {
    if (!bridge) { return; }
    try {
      bridge.postMessage(Object.assign({ type: type }, payload || {}));
    } catch (error) {
      /* 原生通道暂不可用时应静默降级为纯 Web 预览 */
    }
  }

  var root = document.documentElement;
  var workspace = document.getElementById('workspace');
  var preview = document.getElementById('preview');
  var previewScroll = document.getElementById('preview-scroll');
  var previewHint = document.getElementById('preview-hint');
  var placeholder = document.getElementById('source-placeholder');
  var lightSheet = document.getElementById('hljs-light');
  var darkSheet = document.getElementById('hljs-dark');

  var state = {
    appearance: root.dataset.appearance || 'light',
    previewTheme: root.dataset.preview || 'github',
    mode: 'split',
    editorFontSize: 14,
    previewFontSize: 15.5,
    baseDirectory: '',
    suppress: false
  };

  var cm = CodeMirror.fromTextArea(document.getElementById('source'), {
    mode: 'gfm',
    lineNumbers: false,
    lineWrapping: true,
    styleActiveLine: true,
    matchBrackets: true,
    autoCloseBrackets: true,
    indentUnit: 2,
    tabSize: 2,
    scrollbarStyle: 'native',
    extraKeys: {
      'Cmd-S': function () { post('save'); },
      'Cmd-B': function () { wrap('**', '**'); },
      'Cmd-I': function () { wrap('_', '_'); }
    }
  });

  if (window.marked) {
    marked.setOptions({ gfm: true, breaks: false });
  }

  // MARK: - 渲染

  var renderQueued = false;

  function scheduleRender() {
    if (renderQueued) { return; }
    renderQueued = true;
    requestAnimationFrame(function () {
      renderQueued = false;
      render();
    });
  }

  function render() {
    var text = cm.getValue();
    var html = '';

    try {
      html = window.marked ? marked.parse(text || '') : '';
    } catch (error) {
      html = '<p>' + escapeHTML(String(error)) + '</p>';
    }

    if (window.DOMPurify) {
      preview.innerHTML = DOMPurify.sanitize(html);
    } else {
      preview.textContent = text;
    }

    rewriteImages();
    highlightCode();
    updatePlaceholder();
    previewHint.textContent = state.mode === 'preview' ? '阅读模式' : '实时渲染';
  }

  function escapeHTML(value) {
    return value
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  }

  function highlightCode() {
    if (!window.hljs) { return; }
    var blocks = preview.querySelectorAll('pre code');
    for (var i = 0; i < blocks.length; i += 1) {
      blocks[i].removeAttribute('data-highlighted');
      try {
        hljs.highlightElement(blocks[i]);
      } catch (error) {
        /* 未知语言保持纯文本 */
      }
    }
  }

  function rewriteImages() {
    if (!state.baseDirectory) { return; }
    var base = state.baseDirectory;
    if (base.charAt(base.length - 1) !== '/') { base += '/'; }

    var images = preview.querySelectorAll('img');
    for (var i = 0; i < images.length; i += 1) {
      var src = images[i].getAttribute('src') || '';
      if (!src || /^(https?:|data:|blob:|file:)/i.test(src)) { continue; }
      try {
        images[i].src = new URL(src, base).href;
      } catch (error) {
        /* 保留原始 src */
      }
    }
  }

  function updatePlaceholder() {
    var empty = cm.getValue().length === 0;
    placeholder.style.opacity = empty && !cm.hasFocus() ? '1' : '0';
  }

  // MARK: - 统计

  function computeStats(text) {
    if (!text) {
      return { characters: 0, words: 0, lines: 0, readingMinutes: 0 };
    }
    var characters = 0;
    var codePoints = Array.from(text);
    for (var i = 0; i < codePoints.length; i += 1) {
      if (!/\s/.test(codePoints[i])) { characters += 1; }
    }
    var cjk = (text.match(/[\u3400-\u4DBF\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]/g) || []).length;
    var latin = (text.match(/[A-Za-z0-9_'-]+/g) || []).length;
    var words = cjk + latin;
    return {
      characters: characters,
      words: words,
      lines: text.split('\n').length,
      readingMinutes: words === 0 ? 0 : Math.max(1, Math.ceil(words / 300))
    };
  }

  // MARK: - 输入与滚动

  var changeTimer = null;

  cm.on('change', function () {
    if (state.suppress) { return; }
    scheduleRender();
    updatePlaceholder();

    if (changeTimer) { clearTimeout(changeTimer); }
    changeTimer = setTimeout(function () {
      var text = cm.getValue();
      post('change', { text: text, stats: computeStats(text) });
    }, 140);
  });

  cm.on('focus', updatePlaceholder);
  cm.on('blur', updatePlaceholder);

  var syncingScroll = false;

  function syncScroll(sourceEl, targetEl) {
    if (state.mode !== 'split' || syncingScroll) { return; }
    var sourceMax = sourceEl.scrollHeight - sourceEl.clientHeight;
    var targetMax = targetEl.scrollHeight - targetEl.clientHeight;
    if (sourceMax <= 0 || targetMax <= 0) { return; }

    syncingScroll = true;
    targetEl.scrollTop = (sourceEl.scrollTop / sourceMax) * targetMax;
    window.setTimeout(function () { syncingScroll = false; }, 70);
  }

  cm.on('scroll', function () {
    syncScroll(cm.getScrollerElement(), previewScroll);
  });

  previewScroll.addEventListener('scroll', function () {
    syncScroll(previewScroll, cm.getScrollerElement());
  }, { passive: true });

  // MARK: - 链接

  preview.addEventListener('click', function (event) {
    var anchor = event.target.closest ? event.target.closest('a') : null;
    if (!anchor) { return; }

    var href = anchor.getAttribute('href') || '';
    if (!href) { return; }

    if (href.charAt(0) === '#') {
      event.preventDefault();
      var id = decodeURIComponent(href.slice(1));
      var target = preview.querySelector('[id="' + id.replace(/["\\]/g, '\\$&') + '"]');
      if (target) { target.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
      return;
    }

    event.preventDefault();
    post('link', { href: href });
  }, false);

  // MARK: - 原生指令

  function setHighlightTheme(isDark) {
    if (lightSheet) { lightSheet.disabled = isDark; }
    if (darkSheet) { darkSheet.disabled = !isDark; }
  }

  function setDocument(text, baseDirectory) {
    state.suppress = true;
    cm.setValue(typeof text === 'string' ? text : '');
    cm.clearHistory();
    if (typeof baseDirectory === 'string') { state.baseDirectory = baseDirectory; }
    state.suppress = false;

    cm.setCursor({ line: 0, ch: 0 });
    cm.scrollTo(0, 0);
    previewScroll.scrollTop = 0;

    render();
    cm.refresh();
    post('stats', computeStats(cm.getValue()));
  }

  function setMode(mode) {
    if (mode !== 'source' && mode !== 'split' && mode !== 'preview') { return; }
    state.mode = mode;
    workspace.className = 'mode-' + mode;
    previewHint.textContent = mode === 'preview' ? '阅读模式' : '实时渲染';
    requestAnimationFrame(function () { cm.refresh(); });
  }

  function applyConfig(config) {
    if (!config) { return; }
    var needsRender = false;

    if (config.appearance) {
      state.appearance = config.appearance;
      root.dataset.appearance = config.appearance;
      setHighlightTheme(config.appearance === 'dark');
    }

    if (config.previewTheme && config.previewTheme !== state.previewTheme) {
      state.previewTheme = config.previewTheme;
      root.dataset.preview = config.previewTheme;
    }

    if (typeof config.editorFontSize === 'number') {
      state.editorFontSize = config.editorFontSize;
      root.style.setProperty('--editor-font-size', config.editorFontSize + 'px');
    }

    if (typeof config.previewFontSize === 'number') {
      state.previewFontSize = config.previewFontSize;
      root.style.setProperty('--preview-font-size', config.previewFontSize + 'px');
    }

    if (typeof config.baseDirectory === 'string' && config.baseDirectory !== state.baseDirectory) {
      state.baseDirectory = config.baseDirectory;
      needsRender = true;
    }

    cm.refresh();
    if (needsRender) { render(); }
  }

  function wrap(before, after) {
    var selection = cm.getSelection();
    var cursor = cm.getCursor();
    cm.replaceSelection(before + selection + after);
    if (!selection) {
      cm.setCursor({ line: cursor.line, ch: cursor.ch + before.length });
    }
    cm.focus();
  }

  function insert(text) {
    cm.replaceSelection(text);
    cm.focus();
  }

  window.MD = {
    setDocument: setDocument,
    setMode: setMode,
    applyConfig: applyConfig,
    wrap: wrap,
    insert: insert,
    focus: function () { cm.focus(); },
    getText: function () { return cm.getValue(); },
    getArticleHTML: function () { return preview.innerHTML; }
  };

  render();
  updatePlaceholder();
  cm.refresh();

  // 就绪信号不依赖 requestAnimationFrame：窗口不可见或被系统节流时，
  // rAF 可能长时间不触发，导致原生侧一直拿不到编辑器。
  post('ready');

  requestAnimationFrame(function () {
    cm.refresh();
  });
})();
