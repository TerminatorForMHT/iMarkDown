import Combine
import Foundation

/// 文件树节点。仅描述路径与类型，不持有子节点，便于按需加载大型目录。
public struct FileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

/// 工作区文件树：一次打开一个文件夹，目录内容按展开动作懒加载。
/// 只展示目录与 Markdown / 纯文本文件，隐藏文件与常见构建目录会被忽略。
@MainActor
public final class WorkspaceStore: ObservableObject {
    @Published public private(set) var rootURL: URL?
    @Published private var childrenByDirectory: [URL: [FileNode]] = [:]
    @Published private(set) var expanded: Set<URL> = []

    private let defaults: UserDefaults
    private let rootKey = "workspace.root.v1"

    private static let ignoredDirectories: Set<String> = [
        ".git", ".build", "node_modules", "Pods", "DerivedData", ".venv",
        "__pycache__", "dist", ".next", "target", ".idea", ".vscode"
    ]

    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt"
    ]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let path = defaults.string(forKey: rootKey) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            defaults.removeObject(forKey: rootKey)
            return
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        rootURL = url
        expanded = [url]
        loadChildren(of: url)
    }

    public func openFolder(_ url: URL) {
        let standardized = url.standardizedFileURL
        rootURL = standardized
        childrenByDirectory.removeAll()
        expanded = [standardized]
        defaults.set(standardized.path, forKey: rootKey)
        loadChildren(of: standardized)
    }

    public func closeFolder() {
        rootURL = nil
        childrenByDirectory.removeAll()
        expanded.removeAll()
        defaults.removeObject(forKey: rootKey)
    }

    public func reload() {
        guard let rootURL else { return }
        let expandedDirectories = expanded
        childrenByDirectory.removeAll()
        loadChildren(of: rootURL)
        for directory in expandedDirectories where directory != rootURL {
            loadChildren(of: directory)
        }
    }

    public func children(of directory: URL) -> [FileNode] {
        childrenByDirectory[directory.standardizedFileURL] ?? []
    }

    public func hasLoaded(_ directory: URL) -> Bool {
        childrenByDirectory[directory.standardizedFileURL] != nil
    }

    public func isExpanded(_ url: URL) -> Bool {
        expanded.contains(url.standardizedFileURL)
    }

    public func setExpanded(_ value: Bool, for url: URL) {
        let standardized = url.standardizedFileURL
        if value {
            expanded.insert(standardized)
            loadChildren(of: standardized)
        } else {
            expanded.remove(standardized)
        }
    }

    /// 展开目标文件的各级父目录，让当前文档在树中可见。
    public func reveal(_ fileURL: URL) {
        guard let rootURL else { return }
        let root = rootURL.standardizedFileURL
        let target = fileURL.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return }

        expanded.insert(root)
        loadChildren(of: root)

        var chain: [URL] = []
        var directory = target.deletingLastPathComponent()
        while directory.path != root.path, directory.path.hasPrefix(root.path + "/") {
            chain.append(directory)
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        for url in chain {
            expanded.insert(url)
            loadChildren(of: url)
        }
    }

    public func loadChildren(of directory: URL) {
        let key = directory.standardizedFileURL
        guard childrenByDirectory[key] == nil else { return }

        let ignored = Self.ignoredDirectories
        let allowed = Self.markdownExtensions
        Task.detached(priority: .userInitiated) {
            let nodes = Self.scan(directory: key, ignored: ignored, extensions: allowed)
            await MainActor.run { [weak self] in
                self?.childrenByDirectory[key] = nodes
            }
        }
    }

    private nonisolated static func scan(
        directory: URL,
        ignored: Set<String>,
        extensions: Set<String>
    ) -> [FileNode] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var nodes: [FileNode] = []
        for url in entries {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isHidden == true { continue }

            if values?.isDirectory == true {
                if ignored.contains(url.lastPathComponent) { continue }
                nodes.append(FileNode(url: url.standardizedFileURL, isDirectory: true))
            } else if extensions.contains(url.pathExtension.lowercased()) {
                nodes.append(FileNode(url: url.standardizedFileURL, isDirectory: false))
            }
        }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
