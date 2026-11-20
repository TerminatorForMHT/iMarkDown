import AppKit
import SwiftUI

@main
struct iMarkDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("iMarkDown", id: "main") {
            RootView()
                .environmentObject(state)
                .environmentObject(state.settings)
        }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI 会用内部代理对象包装 delegate，`NSApp.delegate as? AppDelegate` 并不可靠，
    /// 因此通过静态引用把实例暴露给 RootView。
    static weak var shared: AppDelegate?

    /// 由 RootView 在出现时注入，用于退出前检查未保存修改。
    weak var appState: AppState?

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
        guard let state = appState, state.session.isDirty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "“\(state.session.displayName)”有未保存的更改"
        alert.informativeText = "关闭前是否保存？选择「不保存」将丢失这些更改。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // 保存可能弹出另存为面板，必须异步完成后才能放行退出。
            Task { @MainActor in
                let saved = await state.saveNow()
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            // 明确选择不保存时顺带清掉崩溃兜底草稿，避免下次启动又提示恢复。
            state.discardDraft()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
