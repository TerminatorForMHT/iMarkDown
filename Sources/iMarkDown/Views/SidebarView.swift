import AppKit
import MarkdownKit
import SwiftUI

/// 同一文件可出现在多个区域，系统选择只标记用户实际操作的那一行。
struct SidebarFileSelection: Hashable {
    enum Location { case tree, recent }
    let location: Location
    let url: URL

    init(_ location: Location, _ url: URL) {
        self.location = location
        self.url = url.standardizedFileURL
    }
}

/// 只衔接系统选择与异步文档操作，不负责行的颜色、焦点或键盘反馈。
@MainActor
final class SidebarFileSelectionState: ObservableObject {
    @Published private(set) var value: SidebarFileSelection?
    private var pendingOpen: Task<Void, Never>?

    @discardableResult
    func select(_ item: SidebarFileSelection?, in state: AppState) -> Task<Void, Never>? {
        guard pendingOpen == nil, !state.isDocumentOperationInProgress else { return nil }
        guard let item else {
            // 收起分组只隐藏选中行，保留身份以便再次展开，不重新打开文档。
            if let current = value, current.url == state.session.url?.standardizedFileURL,
               (current.location == .tree ? !state.settings.sidebarFileTreeExpanded
                                         : !state.settings.sidebarRecentFilesExpanded) { return nil }
            value = nil
            return nil
        }
        guard item != value else { return nil }
        let previous = value
        value = item
        // 仅切换同一文件所在的行，不重新读盘或清空编辑器历史。
        guard state.session.url?.standardizedFileURL != item.url else { return nil }
        let task = Task { @MainActor in
            await state.requestOpen(url: item.url).value
            if state.session.url?.standardizedFileURL != item.url { value = previous }
            pendingOpen = nil
            synchronize(in: state)
        }
        pendingOpen = task
        return task
    }

    func synchronize(in state: AppState) {
        guard pendingOpen == nil else { return }
        guard let url = state.session.url?.standardizedFileURL else { value = nil; return }
        let inTree = state.workspace.rootURL.map {
            let path = $0.standardizedFileURL.path
            return url.path.hasPrefix(path.hasSuffix("/") ? path : path + "/")
        } ?? false
        let inRecents = state.recents.items.contains { $0.url.standardizedFileURL == url && $0.exists }
        if value?.url == url,
           (value?.location == .tree ? inTree : inRecents) { return }
        if value?.location == .tree && inTree { value = SidebarFileSelection(.tree, url) }
        else { value = inRecents ? SidebarFileSelection(.recent, url) : nil }
    }
}

@MainActor
struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var fileSelection: SidebarFileSelectionState
    @State private var collapsedHeadings: Set<Int> = []

    init(fileSelection: SidebarFileSelectionState? = nil) {
        _fileSelection = StateObject(wrappedValue: fileSelection ?? SidebarFileSelectionState())
    }

    var body: some View {
        List(selection: Binding(get: { fileSelection.value }, set: { _ = fileSelection.select($0, in: state) })) {
            outlineSection

            FileTreeSection(workspace: state.workspace)

            FolderHistorySection(workspace: state.workspace)

            recentSection
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            GlassActionPair(onNew: { _ = state.newDocument() }, onOpen: { _ = state.openDocument() })
                .disabled(state.isDocumentOperationInProgress)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background { SidebarGlassBackground().ignoresSafeArea() }
        .onAppear { fileSelection.synchronize(in: state) }
        .onChange(of: state.session.url) { _, _ in fileSelection.synchronize(in: state) }
        .onChange(of: state.recents.items) { _, _ in fileSelection.synchronize(in: state) }
        .onReceive(state.workspace.$rootURL) { _ in
            Task { @MainActor in fileSelection.synchronize(in: state) }
        }
        .onChange(of: state.outline) { old, new in
            if old != new { collapsedHeadings.removeAll() }
        }
    }

    private var outlineSection: some View {
        Section(isExpanded: $settings.sidebarOutlineExpanded) {
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
                    .outlineReadingPosition(isActive: isActive)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .listRowBackground(Color.clear)
                }
            }
        } header: {
            Text("大纲")
        }
        .selectionDisabled()
    }

    private var recentSection: some View {
        Section(isExpanded: $settings.sidebarRecentFilesExpanded) {
            if state.recents.items.isEmpty {
                emptyHint.selectionDisabled()
            } else {
                ForEach(state.recents.items) { entry in
                    RecentRow(entry: entry, isCurrent: state.session.url?.standardizedFileURL == entry.url.standardizedFileURL)
                    .tag(SidebarFileSelection(.recent, entry.url))
                    .selectionDisabled(!entry.exists || state.isDocumentOperationInProgress)
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
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(abbreviatedPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if isCurrent {
                Circle()
                    .fill(.primary)
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
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var workspace: WorkspaceStore

    @State private var query = ""
    @State private var results: [FileNode] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section(isExpanded: $settings.sidebarFileTreeExpanded) {
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
                .selectionDisabled()
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
        .selectionDisabled()
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
                .selectionDisabled()
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
            .selectionDisabled()
        } else if results.isEmpty {
            Text("没有匹配的文件")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
                .selectionDisabled()
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
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var workspace: WorkspaceStore

    var body: some View {
        if workspace.rootURL == nil, !workspace.recentFolders.isEmpty {
            Section(isExpanded: $settings.sidebarRecentFoldersExpanded) {
                ForEach(workspace.recentFolders) { folder in
                    Button {
                        state.openFolder(at: folder.url)
                    } label: {
                        FolderHistoryRow(folder: folder)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, DesignTokens.rowHorizontalInset)
                    .selectionDisabled()
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
            .selectionDisabled()
            .contextMenu {
                Button("新建 Markdown 文件…") { createFile() }
                Divider()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
            }
        } else {
            HStack(spacing: 7) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 2)
                if isCurrent {
                    Circle()
                        .fill(.primary)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .tag(SidebarFileSelection(.tree, node.url))
            .selectionDisabled(state.isDocumentOperationInProgress)
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

#if IMARKDOWN_UI_CHECK
/// 独立会话中的真实系统 List 回归，不读取用户文档或使用用户偏好。
@MainActor
enum SidebarSelectionChecks {
    static func run(outputDirectory: URL) async throws {
        let root = outputDirectory.appendingPathComponent("native-list-fixture", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("A.md"), b = root.appendingPathComponent("B.md")
        let child = nested.appendingPathComponent("Child.md"), missing = root.appendingPathComponent("Missing.md")
        for url in [a, b, child] { try FileService.write("# \(url.lastPathComponent)", to: url) }
        let defaults = UserDefaults(suiteName: "iMarkDownSidebarChecks-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.autoSaveEnabled = false
        let state = AppState(settings: settings, recents: RecentFilesStore(defaults: defaults),
                             workspace: WorkspaceStore(defaults: defaults), defaults: defaults,
                             draftStore: DraftStore(fileURL: root.appendingPathComponent("draft.md")))
        state.recents.record(missing)
        state.recents.record(b)
        await state.requestOpen(url: a).value
        await state.openFolder(at: root).value
        let selection = SidebarFileSelectionState()
        let host = NSHostingView(rootView: SidebarView(fileSelection: selection)
            .environmentObject(state).environmentObject(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 740),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "系统侧栏隔离验收"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let focusWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        focusWindow.title = "焦点验收"
        focusWindow.isReleasedWhenClosed = false
        defer { focusWindow.close(); window.close() }
        try await Task.sleep(nanoseconds: 400_000_000)
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        guard let table = findTable(host) else { throw HeaderBackdropChecks.failure("侧栏没有系统 List 表格") }
        let foldedRows = table.numberOfRows
        let initialEpoch = state.editor.documentEpoch
        try HeaderBackdropChecks.require(settings.sidebarOutlineExpanded && settings.sidebarFileTreeExpanded &&
            !settings.sidebarRecentFilesExpanded && !settings.sidebarRecentFoldersExpanded,
            "大纲和文件树默认展开，最近文件与最近文件夹默认收起")
        settings.sidebarRecentFilesExpanded = true
        try await Task.sleep(nanoseconds: 250_000_000)
        try HeaderBackdropChecks.require(table.numberOfRows == foldedRows + state.recents.items.count &&
            table.selectedRow >= 0 && selection.value == SidebarFileSelection(.recent, a),
            "展开历史后系统恢复当前文件选中行")
        let expandedRows = table.numberOfRows
        settings.sidebarRecentFilesExpanded = false
        try await Task.sleep(nanoseconds: 250_000_000)
        try HeaderBackdropChecks.require(table.numberOfRows == foldedRows && state.session.url == a &&
            state.editor.documentEpoch == initialEpoch && selection.value == SidebarFileSelection(.recent, a),
            "收起最近文件只隐藏行，不切换文档或丢失选择身份")
        settings.sidebarRecentFilesExpanded = true
        settings.sidebarOutlineExpanded = false
        try await Task.sleep(nanoseconds: 250_000_000)
        try HeaderBackdropChecks.require(table.numberOfRows == expandedRows - 1 && state.session.url == a,
            "大纲分组可独立收起，不影响文件与文档")
        settings.sidebarOutlineExpanded = true
        state.workspace.closeFolder()
        try await Task.sleep(nanoseconds: 250_000_000)
        let collapsedFolderRows = table.numberOfRows
        settings.sidebarRecentFoldersExpanded = true
        try await Task.sleep(nanoseconds: 250_000_000)
        try HeaderBackdropChecks.require(table.numberOfRows == collapsedFolderRows + state.workspace.recentFolders.count &&
            state.session.url == a && state.editor.documentEpoch == initialEpoch,
            "最近文件夹独立展开，不自动打开或切换工作区")
        settings.sidebarRecentFoldersExpanded = false
        state.workspace.openFolder(root)
        try await Task.sleep(nanoseconds: 250_000_000)
        try HeaderBackdropChecks.require(table.delegate != nil && table.selectedRow >= 0 &&
            table.selectedRowIndexes.count == 1 && selection.value == SidebarFileSelection(.recent, a),
            "系统 List 使用单行选择，并从当前文档恢复最近文件行")
        let recentARow = table.selectedRow
        let epoch = state.editor.documentEpoch
        state.session.text += "\n未保存内容"
        var prompts = 0
        state.alertResponseForChecks = { _ in prompts += 1; return .alertThirdButtonReturn }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table)
        try await Task.sleep(nanoseconds: 150_000_000)
        print("原生侧栏宿主：应用激活=\(NSApp.isActive)，窗口激活=\(window.isKeyWindow)，行数=\(table.numberOfRows)，选中行=\(table.selectedRow)，焦点=\(String(describing: window.firstResponder))")
        func pressDown() throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125) else {
                throw HeaderBackdropChecks.failure("侧栏键盘事件不可用")
            }
            NSApp.sendEvent(event)
        }
        try pressDown()
        try await Task.sleep(nanoseconds: 300_000_000)
        print("取消键盘切换：确认次数=\(prompts)，文件=\(String(describing: state.session.url))，选择=\(String(describing: selection.value))，表格行=\(table.selectedRow)")
        try HeaderBackdropChecks.require(prompts == 1 && state.session.url == a && state.session.isDirty &&
            selection.value == SidebarFileSelection(.recent, a) && table.selectedRow == recentARow,
            "原生向下键触发未保存确认，取消后文档与实际选中行均恢复")
        state.alertResponseForChecks = { _ in prompts += 1; return .alertSecondButtonReturn }
        try pressDown()
        try await Task.sleep(nanoseconds: 300_000_000)
        print("确认键盘切换：确认次数=\(prompts)，文件=\(String(describing: state.session.url))，选择=\(String(describing: selection.value))，表格行=\(table.selectedRow)")
        try HeaderBackdropChecks.require(prompts == 2 && state.session.url == b &&
            selection.value == SidebarFileSelection(.recent, b) && table.selectedRowIndexes.count == 1,
            "系统向下键可以打开下一文件，并在最近记录重排后保持正确选择")
        let recentBRow = table.selectedRow
        guard let outline = table as? NSOutlineView,
              let missingItem = outline.item(atRow: table.numberOfRows - 1) else {
            throw HeaderBackdropChecks.failure("未找到失效最近文件的系统行")
        }
        try HeaderBackdropChecks.require(outline.delegate?.outlineView?(outline, shouldSelectItem: missingItem) == false,
            "系统选择代理禁止选择失效的最近文件行")
        let sameFileEpoch = state.editor.documentEpoch
        selection.select(SidebarFileSelection(.tree, b), in: state)
        try await Task.sleep(nanoseconds: 150_000_000)
        try HeaderBackdropChecks.require(state.editor.documentEpoch == sameFileEpoch && table.selectedRow >= 0 &&
            table.selectedRow != recentBRow && table.selectedRowIndexes.count == 1,
            "同文件的文件树与最近行使用不同标识，只选中一处且不重置编辑历史")
        await selection.select(SidebarFileSelection(.recent, missing), in: state)?.value
        try await Task.sleep(nanoseconds: 150_000_000)
        try HeaderBackdropChecks.require(state.session.url == b && selection.value == SidebarFileSelection(.tree, b) &&
            state.activeAlert != nil && !state.isDocumentOperationInProgress, "打开失败恢复原选择并释放文档操作锁")
        state.activeAlert = nil
        state.session.text += "\n并发保护内容"
        state.alertResponseForChecks = { _ in
            try? await Task.sleep(nanoseconds: 120_000_000)
            return .alertThirdButtonReturn
        }
        let pending = selection.select(SidebarFileSelection(.recent, a), in: state)
        let refused = selection.select(SidebarFileSelection(.tree, child), in: state)
        await pending?.value
        try HeaderBackdropChecks.require(refused == nil && state.session.url == b &&
            selection.value == SidebarFileSelection(.tree, b), "确认进行中不接受第二次选择，取消后恢复原文件")
        state.alertResponseForChecks = { _ in .alertSecondButtonReturn }
        await state.requestOpen(url: child).value
        selection.select(SidebarFileSelection(.tree, child), in: state)
        try await Task.sleep(nanoseconds: 350_000_000)
        try HeaderBackdropChecks.require(table.selectedRow >= 0 && selection.value == SidebarFileSelection(.tree, child),
            "嵌套 DisclosureGroup 子文件也接入系统选择")
        window.makeFirstResponder(table)
        try pressDown()
        try await Task.sleep(nanoseconds: 300_000_000)
        try HeaderBackdropChecks.require(state.session.url == a && selection.value == SidebarFileSelection(.tree, a),
            "嵌套文件与根目录文件之间的原生键盘导航可用")
        let treeRows = table.numberOfRows
        let directories = [root, nested]
        let expandedDirectories = directories.map { state.workspace.isExpanded($0) }
        let treeEpoch = state.editor.documentEpoch
        settings.sidebarFileTreeExpanded = false
        try await Task.sleep(nanoseconds: 250_000_000)
        try HeaderBackdropChecks.require(table.numberOfRows < treeRows && state.workspace.rootURL == root &&
            directories.map { state.workspace.isExpanded($0) } == expandedDirectories && state.session.url == a &&
            state.editor.documentEpoch == treeEpoch && selection.value == SidebarFileSelection(.tree, a),
            "收起文件树保留工作区、目录展开状态与当前文档")
        settings.sidebarFileTreeExpanded = true
        try await Task.sleep(nanoseconds: 250_000_000)
        try HeaderBackdropChecks.require(table.numberOfRows == treeRows && table.selectedRow >= 0 &&
            selection.value == SidebarFileSelection(.tree, a) && state.editor.documentEpoch == treeEpoch,
            "重新展开文件树恢复原生选中行，不重置编辑历史")
        state.outline = OutlineParser.parse("# 构建与运行\n\n## 运行测试")
        state.activeHeadingIndex = 0
        print("SIDEBAR_SECTION_CHECK_PASSED：四组原生折叠、默认状态与文档保护通过")
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        for (name, appearanceName, scheme, increased) in [
            ("light", NSAppearance.Name.aqua, ColorScheme.light, false),
            ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark, false),
            ("light-contrast", NSAppearance.Name.accessibilityHighContrastAqua, ColorScheme.light, true),
            ("dark-contrast", NSAppearance.Name.accessibilityHighContrastDarkAqua, ColorScheme.dark, true)
        ] {
            NSApp.appearance = NSAppearance(named: appearanceName)
            window.appearance = NSApp.appearance
            for active in [true, false] {
                if active { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(table) }
                else { focusWindow.makeKeyAndOrderFront(nil) }
                try await Task.sleep(nanoseconds: 150_000_000)
                try HeaderBackdropChecks.require(table.selectedRowIndexes.count == 1 && window.isKeyWindow == active,
                    "\(name)：真实窗口激活／非激活时系统仍保留单行选择")
                var ratio = 0.0
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    ratio = contrast(.labelColor, OutlineReadingPositionStyle.background(
                        appearsActive: active, colorScheme: scheme, increasedContrast: increased))
                }
                try HeaderBackdropChecks.require(ratio >= 4.5, "\(name)：大纲阅读位置保持文字可读性")
                // 离屏缓存不能完整采样系统玻璃与合成图层，仅保留诊断图，不用于外观验收。
                window.displayIfNeeded()
                guard let frameView = window.contentView?.superview,
                      let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
                    throw HeaderBackdropChecks.failure("原生侧栏快照不可用")
                }
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                }
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw HeaderBackdropChecks.failure("原生侧栏 PNG 编码失败")
                }
                try png.write(to: outputDirectory.appendingPathComponent("sidebar-native-\(name)-\(active ? "active" : "inactive").png"))
            }
        }
        state.alertResponseForChecks = { _ in .alertSecondButtonReturn }
        await state.newDocument().value
        try await Task.sleep(nanoseconds: 150_000_000)
        try HeaderBackdropChecks.require(selection.value == nil && table.selectedRow == -1,
            "新建文档后系统文件选择清空")
        state.session.text = "未命名草稿"
        state.alertResponseForChecks = { _ in .alertFirstButtonReturn }
        state.panelURLForChecks = { _ in nil }
        await selection.select(SidebarFileSelection(.recent, a), in: state)?.value
        try HeaderBackdropChecks.require(state.session.url == nil && selection.value == nil && state.session.isDirty,
            "取消草稿另存为后不留下错误选中项")
        try HeaderBackdropChecks.require(epoch < state.editor.documentEpoch, "回归确实执行了文档切换")
        print("SIDEBAR_SELECTION_CHECK_PASSED：真实系统 List、键盘导航、取消恢复、窗口激活状态与大纲对比度通过；离屏图仅供诊断，玻璃外观需另行验收")
    }

    private static func contrast(_ foreground: NSColor, _ background: NSColor) -> Double {
        func components(_ color: NSColor) -> [Double] {
            guard let rgb = color.usingColorSpace(.sRGB) else { return [0, 0, 0, 0] }
            return [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent), Double(rgb.alphaComponent)]
        }
        func blend(_ color: [Double], over base: [Double]) -> [Double] {
            (0..<3).map { color[$0] * color[3] + base[$0] * (1 - color[3]) } + [1]
        }
        func luminance(_ color: [Double]) -> Double {
            let linear = color.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let backgroundRGB = blend(components(background), over: components(.windowBackgroundColor))
        let back = luminance(backgroundRGB)
        let front = luminance(blend(components(foreground), over: backgroundRGB))
        return (max(front, back) + 0.05) / (min(front, back) + 0.05)
    }
}
#endif
