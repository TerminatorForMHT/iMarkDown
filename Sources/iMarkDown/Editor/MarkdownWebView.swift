import AppKit
import MarkdownKit
import UniformTypeIdentifiers
import SwiftUI
import WebKit

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
                        if ProcessInfo.processInfo.environment["IMARKDOWN_DOCUMENT_CHECKS"] == "1" {
                            try await DocumentTransitionChecks.run(state: state, directory: output)
                        } else {
                            if ProcessInfo.processInfo.environment["IMARKDOWN_SETTINGS_CHECKS"] == "1" {
                                try await SettingsWindowChecks.run(outputDirectory: output)
                            }
                            try HeaderBackdropChecks.captureModeControl(in: webView, outputDirectory: output)
                            if ProcessInfo.processInfo.environment["IMARKDOWN_UI_LAYOUT_ONLY"] == "1" {
                                print("UI_LAYOUT_CHECK_PASSED：原生导出按钮与实际图标右侧居中对齐")
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
        try require(export.borderShape == .circle && export.imagePosition == .imageOnly &&
                    export.action != nil && export.target != nil && !(export is NSPopUpButton),
                    "导出使用原生圆形图标按钮，不使用下拉控件的标题/箭头布局")
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
