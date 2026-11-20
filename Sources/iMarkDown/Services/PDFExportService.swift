import AppKit
import Foundation
import WebKit

enum ExportError: LocalizedError {
    case loadFailed
    case printFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "无法渲染导出内容。"
        case .printFailed: return "生成 PDF 失败。"
        }
    }
}

/// 使用 WebKit 官方打印链路导出 PDF：隐藏窗口 + NSPrintOperation(.save)。
/// 这样能复用预览样式，并由系统自动分页。
@MainActor
enum PDFExportService {
    static func export(html: String, baseURL: URL?, to destination: URL) async throws {
        // A4 纵向（单位：point）。
        let pageSize = NSSize(width: 595.2, height: 841.8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: NSRect(origin: .zero, size: pageSize), configuration: configuration)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: pageSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.orderFrontRegardless()

        defer {
            window.orderOut(nil)
            webView.removeFromSuperview()
        }

        let loader = WebPageLoader()
        try await loader.load(webView, html: html, baseURL: baseURL)

        let printInfo = NSPrintInfo()
        printInfo.paperSize = pageSize
        printInfo.orientation = .portrait
        printInfo.topMargin = 48
        printInfo.bottomMargin = 48
        printInfo.leftMargin = 52
        printInfo.rightMargin = 52
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination as NSURL

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else {
            throw ExportError.printFailed
        }
    }
}

@MainActor
private final class WebPageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ webView: WKWebView, html: String, baseURL: URL?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.navigationDelegate = self
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        // 等待图片解码完成，避免打印出缺少插图的页面。
        let waitScript = """
        await Promise.all(Array.from(document.images).map(function (img) {
          if (img.complete) { return true; }
          return new Promise(function (resolve) {
            img.addEventListener('load', resolve, { once: true });
            img.addEventListener('error', resolve, { once: true });
          });
        }));
        """
        _ = try? await webView.callAsyncJavaScript(
            waitScript,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        // 给字体与样式一点排版时间，避免打印出空页。
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
