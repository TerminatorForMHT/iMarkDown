import AppKit
import MarkdownKit
import UniformTypeIdentifiers
import SwiftUI
import WebKit
#if IMARKDOWN_CHECKS || IMARKDOWN_UI_CHECK
import PDFKit
#endif

enum WebResources {
    #if IMARKDOWN_CHECKS
    static let rootURL: URL? = ProcessInfo.processInfo.environment["IMARKDOWN_WEB_ROOT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }
    #else
    static let rootURL: URL? = Bundle.module.url(forResource: "Web", withExtension: nil)
    #endif

    static var indexURL: URL? {
        rootURL?.appendingPathComponent("index.html")
    }

    static func text(_ relativePath: String) -> String {
        guard let url = rootURL?.appendingPathComponent(relativePath),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

/// 外层容器：负责布局就绪回调与承载远程图层。
///
/// 编辑区不再有圆角卡片，所以这里不做裁剪；若将来需要圆角，也必须由这个
/// 普通 AppKit 图层承担 `masksToBounds`，不能直接设在 WKWebView 的远程图层上
/// ——部分 macOS 版本会因此出现「背景能画、正文全部空白」的合成问题。
final class WebViewClippingView: NSView {
    /// 当视图已进入窗口且拿到非零尺寸时调用一次。
    var onLayoutReady: (() -> Void)?
    private var didFire = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        checkReady()
    }

    override func layout() {
        super.layout()
        checkReady()
    }

    private func checkReady() {
        guard !didFire, window != nil,
              bounds.width > 0, bounds.height > 0 else { return }
        didFire = true
        if let window { AppDelegate.shared?.protectClose(of: window) }
        onLayoutReady?()
    }
}

/// 承载 Web 内核的 WKWebView。原生只负责创建、加载与生命周期，不干预编辑行为。
struct MarkdownWebView: NSViewRepresentable {
    let controller: EditorController
    let bridge: EditorBridge

    @MainActor
    final class Coordinator {
        let controller: EditorController
        let bridge: EditorBridge
        weak var webView: WKWebView?
        private var didLoad = false

        init(controller: EditorController, bridge: EditorBridge) {
            self.controller = controller
            self.bridge = bridge
        }

        /// 仅在第一次布局就绪后加载一次编辑器，避免在零尺寸 / 无窗口状态下
        /// 加载 HTML 导致 WebKit 首帧瓦片层不重绘（间歇性空白）。
        func loadIfNeeded() {
            guard !didLoad, let webView else { return }
            didLoad = true
            loadEditor(into: webView)
        }

        /// Web 内容进程崩溃后重建页面；原生侧收到 ready 事件会重新回填文档。
        @MainActor
        func recover() {
            guard let webView else { return }
            controller.markUnready()
            didLoad = true
            loadEditor(into: webView)
        }

        private func loadEditor(into webView: WKWebView) {
            guard WebResources.indexURL != nil else {
                webView.loadHTMLString(
                    """
                    <html><body style="font-family:-apple-system;padding:40px;color:#666">
                    找不到 Web 编辑器资源。请先运行 <code>scripts/fetch-vendor.sh</code> 并重新构建。
                    </body></html>
                    """,
                    baseURL: nil
                )
                return
            }
            // 内置资源和用户选择的文档图片分别通过受控通道读取。
            webView.load(URLRequest(url: EditorResourceHandler.editorURL))
            #if IMARKDOWN_UI_CHECK
            if let path = ProcessInfo.processInfo.environment["IMARKDOWN_UI_SNAPSHOTS"] {
                Task { @MainActor [weak webView] in
                    guard let webView else { return }
                    do {
                        for _ in 0..<300 {
                            if AppDelegate.shared?.appState?.isEditorReady == true { break }
                            try await Task.sleep(nanoseconds: 30_000_000)
                        }
                        guard let state = AppDelegate.shared?.appState else {
                            throw HeaderBackdropChecks.failure("隔离验收状态未就绪")
                        }
                        let output = URL(fileURLWithPath: path, isDirectory: true)
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        if ProcessInfo.processInfo.environment["IMARKDOWN_THEME_CHECKS"] == "1" {
                            try await PreviewThemeChecks.run(state: state, view: webView, directory: output)
                        } else if ProcessInfo.processInfo.environment["IMARKDOWN_DOCUMENT_CHECKS"] == "1" {
                            try await DocumentTransitionChecks.run(state: state, directory: output)
                        } else {
                            if ProcessInfo.processInfo.environment["IMARKDOWN_SETTINGS_CHECKS"] == "1" {
                                try await SettingsWindowChecks.run(outputDirectory: output)
                            }
                            try await SidebarSelectionChecks.run(outputDirectory: output)
                            try await HeaderBackdropChecks.checkCornerRadii(in: webView)
                            try HeaderBackdropChecks.captureModeControl(in: webView, outputDirectory: output)
                            if ProcessInfo.processInfo.environment["IMARKDOWN_UI_LAYOUT_ONLY"] == "1" {
                                print("UI_LAYOUT_CHECK_PASSED：侧栏选中样式、胶囊控件与原生工具栏布局检查通过")
                            } else {
                                try await HeaderBackdropChecks.run(in: webView, state: state, outputDirectory: output)
                                print("UI_CHECK_PASSED：顶部模糊像素回归和工具栏结构检查通过；整窗玻璃外观需另行验收")
                            }
                        }
                        if ProcessInfo.processInfo.environment["IMARKDOWN_UI_CHECK_EXIT"] == "1" {
                            NSApp.terminate(nil)
                        }
                    } catch {
                        print("UI_CHECK_FAILED：\(error)")
                        if ProcessInfo.processInfo.environment["IMARKDOWN_UI_CHECK_EXIT"] == "1" { exit(1) }
                    }
                }
            }
            #endif
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, bridge: bridge)
    }

    func makeNSView(context: Context) -> WebViewClippingView {
        let wrapper = WebViewClippingView()
        wrapper.wantsLayer = true

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(controller.resources, forURLScheme: "imarkdown")
        configuration.userContentController.add(bridge, name: "editor")

        // 捕获 Web 端未捕获错误并回传原生日志，便于排查空白预览等渲染问题。
        let errorCapture = WKUserScript(source: #"""
        (function () {
          function send(message) {
            try { window.webkit.messageHandlers.editor.postMessage({ type: 'log', text: String(message) }); } catch (e) {}
          }
          window.addEventListener('error', function (e) {
            send('JS_ERROR: ' + e.message + ' @ ' + (e.filename || '') + ':' + (e.lineno || '') + ':' + (e.colno || ''));
          });
          var originalError = console.error;
          console.error = function () {
            send('CONSOLE_ERROR: ' + Array.prototype.slice.call(arguments).join(' '));
            if (originalError) { originalError.apply(console, arguments); }
          };
        })();
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(errorCapture)

        let webView = WKWebView(frame: wrapper.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = bridge
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.underPageBackgroundColor = .clear

        // 注意：此处不要给 webView.layer 设 cornerRadius / masksToBounds，
        // 需要裁剪时交给外层 wrapper，避免破坏远程图层合成。

        wrapper.addSubview(webView)
        context.coordinator.webView = webView
        controller.attach(webView)

        bridge.onWebProcessTerminated = { [weak coordinator = context.coordinator] in
            Task { @MainActor in coordinator?.recover() }
        }

        // 等 wrapper 进入窗口并取得真实尺寸后再加载。
        wrapper.onLayoutReady = { [weak coordinator = context.coordinator] in
            coordinator?.loadIfNeeded()
        }
        return wrapper
    }

    func updateNSView(_ wrapper: WebViewClippingView, context: Context) {
        // 强制 WebKit 重新布局，规避 SwiftUI 尺寸变更后内容不刷新的问题。
        wrapper.needsLayout = true
        wrapper.layoutSubtreeIfNeeded()
        context.coordinator.loadIfNeeded()
    }
}

#if IMARKDOWN_CHECKS || IMARKDOWN_UI_CHECK
/// 两种隔离回归入口共用真实配置、Web 渲染与导出实现。
@MainActor
enum PreviewThemeChecks {
    static func run(state: AppState, view: WKWebView, directory: URL) async throws {
        let originalTheme = state.settings.previewTheme
        let originalAppearance = state.settings.appearance
        let originalSize = state.settings.previewFontSize
        defer {
            state.settings.previewTheme = originalTheme
            state.settings.appearance = originalAppearance
            state.settings.previewFontSize = originalSize
        }
        let markdown = "# Theme check · 主题回归\n\n正文 Mixed text 与 `code`。[链接](https://example.com)\n\n## 章节\n\n> 引用内容\n\n```swift\nlet value = 42\n```\n\n| 字段 | 内容 |\n| --- | --- |\n| name | 示例 |\n"
        state.editor.setDocument(text: markdown, baseDirectory: nil)
        _ = try await state.editor.currentText()
        _ = try await view.evaluateJavaScript("window.MD.insert('可撤销输入\\n')")
        let source = try await state.editor.currentText()
        let epoch = state.editor.documentEpoch
        guard let sourceStyle = try await view.evaluateJavaScript("JSON.stringify([getComputedStyle(document.querySelector('.CodeMirror')).fontFamily, getComputedStyle(document.querySelector('.CodeMirror')).fontSize])") as? String else {
            throw HeaderBackdropChecks.failure("源码样式响应无效")
        }
        state.settings.previewFontSize = 19.5
        let widths: [PreviewTheme: String] = [.github: "720px", .serif: "690px", .compact: "100%", .paper: "700px", .technical: "800px", .focus: "640px"]
        let exportWidths: [PreviewTheme: String] = [.paper: "700px", .technical: "800px", .focus: "640px"]
        let lineHeights: [PreviewTheme: Double] = [.github: 1.78, .serif: 1.92, .compact: 1.62, .paper: 1.9, .technical: 1.7, .focus: 1.95]
        let exportView = WKWebView(frame: view.frame)
        let exportWindow = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        exportWindow.isReleasedWhenClosed = false
        exportWindow.alphaValue = 0
        exportWindow.ignoresMouseEvents = true
        exportWindow.contentView = exportView
        exportWindow.orderFrontRegardless()
        defer { exportWindow.orderOut(nil); exportView.removeFromSuperview() }
        for appearance in [AppearancePreference.light, .dark] {
            state.settings.appearance = appearance
            for theme in PreviewTheme.allCases {
                state.settings.previewTheme = theme
                let themeID = JS.encode(theme.rawValue)
                let appearanceID = JS.encode(appearance.rawValue)
                try await wait {
                    (try? await bool(view, "document.documentElement.dataset.preview === \(themeID) && document.documentElement.dataset.appearance === \(appearanceID)")) == true
                }
                let layoutCheck = """
                (() => {
                  const style = getComputedStyle(document.querySelector('#preview'));
                  return style.getPropertyValue('--md-width').trim() === \(JS.encode(widths[theme]!)) &&
                    Math.abs(parseFloat(style.lineHeight) / parseFloat(style.fontSize) - \(lineHeights[theme]!)) < 0.01 &&
                    parseFloat(style.fontSize) === 19.5 &&
                    JSON.stringify([getComputedStyle(document.querySelector('.CodeMirror')).fontFamily,
                      getComputedStyle(document.querySelector('.CodeMirror')).fontSize]) === \(JS.encode(sourceStyle));
                })()
                """
                try HeaderBackdropChecks.require(try await bool(view, layoutCheck), "\(theme.title)/\(appearance.title)：版心与行距生效，保留预览字号及源码样式")
                if theme == .paper {
                    try HeaderBackdropChecks.require(try await bool(view, "getComputedStyle(document.querySelector('#preview')).fontFamily.includes('serif') && getComputedStyle(document.querySelector('#preview h1')).fontFamily.includes('sans-serif')"), "纸感：衬线正文与无衬线标题分层")
                } else if theme == .technical {
                    try HeaderBackdropChecks.require(try await bool(view, "getComputedStyle(document.querySelector('#preview pre')).borderRadius === '6px' && getComputedStyle(document.querySelector('#preview td')).paddingTop === '6px'"), "技术文档：代码与表格使用独立密度")
                } else if theme == .focus {
                    try HeaderBackdropChecks.require(try await bool(view, "getComputedStyle(document.querySelector('#preview h1')).borderBottomWidth === '0px' && getComputedStyle(document.querySelector('#preview a')).textDecorationLine.includes('underline')"), "专注阅读：去掉标题分隔，链接仍可辨识")
                }
                // 原有主题保持配色兼容；新增风格要求包含链接在内的正文对比度达到 4.5。
                if exportWidths[theme] != nil {
                    try HeaderBackdropChecks.require(try await bool(view, contrastCheck), "\(theme.title)/\(appearance.title)：正文、标题、链接及行内代码对比度达标")
                }
                try HeaderBackdropChecks.require(try await state.editor.currentText() == source && state.editor.documentEpoch == epoch,
                                                "\(theme.title)/\(appearance.title)：切换风格不改源码或文档代数")
                let html = HTMLComposer.compose(articleHTML: try await state.editor.articleHTML(), title: "主题回归",
                                                dark: appearance == .dark, previewTheme: theme, documentURL: nil)
                exportView.loadHTMLString(html, baseURL: nil)
                try await wait {
                    guard !exportView.isLoading else { return false }
                    return (try? await bool(exportView, "document.documentElement.dataset.preview === \(themeID) && document.documentElement.dataset.appearance === \(appearanceID) && !!document.querySelector('article table')")) == true
                }
                let exportWidth = exportWidths[theme] ?? "780px"
                try HeaderBackdropChecks.require(try await bool(exportView, "getComputedStyle(document.querySelector('article')).maxWidth === \(JS.encode(exportWidth)) && document.querySelector('article').textContent.includes('Theme check') && !document.querySelector('script, link[rel=stylesheet]')"),
                                                "\(theme.title)/\(appearance.title)：独立 HTML 复用主题且不依赖外部样式")
                if exportWidths[theme] != nil {
                    try HeaderBackdropChecks.require(try await bool(exportView, contrastCheck), "\(theme.title)/\(appearance.title)：HTML 导出文字对比度达标")
                }
                if appearance == .light && exportWidths[theme] != nil {
                    let paragraphs = String(repeating: "<p>主题分页检查 Mixed text，文档内容可正常阅读。</p>", count: 40)
                    let pdfHTML = HTMLComposer.compose(articleHTML: (try await state.editor.articleHTML()) + paragraphs,
                                                      title: "主题回归", dark: false, previewTheme: theme, documentURL: nil, layout: .pdf)
                    let destination = directory.appendingPathComponent("theme-\(theme.rawValue).pdf")
                    try await PDFExportService.export(html: pdfHTML, baseURL: nil, to: destination)
                    guard let document = PDFDocument(url: destination) else { throw HeaderBackdropChecks.failure("主题 PDF 无法读取") }
                    try HeaderBackdropChecks.require(document.pageCount >= 2 && document.string?.contains("Theme check") == true,
                                                    "\(theme.title)：PDF 保留文本并正常分页")
                    for index in 0..<document.pageCount {
                        guard let page = document.page(at: index) else { throw HeaderBackdropChecks.failure("主题 PDF 页面缺失") }
                        let size = page.bounds(for: .mediaBox).size
                        try HeaderBackdropChecks.require(abs(size.width - 595.2) < 1 && abs(size.height - 841.8) < 1,
                                                        "\(theme.title)：PDF 第 \(index + 1) 页为 A4")
                    }
                }
            }
        }
        _ = try await view.evaluateJavaScript("window.MD.undo()")
        try HeaderBackdropChecks.require(try await state.editor.currentText() == markdown, "多次切换主题后编辑撤销历史仍完整")
        print("PREVIEW_THEME_CHECKS_PASSED：六套风格深浅色渲染、HTML 与新增主题 PDF 导出通过")
    }

    private static func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw HeaderBackdropChecks.failure("等待主题渲染超时")
    }

    private static func bool(_ view: WKWebView, _ script: String) async throws -> Bool {
        try await view.evaluateJavaScript(script) as? Bool ?? false
    }

    // 以实际背景和半透明行内代码底色计算对比度，不依赖截图采样。
    private static let contrastCheck = """
    (() => {
      const rgb = value => (value.match(/[\\d.]+/g) || []).map(Number);
      const blend = (front, back) => front.slice(0, 3).map((v, i) => v * (front[3] ?? 1) + back[i] * (1 - (front[3] ?? 1)));
      const lum = color => color.map(v => v / 255).map(v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4))
        .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
      const contrast = (front, back) => (Math.max(lum(front), lum(back)) + 0.05) / (Math.min(lum(front), lum(back)) + 0.05);
      const background = rgb(getComputedStyle(document.body).backgroundColor).slice(0, 3);
      return ['.markdown-body p', '.markdown-body h1', '.markdown-body a', '.markdown-body p code'].every(selector => {
        const style = getComputedStyle(document.querySelector(selector));
        const back = blend(rgb(style.backgroundColor), background);
        return contrast(blend(rgb(style.color), back), back) >= 4.5;
      });
    })()
    """
}

/// 使用应用自身的渲染快照比较模糊前后像素，不读取桌面或其他窗口。
@MainActor
enum HeaderBackdropChecks {
    static func failure(_ text: String) -> NSError {
        NSError(domain: "iMarkDown.HeaderBackdropChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: text])
    }

    static func require(_ condition: Bool, _ text: String) throws {
        guard condition else { throw failure(text) }
        print("✓ \(text)")
    }

    static func checkCornerRadii(in view: WKWebView) async throws {
        try require(DesignTokens.CornerRadius.icon == 8 && DesignTokens.CornerRadius.surface == 12 &&
                    DesignTokens.CornerRadius.container == 18 &&
                    GlassSurface().cornerRadius == DesignTokens.CornerRadius.surface,
                    "品牌图标与大容器保留 8/12/18 pt，通用玻璃浮层不强行胶囊化")
        for height: CGFloat in [28, 38, 30, 42] {
            let rect = CGRect(x: 0, y: 0, width: 220, height: height)
            let shape = DesignTokens.controlShape
            let path = shape.path(in: rect)
            let inset = shape.inset(by: 1.2).path(in: rect)
            try require(path.contains(CGPoint(x: 0.5, y: rect.midY)) &&
                        !path.contains(CGPoint(x: 0.5, y: height / 4)) &&
                        !path.contains(CGPoint(x: 1, y: 1)) &&
                        !inset.contains(CGPoint(x: 0.5, y: rect.midY)) &&
                        inset.contains(CGPoint(x: 1.5, y: rect.midY)),
                        "\(Int(height)) pt 控件：共用胶囊路径，背景与内描边随高度一致变化")
        }
        let config = EditorConfig(appearance: "light", previewTheme: "github", editorFontSize: 14,
                                  previewFontSize: 15.5, baseDirectory: "", accentColor: "#0a7cff")
        struct RadiusPayload: Decodable { let uiCornerRadii: [String: Double] }
        let payload = try JSONDecoder().decode(RadiusPayload.self, from: Data(config.jsonString.utf8))
        try require(payload.uiCornerRadii == DesignTokens.CornerRadius.webConfig,
                    "编辑器配置将原生圆角规格完整编码给 Web 控件")
        // DOM 的 activeElement 不代表 WebView 已激活；焦点样式需要真实的键盘焦点。
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
        let acceptedFocus = view.window?.makeFirstResponder(view) ?? false
        try await Task.sleep(nanoseconds: 200_000_000)
        print("焦点宿主：应用激活=\(NSApp.isActive)，主窗口激活=\(view.window?.isKeyWindow == true)，接收焦点=\(acceptedFocus)")
        let result = try await view.callAsyncJavaScript("""
            return (async () => {
              const root = document.documentElement, bar = document.getElementById('find-bar');
              const settled = () => new Promise(resolve => setTimeout(resolve, 50));
              const expected = (\(config.jsonString)).uiCornerRadii;
              const appearance = root.dataset.appearance, wasOpen = !bar.hidden, focus = document.activeElement;
              const inlineMatches = ['control', 'surface'].every(name =>
                parseFloat(root.style.getPropertyValue('--ui-' + name + '-radius')) === expected[name]);
              const matches = (node, radius) => {
                const style = getComputedStyle(node);
                return ['borderTopLeftRadius', 'borderTopRightRadius', 'borderBottomLeftRadius', 'borderBottomRightRadius']
                  .every(key => parseFloat(style[key]) === radius);
              };
              try {
                window.MD.openFind();
                const opened = !bar.hidden && document.activeElement === document.getElementById('find-input');
                const controls = Array.from(bar.querySelectorAll('input, button'));
                const samples = [];
                for (const value of ['light', 'dark']) {
                  window.MD.applyConfig({ appearance: value });
                  await settled();
                  const capsules = controls.length > 0 && controls.every(node => {
                    const rect = node.getBoundingClientRect();
                    return matches(node, expected.control) && rect.height >= 26 &&
                      expected.control >= Math.min(rect.width, rect.height) / 2;
                  });
                  const focusDetails = [];
                  for (const node of controls.filter(node => node.tagName === 'INPUT')) {
                    node.blur();
                    await settled();
                    const border = getComputedStyle(node).borderTopColor;
                    node.focus();
                    await settled();
                    const focusedBorder = getComputedStyle(node).borderTopColor;
                    focusDetails.push({ id: node.id, border, focusedBorder, active: document.activeElement === node,
                      focused: node.matches(':focus'), documentFocused: document.hasFocus(),
                      matches: matches(node, expected.control) && focusedBorder !== border });
                  }
                  samples.push({ appearance: value, matches: matches(bar, expected.surface) && capsules,
                    focused: focusDetails.length === 2 && focusDetails.every(item => item.active && item.matches),
                    focusDetails: JSON.stringify(focusDetails) });
                }
                window.MD.closeFind();
                return JSON.stringify({ inlineMatches, samples, opened, closed: bar.hidden });
              } finally {
                window.MD.applyConfig({ appearance });
                if (wasOpen) { window.MD.openFind(); } else { window.MD.closeFind(); }
                if (focus && typeof focus.focus === 'function') { focus.focus(); }
              }
            })()
            """, arguments: [:], in: nil, contentWorld: .page)
        struct RadiusResult: Decodable {
            struct Sample: Decodable {
                let appearance: String
                let matches: Bool
                let focused: Bool
                let focusDetails: String
            }
            let inlineMatches: Bool
            let samples: [Sample]
            let opened: Bool
            let closed: Bool
        }
        guard let json = result as? String else { throw failure("Web 圆角验收未返回有效结果") }
        let check = try JSONDecoder().decode(RadiusResult.self, from: Data(json.utf8))
        try require(check.inlineMatches, "Web 使用实际收到的原生圆角配置，不仅依赖 CSS 兜底值")
        try require(check.samples.map(\.appearance) == ["light", "dark"], "圆角验收覆盖深浅两种外观")
        for sample in check.samples {
            try require(sample.matches, "\(sample.appearance)：查找浮层保留 12 px，输入框与按钮按短边形成胶囊")
            if !sample.focused { print("焦点样本：\(sample.focusDetails)") }
            try require(sample.focused, "\(sample.appearance)：查找与替换输入框聚焦时胶囊形状不变，并显示焦点描边")
        }
        try require(check.opened && check.closed, "统一圆角后查找栏仍可打开、聚焦与关闭")
    }

    static func run(in view: WKWebView, state: AppState, outputDirectory: URL? = nil) async throws {
        let originalText = try await state.editor.currentText()
        let originalMode = state.mode
        let baseDirectory = state.session.url?.deletingLastPathComponent().absoluteString
        var restored = false
        defer {
            if !restored {
                view.evaluateJavaScript("document.getElementById('backdrop-pixel-fixture')?.remove()", completionHandler: nil)
                state.editor.setDocument(text: originalText, baseDirectory: baseDirectory)
                state.setMode(originalMode)
            }
        }
        if let outputDirectory {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }
        // 空文档也要能回归滚动到覆盖区的行为；只在隔离进程中替换测试样本。
        if originalText.count < 1000 {
            state.editor.setDocument(text: "# 顶部模糊回归\n\n" + String(repeating: "🔴 🟢 🔵 中英文正文 Background blur\n\n", count: 100), baseDirectory: nil)
            _ = try await state.editor.currentText()
        }
        for mode in EditorMode.allCases {
            state.setMode(mode)
            try await Task.sleep(nanoseconds: 250_000_000)
            _ = try await view.evaluateJavaScript("document.querySelector('.CodeMirror').CodeMirror.scrollTo(0, 260); document.getElementById('preview-scroll').scrollTop = 260")
            try await Task.sleep(nanoseconds: 250_000_000)
            let correct = try await view.evaluateJavaScript("""
                (() => {
                  const b = document.getElementById('chrome-backdrop'), s = getComputedStyle(b), r = b.getBoundingClientRect();
                  return !b.hidden && s.position === 'fixed' && s.pointerEvents === 'none' &&
                    r.top === 0 && r.height === 64 && Math.abs(r.width - innerWidth) < 1 &&
                    (s.backdropFilter || s.webkitBackdropFilter).includes('blur(20px)') &&
                    b.getAttribute('aria-hidden') === 'true' && !document.getElementById('preview').contains(b);
                })()
                """) as? Bool ?? false
            try require(correct, "\(mode.title)：顶部模糊启用、尺寸正确且不拦截正文")
            if let outputDirectory {
                let image = try await snapshot(view, height: 180)
                try save(image, to: outputDirectory.appendingPathComponent("\(mode.rawValue)-header.png"))
            }
        }
        // 高频彩色条纹使纯色遮盖或仅设置属性的假阳性无法通过像素比较。
        _ = try await view.evaluateJavaScript("""
            (() => {
              const pattern = document.createElement('div'); pattern.id = 'backdrop-pixel-fixture';
              pattern.style.cssText = 'position:fixed;inset:0 0 auto;height:128px;z-index:10;pointer-events:none;background:repeating-linear-gradient(90deg,#ff0033 0px,#ff0033 4px,#0033ff 4px,#0033ff 8px)';
              document.body.appendChild(pattern); document.getElementById('chrome-backdrop').hidden = true;
            })()
            """)
        let clear = try await snapshot(view, height: 128)
        _ = try await view.evaluateJavaScript("document.getElementById('chrome-backdrop').hidden = false")
        let blurred = try await snapshot(view, height: 128)
        if let outputDirectory {
            try save(clear, to: outputDirectory.appendingPathComponent("pixels-clear.png"))
            try save(blurred, to: outputDirectory.appendingPathComponent("pixels-blurred.png"))
        }
        if let data = blurred.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
           let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(24 * CGFloat(bitmap.pixelsWide) / view.bounds.width))?.usingColorSpace(.deviceRGB) {
            try require(color.redComponent - color.greenComponent > 0.1 && color.blueComponent - color.greenComponent > 0.1,
                        "模糊保留后方红蓝颜色，未被纯色背景遮盖")
        } else {
            throw failure("模糊后颜色像素不可读")
        }
        let clearEdges = try edgeEnergy(clear, row: 24, logicalWidth: view.bounds.width)
        let blurredEdges = try edgeEnergy(blurred, row: 24, logicalWidth: view.bounds.width)
        print("顶部像素边缘能量：清晰=\(clearEdges)，模糊=\(blurredEdges)")
        try require(clearEdges > 0.01 && blurredEdges < clearEdges * 0.2, "顶部实际像素被模糊，条纹边缘能量下降超过 80%")
        let belowClear = try edgeEnergy(clear, row: 100, logicalWidth: view.bounds.width)
        let belowBlurred = try edgeEnergy(blurred, row: 100, logicalWidth: view.bounds.width)
        try require(abs(belowClear - belowBlurred) < 0.005, "64pt 以下的正文像素未被模糊")
        _ = try await view.evaluateJavaScript("document.getElementById('backdrop-pixel-fixture').remove()")
        state.editor.setDocument(text: originalText, baseDirectory: baseDirectory)
        state.setMode(originalMode)
        _ = try await state.editor.currentText()
        try await Task.sleep(nanoseconds: 250_000_000)
        let hidden = try await view.evaluateJavaScript("document.getElementById('chrome-backdrop').hidden") as? Bool ?? false
        try require(hidden, "回到文档顶部后背景隐藏")
        try require(!(try await state.editor.articleHTML()).contains("chrome-backdrop"), "背景节点不进入文档导出")
        restored = true
    }

    static func snapshot(_ view: WKWebView, height: CGFloat) async throws -> NSImage {
        try await Task.sleep(nanoseconds: 150_000_000)
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: view.bounds.width, height: height)
        config.snapshotWidth = NSNumber(value: Double(view.bounds.width))
        return try await withCheckedThrowingContinuation { continuation in
            view.takeSnapshot(with: config) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? failure("WebKit 快照失败")) }
            }
        }
    }

    static func save(_ image: NSImage, to url: URL) throws {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw failure("快照 PNG 编码失败")
        }
        try png.write(to: url)
    }

    static func edgeEnergy(_ image: NSImage, row: CGFloat, logicalWidth: CGFloat) throws -> Double {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else {
            throw failure("快照像素不可读")
        }
        let scale = CGFloat(bitmap.pixelsWide) / logicalWidth
        let y = min(bitmap.pixelsHigh - 1, Int(row * scale))
        var previous: NSColor?
        var total = 0.0
        var count = 0
        for x in Int(40 * scale)..<min(bitmap.pixelsWide, Int(600 * scale)) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if let previous {
                total += Double(abs(color.redComponent - previous.redComponent) +
                                abs(color.greenComponent - previous.greenComponent) +
                                abs(color.blueComponent - previous.blueComponent)) / 3
                count += 1
            }
            previous = color
        }
        guard count > 0 else { throw failure("快照无有效像素") }
        return total / Double(count)
    }

    static func captureModeControl(in view: WKWebView, outputDirectory: URL) throws {
        func find(_ root: NSView) -> NSSegmentedControl? {
            if let control = root as? NSSegmentedControl,
               control.identifier?.rawValue == "iMarkDown.viewMode" { return control }
            return root.subviews.lazy.compactMap { find($0) }.first
        }
        guard let toolbar = view.window?.toolbar,
              let control = toolbar.items.lazy.compactMap({ $0.view.flatMap { find($0) } }).first else {
            throw failure("模式控件未进入原生工具栏")
        }
        try require(control.borderShape == .capsule && control.segmentStyle == .automatic,
                    "模式切换位于系统工具栏内，使用原生胶囊边框")
        let rect = control.convert(control.bounds, to: nil)
        let width = view.window?.frame.width ?? 0
        print("工具栏布局：模式按钮 x=\(rect.minX)...\(rect.maxX)，窗口宽=\(width)")
        try require(rect.minX > width / 2 && width - rect.maxX < 110,
                    "模式按钮位于窗口右侧，为左侧标题留出空间")
        func findExport(_ root: NSView) -> NSButton? {
            if let button = root as? NSButton,
               button.identifier?.rawValue == "iMarkDown.exportControl" { return button }
            return root.subviews.lazy.compactMap { findExport($0) }.first
        }
        guard let exportRoot = toolbar.items.first(where: {
            $0.itemIdentifier.rawValue.contains("iMarkDown.export")
        })?.view, let export = findExport(exportRoot), let cell = export.cell as? NSButtonCell else {
            throw failure("未找到工具栏内的实际原生导出按钮")
        }
        let exportRect = export.convert(export.bounds, to: nil)
        let iconRect = export.convert(cell.imageRect(forBounds: export.bounds), to: nil)
        print("工具栏实际布局：模式中心=\(rect.midY)，导出中心=\(exportRect.midY)，图标中心=\(iconRect.midY)，按钮=\(exportRect)，图标=\(iconRect)")
        try require(abs(rect.midY - exportRect.midY) <= 0.5 && exportRect.minX - rect.maxX >= 4,
                    "实际导出按钮与模式控件同一水平中心线，并有独立间隔")
        try require(!iconRect.isEmpty && abs(iconRect.midY - exportRect.midY) <= 1 &&
                    abs(iconRect.midX - exportRect.midX) <= 1 && exportRect.contains(iconRect),
                    "导出图标在实际按钮内部水平、垂直居中且没有裁切")
        try require(export.borderShape == .circle && export.bezelStyle == .glass &&
                    abs(exportRect.width - exportRect.height) <= 0.5 && abs(exportRect.width - 36) <= 0.5 &&
                    export.imagePosition == .imageOnly && export.action != nil &&
                    export.target != nil && !(export is NSPopUpButton),
                    "导出使用 36×36 pt 正方形布局及原生玻璃圆形边框")
        let backingScale = max(1, view.window?.backingScaleFactor ?? 1)
        guard let image = export.image,
              let imageBitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                  pixelsWide: Int(image.size.width * backingScale), pixelsHigh: Int(image.size.height * backingScale),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let imageContext = NSGraphicsContext(bitmapImageRep: imageBitmap) else {
            throw failure("导出图标的可见笔画像素不可读")
        }
        // 按实际屏幕倍率绘制，避免低分辨率 TIFF 的像素舍入影响居中判断。
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = imageContext
        imageContext.cgContext.scaleBy(x: backingScale, y: backingScale)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var minX = imageBitmap.pixelsWide, minY = imageBitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<imageBitmap.pixelsHigh {
            for x in 0..<imageBitmap.pixelsWide where (imageBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX && maxY >= minY else { throw failure("导出图标没有可见笔画") }
        let scaleX = iconRect.width / CGFloat(imageBitmap.pixelsWide)
        let scaleY = iconRect.height / CGFloat(imageBitmap.pixelsHigh)
        let visibleInkRect = NSRect(x: iconRect.minX + CGFloat(minX) * scaleX,
                                   y: iconRect.minY + CGFloat(imageBitmap.pixelsHigh - maxY - 1) * scaleY,
                                   width: CGFloat(maxX - minX + 1) * scaleX,
                                   height: CGFloat(maxY - minY + 1) * scaleY)
        print("导出图标可见笔画（\(backingScale)×）：\(visibleInkRect)，中心=(\(visibleInkRect.midX), \(visibleInkRect.midY))，按钮中心=(\(exportRect.midX), \(exportRect.midY))")
        if let png = imageBitmap.representation(using: .png, properties: [:]) {
            try png.write(to: outputDirectory.appendingPathComponent("export-icon-render.png"))
        }
        try require(abs(visibleInkRect.midX - exportRect.midX) <= 0.5 &&
                    abs(visibleInkRect.midY - exportRect.midY) <= 0.5 && exportRect.contains(visibleInkRect),
                    "导出图标可见笔画水平、垂直居中，不仅校验图像外框")
        try require(export.menu?.items.map(\.title) == ["导出为 HTML…", "导出为 PDF…"] &&
                    export.menu?.items.allSatisfy({ $0.action != nil && $0.target != nil && !$0.isHidden && $0.isEnabled == export.isEnabled }) == true,
                    "导出菜单保留 HTML / PDF 两项及原有启用状态")
        #if IMARKDOWN_UI_CHECK
        if export.isEnabled, let menu = export.menu {
            final class MenuProbe: NSObject, NSMenuDelegate {
                var didOpen = false
                weak var menuToCancel: NSMenu?
                func menuWillOpen(_ menu: NSMenu) { didOpen = true }
                @objc func cancelMenu(_ timer: Timer) { menuToCancel?.cancelTracking() }
            }
            let originalDelegate = menu.delegate
            let probe = MenuProbe()
            probe.menuToCancel = menu
            menu.delegate = probe
            view.window?.makeKeyAndOrderFront(nil)
            let timer = Timer(timeInterval: 0.3, target: probe, selector: #selector(MenuProbe.cancelMenu(_:)),
                              userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .common)
            export.performClick(nil)
            timer.invalidate()
            menu.delegate = originalDelegate
            try require(probe.didOpen, "点击实际导出按钮可以打开原生菜单，取消不触发文件导出")
        }
        #endif
        if let bitmap = export.bitmapImageRepForCachingDisplay(in: export.bounds) {
            export.cacheDisplay(in: export.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: outputDirectory.appendingPathComponent("export-control-render.png"))
            }
        }
        if let bitmap = control.bitmapImageRepForCachingDisplay(in: control.bounds) {
            control.cacheDisplay(in: control.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: outputDirectory.appendingPathComponent("mode-control-render.png"))
            }
        }
        if let frameView = view.window?.contentView?.superview {
            let header = NSRect(x: frameView.bounds.minX,
                                y: frameView.isFlipped ? frameView.bounds.minY : frameView.bounds.maxY - 64,
                                width: frameView.bounds.width, height: 64)
            if let bitmap = frameView.bitmapImageRepForCachingDisplay(in: header) {
                frameView.cacheDisplay(in: header, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: outputDirectory.appendingPathComponent("toolbar-render.png"))
                }
            }
        }
    }
}
#endif

/// 应用资源与文档图片分别授权，不给 Web 内容主目录或整盘读取权限。
@MainActor
final class EditorResourceHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let editorURL = URL(string: "imarkdown://app/index.html")!
    var documentDirectory: URL?
    private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let requestURL = urlSchemeTask.request.url,
              let file = resolve(requestURL) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let limit = requestURL.host == "document" ? 8 * 1024 * 1024 : 16 * 1024 * 1024
        pending[key] = Task { @MainActor in
            do {
                let data = try await Task.detached(priority: .utility) {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= limit else { throw URLError(.dataLengthExceedsMaximum) }
                    return try Data(contentsOf: file)
                }.value
                guard !Task.isCancelled, pending[key] != nil else { return }
                urlSchemeTask.didReceive(URLResponse(url: requestURL, mimeType: mime,
                                                      expectedContentLength: data.count,
                                                      textEncodingName: "utf-8"))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, pending[key] != nil else { return }
                urlSchemeTask.didFailWithError(error)
            }
            pending.removeValue(forKey: key)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        pending.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    private func resolve(_ url: URL) -> URL? {
        guard url.scheme == "imarkdown" else { return nil }
        let path = String(url.path.dropFirst())
        if url.host == "document", let directory = documentDirectory {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            return FileService.localImageURL(encoded, directory: directory)
        }
        guard url.host == "app", let root = WebResources.rootURL?.resolvingSymlinksInPath() else { return nil }
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"),
              ["html", "css", "js", "woff", "woff2"].contains(file.pathExtension.lowercased()) else { return nil }
        return file
    }
}
