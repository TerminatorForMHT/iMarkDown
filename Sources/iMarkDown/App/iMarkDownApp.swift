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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
