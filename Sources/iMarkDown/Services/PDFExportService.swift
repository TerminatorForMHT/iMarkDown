import AppKit
import Foundation
import WebKit

enum ExportError: LocalizedError {
    case loadFailed
    case renderFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "无法渲染导出内容。"
        case .renderFailed: return "生成 PDF 失败。"
        case .writeFailed: return "无法写入 PDF 文件。"
        }
    }
}

/// 使用 WKWebView.createPDF 逐页渲染再合成 A4。
///
/// 不走 `printOperation(with:)`：macOS 26 上该链路存在页数计算缺陷
/// （FB20581927），会无限生成页面并卡死导出。createPDF 稳定且保留矢量文字，
/// 只是它按屏幕媒体渲染、且不会自动分页，所以这里自己做块级分页与页边距。
@MainActor
enum PDFExportService {
    /// A4 纵向（单位：point）。
    private static let pageSize = CGSize(width: 595.2, height: 841.8)
    private static let marginX: CGFloat = 48
    private static let marginTop: CGFloat = 48
    private static let marginBottom: CGFloat = 48

    private static var contentSize: CGSize {
        CGSize(
            width: pageSize.width - marginX * 2,
            height: pageSize.height - marginTop - marginBottom
        )
    }

    static func export(html: String, baseURL: URL?, to destination: URL) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(
            frame: NSRect(origin: .zero, size: contentSize),
            configuration: configuration
        )

        // 打印需要 WebKit 正常布局与图片解码，窗口不可见但必须真正在屏外存在。
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: contentSize),
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

        let slices = try await pageSlices(in: webView)
        guard !slices.isEmpty else { throw ExportError.renderFailed }

        let data = try await composePages(webView: webView, slices: slices)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ExportError.writeFailed
        }
    }

    // MARK: - 分页

    /// 在块级元素边界上取分页点，避免把段落、代码块或表格拦腰切断。
    private static func pageSlices(in webView: WKWebView) async throws -> [[Double]] {
        let script = """
        (function () {
          var LIMIT = \(format(contentSize.height));
          var root = document.querySelector('article.markdown-body') || document.body;
          var total = Math.max(root.scrollHeight, document.documentElement.scrollHeight);
          var nodes = Array.prototype.slice.call(root.children);
          var candidates = [];
          nodes.forEach(function (el) {
            var tag = el.tagName;
            if (tag === 'H1' || tag === 'H2' || tag === 'H3' || tag === 'H4') { return; }
            var rect = el.getBoundingClientRect();
            var bottom = rect.bottom + window.scrollY;
            if (bottom > 1 && bottom < total - 1) { candidates.push(bottom); }
          });
          candidates.sort(function (a, b) { return a - b; });

          var slices = [];
          var start = 0;
          var guard = 0;
          while (start < total - 1 && guard < 1000) {
            guard += 1;
            var limit = start + LIMIT;
            var end = 0;
            for (var i = 0; i < candidates.length; i += 1) {
              var c = candidates[i];
              if (c <= start + 24) { continue; }
              if (c <= limit) { end = c; } else { break; }
            }
            if (!end) { end = Math.min(limit, total); }
            if (end <= start + 1) { break; }
            slices.push([
              Math.round(start * 100) / 100,
              Math.round((end - start) * 100) / 100
            ]);
            start = end;
          }
          return JSON.stringify(slices);
        })();
        """

        let value = try await webView.evaluateJavaScript(script)
        guard let json = value as? String,
              let data = json.data(using: .utf8),
              let slices = try? JSONSerialization.jsonObject(with: data) as? [[Double]] else {
            throw ExportError.renderFailed
        }
        return slices
    }

    // MARK: - 合成

    /// 把每页切片画进标准 A4 页面，保留矢量文字与页边距。
    private static func composePages(
        webView: WKWebView,
        slices: [[Double]]
    ) async throws -> Data {
        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.renderFailed
        }

        for slice in slices {
            let originY = slice[0]
            let height = slice[1]
            let rect = CGRect(
                x: 0,
                y: originY,
                width: contentSize.width,
                height: height
            )
            let configuration = WKPDFConfiguration()
            configuration.rect = rect
            let pageData = try await createPDF(webView: webView, configuration: configuration)
            guard let provider = CGDataProvider(data: pageData as CFData),
                  let document = CGPDFDocument(provider),
                  let page = document.page(at: 1) else {
                throw ExportError.renderFailed
            }

            let box = page.getBoxRect(.mediaBox)
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            context.saveGState()
            context.translateBy(
                x: marginX,
                y: pageSize.height - marginTop - box.height
            )
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }

        context.closePDF()
        return output as Data
    }

    private static func createPDF(
        webView: WKWebView,
        configuration: WKPDFConfiguration
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: configuration) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
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
        // 等待图片解码完成，避免导出的页面缺少插图。
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
        // 给字体与样式一点排版时间，避免测量到未稳定的高度。
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
