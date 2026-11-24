import AppKit
import MarkdownKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @State private var collapsedHeadings: Set<Int> = []

    var body: some View {
        List {
            outlineSection

            FileTreeSection(workspace: state.workspace)

            FolderHistorySection(workspace: state.workspace)

            recentSection
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top) { brand }
        .safeAreaInset(edge: .bottom) {
            GlassActionPair(onNew: { _ = state.newDocument() }, onOpen: { _ = state.openDocument() })
                .disabled(state.isDocumentOperationInProgress)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background { SidebarGlassBackground().ignoresSafeArea() }
        .navigationTitle("iMarkDown")
        .onChange(of: state.outline) { old, new in
            if old != new { collapsedHeadings.removeAll() }
        }
    }

    private var outlineSection: some View {
        Section {
            if state.outline.isEmpty {
                Text("当前文档暂无标题")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(OutlineItem.visibleItems(state.outline, collapsed: collapsedHeadings)) { item in
                    let isActive = item.index == state.activeHeadingIndex
                    let hasChildren = state.outline.indices.contains(item.index + 1) &&
                        state.outline[item.index + 1].level > item.level
                    HStack(spacing: 2) {
                        if hasChildren {
                            Button {
                                if !collapsedHeadings.insert(item.index).inserted {
                                    collapsedHeadings.remove(item.index)
                                }
                            } label: {
                                Image(systemName: collapsedHeadings.contains(item.index) ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .frame(width: 14, height: 20)
                            }
                            .buttonStyle(.plain)
                            .help(collapsedHeadings.contains(item.index) ? "展开章节" : "折叠章节")
                            .accessibilityLabel("\(collapsedHeadings.contains(item.index) ? "展开" : "折叠")\(item.title)")
                        } else {
                            Color.clear.frame(width: 14, height: 20)
                        }
                        Button {
                            state.jumpToOutline(item)
                        } label: {
                            HStack(spacing: 0) {
                                Text(item.title)
                                    .font(.system(
                                        size: item.level <= 2 ? 12 : 11.5,
                                        weight: (isActive || item.level == 1) ? .semibold : .regular
                                    ))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(item.title)
                    }
                    .padding(.leading, CGFloat(max(0, item.level - 1)) * 10 + DesignTokens.rowHorizontalInset)
                    .padding(.trailing, DesignTokens.rowHorizontalInset)
                    .padding(.vertical, 4)
                    .glassRow(isSelected: isActive)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .listRowBackground(Color.clear)
                }
            }
        } header: {
            Text("大纲")
        }
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
                    .padding(.horizontal, DesignTokens.rowHorizontalInset)
                    .glassRow(isSelected: state.session.url?.path == entry.path)
                    .listRowBackground(Color.clear)
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
            HStack {
                Text("最近打开")
                Spacer(minLength: 4)

                Menu {
                    Button("清理失效记录") {
                        state.recents.clearMissing()
                    }
                    .disabled(!state.recents.items.contains { !$0.exists })

                    Button("清空最近打开") {
                        state.recents.clearAll()
                    }
                    .disabled(state.recents.items.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .glassIconControl()
                .frame(width: DesignTokens.sidebarIconSize, height: DesignTokens.sidebarIconSize)
                .help("管理最近文件")
                .accessibilityLabel("管理最近文件")
            }
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.icon, style: .continuous)
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
            Spacer(minLength: 8)

            // 外观、字号等偏好已统一收敛到「设置」，这里提供一个就近入口。
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .glassIconControl()
            .frame(width: DesignTokens.controlHeight, height: DesignTokens.controlHeight)
            .help("设置")
            .accessibilityLabel("设置")
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

    @State private var query = ""
    @State private var results: [FileNode] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            if let root = workspace.rootURL {
                searchField
                if trimmedQuery.isEmpty {
                    tree(root: root)
                } else {
                    searchResults(root: root)
                }
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
                    .padding(.horizontal, DesignTokens.rowHorizontalInset)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassRow()
                .listRowBackground(Color.clear)
            }
        } header: {
            header
        }
        // 切换文件夹后旧结果已失效，直接清空查询回到完整文件树。
        .onChange(of: workspace.rootURL) { _, _ in
            query = ""
            results = []
            isSearching = false
            searchTask?.cancel()
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            TextField("搜索文件", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($isSearchFocused)
                .accessibilityLabel("搜索工作区文件")
                .onChange(of: query) { _, _ in scheduleSearch() }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, DesignTokens.rowHorizontalInset)
        .padding(.vertical, 7)
        .glassChrome(.inset, in: DesignTokens.controlShape)
        .overlay {
            DesignTokens.controlShape
                .strokeBorder(Color.accentColor.opacity(isSearchFocused ? 0.65 : 0), lineWidth: 1.2)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSearchFocused)
        .padding(.vertical, 2)
        .listRowBackground(Color.clear)
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

    @ViewBuilder
    private func searchResults(root: URL) -> some View {
        if isSearching && results.isEmpty {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("搜索中…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        } else if results.isEmpty {
            Text("没有匹配的文件")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
        } else {
            ForEach(results) { node in
                FileTreeRow(
                    workspace: workspace,
                    node: node,
                    subtitle: relativeDirectory(of: node.url, root: root)
                )
            }
        }
    }

    /// 搜索结果平铺展示，用相对路径补回层级信息；根目录下的文件不显示。
    private func relativeDirectory(of url: URL, root: URL) -> String? {
        let directory = url.deletingLastPathComponent().standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard directory != rootPath else { return nil }
        guard directory.hasPrefix(rootPath + "/") else { return directory }
        return String(directory.dropFirst(rootPath.count + 1))
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = trimmedQuery
        guard !text.isEmpty else {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task {
            // 输入过程中合并请求，停止输入 200ms 后才真正遍历目录。
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let found = await workspace.search(text)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(workspace.rootURL?.lastPathComponent ?? "文件")
                .lineLimit(1)
                .truncationMode(.middle)
                .help(workspace.rootURL?.path ?? "文件")
            Spacer(minLength: 4)

            // 未打开文件夹时由列表内的空状态提供入口，避免两个「打开文件夹」重复出现。
            if workspace.rootURL != nil {
                headerButton("arrow.clockwise", help: "刷新文件树") {
                    workspace.reload()
                }
                headerButton("xmark", help: "关闭文件夹") {
                    workspace.closeFolder()
                }
                headerButton("folder.badge.plus", help: "切换文件夹") {
                    state.openFolder()
                }
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
                .frame(width: 12, height: 12)
        }
        .glassIconControl()
        .frame(width: DesignTokens.sidebarIconSize, height: DesignTokens.sidebarIconSize)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct FolderHistorySection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: WorkspaceStore

    var body: some View {
        if workspace.rootURL == nil, !workspace.recentFolders.isEmpty {
            Section {
                ForEach(workspace.recentFolders) { folder in
                    Button {
                        state.openFolder(at: folder.url)
                    } label: {
                        FolderHistoryRow(folder: folder)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, DesignTokens.rowHorizontalInset)
                    .glassRow()
                    .listRowBackground(Color.clear)
                    .disabled(!folder.exists)
                    .contextMenu {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                        }
                        Divider()
                        Button("从历史记录中移除") {
                            workspace.removeRecentFolder(folder)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("最近文件夹")
                    Spacer(minLength: 4)

                    Menu {
                        Button("清理失效记录") {
                            workspace.pruneMissingRecentFolders()
                        }
                        .disabled(!workspace.recentFolders.contains { !$0.exists })

                        Button("清空历史记录") {
                            workspace.clearRecentFolders()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 12)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .glassIconControl()
                    .frame(width: DesignTokens.sidebarIconSize, height: DesignTokens.sidebarIconSize)
                    .help("管理最近文件夹")
                    .accessibilityLabel("管理最近文件夹")
                }
            }
        }
    }
}

private struct FolderHistoryRow: View {
    let folder: RecentFolder

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(abbreviatedPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .opacity(folder.exists ? 1 : 0.45)
    }

    private var abbreviatedPath: String {
        folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

private struct FileTreeRow: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: WorkspaceStore
    let node: FileNode
    /// 搜索结果平铺展示时补充所在目录，文件树内为 nil。
    var subtitle: String? = nil

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
            .contextMenu {
                Button("新建 Markdown 文件…") { createFile() }
                Divider()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 2)
                    if isCurrent {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.horizontal, DesignTokens.rowHorizontalInset)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassRow(isSelected: isCurrent)
            .listRowBackground(Color.clear)
            .contextMenu {
                Button("打开") { state.requestOpen(url: node.url) }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
                Divider()
                Button("重命名…") { rename() }
                    .disabled(state.isDocumentOperationInProgress)
                Button("移到废纸篓…", role: .destructive) { moveToTrash() }
                    .disabled(state.isDocumentOperationInProgress)
            }
        }
    }

    // MARK: - 文件操作

    private func rename() {
        guard !state.isDocumentOperationInProgress else { return }
        guard let name = promptForName(
            title: "重命名",
            message: node.isDirectory ? "重命名文件夹不会移动其中的文件。" : "重命名当前文件。",
            defaultName: node.name
        ) else { return }

        do {
            let newURL = try workspace.rename(node, to: name)
            state.didRenameCurrentDocument(from: node.url, to: newURL)
        } catch {
            present(error)
        }
    }

    private func createFile() {
        guard let name = promptForName(
            title: "新建 Markdown 文件",
            message: "文件会创建在「\(node.name)」中。",
            defaultName: "未命名.md"
        ) else { return }

        do {
            let url = try workspace.createMarkdownFile(in: node.url, named: name)
            workspace.setExpanded(true, for: node.url)
            state.requestOpen(url: url)
        } catch {
            present(error)
        }
    }

    private func moveToTrash() {
        guard !state.isDocumentOperationInProgress else { return }
        let alert = NSAlert()
        alert.messageText = "移到废纸篓？"
        alert.informativeText = node.name
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try workspace.trash(node)
            if isCurrent {
                state.didRemoveCurrentDocument(node.url)
            }
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        state.activeAlert = AppAlert(title: "操作失败", message: error.localizedDescription)
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

@MainActor
private func promptForName(title: String, message: String, defaultName: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "确定")
    alert.addButton(withTitle: "取消")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = defaultName
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    field.selectText(nil)

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue
}

struct GlassActionPair: View {
    let onNew: () -> Void
    let onOpen: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 8) {
                newButton.buttonStyle(.glassProminent)
                openButton.buttonStyle(.glass(.clear))
            }
            .padding(6)
            .glassChrome(.regular, in: DesignTokens.controlShape, elevated: true)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var newButton: some View {
        Button(action: onNew) {
            Label("新建", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
    }

    private var openButton: some View {
        Button(action: onOpen) {
            Label("打开文件", systemImage: "doc.text")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
    }
}
