import AppKit
import MarkdownKit
import SwiftUI

@main
struct iMarkDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = Self.makeAppState()

    private static var windowTitle: String {
        #if IMARKDOWN_UI_CHECK
        return "iMarkDown UI 验收"
        #else
        return "iMarkDown"
        #endif
    }

    @MainActor
    private static func makeAppState() -> AppState {
        #if IMARKDOWN_UI_CHECK
        // 验收窗口与真实文档、设置、最近记录及草稿完全隔离。
        let defaults = UserDefaults(suiteName: "iMarkDownUICheck-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.autoSaveEnabled = false
        let state = AppState(settings: settings, recents: RecentFilesStore(defaults: defaults),
                             workspace: WorkspaceStore(defaults: defaults), defaults: defaults,
                             draftStore: DraftStore(fileURL: Bundle.main.bundleURL.deletingLastPathComponent()
                                .appendingPathComponent("ui-check-draft.md")))
        let sample = "# 玻璃与背景模糊验收\n\n本窗口只使用独立的测试内容，不加载真实文档。\n\n" + (1...30).map { index in
            """
            ## 第 \(index) 节 · 原生窗口验收

            🔴 🟢 🔵 🟣 🟠 **滚动到顶部后，文字与颜色应透过背景模糊。**

            | 项目 | 内容 | 状态 |
            | --- | --- | --- |
            | 第 \(index) 项 | Background blur test · 中英文正文 | [查看](https://example.com) |
            | 系统按钮 | 源码 / 分栏 / 预览 | Native Liquid Glass |


            """
        }.joined()
        state.session = DocumentSession(text: sample, savedText: sample)
        state.stats = .from(text: sample)
        state.mode = .preview
        return state
        #else
        return AppState()
        #endif
    }

    var body: some Scene {
        Window(Self.windowTitle, id: "main") {
            RootView()
                .environmentObject(state)
                .environmentObject(state.settings)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1240, height: 820)
        .commands {
            AppCommands(state: state)
        }

        Settings {
            SettingsView()
                .environmentObject(state.settings)
        }
    }
}

/// 主窗口关闭也走异步退出确认，保留窗口与 WebView，直到最新文本已核验。
private final class MainWindowCloseGuard: NSObject, NSWindowDelegate {
    private let original: NSWindowDelegate?

    init(original: NSWindowDelegate?) {
        self.original = original
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI 会用内部代理对象包装 delegate，`NSApp.delegate as? AppDelegate` 并不可靠，
    /// 因此通过静态引用把实例暴露给 RootView。
    static weak var shared: AppDelegate?

    /// 由 RootView 在出现时注入，用于退出前检查未保存修改。
    weak var appState: AppState?
    private var closeGuard: MainWindowCloseGuard?
    private var isConfirmingTermination = false
    private var isTerminationApproved = false

    func protectClose(of window: NSWindow) {
        guard closeGuard == nil else { return }
        let proxy = MainWindowCloseGuard(original: window.delegate)
        closeGuard = proxy
        window.delegate = proxy
    }

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// ⌘Q 或关闭最后一个窗口时的兜底确认，避免静默丢失未保存内容。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminationApproved, let state = appState else { return .terminateNow }
        guard !isConfirmingTermination else { return .terminateCancel }
        isConfirmingTermination = true
        // 先取消这次系统退出，保持正常事件循环，供 WebKit 快照和异步 sheet 回调完成。
        // 确认通过后再退出，不在 terminateLater 的等待循环中持有文档操作锁。
        Task { @MainActor in
            let confirmed = await state.confirmTermination()
            isConfirmingTermination = false
            if confirmed {
                isTerminationApproved = true
                sender.terminate(nil)
            }
        }
        return .terminateCancel
    }
}
