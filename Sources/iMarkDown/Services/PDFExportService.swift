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
        let pageSize = NSSize(width: 595, height: 842)
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
        printInfo.topMargin = 42
        printInfo.bottomMargin = 42
        printInfo.leftMargin = 46
        printInfo.rightMargin = 46
        printInfo.horizontalPagination = .automatic
        printInfo.verticalPagination = .automatic
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
        // 给字体、图片与样式一点排版时间，避免打印出空页。
        try? await Task.sleep(nanoseconds: 350_000_000)
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
