import Foundation

/// 当前编辑会话。文本真源始终在 Web 编辑器内，这里保存的是可观察镜像，
/// 用于标题、脏状态、自动保存以及原生侧的状态展示。
public struct DocumentSession: Equatable {
    public var url: URL?
    public var text: String
    public var savedText: String
    public var loadedAt: Date?

    public init(url: URL? = nil, text: String = "", savedText: String = "") {
        self.url = url
        self.text = text
        self.savedText = savedText
        self.loadedAt = nil
    }

    public static func untitled() -> DocumentSession {
        DocumentSession(url: nil, text: "", savedText: "")
    }

    public var isDirty: Bool { text != savedText }

    /// 不含扩展名的标题，用于窗口标题与侧边栏。
    public var displayName: String {
        guard let url else { return "未命名" }
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? url.lastPathComponent : name
    }

    public var fileName: String {
        url?.lastPathComponent ?? "未命名.md"
    }

    /// 供 Web 预览解析相对图片路径的目录 URL（以 / 结尾）。
    public var baseDirectoryURL: String? {
        guard let url else { return nil }
        return url.deletingLastPathComponent().absoluteString
    }
}
