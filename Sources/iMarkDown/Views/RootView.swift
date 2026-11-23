import Foundation
import MarkdownKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView(columnVisibility: $state.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 252, max: 320)
        } detail: {
            EditorWorkspaceView()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            AppDelegate.shared?.appState = state
            state.applyAppearance()
            state.pushEditorConfig()
            state.offerDraftRecoveryIfNeeded()
            if let path = CommandLine.arguments.dropFirst().first,
               FileManager.default.fileExists(atPath: path) {
                state.requestOpen(url: URL(fileURLWithPath: path))
            } else {
                // 命令行指定了文件时以它为准，否则回到上次编辑的文档。
                state.restoreLastSessionIfNeeded()
            }
        }
        .onChange(of: state.mode) { _, newMode in
            state.editor.setMode(newMode)
        }
        .onChange(of: colorScheme) { _, _ in
            state.pushEditorConfig()
        }
        .alert(item: $state.activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }
}
