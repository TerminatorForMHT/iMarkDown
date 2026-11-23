import Combine
import Dispatch
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

/// 最近打开过的文件夹，用于文件树收起后的历史入口。
public struct RecentFolder: Identifiable, Hashable, Sendable {
    public let url: URL

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public var path: String { url.path }
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }
}

/// 工作区文件树：一次打开一个文件夹，目录内容按展开动作懒加载。
/// 只展示目录与 Markdown / 纯文本文件，隐藏文件与常见构建目录会被忽略。
@MainActor
public final class WorkspaceStore: ObservableObject {
    @Published public private(set) var rootURL: URL?
    @Published private var childrenByDirectory: [URL: [FileNode]] = [:]
    @Published private(set) var expanded: Set<URL> = []
    /// 打开过的文件夹历史（最近在前），收起文件树后仍可从这里恢复。
    @Published public private(set) var recentFolders: [RecentFolder] = []

    private let defaults: UserDefaults
    private let rootKey = "workspace.root.v1"
    private let recentKey = "workspace.recentFolders.v1"
    private let maxRecentFolders = 8
    /// 每个已加载目录一条文件描述符监听，外部增删文件后自动刷新。
    private var watchers: [URL: DispatchSourceFileSystemObject] = [:]

    private static let ignoredDirectories: Set<String> = [
        ".git", ".build", "node_modules", "Pods", "DerivedData", ".venv",
        "__pycache__", "dist", ".next", "target", ".idea", ".vscode"
    ]

    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt"
    ]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentFolders = Self.decodeRecentFolders(
            defaults.stringArray(forKey: recentKey) ?? [],
            limit: maxRecentFolders
        )

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
        if let rootURL, rootURL != standardized {
            recordRecentFolder(rootURL)
        }
        recordRecentFolder(standardized)

        stopWatching()
        rootURL = standardized
        childrenByDirectory.removeAll()
        expanded = [standardized]
        defaults.set(standardized.path, forKey: rootKey)
        loadChildren(of: standardized)
    }

    public func closeFolder() {
        // 收起文件树不等于忘记它：保留到最近文件夹历史中。
        if let rootURL {
            recordRecentFolder(rootURL)
        }
        stopWatching()
        rootURL = nil
        childrenByDirectory.removeAll()
        expanded.removeAll()
        defaults.removeObject(forKey: rootKey)
    }

    // MARK: - 文件夹历史

    public func removeRecentFolder(_ folder: RecentFolder) {
        persist(recentFolders.filter { $0.path != folder.path })
    }

    public func clearRecentFolders() {
        persist([])
    }

    public func pruneMissingRecentFolders() {
        persist(recentFolders.filter(\.exists))
    }

    private func recordRecentFolder(_ url: URL) {
        let standardized = url.standardizedFileURL
        var paths = recentFolders.map(\.path).filter { $0 != standardized.path }
        paths.insert(standardized.path, at: 0)
        if paths.count > maxRecentFolders {
            paths.removeLast(paths.count - maxRecentFolders)
        }
        persist(Self.decodeRecentFolders(paths, limit: maxRecentFolders))
    }

    private func persist(_ folders: [RecentFolder]) {
        recentFolders = folders
        defaults.set(folders.map(\.path), forKey: recentKey)
    }

    private nonisolated static func decodeRecentFolders(_ paths: [String], limit: Int) -> [RecentFolder] {
        var seen = Set<String>()
        var folders: [RecentFolder] = []
        for path in paths where seen.insert(path).inserted {
            folders.append(RecentFolder(url: URL(fileURLWithPath: path)))
            if folders.count >= limit { break }
        }
        return folders
    }

    public func reload() {
        guard let rootURL else { return }
        let directories = Set(expanded).union([rootURL])
        for directory in directories {
            refreshChildren(of: directory)
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

    /// 在整个工作区内按文件名搜索（不区分大小写），最多返回 `limit` 个结果。
    /// 目录树是懒加载的，搜索单独走一次后台遍历，避免为了搜索把整棵树读进内存。
    public func search(_ rawQuery: String, limit: Int = 200) async -> [FileNode] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let rootURL else { return [] }

        let ignored = Self.ignoredDirectories
        let allowed = Self.markdownExtensions
        return await Task.detached(priority: .userInitiated) {
            Self.searchFiles(
                in: rootURL,
                query: query,
                ignored: ignored,
                extensions: allowed,
                limit: limit
            )
        }.value
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

        watch(key)
        let ignored = Self.ignoredDirectories
        let allowed = Self.markdownExtensions
        Task.detached(priority: .userInitiated) {
            let nodes = Self.scan(directory: key, ignored: ignored, extensions: allowed)
            await MainActor.run { [weak self] in
                self?.childrenByDirectory[key] = nodes
            }
        }
    }

    /// 强制重新扫描单个目录（监听触发或手动刷新），期间保留旧列表避免闪烁。
    private func refreshChildren(of directory: URL) {
        let key = directory.standardizedFileURL
        watch(key)
        let ignored = Self.ignoredDirectories
        let allowed = Self.markdownExtensions
        Task.detached(priority: .userInitiated) {
            let nodes = Self.scan(directory: key, ignored: ignored, extensions: allowed)
            await MainActor.run { [weak self] in
                self?.childrenByDirectory[key] = nodes
            }
        }
    }

    // MARK: - 文件操作

    public enum WorkspaceError: LocalizedError {
        case invalidName
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidName: return "名称不能为空，也不能包含斜杠。"
            case .failed(let message): return message
            }
        }
    }

    /// 重命名文件或文件夹，返回新路径。
    @discardableResult
    public func rename(_ node: FileNode, to rawName: String) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { throw WorkspaceError.invalidName }
        let target = node.url
            .deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: node.isDirectory)
        guard target != node.url else { return node.url }

        do {
            try FileManager.default.moveItem(at: node.url, to: target)
        } catch {
            throw WorkspaceError.failed(error.localizedDescription)
        }
        refreshChildren(of: node.url.deletingLastPathComponent())
        return target
    }

    /// 在指定目录创建一个带标题的 Markdown 文件，并自动展开该目录。
    @discardableResult
    public func createMarkdownFile(in directory: URL, named rawName: String) throws -> URL {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { throw WorkspaceError.invalidName }
        if URL(fileURLWithPath: name).pathExtension.isEmpty {
            name += ".md"
        }
        let target = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw WorkspaceError.failed("同名文件已存在。")
        }

        let title = target.deletingPathExtension().lastPathComponent
        guard FileManager.default.createFile(
            atPath: target.path,
            contents: Data("# \(title)\n\n".utf8)
        ) else {
            throw WorkspaceError.failed("无法创建文件。")
        }

        expanded.insert(directory.standardizedFileURL)
        refreshChildren(of: directory)
        return target
    }

    /// 移到废纸篓，可撤销。
    public func trash(_ node: FileNode) throws {
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        } catch {
            throw WorkspaceError.failed(error.localizedDescription)
        }
        refreshChildren(of: node.url.deletingLastPathComponent())
    }

    // MARK: - 目录监听

    private func watch(_ directory: URL) {
        let key = directory.standardizedFileURL
        guard watchers[key] == nil else { return }

        let fd = open(key.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                // 编辑器批量写文件时会连续触发，合并一次刷新即可。
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.refreshChildren(of: key)
            }
        }
        source.setCancelHandler { close(fd) }
        watchers[key] = source
        source.resume()
    }

    private func stopWatching() {
        for source in watchers.values {
            source.cancel()
        }
        watchers.removeAll()
    }

    private nonisolated static func searchFiles(
        in root: URL,
        query: String,
        ignored: Set<String>,
        extensions: Set<String>,
        limit: Int
    ) -> [FileNode] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var matches: [FileNode] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true {
                if ignored.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            guard url.lastPathComponent.localizedStandardContains(query) else { continue }

            matches.append(FileNode(url: url.standardizedFileURL, isDirectory: false))
            if matches.count >= limit { break }
        }

        return matches.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
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
