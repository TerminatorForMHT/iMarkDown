import Foundation
import MarkdownKit
import WebKit

/// 推送到 Web 编辑器的配置快照。Web 侧只接收自己需要的字段，避免双向状态耦合。
struct EditorConfig: Encodable {
    var appearance: String
    var previewTheme: String
    var editorFontSize: Double
    var previewFontSize: Double
    var baseDirectory: String

    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

enum EditorError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady: return "编辑器尚未就绪。"
        }
    }
}

enum JS {
    /// 把 Swift 字符串安全地转成 JS 字符串字面量。
    static func encode(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }
}

/// 原生侧唯一持有 WKWebView 的入口。所有对 Web 的调用都经过这里，
/// 未就绪时先入队，避免文档加载与配置推送的时序竞争。
@MainActor
final class EditorController: ObservableObject {
    private weak var webView: WKWebView?
    private var isReady = false
    private var pendingScripts: [String] = []

    private(set) var isAttached = false

    func attach(_ webView: WKWebView) {
        self.webView = webView
        isAttached = true
    }

    func markReady() {
        isReady = true
        let scripts = pendingScripts
        pendingScripts.removeAll()
        scripts.forEach(execute)
    }

    func markUnready() {
        isReady = false
    }

    func setDocument(text: String, baseDirectory: String?) {
        run("window.MD.setDocument(\(JS.encode(text)), \(JS.encode(baseDirectory ?? "")))")
    }

    func setMode(_ mode: EditorMode) {
        run("window.MD.setMode(\(JS.encode(mode.rawValue)))")
    }

    func apply(_ config: EditorConfig) {
        run("window.MD.applyConfig(\(config.jsonString))")
    }

    func wrap(_ before: String, _ after: String) {
        run("window.MD.wrap(\(JS.encode(before)), \(JS.encode(after)))")
    }

    func insert(_ text: String) {
        run("window.MD.insert(\(JS.encode(text)))")
    }

    func focus() {
        run("window.MD.focus()")
    }

    func currentText() async throws -> String {
        try await evaluateString("window.MD.getText()")
    }

    func articleHTML() async throws -> String {
        try await evaluateString("window.MD.getArticleHTML()")
    }

    private func run(_ script: String) {
        guard isReady, webView != nil else {
            pendingScripts.append(script)
            return
        }
        execute(script)
    }

    private func execute(_ script: String) {
        guard let webView else { return }
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                print("[iMarkDown] JS error: \(error.localizedDescription)")
            }
        }
    }

    private func evaluateString(_ script: String) async throws -> String {
        guard isReady, let webView else { throw EditorError.notReady }
        let value = try await webView.evaluateJavaScript(script)
        return value as? String ?? ""
    }
}
