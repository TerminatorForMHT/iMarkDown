import AppKit
import Combine
import MarkdownKit
import SwiftUI
import UniformTypeIdentifiers

enum SaveStatus: Equatable {
    case idle
    case unsaved
    case saving
    case saved(Date)
    case failed(String)
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 应用状态机：文档会话、保存状态、外观、最近文件、导出。
/// 文本真源在 Web 编辑器，session.text 是供原生 UI 使用的镜像。
@MainActor
final class AppState: ObservableObject {
    let settings: AppSettings
    let recents: RecentFilesStore
    let workspace: WorkspaceStore
    let editor = EditorController()
    let bridge = EditorBridge()

    @Published var session: DocumentSession = .untitled()
    @Published var stats: DocumentStats = .zero
    @Published var mode: EditorMode = .split
    @Published var saveStatus: SaveStatus = .idle
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Published var activeAlert: AppAlert?
    @Published var isEditorReady = false
    @Published var isExporting = false

    private var autosaveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: AppSettings? = nil,
        recents: RecentFilesStore? = nil,
        workspace: WorkspaceStore? = nil
    ) {
        self.settings = settings ?? AppSettings()
        self.recents = recents ?? RecentFilesStore()
        self.workspace = workspace ?? WorkspaceStore()
        bridge.onEvent = { [weak self] event in
            self?.handle(event)
        }
        subscribeSettings()
    }

    // MARK: - 派生状态

    var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    var documentSubtitle: String {
        guard let url = session.url else { return "尚未保存到磁盘" }
        return url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var saveLabel: String {
        switch saveStatus {
        case .idle:
            return session.url == nil ? "未命名草稿" : "已就绪"
        case .unsaved:
            return "未保存"
        case .saving:
            return "正在保存…"
        case .saved(let date):
            return "已保存 \(date.formatted(date: .omitted, time: .shortened))"
        case .failed:
            return "保存失败"
        }
    }

    // MARK: - Web 事件

    private func handle(_ event: EditorEvent) {
        switch event {
        case .ready:
            // 必须先放行队列，否则编辑器就绪前排队的 setDocument / applyConfig 永远不会执行。
            editor.markReady()
            isEditorReady = true
            pushEditorConfig()
            editor.setMode(mode)
            if !session.text.isEmpty || session.url != nil {
                editor.setDocument(text: session.text, baseDirectory: session.baseDirectoryURL)
            }

        case .change(let text, let stats):
            session.text = text
            self.stats = stats
            if session.url == nil {
                saveStatus = session.text.isEmpty ? .idle : .unsaved
            } else {
                saveStatus = session.isDirty ? .unsaved : .saved(.now)
            }
            scheduleAutosave()

        case .stats(let stats):
            self.stats = stats

        case .link(let href):
            openLink(href)

        case .saveRequested:
            save()

        case .log(let message):
            print("[web] \(message)")
        }
    }

    // MARK: - 设置联动

    private func subscribeSettings() {
        settings.$appearance
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyAppearance() }
            }
            .store(in: &cancellables)

        settings.$previewTheme
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.pushEditorConfig() }
            }
            .store(in: &cancellables)

        settings.$editorFontSize
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.pushEditorConfig() }
            }
            .store(in: &cancellables)

        settings.$previewFontSize
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.pushEditorConfig() }
            }
            .store(in: &cancellables)
    }

    func applyAppearance() {
        NSApp.appearance = settings.appearance.nsAppearance
        pushEditorConfig()
    }

    func pushEditorConfig() {
        let config = EditorConfig(
            appearance: settings.appearance.resolved(isDarkSystem: isDark),
            previewTheme: settings.previewTheme.rawValue,
            editorFontSize: settings.editorFontSize,
            previewFontSize: settings.previewFontSize,
            baseDirectory: session.baseDirectoryURL ?? ""
        )
        editor.apply(config)
    }

    // MARK: - 文档操作

    func newDocument() {
        guard confirmDiscardIfNeeded() else { return }
        autosaveTask?.cancel()
        session = .untitled()
        stats = .zero
        saveStatus = .idle
        mode = .split
        editor.setMode(.split)
        editor.setDocument(text: "", baseDirectory: nil)
        editor.focus()
    }

    func openDocument() {
        guard confirmDiscardIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileService.markdownContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "打开"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    /// 打开文件夹作为左侧文件树的工作区；不会影响当前文档。
    func openFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "打开文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.openFolder(url)
        if let current = session.url {
            workspace.reveal(current)
        }
    }

    /// 供侧边栏 / 最近文件菜单使用，会先检查未保存修改。
    func requestOpen(url: URL) {
        guard confirmDiscardIfNeeded() else { return }
        open(url: url)
    }

    private func open(url: URL) {
        do {
            let text = try FileService.read(from: url)
            autosaveTask?.cancel()
            session = DocumentSession(url: url, text: text, savedText: text)
            session.loadedAt = .now
            stats = DocumentStats.from(text: text)
            saveStatus = .saved(.now)
            recents.record(url)
            workspace.reveal(url)
            editor.setDocument(text: text, baseDirectory: session.baseDirectoryURL)
            editor.setMode(mode)
        } catch {
            present(error)
        }
    }

    func save() {
        Task { await saveNow() }
    }

    func saveAs() {
        Task {
            let latest = await latestText()
            _ = presentSavePanel(text: latest)
        }
    }

    @discardableResult
    func saveNow() async -> Bool {
        let latest = await latestText()
        if let url = session.url {
            return write(text: latest, to: url)
        }
        return presentSavePanel(text: latest)
    }

    private func latestText() async -> String {
        guard isEditorReady, let text = try? await editor.currentText() else {
            return session.text
        }
        return text
    }

    private func presentSavePanel(text: String) -> Bool {
        let panel = NSSavePanel()
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown]
        }
        panel.nameFieldStringValue = FileService.suggestedFileName(for: session)
        panel.prompt = "保存"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var url = panel.url else { return false }
        if url.pathExtension.isEmpty {
            url.appendPathExtension("md")
        }
        return write(text: text, to: url)
    }

    @discardableResult
    private func write(text: String, to url: URL) -> Bool {
        do {
            saveStatus = .saving
            try FileService.write(text, to: url)
            session.text = text
            session.savedText = text
            session.url = url
            saveStatus = .saved(.now)
            recents.record(url)
            pushEditorConfig()
            return true
        } catch {
            saveStatus = .failed(error.localizedDescription)
            present(error)
            return false
        }
    }

    private func scheduleAutosave() {
        guard settings.autoSaveEnabled, session.url != nil else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.session.isDirty, let url = self.session.url else { return }
            do {
                self.saveStatus = .saving
                try FileService.write(self.session.text, to: url)
                self.session.savedText = self.session.text
                self.saveStatus = .saved(.now)
            } catch {
                self.saveStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard session.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "“\(session.displayName)”有未保存的更改"
        alert.informativeText = "继续操作将丢失这些更改。可以取消后先保存。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续并丢弃")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - 导出

    func exportHTML() {
        Task { await exportHTMLNow() }
    }

    private func exportHTMLNow() async {
        guard let article = try? await editor.articleHTML(), isEditorReady else {
            present(title: "无法导出", message: "编辑器尚未就绪，请稍后重试。")
            return
        }
        let html = HTMLComposer.compose(
            articleHTML: article,
            title: session.displayName,
            dark: isDark,
            previewTheme: settings.previewTheme,
            documentURL: session.url
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = session.displayName + ".html"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            present(error)
        }
    }

    func exportPDF() {
        Task { await exportPDFNow() }
    }

    private func exportPDFNow() async {
        guard isEditorReady, let article = try? await editor.articleHTML() else {
            present(title: "无法导出", message: "编辑器尚未就绪，请稍后重试。")
            return
        }
        let html = HTMLComposer.compose(
            articleHTML: article,
            title: session.displayName,
            dark: isDark,
            previewTheme: settings.previewTheme,
            documentURL: session.url
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = session.displayName + ".pdf"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        defer { isExporting = false }
        do {
            try await PDFExportService.export(
                html: html,
                baseURL: session.url?.deletingLastPathComponent(),
                to: url
            )
        } catch {
            present(error)
        }
    }

    // MARK: - 链接与格式

    private func openLink(_ href: String) {
        guard !href.isEmpty, !href.hasPrefix("#") else { return }

        let isRemote = href.hasPrefix("http://") || href.hasPrefix("https://") || href.hasPrefix("mailto:")
        let resolved: URL?
        if isRemote {
            resolved = URL(string: href)
        } else {
            resolved = URL(string: href, relativeTo: session.url?.deletingLastPathComponent())?.absoluteURL
        }
        guard let url = resolved else { return }

        if url.isFileURL {
            let markdownExtensions = ["md", "markdown", "mdown", "mkd", "txt"]
            if markdownExtensions.contains(url.pathExtension.lowercased()) {
                requestOpen(url: url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func setMode(_ newMode: EditorMode) {
        mode = newMode
        editor.setMode(newMode)
    }

    func wrap(_ before: String, _ after: String) {
        editor.wrap(before, after)
    }

    // MARK: - 提示

    private func present(_ error: Error) {
        present(title: "操作失败", message: error.localizedDescription)
    }

    private func present(title: String, message: String) {
        activeAlert = AppAlert(title: title, message: message)
    }
}
