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

#if IMARKDOWN_CHECKS || IMARKDOWN_UI_CHECK
/// 只在独立测试会话内运行；真实 WebKit 快照与生产文档操作共用同一实现。
@MainActor
enum DocumentTransitionChecks {
    static func require(_ value: Bool, _ text: String) throws {
        guard value else {
            throw NSError(domain: "iMarkDown.DocumentTransitionChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
        print("✓ \(text)")
    }

    static func run(state: AppState, directory: URL) async throws {
        let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("workspace", isDirectory: true)
        let otherFolder = root.appendingPathComponent("other-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        let savedDraft = root.appendingPathComponent("saved-draft.md")
        try FileService.write("# A", to: a)
        try FileService.write("# B", to: b)
        var answer = NSApplication.ModalResponse.alertThirdButtonReturn
        var selectedURL: URL?
        var panelCount = 0
        var promptCount = 0
        var promptButtonsCorrect = true
        state.alertResponseForChecks = { alert in
            promptButtonsCorrect = promptButtonsCorrect && alert.buttons.map(\.title) == ["保存", "放弃更改", "取消"]
            promptCount += 1
            return answer
        }
        state.panelURLForChecks = { _ in panelCount += 1; return selectedURL }
        defer { state.alertResponseForChecks = nil; state.panelURLForChecks = nil }
        state.settings.autoSaveEnabled = false
        await state.newDocument().value
        state.editor.insert("即时未保存输入")
        await state.requestOpen(url: b).value
        try require(promptButtonsCorrect, "未保存确认提供保存、放弃更改和取消")
        try require(promptCount == 1 && state.session.url == nil && !state.isDocumentOperationInProgress,
                    "未同步输入也触发确认，取消后保留草稿并释放操作锁")
        try require(try await state.editor.currentText() == "即时未保存输入", "取消切换不会丢失真实编辑内容")

        answer = .alertFirstButtonReturn
        await state.requestOpen(url: b).value
        try require(panelCount == 1 && state.session.url == nil && !state.isDocumentOperationInProgress,
                    "取消另存为后不打开目标文件，也不会锁住后续操作")
        selectedURL = savedDraft
        await state.requestOpen(url: b).value
        try require(try FileService.read(from: savedDraft) == "即时未保存输入" && state.session.url == b,
                    "未命名草稿先保存真实输入，再打开目标文件")

        state.editor.insert("放弃的 B 修改\n")
        answer = .alertSecondButtonReturn
        await state.requestOpen(url: a).value
        let diskB = try FileService.read(from: b)
        try require(state.session.url == a && diskB == "# B",
                    "放弃更改后打开另一文件，不改动原文件磁盘内容")
        _ = try await state.editor.currentText()
        state.editor.insert("保存的 A 修改\n")
        answer = .alertThirdButtonReturn
        await state.openFolder(at: folder).value
        try require(state.workspace.rootURL == nil && state.session.url == a && !state.isDocumentOperationInProgress,
                    "取消工作区切换时保留原文档和文件树")
        answer = .alertFirstButtonReturn
        await state.openFolder(at: folder).value
        try require(state.workspace.rootURL == folder && state.session.url == a && !state.session.isDirty,
                    "保存当前文件后成功打开文件夹")
        let savedA = try FileService.read(from: a)
        try require(savedA.contains("保存的 A 修改"), "文件夹切换前的保存包含最新输入")

        state.editor.insert("不应落盘的 A 修改\n")
        answer = .alertSecondButtonReturn
        selectedURL = nil
        await state.openFolder().value
        try require(state.workspace.rootURL == folder && state.session.url == a && state.session.isDirty,
                    "取消文件夹选择器时不提前丢弃当前文档")
        await state.openFolder(at: otherFolder).value
        try require(state.workspace.rootURL == otherFolder && state.session.url == nil && state.session.text.isEmpty,
                    "明确放弃更改后打开新工作区，并清空已放弃的文档")
        try require(try FileService.read(from: a) == savedA, "放弃工作区修改不会覆盖旧文件")

        state.editor.insert("文件选择器测试")
        let beforeCancel = panelCount
        answer = .alertThirdButtonReturn
        await state.openDocument().value
        try require(panelCount == beforeCancel && state.session.url == nil && !state.isDocumentOperationInProgress,
                    "打开文件前先显示未保存确认，取消时不弹文件选择器")
        answer = .alertSecondButtonReturn
        selectedURL = b
        await state.openDocument().value
        try require(state.session.url == b && !state.isDocumentOperationInProgress,
                    "放弃更改后文件选择器可以正常打开文件")

        await state.newDocument().value
        state.editor.insert("保存失败保护内容")
        answer = .alertFirstButtonReturn
        selectedURL = root.appendingPathComponent("missing-parent/blocked.md")
        await state.requestOpen(url: a).value
        try require(state.session.url == nil && state.activeAlert != nil && !state.isDocumentOperationInProgress,
                    "保存失败阻止切换、保留当前文档并释放操作锁")
        state.activeAlert = nil
        answer = .alertThirdButtonReturn
        try require(!(await state.confirmTermination()) && !state.isDocumentOperationInProgress,
                    "取消退出后操作锁立即释放")

        // 实际展示并取消当前测试窗口的 sheet，验证主线程异步回调可继续运行。
        state.alertResponseForChecks = nil
        try await Task.sleep(nanoseconds: 300_000_000)
        let dismiss = Task { @MainActor in
            for _ in 0..<300 {
                if let window = state.editor.hostingWindow, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .alertThirdButtonReturn)
                    sheet.orderOut(nil)
                    return true
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return false
        }
        let closed = await state.confirmTermination()
        try require(await dismiss.value && !closed && !state.isDocumentOperationInProgress,
                    "真实未保存确认 sheet 可以取消，WebKit 与主线程没有被阻塞")
        state.alertResponseForChecks = { _ in .alertSecondButtonReturn }
        await state.newDocument().value
        _ = try await state.editor.currentText()
        try require(!state.session.isDirty && !state.isDocumentOperationInProgress, "回归结束后编辑与文档操作均可继续")
        print("DOCUMENT_TRANSITION_CHECKS_PASSED")
    }
}
#endif

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
    @Published var mode: EditorMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }
    @Published var saveStatus: SaveStatus = .idle
    @Published var sidebarVisibility: NavigationSplitViewVisibility {
        didSet {
            defaults.set(sidebarVisibility != .detailOnly, forKey: Keys.sidebarVisible)
        }
    }
    @Published var activeAlert: AppAlert?
    @Published var isEditorReady = false
    @Published var isExporting = false
    @Published var outline: [OutlineItem] = []
    /// 当前阅读位置对应的标题序号（与 outline 一一对应），-1 表示尚未进入正文。
    @Published var activeHeadingIndex = -1
    /// 正文是否已进入顶部覆盖区：由 Web 侧按真实重叠关系上报。
    @Published var chromeOverlapped = false
    /// 文档大标题是否已移出顶部覆盖区：决定紧凑标题是否出现。
    @Published var compactTitleVisible = false
    /// 外部修改选择「保留当前内容」后暂停自动保存，避免覆盖对方写入。
    @Published private(set) var isAutosaveSuspended = false

    private let defaults: UserDefaults
    private var autosaveTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    @Published private(set) var isDocumentOperationInProgress = false
    @Published private(set) var isReading = false
    private var hasPendingEdits = false
    private var observedDiskText: String?
    private let drafts: DraftStore
    private var didOfferDraftRecovery = false
    private var cancellables = Set<AnyCancellable>()
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var externalCheckTask: Task<Void, Never>?
    private var isHandlingExternalChange = false

    #if IMARKDOWN_CHECKS || IMARKDOWN_UI_CHECK
    // 仅隔离回归可替换用户选择，不在正式构建中提供自动确认。
    var alertResponseForChecks: ((NSAlert) async -> NSApplication.ModalResponse)?
    var panelURLForChecks: ((NSSavePanel) async -> URL?)?
    #endif

    private enum Keys {
        static let mode = "session.mode"
        static let sidebarVisible = "session.sidebarVisible"
        static let lastDocument = "session.lastDocument"
    }

    init(
        settings: AppSettings? = nil,
        recents: RecentFilesStore? = nil,
        workspace: WorkspaceStore? = nil,
        defaults: UserDefaults = .standard,
        draftStore: DraftStore? = nil
    ) {
        self.settings = settings ?? AppSettings()
        self.recents = recents ?? RecentFilesStore()
        self.workspace = workspace ?? WorkspaceStore()
        self.defaults = defaults
        self.drafts = draftStore ?? DraftStore()
        defaults.register(defaults: [Keys.sidebarVisible: true])
        mode = EditorMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .split
        sidebarVisibility = defaults.bool(forKey: Keys.sidebarVisible) ? .all : .detailOnly
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
            // 页面重建后旧的顶部状态可能已失效，先归零等待 Web 重新上报。
            chromeOverlapped = false
            compactTitleVisible = false
            activeHeadingIndex = -1
            pushEditorConfig()
            editor.setMode(mode)
            // 页面每次重建都重新灌入当前文档：既恢复内容，也让 Web 侧代数与原生对齐，
            // 否则空文档时 Web 代数停在 0，会把它后续的 change 全判成过期事件。
            editor.setDocument(text: session.text, baseDirectory: session.baseDirectoryURL)
            editor.setReadOnly(isDocumentOperationInProgress)

        case .unready:
            isEditorReady = false
            if hasPendingEdits {
                present(title: "编辑器已重新加载", message: "内容进程意外退出，最后尚未同步的输入可能无法恢复。")
            }
        case .edited(let epoch):
            guard epoch == editor.documentEpoch else { return }
            hasPendingEdits = true
            saveStatus = .unsaved
            autosaveTask?.cancel()
        case .outline(let items, let epoch):
            guard epoch == editor.documentEpoch else { return }
            outline = items
            if activeHeadingIndex >= items.count { activeHeadingIndex = -1 }
        case .reading(let reading, let epoch):
            guard epoch == editor.documentEpoch else { return }
            isReading = reading
        case .change(let text, let stats, let epoch):
            // 切换文档时旧文档可能还有一次 debounce 中的 change 在路上，
            // 代对齐后直接丢弃，避免旧内容覆盖新文档的文本镜像甚至写盘。
            guard epoch == editor.documentEpoch else { return }
            session.text = text
            self.stats = stats
            hasPendingEdits = false
            if session.url == nil {
                saveStatus = session.text.isEmpty ? .idle : .unsaved
                scheduleDraftSave()
            } else {
                saveStatus = session.isDirty ? .unsaved : .saved(.now)
            }
            scheduleAutosave()

        case .stats(let stats, let epoch):
            guard epoch == editor.documentEpoch else { return }
            self.stats = stats

        case .chrome(let overlapped, let compactTitleVisible, let activeHeadingIndex, let epoch):
            guard epoch == editor.documentEpoch else { return }
            chromeOverlapped = overlapped
            self.compactTitleVisible = compactTitleVisible
            if self.activeHeadingIndex != activeHeadingIndex {
                self.activeHeadingIndex = activeHeadingIndex
            }

        case .link(let href):
            openLink(href)

        case .saveRequested:
            save()

        case .imagePasted(let data, let mime, let filename, let epoch):
            guard epoch == editor.documentEpoch, !isDocumentOperationInProgress else { return }
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

        // recents 是独立的 ObservableObject，转发变更让侧边栏与菜单立即刷新。
        recents.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
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

    @discardableResult
    func newDocument() -> Task<Void, Never> {
        Task {
            guard beginDocumentOperation() else { return }
            defer { endDocumentOperation() }
            guard await confirmDiscardIfNeeded() else { return }
            resetDocument()
        }
    }

    private func resetDocument() {
        autosaveTask?.cancel()
        stopFileWatcher()
        discardDraft()
        isAutosaveSuspended = false
        session = .untitled()
        observedDiskText = nil
        hasPendingEdits = false
        stats = .zero
        outline = []
        activeHeadingIndex = -1
        saveStatus = .idle
        defaults.removeObject(forKey: Keys.lastDocument)
        mode = .split
        editor.setMode(.split)
        editor.setDocument(text: "", baseDirectory: nil)
        editor.focus()
    }

    @discardableResult
    func openDocument() -> Task<Void, Never> {
        Task {
            guard beginDocumentOperation() else { return }
            defer { endDocumentOperation() }
            guard await confirmDiscardIfNeeded() else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = FileService.markdownContentTypes
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.prompt = "打开"
            guard let url = await chooseURL(using: panel) else { return }
            open(url: url)
        }
    }

    /// 切换工作区前先处理未保存内容；取消选择文件夹时保留当前文档。
    @discardableResult
    func openFolder() -> Task<Void, Never> {
        Task {
            guard beginDocumentOperation() else { return }
            defer { endDocumentOperation() }
            guard await confirmDiscardIfNeeded() else { return }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.prompt = "打开文件夹"
            guard let url = await chooseURL(using: panel) else { return }
            if session.isDirty { resetDocument() }
            openWorkspace(at: url)
        }
    }

    /// 最近文件夹历史和拖拽也必须经过同一确认流程。
    @discardableResult
    func openFolder(at url: URL) -> Task<Void, Never> {
        Task {
            guard beginDocumentOperation() else { return }
            defer { endDocumentOperation() }
            guard await confirmDiscardIfNeeded() else { return }
            if session.isDirty { resetDocument() }
            openWorkspace(at: url)
        }
    }

    private func openWorkspace(at url: URL) {
        workspace.openFolder(url)
        if let current = session.url { workspace.reveal(current) }
    }

    /// 供侧边栏 / 最近文件菜单使用，会先检查未保存修改。
    @discardableResult
    func requestOpen(url: URL) -> Task<Void, Never> {
        Task {
            guard beginDocumentOperation() else { return }
            defer { endDocumentOperation() }
            guard await confirmDiscardIfNeeded() else { return }
            open(url: url)
        }
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
            observedDiskText = text
            hasPendingEdits = false
            session.loadedAt = .now
            stats = DocumentStats.from(text: text)
            outline = []
            activeHeadingIndex = -1
            saveStatus = .saved(.now)
            recents.record(standardized)
            defaults.set(standardized.path, forKey: Keys.lastDocument)
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
            guard beginDocumentOperation() else { return }
            defer { endDocumentOperation() }
            do { _ = await presentSavePanel(text: try await synchronizeText()) }
            catch { present(error) }
        }
    }

    @discardableResult
    func saveNow() async -> Bool {
        guard beginDocumentOperation() else { return false }
        defer { endDocumentOperation() }
        do { return await saveSynchronizedText(try await synchronizeText()) }
        catch { present(error); return false }
    }

    private func beginDocumentOperation() -> Bool {
        guard !isDocumentOperationInProgress, !isHandlingExternalChange else { return false }
        isDocumentOperationInProgress = true
        autosaveTask?.cancel()
        editor.setReadOnly(true)
        return true
    }

    private func endDocumentOperation() {
        isDocumentOperationInProgress = false
        editor.setReadOnly(false)
        if session.isDirty { scheduleAutosave() }
    }

    /// 同步失败不能把旧镜像当作最新内容，否则保存和退出都会静默丢字。
    private func synchronizeText() async throws -> String {
        let epoch = editor.documentEpoch
        let url = session.url
        let text: String
        if isEditorReady { text = try await editor.currentText() }
        else {
            guard !hasPendingEdits else { throw EditorError.notReady }
            text = session.text
        }
        guard epoch == editor.documentEpoch, url == session.url else { throw EditorError.documentChanged }
        session.text = text
        hasPendingEdits = false
        stats = DocumentStats.from(text: text)
        return text
    }

    private func saveSynchronizedText(_ text: String) async -> Bool {
        guard let url = session.url else { return await presentSavePanel(text: text) }
        let disk = try? FileService.read(from: url)
        if disk != observedDiskText || isAutosaveSuspended {
            let alert = NSAlert()
            alert.messageText = "磁盘文件已发生变化"
            alert.informativeText = "是否用当前内容覆盖？取消不会改动磁盘文件。"
            alert.addButton(withTitle: "覆盖保存")
            alert.addButton(withTitle: "取消")
            guard await showDialog(alert) == .alertFirstButtonReturn else { return false }
        }
        return write(text: text, to: url, expectedText: disk)
    }

    private func presentSavePanel(text: String) async -> Bool {
        let panel = NSSavePanel()
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown]
        }
        panel.nameFieldStringValue = FileService.suggestedFileName(for: session)
        panel.prompt = "保存"
        panel.canCreateDirectories = true
        guard var url = await chooseURL(using: panel) else { return false }
        if url.pathExtension.isEmpty {
            url.appendPathExtension("md")
        }
        if url == session.url { return await saveSynchronizedText(text) }
        return write(text: text, to: url, expectedText: try? FileService.read(from: url))
    }

    @discardableResult
    private func write(text: String, to url: URL, expectedText: String?) -> Bool {
        do {
            saveStatus = .saving
            try FileService.write(text, to: url, expectedText: expectedText)
            session.text = text
            session.savedText = text
            observedDiskText = text
            session.url = url
            saveStatus = .saved(.now)
            isAutosaveSuspended = false
            discardDraft()
            recents.record(url)
            defaults.set(url.path, forKey: Keys.lastDocument)
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
        guard settings.autoSaveEnabled, session.url != nil, !isAutosaveSuspended,
              !isDocumentOperationInProgress else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            guard !self.isAutosaveSuspended, !self.isDocumentOperationInProgress,
                  !self.isHandlingExternalChange, !self.hasPendingEdits else { return }
            guard self.session.isDirty, let url = self.session.url else { return }
            do {
                self.saveStatus = .saving
                try FileService.write(self.session.text, to: url, expectedText: self.observedDiskText)
                self.session.savedText = self.session.text
                self.observedDiskText = self.session.text
                self.saveStatus = .saved(.now)
                self.startFileWatcher(for: url)
            } catch {
                self.isAutosaveSuspended = true
                self.saveStatus = .failed(error.localizedDescription)
                self.scheduleExternalCheck()
            }
        }
    }

    // MARK: - 大纲

    // 大纲直接使用 Web 清洗后的标题节点，不再重复解析整篇文本。

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
            outline = []
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

    /// 启动时回到上次打开的文档；有未保存草稿或已通过命令行指定文件时不抢焦点。
    func restoreLastSessionIfNeeded() {
        guard session.url == nil, session.text.isEmpty else { return }
        guard let path = defaults.string(forKey: Keys.lastDocument),
              FileManager.default.fileExists(atPath: path) else { return }
        open(url: URL(fileURLWithPath: path))
    }

    /// 当前文档在侧栏被重命名后，同步会话路径与相对图片基准目录。
    func didRenameCurrentDocument(from oldURL: URL, to newURL: URL) {
        guard !isDocumentOperationInProgress else { return }
        guard session.url?.standardizedFileURL == oldURL.standardizedFileURL else { return }
        session.url = newURL
        stopFileWatcher()
        startFileWatcher(for: newURL)
        recents.record(newURL)
        defaults.set(newURL.path, forKey: Keys.lastDocument)
        // 只更新基准目录并重绘，避免 setDocument 重置光标与撤销历史。
        pushEditorConfig()
    }

    /// 当前文档被移到废纸篓后，回到未命名状态，防止自动保存又把文件写回来。
    func didRemoveCurrentDocument(_ url: URL) {
        guard !isDocumentOperationInProgress else { return }
        guard session.url?.standardizedFileURL == url.standardizedFileURL else { return }
        autosaveTask?.cancel()
        stopFileWatcher()
        isAutosaveSuspended = false
        discardDraft()
        session = .untitled()
        observedDiskText = nil
        hasPendingEdits = false
        stats = .zero
        outline = []
        activeHeadingIndex = -1
        saveStatus = .idle
        defaults.removeObject(forKey: Keys.lastDocument)
        editor.setDocument(text: "", baseDirectory: nil)
    }

    // MARK: - 图片插入

    /// 粘贴 / 拖入的图片写入文档同级的 assets 目录，正文里只保留相对路径。
    private func insertPastedImage(data: Data, mime: String, filename: String) {
        guard !isDocumentOperationInProgress, data.count <= 8 * 1024 * 1024 else { return }
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

    private func confirmDiscardIfNeeded() async -> Bool {
        do {
            let text = try await synchronizeText()
            guard session.isDirty else { return true }
            let alert = NSAlert()
            alert.messageText = "“\(session.displayName)”有未保存的更改"
            alert.informativeText = "是否先保存当前文档？放弃更改后继续操作，取消则保留当前文档。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "放弃更改")
            alert.addButton(withTitle: "取消")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            switch await showDialog(alert) {
            // 已持有操作锁，直接保存本次真实快照，不再次调用 saveNow 获取锁。
            case .alertFirstButtonReturn: return await saveSynchronizedText(text)
            case .alertSecondButtonReturn: return true
            default: return false
            }
        } catch { present(error); return false }
    }

    func confirmTermination() async -> Bool {
        guard beginDocumentOperation() else { return false }
        defer { endDocumentOperation() }
        guard await confirmDiscardIfNeeded() else { return false }
        if session.isDirty { discardDraft() }
        return true
    }

    /// 对话框归属于编辑器窗口，避免把后续确认绑到已经关闭的文件选择器。
    private func showDialog(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        #if IMARKDOWN_CHECKS || IMARKDOWN_UI_CHECK
        if let alertResponseForChecks { return await alertResponseForChecks(alert) }
        #endif
        guard let window = editor.hostingWindow ?? NSApp.mainWindow else { return alert.runModal() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private func chooseURL(using panel: NSSavePanel) async -> URL? {
        #if IMARKDOWN_CHECKS || IMARKDOWN_UI_CHECK
        if let panelURLForChecks { return await panelURLForChecks(panel) }
        #endif
        NSApp.activate(ignoringOtherApps: true)
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response)
            }
            if let window = editor.hostingWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
        return response == .OK ? panel.url : nil
    }

    // MARK: - 导出

    func exportHTML() {
        Task { await exportHTMLNow() }
    }

    private func exportHTMLNow() async {
        guard beginDocumentOperation() else { return }
        isExporting = true
        defer { isExporting = false; endDocumentOperation() }
        guard let article = try? await exportArticle(), isEditorReady else {
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
        guard beginDocumentOperation() else { return }
        isExporting = true
        defer { isExporting = false; endDocumentOperation() }
        guard isEditorReady, let article = try? await exportArticle() else {
            present(title: "无法导出", message: "编辑器尚未就绪，请稍后重试。")
            return
        }
        // PDF 固定用浅色与打印版式：页边距与分页由导出服务控制。
        let html = HTMLComposer.compose(
            articleHTML: article,
            title: session.displayName,
            dark: false,
            previewTheme: settings.previewTheme,
            documentURL: session.url,
            layout: .pdf
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = session.displayName + ".pdf"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }

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

    private func exportArticle() async throws -> String {
        let epoch = editor.documentEpoch
        let url = session.url
        let article = try await editor.articleHTML()
        guard epoch == editor.documentEpoch, url == session.url else { throw EditorError.documentChanged }
        return article
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
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
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
        let epoch = editor.documentEpoch
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
                    guard let self, epoch == self.editor.documentEpoch,
                          !self.isDocumentOperationInProgress else { return }
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
                    if isDirectory.boolValue {
                        self.openFolder(at: url)
                    } else if Self.imageFileExtensions.contains(url.pathExtension.lowercased()) {
                        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                              size <= 8 * 1024 * 1024 else { return }
                        if let data = try? Data(contentsOf: url) {
                            self.insertPastedImage(data: data, mime: "", filename: url.lastPathComponent)
                        }
                    } else {
                        let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]
                        guard markdownExtensions.contains(url.pathExtension.lowercased()) else { return }
                        self.requestOpen(url: url)
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
                guard let data, data.count <= 8 * 1024 * 1024 else { return }
                Task { @MainActor in
                    guard let self, epoch == self.editor.documentEpoch,
                          !self.isDocumentOperationInProgress else { return }
                    self.insertPastedImage(data: data, mime: mime, filename: "")
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
            await self?.reloadIfChangedOnDisk()
        }
    }

    private func reloadIfChangedOnDisk() async {
        guard let url = session.url, !isHandlingExternalChange else { return }
        guard !isDocumentOperationInProgress else { scheduleExternalCheck(); return }
        // 自身原子写入也会替换文件，所有分支都要重新挂接描述符。
        defer { startFileWatcher(for: url) }
        let disk = try? FileService.read(from: url)
        guard disk != observedDiskText else { return }
        isAutosaveSuspended = true
        autosaveTask?.cancel()
        guard let disk else {
            observedDiskText = nil
            saveStatus = .failed("文件已移除或无法读取，自动保存已暂停")
            return
        }
        guard beginDocumentOperation() else { return }
        isHandlingExternalChange = true
        defer { isHandlingExternalChange = false; endDocumentOperation() }
        do { _ = try await synchronizeText() }
        catch { present(error); return }
        observedDiskText = disk

        let alert = NSAlert()
        alert.messageText = "文件已在其他程序中修改"
        alert.informativeText = "磁盘上的「\(url.lastPathComponent)」与当前编辑内容不一致。重新载入会丢弃当前未保存的修改。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重新载入")
        alert.addButton(withTitle: "保留当前内容")

        if await showDialog(alert) == .alertFirstButtonReturn {
            autosaveTask?.cancel()
            session.text = disk
            session.savedText = disk
            hasPendingEdits = false
            isAutosaveSuspended = false
            stats = DocumentStats.from(text: disk)
            outline = []
            saveStatus = .saved(.now)
            editor.setDocument(text: disk, baseDirectory: session.baseDirectoryURL)
            editor.setMode(mode)
        } else {
            // 用户选择保留自己的内容：暂停自动保存，避免把对方刚写入的版本覆盖掉。
            // 手动 ⌘S 仍可显式覆盖保存并解除暂停。
            autosaveTask?.cancel()
            isAutosaveSuspended = true
            // 视为有意忽略该次外部修改，避免同一内容反复弹窗。
            observedDiskText = disk
            saveStatus = .unsaved
        }

        // rename / delete 会让旧描述符失效，重新挂接监听。
        // defer 同时覆盖内容未变化的分支。
    }

    // MARK: - 提示

    private func present(_ error: Error) {
        present(title: "操作失败", message: error.localizedDescription)
    }

    private func present(title: String, message: String) {
        activeAlert = AppAlert(title: title, message: message)
    }
}
