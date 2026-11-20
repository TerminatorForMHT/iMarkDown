import AppKit
import SwiftUI
import WebKit

enum WebResources {
    static let rootURL: URL? = Bundle.module.url(forResource: "Web", withExtension: nil)

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

/// 外层裁剪视图：承担圆角与 masksToBounds。
///
/// 绝不能把 `masksToBounds` / `cornerRadius` 直接设在承载 WKWebView 的
/// 远程图层（remote layer）上——在部分 macOS 版本上这会导致 WebKit 内容
/// 层不参与合成，出现「背景能画、正文/源码全部空白」的症状。改成由一个
/// 普通 AppKit 图层做裁剪，WebView 在内部满尺寸绘制，即可正常合成。
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
        onLayoutReady?()
    }
}

/// 承载 Web 内核的 WKWebView。原生只负责创建、加载与生命周期，不干预编辑行为。
struct MarkdownWebView: NSViewRepresentable {
    let controller: EditorController
    let bridge: EditorBridge

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
            guard let indexURL = WebResources.indexURL else {
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
            // 预览需要读取文档所在目录的本地图片。权限收窄到用户主目录，
            // 不再对整个根文件系统开放；如需支持外置磁盘可在此追加挂载点。
            webView.loadFileURL(
                indexURL,
                allowingReadAccessTo: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, bridge: bridge)
    }

    func makeNSView(context: Context) -> WebViewClippingView {
        let wrapper = WebViewClippingView()
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = DesignTokens.cardRadius
        wrapper.layer?.masksToBounds = true

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
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

        // 注意：此处不再给 webView.layer 设 cornerRadius / masksToBounds，
        // 裁剪交给外层 wrapper，避免破坏远程图层合成。

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
