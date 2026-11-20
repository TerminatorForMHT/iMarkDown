import AppKit
import MarkdownKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
            FileTreeSection(workspace: state.workspace)

            recentSection

            Section("外观") {
                Picker("外观", selection: $settings.appearance) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.vertical, 4)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { brand }
        .safeAreaInset(edge: .bottom) {
            GlassActionPair(onNew: state.newDocument, onOpen: state.openDocument)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .navigationTitle("iMarkDown")
    }

    private var recentSection: some View {
        Section {
            if state.recents.items.isEmpty {
                emptyHint
            } else {
                ForEach(state.recents.items) { entry in
                    Button {
                        state.requestOpen(url: entry.url)
                    } label: {
                        RecentRow(entry: entry, isCurrent: state.session.url?.path == entry.path)
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.exists)
                    .contextMenu {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                        Divider()
                        Button("从最近列表中移除") {
                            state.recents.remove(entry)
                        }
                    }
                }
            }
        } header: {
            Text("最近打开")
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x64D2FF), Color(hex: 0x0A7CFF)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("iMarkDown")
                    .font(.system(size: 13, weight: .semibold))
                Text("Liquid Glass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("还没有最近文件")
                .font(.system(size: 12, weight: .medium))
            Text("打开一个 .md 文件后，它会出现在这里。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

private struct RecentRow: View {
    let entry: RecentDocument
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 14))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(abbreviatedPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if isCurrent {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .opacity(entry.exists ? 1 : 0.45)
    }

    private var abbreviatedPath: String {
        entry.path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .replacingOccurrences(of: "/" + entry.name, with: "")
    }
}

// MARK: - 文件树

private struct FileTreeSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: WorkspaceStore

    var body: some View {
        Section {
            if let root = workspace.rootURL {
                tree(root: root)
            } else {
                Button {
                    state.openFolder()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "folder.badge.plus")
                        Text("打开文件夹")
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            header
        }
    }

    @ViewBuilder
    private func tree(root: URL) -> some View {
        let children = workspace.children(of: root)
        if workspace.hasLoaded(root) && children.isEmpty {
            Text("没有 Markdown 文件")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
        } else {
            ForEach(children) { node in
                FileTreeRow(workspace: workspace, node: node)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(workspace.rootURL?.lastPathComponent ?? "文件")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)

            if workspace.rootURL != nil {
                headerButton("arrow.clockwise", help: "刷新文件树") {
                    workspace.reload()
                }
                headerButton("xmark", help: "关闭文件夹") {
                    workspace.closeFolder()
                }
            }
            headerButton("folder.badge.plus", help: "打开文件夹") {
                state.openFolder()
            }
        }
    }

    private func headerButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct FileTreeRow: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: WorkspaceStore
    let node: FileNode

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expansion) {
                let children = workspace.children(of: node.url)
                if workspace.hasLoaded(node.url) && children.isEmpty {
                    Text("空")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(children) { child in
                        FileTreeRow(workspace: workspace, node: child)
                    }
                }
            } label: {
                Label {
                    Text(node.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: workspace.isExpanded(node.url) ? "folder.fill" : "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor.opacity(0.9))
                }
            }
        } else {
            Button {
                state.requestOpen(url: node.url)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12))
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    Text(node.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    if isCurrent {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("打开") { state.requestOpen(url: node.url) }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
            }
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { workspace.isExpanded(node.url) },
            set: { workspace.setExpanded($0, for: node.url) }
        )
    }

    private var isCurrent: Bool {
        state.session.url?.standardizedFileURL == node.url.standardizedFileURL
    }
}

struct GlassActionPair: View {
    let onNew: () -> Void
    let onOpen: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    newButton.buttonStyle(.glassProminent)
                    openButton.buttonStyle(.glass)
                }
            }
        } else {
            HStack(spacing: 8) {
                newButton.buttonStyle(.borderedProminent)
                openButton.buttonStyle(.bordered)
            }
        }
    }

    private var newButton: some View {
        Button(action: onNew) {
            Label("新建", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    private var openButton: some View {
        Button(action: onOpen) {
            Label("打开文件", systemImage: "doc.text")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }
}
