import Foundation
import MarkdownKit
import WebKit

enum EditorEvent {
    case ready
    case unready
    case edited(epoch: Int)
    case outline([OutlineItem], epoch: Int)
    case reading(Bool, epoch: Int)
    case change(text: String, stats: DocumentStats, epoch: Int)
    case stats(DocumentStats, epoch: Int)
    case chrome(overlapped: Bool, compactTitleVisible: Bool, activeHeadingIndex: Int, epoch: Int)
    case link(href: String)
    case saveRequested
    case imagePasted(data: Data, mime: String, filename: String, epoch: Int)
    case log(String)
}

/// Web → 原生单向事件通道。只接受白名单消息类型，不执行任意脚本。
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onEvent: ((EditorEvent) -> Void)?
    /// Web 内容进程被系统回收 / 崩溃时触发，由外壳负责重载并回填文档。
    var onWebProcessTerminated: (() -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "editor",
              message.frameInfo.isMainFrame,
              message.frameInfo.request.url == EditorResourceHandler.editorURL,
              let payload = message.body as? [String: Any],
              let type = payload["type"] as? String else {
            return
        }

        switch type {
        case "ready":
            onEvent?(.ready)
        case "edited":
            onEvent?(.edited(epoch: Self.intValue(payload["epoch"])))
        case "outline":
            guard let rows = payload["headings"] as? [[String: Any]] else { return }
            let items = rows.enumerated().compactMap { index, row -> OutlineItem? in
                guard let title = row["title"] as? String else { return nil }
                let level = Self.intValue(row["level"])
                guard (1...6).contains(level) else { return nil }
                return OutlineItem(index: index, level: level, title: title, line: -1)
            }
            onEvent?(.outline(items, epoch: Self.intValue(payload["epoch"])))
        case "reading":
            onEvent?(.reading(payload["active"] as? Bool ?? false, epoch: Self.intValue(payload["epoch"])))
        case "change":
            let text = payload["text"] as? String ?? ""
            onEvent?(.change(
                text: text,
                stats: Self.decodeStats(payload["stats"]),
                epoch: Self.intValue(payload["epoch"])
            ))
        case "stats":
            // app.js 把统计字段直接铺在消息根部，而不是放在 stats 子对象里。
            onEvent?(.stats(Self.decodeStats(payload), epoch: Self.intValue(payload["epoch"])))
        case "chrome":
            // 正文是否进入顶部覆盖区、文档大标题是否已移出。
            onEvent?(.chrome(
                overlapped: payload["overlapped"] as? Bool ?? false,
                compactTitleVisible: payload["compactTitle"] as? Bool ?? false,
                activeHeadingIndex: payload["activeHeading"] as? Int ?? -1,
                epoch: Self.intValue(payload["epoch"])
            ))
        case "link":
            if let href = payload["href"] as? String {
                onEvent?(.link(href: href))
            }
        case "save":
            onEvent?(.saveRequested)
        case "image":
            // 图片以 base64 传输，原生侧解码后落盘到文档同级 assets 目录。
            guard let base64 = payload["data"] as? String,
                  base64.utf8.count <= 12 * 1024 * 1024,
                  let data = Data(base64Encoded: base64) else {
                break
            }
            onEvent?(.imagePasted(
                data: data,
                mime: payload["mime"] as? String ?? "",
                filename: payload["name"] as? String ?? "",
                epoch: Self.intValue(payload["epoch"])
            ))
        case "log":
            if let text = payload["text"] as? String {
                onEvent?(.log(text))
            }
        default:
            break
        }
    }

    /// 内容进程被系统回收（内存压力）或崩溃：通知外壳重建编辑器，避免永久白屏。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onEvent?(.unready)
        onWebProcessTerminated?()
    }

    /// 拦截 Web 内点击链接，交给原生用系统浏览器 / 文件关联打开。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            onEvent?(.link(href: url.absoluteString))
            decisionHandler(.cancel)
            return
        }
        let isEditor = navigationAction.request.url == EditorResourceHandler.editorURL
        let isMain = navigationAction.targetFrame?.isMainFrame == true
        let isLoad = navigationAction.navigationType == .other || navigationAction.navigationType == .reload
        decisionHandler(isEditor && isMain && isLoad ? .allow : .cancel)
    }

    private static func decodeStats(_ value: Any?) -> DocumentStats {
        guard let dict = value as? [String: Any] else { return .zero }
        return DocumentStats(
            characters: intValue(dict["characters"]),
            words: intValue(dict["words"]),
            lines: intValue(dict["lines"])
        )
    }

    /// JS 数字经 WKWebView 桥接后通常是 NSNumber / Double，不能直接用 `as? Int`。
    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return 0
    }
}
