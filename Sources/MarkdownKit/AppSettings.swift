import AppKit
import Combine
import Foundation

public enum AppearancePreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Web 侧只需要两种确定的外观状态。
    public func resolved(isDarkSystem: Bool) -> String {
        switch self {
        case .system: return isDarkSystem ? "dark" : "light"
        case .light: return "light"
        case .dark: return "dark"
        }
    }
}

public enum PreviewTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case github
    case serif
    case compact

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .github: return "GitHub"
        case .serif: return "阅读（衬线）"
        case .compact: return "紧凑"
        }
    }

    public var detail: String {
        switch self {
        case .github: return "等宽代码与标准 Markdown 排版，适合技术文档"
        case .serif: return "New York 衬线正文与更宽行距，适合长文阅读"
        case .compact: return "更小的字号与更紧的行距，单屏信息量更大"
        }
    }
}

/// 应用级偏好设置，持久化到 UserDefaults，供原生与 Web 两侧共享。
@MainActor
public final class AppSettings: ObservableObject {
    @Published public var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    @Published public var previewTheme: PreviewTheme {
        didSet { defaults.set(previewTheme.rawValue, forKey: Keys.previewTheme) }
    }
    @Published public var editorFontSize: Double {
        didSet { defaults.set(editorFontSize, forKey: Keys.editorFontSize) }
    }
    @Published public var previewFontSize: Double {
        didSet { defaults.set(previewFontSize, forKey: Keys.previewFontSize) }
    }
    @Published public var autoSaveEnabled: Bool {
        didSet { defaults.set(autoSaveEnabled, forKey: Keys.autoSave) }
    }
    @Published public var showsStatusHUD: Bool {
        didSet { defaults.set(showsStatusHUD, forKey: Keys.statusHUD) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let appearance = "settings.appearance"
        static let previewTheme = "settings.previewTheme"
        static let editorFontSize = "settings.editorFontSize"
        static let previewFontSize = "settings.previewFontSize"
        static let autoSave = "settings.autoSave"
        static let statusHUD = "settings.statusHUD"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.appearance: AppearancePreference.system.rawValue,
            Keys.previewTheme: PreviewTheme.github.rawValue,
            Keys.editorFontSize: 14.0,
            Keys.previewFontSize: 15.5,
            Keys.autoSave: true,
            Keys.statusHUD: true
        ])
        appearance = AppearancePreference(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        previewTheme = PreviewTheme(rawValue: defaults.string(forKey: Keys.previewTheme) ?? "") ?? .github
        editorFontSize = defaults.double(forKey: Keys.editorFontSize)
        previewFontSize = defaults.double(forKey: Keys.previewFontSize)
        autoSaveEnabled = defaults.bool(forKey: Keys.autoSave)
        showsStatusHUD = defaults.bool(forKey: Keys.statusHUD)
    }

    public func increaseFontSize() {
        editorFontSize = min(24, editorFontSize + 1)
        previewFontSize = min(26, previewFontSize + 1)
    }

    public func decreaseFontSize() {
        editorFontSize = max(11, editorFontSize - 1)
        previewFontSize = max(12, previewFontSize - 1)
    }

    public func resetFontSizes() {
        editorFontSize = 14
        previewFontSize = 15.5
    }
}
