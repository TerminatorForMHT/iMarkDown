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
  var chromeBackdrop = document.getElementById('chrome-backdrop');
  var placeholder = document.getElementById('source-placeholder');
  var lightSheet = document.getElementById('hljs-light');
  var darkSheet = document.getElementById('hljs-dark');
  var findBar = document.getElementById('find-bar');
  var findInput = document.getElementById('find-input');
  var replaceInput = document.getElementById('replace-input');
  var findCount = document.getElementById('find-count');

  var state = {
    appearance: root.dataset.appearance || 'light',
    previewTheme: root.dataset.preview || 'github',
    mode: 'split',
    editorFontSize: 14,
    previewFontSize: 15.5,
    baseDirectory: '',
    suppress: false,
    readOnly: false,
    // 文档代数：每次 setDocument 递增，change 事件带上代数，
    // 原生侧据此丢弃切换文档后仍在队列里的旧文档事件。
    epoch: 0
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
      'Cmd-F': function () { openFind(); },
      'Cmd-G': function () { findNext(); },
      'Shift-Cmd-G': function () { findPrevious(); },
      'Esc': function () { closeFind(); },
      'Cmd-B': function () { wrap('**', '**'); },
      'Cmd-I': function () { wrap('_', '_'); }
    }
  });

  if (window.marked) {
    marked.setOptions({ gfm: true, breaks: false });
  }

  // MARK: - 渲染

  var renderQueued = false;
  var renderTimer = null;
  // 超过阈值后放弃逐帧渲染，改为低频合并，避免输入时主线程被 marked 占满。
  var LARGE_DOCUMENT = 120000;
  // 再大则只做纯文本预览，Markdown 解析与代码高亮全部跳过。
  var HUGE_DOCUMENT = 600000;
  var HIGHLIGHT_LIMIT = 250000;
  var headingNodes = [];
  var outlineSignature = '';
  var metrics = { renderMs: 0, characters: 0, headings: 0 };

  function sanitizedHTML(text) {
    if (!window.marked || !window.DOMPurify) { return '<pre>' + escapeHTML(text) + '</pre>'; }
    return DOMPurify.sanitize(marked.parse(text || ''), {
      FORBID_TAGS: ['form', 'iframe', 'object', 'embed', 'base', 'meta', 'link', 'style', 'button', 'textarea', 'select'],
      FORBID_ATTR: ['srcset', 'action', 'formaction', 'autofocus']
    });
  }

  function publishOutline() {
    headingNodes = Array.from(preview.querySelectorAll('h1,h2,h3,h4,h5,h6'));
    var headings = headingNodes.map(function (node) {
      return { level: Number(node.tagName.slice(1)), title: node.textContent.trim() };
    });
    var signature = JSON.stringify(headings);
    if (signature !== outlineSignature) {
      outlineSignature = signature;
      post('outline', { headings: headings, epoch: state.epoch });
    }
    metrics.headings = headings.length;
  }

  function scheduleRender() {
    var length = cm.getValue().length;

    if (length > LARGE_DOCUMENT) {
      if (renderTimer) { clearTimeout(renderTimer); }
      renderTimer = setTimeout(function () {
        renderTimer = null;
        render();
      }, 400);
      return;
    }

    if (renderQueued) { return; }
    renderQueued = true;
    requestAnimationFrame(function () {
      renderQueued = false;
      render();
    });
  }

  function render() {
    var started = performance.now();
    var text = cm.getValue();
    metrics.characters = text.length;

    if (text.length > HUGE_DOCUMENT) {
      preview.classList.add('is-plain');
      preview.textContent = text;
      publishOutline();
      metrics.renderMs = performance.now() - started;
      updatePlaceholder();
      scheduleChrome();
      return;
    }

    preview.classList.remove('is-plain');
    var html = '';

    try {
      html = sanitizedHTML(text);
    } catch (error) {
      html = '<p>' + escapeHTML(String(error)) + '</p>';
    }

    preview.innerHTML = html;

    rewriteImages();
    decorateHeadings();
    highlightCode(text.length <= HIGHLIGHT_LIMIT);
    enableTaskCheckboxes(preview, true);
    publishOutline();
    metrics.renderMs = performance.now() - started;
    updatePlaceholder();
    scheduleChrome();
  }

  /// 预览里的任务清单保持可点击：点击后回写源码里的 `[ ]` / `[x]`。
  /// marked 只输出 checkbox，不带 GitHub 的任务清单类名，这里补齐以命中样式。
  function enableTaskCheckboxes(container, interactive) {
    var boxes = container.querySelectorAll('li input[type="checkbox"]');
    for (var i = 0; i < boxes.length; i += 1) {
      var box = boxes[i];
      var item = box.closest ? box.closest('li') : null;
      if (item) {
        item.classList.add('task-list-item');
        if (item.parentElement) {
          item.parentElement.classList.add('contains-task-list');
        }
      }
      if (interactive) { box.removeAttribute('disabled'); }
      else { box.setAttribute('disabled', ''); }
      box.setAttribute('data-task-index', String(i));
      box.setAttribute('aria-label', '切换任务完成状态');
    }
  }

  function toggleTaskCheckbox(box) {
    if (state.readOnly) { return; }
    var index = Number(box.getAttribute('data-task-index'));
    if (isNaN(index)) { return; }

    var text = cm.getValue();
    var pattern = /^([ \t]*(?:[-*+]|\d+[.)])\s+\[)([ xX])(\])/gm;
    var match;
    var current = 0;
    while ((match = pattern.exec(text)) !== null) {
      if (current === index) {
        var offset = match.index + match[1].length;
        var from = cm.posFromIndex(offset);
        var to = cm.posFromIndex(offset + 1);
        cm.replaceRange(match[2] === ' ' ? 'x' : ' ', from, to, '+task');
        return;
      }
      current += 1;
    }
  }

  function escapeHTML(value) {
    return value
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  }

  /// marked 不生成标题 id，这里补齐，让 [文字](#标题) 这类锚点可以跳转。
  /// 保留中日韩文字，空格转连字符，重名加 -1 / -2 后缀。
  function slugify(value) {
    var slug = String(value || '')
      .trim()
      .toLowerCase()
      .replace(/[`*_~]/g, '')
      .replace(/\s+/g, '-')
      .replace(/[^\p{L}\p{N}\-_.]/gu, '');
    return slug || 'section';
  }

  function decorateHeadings(container) {
    var headings = (container || preview).querySelectorAll('h1,h2,h3,h4,h5,h6');
    var used = Object.create(null);
    for (var i = 0; i < headings.length; i += 1) {
      var node = headings[i];
      if (node.id) {
        used[node.id] = (used[node.id] || 0) + 1;
        continue;
      }
      var base = slugify(node.textContent);
      var candidate = base;
      var count = used[base] || 0;
      while (used[candidate]) {
        count += 1;
        candidate = base + '-' + count;
      }
      used[candidate] = 1;
      node.id = candidate;
    }
  }

  function highlightCode(enabled, container) {
    if (!window.hljs || enabled === false) { return; }
    var blocks = (container || preview).querySelectorAll('pre code');
    for (var i = 0; i < blocks.length; i += 1) {
      blocks[i].removeAttribute('data-highlighted');
      try {
        hljs.highlightElement(blocks[i]);
      } catch (error) {
        /* 未知语言保持纯文本 */
      }
    }
  }

  function rewriteImages(container, exporting) {
    var images = (container || preview).querySelectorAll('img');
    var base = state.baseDirectory;
    if (base && base.charAt(base.length - 1) !== '/') { base += '/'; }
    for (var i = 0; i < images.length; i += 1) {
      var src = images[i].getAttribute('src') || '';
      if (!src || /^(https?:|data:)/i.test(src)) { continue; }
      try {
        if (!base) { images[i].removeAttribute('src'); continue; }
        var resolved = new URL(src, base);
        var directory = new URL(base);
        if (resolved.protocol !== 'file:' || resolved.host !== directory.host ||
            resolved.pathname.indexOf(directory.pathname) !== 0) {
          images[i].removeAttribute('src');
          continue;
        }
        images[i].src = exporting ? resolved.href :
          'imarkdown://document/' + resolved.pathname.slice(directory.pathname.length);
      } catch (error) {
        /* 保留原始 src */
        images[i].removeAttribute('src');
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
      return { characters: 0, words: 0, lines: 0 };
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
      lines: text.split('\n').length
    };
  }

  // MARK: - 查找与替换

  var findState = {
    open: false,
    matches: [],
    marks: [],
    caseSensitive: false,
    useRegex: false
  };

  // 高亮过多会拖慢渲染，超过上限时只保留计数与逐条跳转。
  var MAX_FIND_MARKS = 400;

  function openFind() {
    if (!findBar) { return; }
    findState.open = true;
    findBar.hidden = false;

    var selection = cm.getSelection();
    if (selection && selection.indexOf('\n') === -1) {
      findInput.value = selection;
    }
    syncFindToggles();
    findInput.focus();
    findInput.select();
    refreshFind();
  }

  function closeFind() {
    if (!findBar) { return; }
    findState.open = false;
    findBar.hidden = true;
    findState.matches = [];
    clearFindMarks();
    if (replaceInput) { replaceInput.blur(); }
    cm.focus();
  }

  function syncFindToggles() {
    if (!findBar) { return; }
    var caseButton = findBar.querySelector('[data-find="case"]');
    var regexButton = findBar.querySelector('[data-find="regex"]');
    if (caseButton) { caseButton.classList.toggle('is-on', findState.caseSensitive); }
    if (regexButton) { regexButton.classList.toggle('is-on', findState.useRegex); }
  }

  function clearFindMarks() {
    for (var i = 0; i < findState.marks.length; i += 1) {
      findState.marks[i].clear();
    }
    findState.marks = [];
  }

  /// 统一返回 {start, end} 区间，普通查找与正则共用同一套选中/替换逻辑。
  function findMatches() {
    var query = findInput ? findInput.value : '';
    var matches = [];
    if (!query) { return matches; }

    var text = cm.getValue();

    if (findState.useRegex) {
      var re;
      try {
        re = new RegExp(query, findState.caseSensitive ? 'g' : 'gi');
      } catch (error) {
        return matches;
      }
      var result;
      while ((result = re.exec(text)) !== null) {
        if (!result[0].length) {
          re.lastIndex += 1;
          continue;
        }
        matches.push({ start: result.index, end: result.index + result[0].length });
      }
      return matches;
    }

    var haystack = findState.caseSensitive ? text : text.toLowerCase();
    var needle = findState.caseSensitive ? query : query.toLowerCase();
    var index = haystack.indexOf(needle);
    while (index !== -1) {
      matches.push({ start: index, end: index + needle.length });
      index = haystack.indexOf(needle, index + needle.length);
    }
    return matches;
  }

  function findCurrentIndex() {
    var matches = findState.matches;
    if (!matches.length) { return -1; }
    var cursor = cm.indexFromPos(cm.getCursor('from'));
    for (var i = 0; i < matches.length; i += 1) {
      if (matches[i].start === cursor) { return i; }
    }
    for (var j = 0; j < matches.length; j += 1) {
      if (cursor > matches[j].start && cursor <= matches[j].end) { return j; }
    }
    return -1;
  }

  function highlightMatches() {
    clearFindMarks();
    if (!findState.open) { return; }
    var matches = findState.matches;
    if (!matches.length || matches.length > MAX_FIND_MARKS) { return; }

    var current = findCurrentIndex();
    for (var i = 0; i < matches.length; i += 1) {
      var handle = cm.markText(
        cm.posFromIndex(matches[i].start),
        cm.posFromIndex(matches[i].end),
        { className: i === current ? 'cm-find-current' : 'cm-find-match' }
      );
      findState.marks.push(handle);
    }
  }

  function refreshFind() {
    findState.matches = findState.open ? findMatches() : [];
    updateFindCount();
    highlightMatches();
  }

  function updateFindCount() {
    if (!findCount || !findInput) { return; }
    var total = findState.matches.length;
    if (!total) {
      findCount.textContent = '0/0';
      return;
    }
    var current = findCurrentIndex();
    findCount.textContent = (current >= 0 ? current + 1 : 0) + '/' + total;
  }

  function selectMatch(match) {
    var from = cm.posFromIndex(match.start);
    var to = cm.posFromIndex(match.end);
    cm.setSelection(from, to);
    cm.scrollIntoView({ from: from, to: to }, 80);
    cm.focus();
    updateFindCount();
    highlightMatches();
  }

  function findNext() {
    if (!findInput || !findInput.value) { return; }
    refreshFind();
    if (!findState.matches.length) { return; }

    var from = cm.indexFromPos(cm.getCursor('to'));
    var target = findState.matches[0];
    for (var i = 0; i < findState.matches.length; i += 1) {
      if (findState.matches[i].start >= from) {
        target = findState.matches[i];
        break;
      }
    }
    selectMatch(target);
  }

  function findPrevious() {
    if (!findInput || !findInput.value) { return; }
    refreshFind();
    if (!findState.matches.length) { return; }

    var from = cm.indexFromPos(cm.getCursor('from'));
    var target = findState.matches[findState.matches.length - 1];
    for (var i = findState.matches.length - 1; i >= 0; i -= 1) {
      if (findState.matches[i].start < from) {
        target = findState.matches[i];
        break;
      }
    }
    selectMatch(target);
  }

  function replaceCurrent() {
    if (state.readOnly) { return; }
    var query = findInput ? findInput.value : '';
    if (!query) { return; }
    refreshFind();
    if (!findState.matches.length) { return; }

    var replacement = replaceInput ? replaceInput.value : '';
    var current = findCurrentIndex();

    // 选区恰好就是某个匹配时直接替换，否则先定位到当前匹配再替换。
    if (current >= 0) {
      var match = findState.matches[current];
      var from = cm.getCursor('from');
      var to = cm.getCursor('to');
      var matchFrom = cm.posFromIndex(match.start);
      var matchTo = cm.posFromIndex(match.end);
      if (from.line !== matchFrom.line || from.ch !== matchFrom.ch ||
          to.line !== matchTo.line || to.ch !== matchTo.ch) {
        cm.setSelection(matchFrom, matchTo);
      }
      cm.replaceSelection(replacement);
    }
    findNext();
  }

  function replaceAll() {
    if (state.readOnly) { return; }
    var query = findInput ? findInput.value : '';
    if (!query) { return; }
    refreshFind();
    var matches = findState.matches;
    if (!matches.length) { return; }

    var replacement = replaceInput ? replaceInput.value : '';
    // 从后往前替换，保证前面的偏移量不失效，同时保留撤销历史。
    // 拼成一次编辑，避免大量匹配逐条回调和重复扫描；撤销仍是一个步骤。
    var text = cm.getValue();
    var parts = [];
    var offset = 0;
    for (var i = 0; i < matches.length; i += 1) {
      parts.push(text.slice(offset, matches[i].start), replacement);
      offset = matches[i].end;
    }
    parts.push(text.slice(offset));
    cm.replaceRange(parts.join(''), { line: 0, ch: 0 }, cm.posFromIndex(text.length), '+replaceAll');
    refreshFind();
  }

  if (findBar) {
    findBar.addEventListener('click', function (event) {
      var action = event.target.getAttribute ? event.target.getAttribute('data-find') : null;
      if (!action) { return; }
      if (action === 'prev') { findPrevious(); }
      else if (action === 'next') { findNext(); }
      else if (action === 'replace') { replaceCurrent(); }
      else if (action === 'replace-all') { replaceAll(); }
      else if (action === 'close') { closeFind(); }
      else if (action === 'case') {
        findState.caseSensitive = !findState.caseSensitive;
        syncFindToggles();
        refreshFind();
      } else if (action === 'regex') {
        findState.useRegex = !findState.useRegex;
        syncFindToggles();
        refreshFind();
      }
    });
  }

  if (findInput) {
    findInput.addEventListener('input', refreshFind);
    findInput.addEventListener('keydown', function (event) {
      if (event.key === 'Enter') {
        event.preventDefault();
        if (event.shiftKey) { findPrevious(); } else { findNext(); }
      } else if (event.key === 'Escape') {
        event.preventDefault();
        closeFind();
      }
    });
  }

  if (replaceInput) {
    replaceInput.addEventListener('keydown', function (event) {
      if (event.key === 'Enter') {
        event.preventDefault();
        replaceCurrent();
      } else if (event.key === 'Escape') {
        event.preventDefault();
        closeFind();
      }
    });
  }

  // MARK: - 输入与滚动

  var changeTimer = null;

  cm.on('change', function () {
    if (state.suppress) { return; }
    post('edited', { epoch: state.epoch });
    scheduleRender();
    updatePlaceholder();
    if (findState.open) { refreshFind(); }

    if (changeTimer) { clearTimeout(changeTimer); }
    changeTimer = setTimeout(function () {
      var text = cm.getValue();
      post('change', { text: text, stats: computeStats(text), epoch: state.epoch });
    }, cm.getValue().length > LARGE_DOCUMENT ? 600 : 140);
  });

  cm.on('focus', updatePlaceholder);
  cm.on('blur', updatePlaceholder);

  // 粘贴图片：读成 base64 交给原生保存到文档同级 assets/，再插入相对路径。
  function readImageFile(file) {
    if (state.readOnly || file.size > 8 * 1024 * 1024) { return; }
    var epoch = state.epoch;
    var reader = new FileReader();
    reader.onload = function () {
      var result = String(reader.result || '');
      var comma = result.indexOf(',');
      if (comma === -1) { return; }
      post('image', {
        data: result.slice(comma + 1),
        mime: file.type || 'image/png',
        name: file.name || '',
        epoch: epoch
      });
    };
    reader.readAsDataURL(file);
  }

  function handleImagePaste(event) {
    var items = event.clipboardData && event.clipboardData.items;
    if (!items) { return; }
    var handled = false;
    for (var i = 0; i < items.length; i += 1) {
      if (items[i].kind === 'file' && items[i].type && items[i].type.indexOf('image/') === 0) {
        var file = items[i].getAsFile();
        if (!file) { continue; }
        handled = true;
        readImageFile(file);
      }
    }
    if (handled) { event.preventDefault(); }
  }

  cm.getWrapperElement().addEventListener('paste', handleImagePaste, false);

  var syncingScroll = false;
  var readingActive = false;
  var readingTimer = null;

  function hasReadingSelection() {
    var selection = window.getSelection();
    return Boolean(selection && preview.contains(selection.anchorNode) && String(selection)) ||
      (state.mode !== 'preview' && cm.somethingSelected());
  }

  function setReading(active, force) {
    if (!force && active === readingActive) { return; }
    readingActive = active;
    post('reading', { active: active, epoch: state.epoch });
  }

  function noteReading() {
    setReading(true);
    if (readingTimer) { clearTimeout(readingTimer); }
    readingTimer = setTimeout(function () { setReading(hasReadingSelection()); }, 1500);
  }

  document.addEventListener('selectionchange', function () { setReading(hasReadingSelection()); });

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
    noteReading();
    syncScroll(cm.getScrollerElement(), previewScroll);
    scheduleChrome();
  });

  previewScroll.addEventListener('scroll', function () {
    noteReading();
    syncScroll(previewScroll, cm.getScrollerElement());
    scheduleChrome();
  }, { passive: true });

  // MARK: - 顶部覆盖区状态

  // 与原生顶部条带同高（DesignTokens.topBarHeight）。判定的是正文是否真的
  // 进入覆盖区，而不是 scrollTop > 0；正文顶部留白仍属于可滚动内容。
  var CHROME_HEIGHT = 64;
  var chromeQueued = false;
  var chromeState = { overlapped: false, compact: false, activeHeading: -1, initialized: false };

  function contentPaddingTop(el) {
    if (!el) { return 0; }
    var value = parseFloat(window.getComputedStyle(el).paddingTop);
    return isNaN(value) ? 0 : value;
  }

  function sourceScroller() {
    return cm.getScrollerElement();
  }

  function sourceLines() {
    return cm.getWrapperElement().querySelector('.CodeMirror-lines');
  }

  function firstSourceLine() {
    return cm.getWrapperElement().querySelector('.CodeMirror-line');
  }

  function computeChrome() {
    var previewVisible = state.mode !== 'source';
    var sourceVisible = state.mode !== 'preview';

    var previewOverlap = false;
    if (previewVisible) {
      previewOverlap = previewScroll.scrollTop > contentPaddingTop(preview) - CHROME_HEIGHT;
    }

    var sourceOverlap = false;
    if (sourceVisible) {
      sourceOverlap = sourceScroller().scrollTop > contentPaddingTop(sourceLines()) - CHROME_HEIGHT;
    }

    var overlapped = previewOverlap || sourceOverlap;
    var compact = false;

    // 分栏优先看预览侧的大标题；预览为空时退回源码首行。
    var titleElement = previewVisible ? preview.firstElementChild : null;
    var lineElement = titleElement ? null : (sourceVisible ? firstSourceLine() : null);
    if (titleElement) {
      compact = titleElement.getBoundingClientRect().bottom < CHROME_HEIGHT;
    } else if (lineElement) {
      compact = lineElement.getBoundingClientRect().bottom < CHROME_HEIGHT;
    } else {
      compact = previewVisible ? previewOverlap : sourceOverlap;
    }

    return { overlapped: overlapped, compact: compact && overlapped };
  }

  /// 侧栏大纲高亮：取视野顶部最后一个越过覆盖区的标题序号。
  function activeHeading() {
    if (state.mode === 'source') { return -1; }
    var threshold = previewScroll.getBoundingClientRect().top + CHROME_HEIGHT + 12;
    // 保留实时几何位置以适应图片加载；二分查找避免逐帧扫描全部标题。
    var low = 0;
    var high = headingNodes.length;
    while (low < high) {
      var middle = Math.floor((low + high) / 2);
      if (headingNodes[middle].getBoundingClientRect().top <= threshold) { low = middle + 1; }
      else { high = middle; }
    }
    return low - 1;
  }

  function updateChrome(force) {
    var result = computeChrome();
    // 在 WebKit 自己的合成树内即时更新，不等待原生桥接往返。
    chromeBackdrop.hidden = !result.overlapped;
    var heading = activeHeading();
    if (!force && chromeState.initialized &&
        chromeState.overlapped === result.overlapped &&
        chromeState.compact === result.compact &&
        chromeState.activeHeading === heading) {
      return;
    }
    chromeState.overlapped = result.overlapped;
    chromeState.compact = result.compact;
    chromeState.activeHeading = heading;
    chromeState.initialized = true;
    post('chrome', {
      overlapped: result.overlapped,
      compactTitle: result.compact,
      activeHeading: heading,
      epoch: state.epoch
    });
  }

  function scheduleChrome() {
    if (chromeQueued) { return; }
    chromeQueued = true;
    requestAnimationFrame(function () {
      chromeQueued = false;
      updateChrome(false);
    });
  }

  window.addEventListener('resize', scheduleChrome);

  // MARK: - 链接

  preview.addEventListener('click', function (event) {
    var box = event.target.closest
      ? event.target.closest('li.task-list-item input[type="checkbox"]')
      : null;
    if (box) {
      event.preventDefault();
      toggleTaskCheckbox(box);
      return;
    }

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

  function setDocument(text, baseDirectory, epoch) {
    if (typeof epoch === 'number') { state.epoch = epoch; }
    outlineSignature = '';
    if (renderTimer) { clearTimeout(renderTimer); renderTimer = null; }
    if (readingTimer) { clearTimeout(readingTimer); readingTimer = null; }
    setReading(false, true);
    // 切换文档时丢弃上一份文档尚未上报的 change，避免旧内容写入新文档。
    if (changeTimer) { clearTimeout(changeTimer); changeTimer = null; }
    state.suppress = true;
    clearFindMarks();
    findState.matches = [];
    cm.setValue(typeof text === 'string' ? text : '');
    cm.clearHistory();
    if (typeof baseDirectory === 'string') { state.baseDirectory = baseDirectory; }
    state.suppress = false;

    cm.setCursor({ line: 0, ch: 0 });
    cm.scrollTo(0, 0);
    previewScroll.scrollTop = 0;

    render();
    if (findState.open) { refreshFind(); }
    cm.refresh();
    // 新文档回到顶部：强制上报一次，清掉上一份文档留下的覆盖状态。
    updateChrome(true);
    post('stats', Object.assign(computeStats(cm.getValue()), { epoch: state.epoch }));
  }

  function setMode(mode) {
    if (mode !== 'source' && mode !== 'split' && mode !== 'preview') { return; }
    state.mode = mode;
    workspace.className = 'mode-' + mode;
    requestAnimationFrame(function () {
      cm.refresh();
      // 模式切换改变了可见窗格，必须按真实位置重算一次顶部状态。
      updateChrome(true);
    });
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
    scheduleChrome();
  }

  function wrap(before, after) {
    if (state.readOnly) { return; }
    var selection = cm.getSelection();
    var cursor = cm.getCursor();
    cm.replaceSelection(before + selection + after);
    if (!selection) {
      cm.setCursor({ line: cursor.line, ch: cursor.ch + before.length });
    }
    cm.focus();
  }

  function insert(text) {
    if (state.readOnly) { return; }
    cm.replaceSelection(text);
    cm.focus();
  }

  /// 图片按块插入：行首/行尾/行中分别补换行，避免和相邻标题或正文粘连。
  function insertImage(path) {
    if (state.readOnly) { return; }
    var cursor = cm.getCursor();
    var line = cm.getLine(cursor.line) || '';
    var before = '';
    var after = '';

    if (line.length > 0) {
      if (cursor.ch === 0) {
        after = '\n';
      } else if (cursor.ch >= line.length) {
        before = '\n';
      } else {
        before = '\n\n';
        after = '\n';
      }
    }

    cm.replaceSelection(before + '![](' + path + ')' + after);
    cm.focus();
  }

  /// 大纲跳转：按标题在预览中的出现顺序定位，避免依赖标题 id。
  function scrollToHeading(index) {
    var target = headingNodes[index];
    if (!target) { return; }
    target.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  window.MD = {
    setDocument: setDocument,
    setMode: setMode,
    applyConfig: applyConfig,
    wrap: wrap,
    insert: insert,
    insertImage: insertImage,
    focus: function () { cm.focus(); },
    openFind: openFind,
    findNext: findNext,
    findPrevious: findPrevious,
    closeFind: closeFind,
    undo: function () { if (!state.readOnly) { cm.undo(); } },
    redo: function () { if (!state.readOnly) { cm.redo(); } },
    scrollToHeading: scrollToHeading,
    getText: function () { return cm.getValue(); },
    getSnapshot: function () { return JSON.stringify({ text: cm.getValue(), epoch: state.epoch }); },
    setReadOnly: function (value) { state.readOnly = Boolean(value); cm.setOption('readOnly', state.readOnly); },
    getMetrics: function () { return Object.assign({}, metrics); },
    getArticleHTML: function (epoch) {
      if (epoch !== state.epoch) { throw new Error('文档已切换'); }
      var text = cm.getValue();
      var article = document.createElement('article');
      article.innerHTML = sanitizedHTML(text);
      rewriteImages(article, true);
      decorateHeadings(article);
      highlightCode(text.length <= HIGHLIGHT_LIMIT, article);
      enableTaskCheckboxes(article, false);
      return article.innerHTML;
    }
  };

  render();
  updatePlaceholder();
  cm.refresh();
  updateChrome(true);

  // 就绪信号不依赖 requestAnimationFrame：窗口不可见或被系统节流时，
  // rAF 可能长时间不触发，导致原生侧一直拿不到编辑器。
  post('ready');

  requestAnimationFrame(function () {
    cm.refresh();
  });
})();
