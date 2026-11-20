import Combine
import Foundation

public struct RecentDocument: Codable, Identifiable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var openedAt: Date

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    public init(path: String, name: String, openedAt: Date = .now) {
        self.path = path
        self.name = name
        self.openedAt = openedAt
    }
}

/// 最近打开列表，独立于系统 NSDocumentController，便于产品自定义排序与清理。
@MainActor
public final class RecentFilesStore: ObservableObject {
    @Published public private(set) var items: [RecentDocument] = []

    private let defaults: UserDefaults
    private let limit: Int
    private let key = "recents.documents.v1"

    public init(defaults: UserDefaults = .standard, limit: Int = 12) {
        self.defaults = defaults
        self.limit = limit
        load()
    }

    public func record(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL else { return }
        let entry = RecentDocument(
            path: standardized.path,
            name: standardized.lastPathComponent,
            openedAt: .now
        )
        items.removeAll { $0.path == entry.path }
        items.insert(entry, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        persist()
    }

    public func remove(_ entry: RecentDocument) {
        items.removeAll { $0.path == entry.path }
        persist()
    }

    public func clearMissing() {
        items.removeAll { !$0.exists }
        persist()
    }

    public func clearAll() {
        items.removeAll()
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentDocument].self, from: data) else {
            return
        }
        items = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}
