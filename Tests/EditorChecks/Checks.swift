import AppKit
import MarkdownKit
import WebKit

// 回归进程不安装主窗口关闭代理，其他编辑器与会话代码均使用生产实现。
@MainActor
final class AppDelegate {
    static let shared: AppDelegate? = nil
    func protectClose(of window: NSWindow) {}
}

@main
struct EditorChecks {
    @MainActor
    static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                print("❌ 编辑器检查失败：\(error)")
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    @MainActor
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iMarkDownEditorChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "iMarkDownEditorChecks-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.autoSaveEnabled = false
        let state = AppState(settings: settings, recents: RecentFilesStore(defaults: defaults),
                             workspace: WorkspaceStore(defaults: defaults), defaults: defaults,
                             draftStore: DraftStore(fileURL: directory.appendingPathComponent("draft.md")))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(state.editor.resources, forURLScheme: "imarkdown")
        config.userContentController.add(state.bridge, name: "editor")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
        view.navigationDelegate = state.bridge
        state.editor.attach(view)
        let wrapper = WebViewClippingView(frame: view.frame)
        wrapper.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        wrapper.addSubview(view)
        try expect(wrapper.subviews.count == 1 && view.layer?.mask == nil && view.layer?.masksToBounds != true,
                   "WebKit 远程图层不添加原生模糊覆盖或裁剪")
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = wrapper
        window.orderFrontRegardless()
        defer { window.orderOut(nil); view.removeFromSuperview(); wrapper.removeFromSuperview() }
        view.load(URLRequest(url: EditorResourceHandler.editorURL))
        try await wait { state.isEditorReady }
        try expect(try await state.editor.currentText() == "", "受控协议与 CSP 下编辑器正常就绪")
        try await DocumentTransitionChecks.run(state: state, directory: directory)
        try await HeaderBackdropChecks.run(in: view, state: state)

        let a = directory.appendingPathComponent("a.md")
        let b = directory.appendingPathComponent("b.md")
        try FileService.write("# A", to: a)
        try FileService.write("# B", to: b)
        state.requestOpen(url: a)
        try await wait { state.session.url == a && !state.isDocumentOperationInProgress }
        try await js(view, "window.MD.insert('即时输入\\n')")
        // 不等 140ms 上报就保存，同时尝试切换；操作锁必须阻止跨文档写入。
        let saving = Task { @MainActor in await state.saveNow() }
        await Task.yield()
        state.requestOpen(url: b)
        try expect(await saving.value, "即时输入能够同步保存")
        try expect(state.session.url == a, "保存期间文档切换被阻止")
        try expect(try FileService.read(from: a).contains("即时输入"), "保存读取真实文本而非旧镜像")
        try expect(try FileService.read(from: b) == "# B", "另一文档未被覆盖")

        let markdown = "Setext\n======\n\n> ## 引用标题\n\n<h3>HTML标题</h3>\n\n# ATX\n\n<form action='https://example.invalid'><input name='q'></form><script>window.pwned = 1</script>"
        state.editor.setDocument(text: markdown, baseDirectory: directory.absoluteString)
        try await wait { state.outline.map(\.title) == ["Setext", "引用标题", "HTML标题", "ATX"] }
        try expect(state.outline.map(\.level) == [1, 2, 3, 1], "大纲来自实际渲染的全部标题")
        try expect(try await bool(view, "!document.querySelector('#preview form') && !window.pwned"), "文档表单与脚本被清除")
        try await js(view, "window.location.href = 'https://example.invalid/unsafe'")
        try await Task.sleep(nanoseconds: 150_000_000)
        try expect(view.url == EditorResourceHandler.editorURL, "非编辑器导航被阻止")

        let large = "# 大文档\n" + String(repeating: "测试文字内容\n", count: 22000)
        state.editor.setDocument(text: large, baseDirectory: directory.absoluteString)
        _ = try await state.editor.currentText()
        try await js(view, "window.MD.insert('## 最后修改\\n')")
        let article = try await state.editor.articleHTML()
        try expect(article.contains("最后修改"), "大文档去抖期间导出包含最新输入")
        try expect(article.contains("<h2"), "导出保持 Markdown 格式")
        let huge = String(repeating: String(repeating: "正文 ", count: 100) + "\n", count: 2100) + "\n# 超大文档标题\n"
        state.editor.setDocument(text: huge, baseDirectory: directory.absoluteString)
        _ = try await state.editor.currentText()
        try expect(try await state.editor.articleHTML().contains("<h1"), "纯文本预览降级不影响完整导出")

        state.editor.setDocument(text: String(repeating: "needle ", count: 6002), baseDirectory: nil)
        _ = try await state.editor.currentText()
        try await js(view, "window.MD.openFind(); document.getElementById('find-input').value='needle'; document.getElementById('replace-input').value='done'; document.querySelector('[data-find=\"replace-all\"]').click()")
        let replaced = try await state.editor.currentText()
        try expect(!replaced.contains("needle") && replaced.components(separatedBy: "done").count == 6003, "全部替换超过 5001 处仍完整处理")
        try await js(view, "window.MD.undo()")
        try expect(try await state.editor.currentText() == String(repeating: "needle ", count: 6002), "大量替换可一次撤销")
        state.editor.setReadOnly(true)
        _ = try await state.editor.currentText()
        try await js(view, "window.MD.insert('禁止输入')")
        try expect(!(try await state.editor.currentText()).contains("禁止输入"), "保存期间禁止编辑指令改变快照")
        state.editor.setReadOnly(false)

        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jXxkAAAAASUVORK5CYII=")!
        try png.write(to: directory.appendingPathComponent("图片 空格.png"))
        state.editor.setDocument(text: "![](图片%20空格.png)", baseDirectory: directory.absoluteString)
        _ = try await state.editor.currentText()
        try await wait {
            (try? await bool(view, "document.querySelector('#preview img').naturalWidth === 1")) == true
        }
        try expect(try await bool(view, "document.querySelector('#preview img').src.startsWith('imarkdown://document/')"), "中文图片通过受控资源通道加载")
        let exported = HTMLComposer.compose(articleHTML: try await state.editor.articleHTML(), title: "检查", dark: false,
                                            previewTheme: .github, documentURL: a)
        try expect(exported.contains("data:image/png;base64,"), "导出图片正确内联")
        state.editor.setDocument(text: "![](../outside.png)", baseDirectory: directory.absoluteString)
        _ = try await state.editor.currentText()
        try expect(try await bool(view, "!document.querySelector('#preview img').hasAttribute('src')"), "预览拒绝越界图片")
        try await PreviewThemeChecks.run(state: state, view: view, directory: directory)

        let sample = (0..<2500).map { $0 % 50 == 0 ? "## 章节 \($0)\n" : "中英文混排 Mixed text\n" }.joined()
        state.editor.setDocument(text: sample, baseDirectory: nil)
        _ = try await state.editor.currentText()
        let metrics = try await view.evaluateJavaScript("JSON.stringify(window.MD.getMetrics())")
        guard let metrics = metrics as? String else { throw CheckError.failed("渲染指标响应无效") }
        try expect(try await bool(view, "window.MD.getMetrics().characters === \(sample.utf16.count)"), "指标来自当前长文档样本")
        print("长文档回归样本（2500 行）渲染指标：\(metrics)")
        print("✅ 编辑器回归全部通过")
    }

    @MainActor
    static func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw CheckError.failed("等待编辑器状态超时")
    }

    @MainActor
    static func js(_ view: WKWebView, _ script: String) async throws {
        _ = try await view.evaluateJavaScript(script)
    }

    @MainActor
    static func bool(_ view: WKWebView, _ script: String) async throws -> Bool {
        try await view.evaluateJavaScript(script) as? Bool ?? false
    }

    static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw CheckError.failed(label) }
        print("✓ \(label)")
    }
}

enum CheckError: Error { case failed(String) }
