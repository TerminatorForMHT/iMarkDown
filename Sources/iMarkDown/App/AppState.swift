import AppKit
import Combine
import Darwin
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
    @Published var outline: [OutlineItem] = []
    /// 外部修改选择「保留当前内容」后暂停自动保存，避免覆盖对方写入。
    @Published private(set) var isAutosaveSuspended = false

    private var autosaveTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private let drafts = DraftStore()
    private var didOfferDraftRecovery = false
    private var cancellables = Set<AnyCancellable>()
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var externalCheckTask: Task<Void, Never>?
    private var isHandlingExternalChange = false

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
            return isAutosaveSuspended ? "未保存 · 自动保存已暂停" : "未保存"
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
            outline = OutlineParser.parse(text)
            if session.url == nil {
                saveStatus = session.text.isEmpty ? .idle : .unsaved
                scheduleDraftSave()
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

        case .imagePasted(let data, let mime, let filename):
            insertPastedImage(data: data, mime: mime, filename: filename)

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
        stopFileWatcher()
        discardDraft()
        isAutosaveSuspended = false
        session = .untitled()
        stats = .zero
        outline = []
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
        openFolder(at: url)
    }

    /// 从最近文件夹历史或拖拽直接打开文件树。
    func openFolder(at url: URL) {
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
            let standardized = url.standardizedFileURL
            let text = try FileService.read(from: standardized)

            // 打开的文件不属于当前文件树时，收起文件树；该文件夹已进入最近文件夹历史。
            // 用户想恢复时可直接从侧边栏历史入口重新打开。
            if let root = workspace.rootURL,
               !standardized.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") {
                workspace.closeFolder()
            }

            autosaveTask?.cancel()
            discardDraft()
            isAutosaveSuspended = false
            session = DocumentSession(url: standardized, text: text, savedText: text)
            session.loadedAt = .now
            stats = DocumentStats.from(text: text)
            outline = OutlineParser.parse(text)
            saveStatus = .saved(.now)
            recents.record(standardized)
            workspace.reveal(standardized)
            editor.setDocument(text: text, baseDirectory: session.baseDirectoryURL)
            editor.setMode(mode)
            startFileWatcher(for: standardized)
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
            isAutosaveSuspended = false
            discardDraft()
            recents.record(url)
            pushEditorConfig()
            startFileWatcher(for: url)
            return true
        } catch {
            saveStatus = .failed(error.localizedDescription)
            present(error)
            return false
        }
    }

    private func scheduleAutosave() {
        guard settings.autoSaveEnabled, session.url != nil, !isAutosaveSuspended else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            guard !self.isAutosaveSuspended else { return }
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

    // MARK: - 未命名草稿

    /// 未命名文档没有磁盘路径，自动保存无从谈起，用 Application Support 里的草稿兜底。
    private func scheduleDraftSave() {
        guard session.url == nil else { return }
        draftTask?.cancel()
        let text = session.text
        draftTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            if text.isEmpty {
                self.drafts.clear()
            } else {
                try? self.drafts.write(text)
            }
        }
    }

    /// 启动时检查上次异常退出遗留的草稿，只提示一次。
    func offerDraftRecoveryIfNeeded() {
        guard !didOfferDraftRecovery else { return }
        didOfferDraftRecovery = true
        guard session.url == nil, session.text.isEmpty,
              let draft = drafts.read(),
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "发现上次未保存的草稿"
        alert.informativeText = "应用上次退出前有正在编辑的未命名文档，是否恢复？"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "恢复草稿")
        alert.addButton(withTitle: "丢弃")

        if alert.runModal() == .alertFirstButtonReturn {
            session = DocumentSession(url: nil, text: draft, savedText: "")
            stats = DocumentStats.from(text: draft)
            outline = OutlineParser.parse(draft)
            saveStatus = .unsaved
            editor.setDocument(text: draft, baseDirectory: nil)
            editor.setMode(mode)
        } else {
            discardDraft()
        }
    }

    /// 退出时选择「不保存」、或文档已落盘后，删除兜底草稿。
    func discardDraft() {
        draftTask?.cancel()
        draftTask = nil
        drafts.clear()
    }

    // MARK: - 图片插入

    /// 粘贴 / 拖入的图片写入文档同级的 assets 目录，正文里只保留相对路径。
    private func insertPastedImage(data: Data, mime: String, filename: String) {
        guard let documentURL = session.url else {
            present(title: "请先保存文档", message: "图片需要保存到文档同级的 assets 文件夹，请先保存当前文档。")
            return
        }
        do {
            let assets = documentURL
                .deletingLastPathComponent()
                .appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let ext = Self.imageExtension(mime: mime, filename: filename)
            let stamp = Int(Date().timeIntervalSince1970)
            let suffix = UUID().uuidString.prefix(6).lowercased()
            let name = "image-\(stamp)-\(suffix).\(ext)"
            try data.write(to: assets.appendingPathComponent(name), options: .atomic)
            editor.insertImage("assets/\(name)")
        } catch {
            present(error)
        }
    }

    private static func imageExtension(mime: String, filename: String) -> String {
        let byMime = [
            "image/png": "png",
            "image/jpeg": "jpg",
            "image/gif": "gif",
            "image/webp": "webp",
            "image/heic": "heic",
            "image/tiff": "tiff"
        ]
        if let ext = byMime[mime.lowercased()] { return ext }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "png" : ext
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

    // MARK: - 大纲与拖拽

    /// 点击大纲条目：预览不可见时切回分栏，保证跳转结果可见。
    func jumpToOutline(_ item: OutlineItem) {
        if mode == .source {
            setMode(.split)
        }
        editor.scrollToHeading(item.index)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else if let value = item as? URL {
                    url = value
                }
                guard let url else { return }

                Task { @MainActor in
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
                    if isDirectory.boolValue {
                        self?.openFolder(at: url)
                    } else if Self.imageFileExtensions.contains(url.pathExtension.lowercased()) {
                        if let data = try? Data(contentsOf: url) {
                            self?.insertPastedImage(data: data, mime: "", filename: url.lastPathComponent)
                        }
                    } else {
                        let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]
                        guard markdownExtensions.contains(url.pathExtension.lowercased()) else { return }
                        self?.requestOpen(url: url)
                    }
                }
            }
            return true
        }

        // 浏览器 / 截图工具拖入的是图片数据而非文件路径。
        if let imageProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) {
            // public.image 只是抽象类型，实际数据挂在具体类型（public.png 等）下。
            let typeID = imageProvider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .image) == true
            } ?? UTType.image.identifier
            let mime = UTType(typeID)?.preferredMIMEType ?? "image/png"
            imageProvider.loadDataRepresentation(forTypeIdentifier: typeID) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor in
                    self?.insertPastedImage(data: data, mime: mime, filename: "")
                }
            }
            return true
        }

        return false
    }

    private static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"
    ]

    // MARK: - 外部修改检测

    /// 监听当前文档的写入 / 重命名事件，避免其他程序改动被自动保存覆盖。
    private func startFileWatcher(for url: URL) {
        stopFileWatcher()

        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.scheduleExternalCheck()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }

    private func stopFileWatcher() {
        externalCheckTask?.cancel()
        externalCheckTask = nil
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    /// 写入时文件系统会连发多次事件，合并成一次检查，避免重复弹窗。
    private func scheduleExternalCheck() {
        externalCheckTask?.cancel()
        externalCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.reloadIfChangedOnDisk()
        }
    }

    private func reloadIfChangedOnDisk() {
        guard let url = session.url, !isHandlingExternalChange else { return }
        guard let disk = try? FileService.read(from: url), disk != session.savedText else { return }

        isHandlingExternalChange = true
        defer { isHandlingExternalChange = false }

        let alert = NSAlert()
        alert.messageText = "文件已在其他程序中修改"
        alert.informativeText = "磁盘上的「\(url.lastPathComponent)」与当前编辑内容不一致。重新载入会丢弃当前未保存的修改。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重新载入")
        alert.addButton(withTitle: "保留当前内容")

        if alert.runModal() == .alertFirstButtonReturn {
            autosaveTask?.cancel()
            session.text = disk
            session.savedText = disk
            stats = DocumentStats.from(text: disk)
            outline = OutlineParser.parse(disk)
            saveStatus = .saved(.now)
            editor.setDocument(text: disk, baseDirectory: session.baseDirectoryURL)
            editor.setMode(mode)
        } else {
            // 用户选择保留自己的内容：暂停自动保存，避免把对方刚写入的版本覆盖掉。
            // 手动 ⌘S 仍可显式覆盖保存并解除暂停。
            autosaveTask?.cancel()
            isAutosaveSuspended = true
            // 视为有意忽略该次外部修改，避免同一内容反复弹窗。
            session.savedText = disk
            saveStatus = .unsaved
        }

        // rename / delete 会让旧描述符失效，重新挂接监听。
        startFileWatcher(for: url)
    }

    // MARK: - 提示

    private func present(_ error: Error) {
        present(title: "操作失败", message: error.localizedDescription)
    }

    private func present(title: String, message: String) {
        activeAlert = AppAlert(title: title, message: message)
    }
}
