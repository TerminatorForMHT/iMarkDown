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
    var uiCornerRadii: [String: Double] = DesignTokens.CornerRadius.webConfig

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
    case timedOut
    case documentChanged
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notReady: return "编辑器尚未就绪。"
        case .timedOut: return "编辑器响应超时。"
        case .documentChanged: return "文档已切换，本次操作已取消。"
        case .invalidResponse: return "编辑器返回了无效数据，未执行保存。"
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
    let resources = EditorResourceHandler()
    private weak var webView: WKWebView?
    private var isReady = false
    private var pendingScripts: [String] = []

    private(set) var isAttached = false
    var hostingWindow: NSWindow? { webView?.window }
    /// 当前文档代数，与 Web 侧 `state.epoch` 一一对应。
    /// change 事件携带发送时的代数，原生只接受等于当前值的事件，
    /// 避免切换文档后旧文档的 debounce 事件把内容写进新文档。
    private(set) var documentEpoch = 0

    func attach(_ webView: WKWebView) {
        self.webView = webView
        isAttached = true
        flushIfPossible()
    }

    func markReady() {
        isReady = true
        flushIfPossible()
    }

    func markUnready() {
        isReady = false
        // 旧页面的待执行脚本不能带到新页面，否则会重复设置文档。
        pendingScripts.removeAll()
    }

    func setDocument(text: String, baseDirectory: String?) {
        documentEpoch += 1
        resources.documentDirectory = baseDirectory.flatMap(URL.init(string:))
        run("window.MD.setDocument(\(JS.encode(text)), \(JS.encode(baseDirectory ?? "")), \(documentEpoch))")
    }

    func setMode(_ mode: EditorMode) {
        run("window.MD.setMode(\(JS.encode(mode.rawValue)))")
    }

    func apply(_ config: EditorConfig) {
        resources.documentDirectory = URL(string: config.baseDirectory)
        run("window.MD.applyConfig(\(config.jsonString))")
    }

    func wrap(_ before: String, _ after: String) {
        run("window.MD.wrap(\(JS.encode(before)), \(JS.encode(after)))")
    }

    func insert(_ text: String) {
        run("window.MD.insert(\(JS.encode(text)))")
    }

    func insertImage(_ path: String) {
        run("window.MD.insertImage(\(JS.encode(path)))")
    }

    func focus() {
        run("window.MD.focus()")
    }

    func openFind() {
        run("window.MD.openFind()")
    }

    func findNext() {
        run("window.MD.findNext()")
    }

    func findPrevious() {
        run("window.MD.findPrevious()")
    }

    func scrollToHeading(_ index: Int) {
        run("window.MD.scrollToHeading(\(index))")
    }

    /// 撤销/重做交给 CodeMirror 自己的历史栈，避免落到 WebKit 的输入撤销上。
    func undo() {
        run("window.MD.undo()")
    }

    func redo() {
        run("window.MD.redo()")
    }

    func setReadOnly(_ readOnly: Bool) {
        run("window.MD.setReadOnly(\(readOnly))")
    }

    func currentText() async throws -> String {
        let epoch = documentEpoch
        let json = try await evaluateString("window.MD.getSnapshot()")
        struct Snapshot: Decodable { let text: String; let epoch: Int }
        guard let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            throw EditorError.invalidResponse
        }
        guard snapshot.epoch == epoch, documentEpoch == epoch else {
            throw EditorError.documentChanged
        }
        return snapshot.text
    }

    func articleHTML() async throws -> String {
        let epoch = documentEpoch
        let html = try await evaluateString("window.MD.getArticleHTML(\(epoch))", timeout: 15)
        guard documentEpoch == epoch else { throw EditorError.documentChanged }
        return html
    }

    private func run(_ script: String) {
        guard isReady, webView != nil else {
            pendingScripts.append(script)
            return
        }
        execute(script)
    }

    /// 就绪与挂载可能以任意顺序发生，两者都满足后才重放队列，
    /// 否则脚本会在 webView 还不存在时被静默丢弃。
    private func flushIfPossible() {
        guard isReady, webView != nil else { return }
        let scripts = pendingScripts
        pendingScripts.removeAll()
        scripts.forEach(execute)
    }

    private func execute(_ script: String) {
        guard let webView else { return }
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                print("[iMarkDown] JS error: \(error.localizedDescription)")
            }
        }
    }

    /// Web 进程卡死时 evaluateJavaScript 可能长期不回调，这里做一次超时兜底，
    /// 让保存/导出能降级到原生镜像文本而不是一直转圈。
    private func evaluateString(_ script: String, timeout: Double = 3) async throws -> String {
        guard isReady, let webView else { throw EditorError.notReady }
        let gate = ContinuationGate()
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do {
                    let value = try await webView.evaluateJavaScript(script)
                    if gate.claim() {
                        if let string = value as? String {
                            continuation.resume(returning: string)
                        } else {
                            continuation.resume(throwing: EditorError.invalidResponse)
                        }
                    }
                } catch {
                    if gate.claim() {
                        continuation.resume(throwing: error)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if gate.claim() {
                    continuation.resume(throwing: EditorError.timedOut)
                }
            }
        }
    }
}

/// 保证超时与正常回调只放行一次。
private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
