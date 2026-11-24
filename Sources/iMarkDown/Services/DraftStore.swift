import Foundation

/// 未命名文档的崩溃兜底草稿。已保存的文档走自动保存，这里只负责无路径的草稿。
struct DraftStore: Sendable {
    let fileURL: URL?

    init(fileManager: FileManager = .default) {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fileURL = nil
            return
        }
        let directory = base.appendingPathComponent("iMarkDown", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("untitled-draft.md")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func read() -> String? {
        guard let fileURL,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        return text
    }

    func write(_ text: String) throws {
        guard let fileURL else { return }
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
