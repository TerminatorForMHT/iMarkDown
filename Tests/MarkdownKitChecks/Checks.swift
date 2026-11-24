import Foundation
import MarkdownKit

/// MarkdownKit 的最小单元检查。当前机器只有 Command Line Tools，
/// XCTest / swift-testing 的运行器不可用，因此以可执行目标的形式运行：
///
///     swift run MarkdownKitChecks
///
/// 任一检查失败时以非零状态码退出，可直接用于 CI 或本地回归。
@main
struct MarkdownKitChecks {
    static func main() async {
        let runner = CheckRunner()
        runner.run("DocumentStats") {
            checkDocumentStats(runner)
        }
        runner.run("OutlineParser") {
            checkOutlineParser(runner)
        }
        runner.run("FileService") {
            try checkFileService(runner)
        }
        await runner.run("WorkspaceStore") {
            try await checkWorkspaceStore(runner)
        }
        runner.finish()
    }

    // MARK: - DocumentStats

    private static func checkDocumentStats(_ runner: CheckRunner) {
        runner.expect(DocumentStats.from(text: "") == .zero, "空文本统计为零")

        let stats = DocumentStats.from(text: "你好 world\nsecond line")
        runner.expect(stats.words == 5, "中日韩逐字 + 拉丁按词计数")
        runner.expect(stats.lines == 2, "行数统计")
        runner.expect(
            stats.characters == "你好worldsecondline".count,
            "字符数不含空白"
        )
    }

    // MARK: - OutlineParser

    private static func checkOutlineParser(_ runner: CheckRunner) {
        let headings = OutlineParser.parse("# 标题一\n## 子标题\n### 三级")
        runner.expect(headings.map(\.level) == [1, 2, 3], "解析标题层级")
        runner.expect(headings.map(\.title) == ["标题一", "子标题", "三级"], "解析标题文本")
        runner.expect(headings.map(\.index) == [0, 1, 2], "标题序号递增")

        let fenced = """
        # 真标题

        ```
        # 代码里的井号
        ```

        ~~~
        ## 也是代码
        ~~~

            # 缩进代码块
        """
        let filtered = OutlineParser.parse(fenced)
        runner.expect(filtered.count == 1, "跳过围栏与缩进代码块")
        runner.expect(filtered.first?.title == "真标题", "围栏代码中的井号不算标题")

        let noSpace = OutlineParser.parse("#没有空格\n# 有空格")
        runner.expect(noSpace.count == 1, "# 后必须有空格")
        runner.expect(noSpace.first?.title == "有空格", "无空格的行被忽略")

        let lineNumber = OutlineParser.parse("intro\n\n## 第二章").first?.line
        runner.expect(lineNumber == 2, "记录标题所在行号")

        let nested = OutlineParser.parse("# 一\n## 子\n#### 深层\n## 同级\n# 二")
        runner.expect(OutlineItem.visibleItems(nested, collapsed: [0]).map(\.index) == [0, 4], "折叠章节隐藏所有后代")
        runner.expect(OutlineItem.visibleItems(nested, collapsed: [1]).map(\.index) == [0, 1, 3, 4], "跳级标题也属于后代")
        runner.expect(OutlineItem.visibleItems(nested, collapsed: []).count == nested.count, "展开后恢复完整大纲")
    }

    // MARK: - FileService

    private static func checkFileService(_ runner: CheckRunner) throws {
        let directory = try makeTemporaryDirectory(prefix: "FileService")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("sample.md")
        let text = "# 标题\n\n正文内容"
        try FileService.write(text, to: url)
        runner.expect(try FileService.read(from: url) == text, "写入后读回一致")

        let bomURL = directory.appendingPathComponent("bom.md")
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: Array("# 标题".utf8))
        try data.write(to: bomURL)
        runner.expect(try FileService.read(from: bomURL) == "# 标题", "读取时剥离 UTF-8 BOM")

        let emptyURL = directory.appendingPathComponent("empty.md")
        try Data().write(to: emptyURL)
        runner.expect(try FileService.read(from: emptyURL).isEmpty, "空文件读取为空字符串")

        try FileService.write("新内容", to: url, expectedText: text)
        runner.expect(try FileService.read(from: url) == "新内容", "磁盘版本匹配时允许保存")
        do {
            try FileService.write("错误覆盖", to: url, expectedText: text)
            runner.expect(false, "拒绝覆盖外部版本")
        } catch FileServiceError.externallyModified {
            runner.expect(try FileService.read(from: url) == "新内容", "冲突不会更改磁盘")
        }
        do {
            try FileService.write("错误重建", to: directory.appendingPathComponent("missing.md"), expectedText: text)
            runner.expect(false, "被删除文件不可自动重建")
        } catch FileServiceError.externallyModified {
            runner.expect(true, "被删除文件不可自动重建")
        }

        let image = directory.appendingPathComponent("图片 空格.png")
        try Data([1, 2, 3]).write(to: image)
        runner.expect(FileService.localImageURL("图片%20空格.png", directory: directory) == image.resolvingSymlinksInPath(), "相对图片支持中文与空格")
        runner.expect(FileService.localImageURL(image.absoluteString, directory: directory) != nil, "授权目录内绝对图片可读取")
        runner.expect(FileService.localImageURL("../outside.png", directory: directory) == nil, "拒绝路径越界")
        runner.expect(FileService.localImageURL("https://example.com/a.png", directory: directory) == nil, "本地通道拒绝远程地址")
        runner.expect(FileService.localImageURL("sample.md", directory: directory) == nil, "本地图片通道拒绝文本")
        let link = directory.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.deletingLastPathComponent().appendingPathComponent("outside.png"))
        runner.expect(FileService.localImageURL("escape.png", directory: directory) == nil, "拒绝失效符号链接")
        let imageDirectory = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: imageDirectory.appendingPathComponent("escape.png"), withDestinationURL: image)
        runner.expect(FileService.localImageURL("escape.png", directory: imageDirectory) == nil, "拒绝越界符号链接")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("safe.png"), withDestinationURL: image)
        runner.expect(FileService.localImageURL("safe.png", directory: directory) == image.resolvingSymlinksInPath(), "允许目录内符号链接图片")
    }

    // MARK: - WorkspaceStore

    @MainActor
    private static func checkWorkspaceStore(_ runner: CheckRunner) async throws {
        let directory = try makeTemporaryDirectory(prefix: "Workspace")
        defer { try? FileManager.default.removeItem(at: directory) }

        try "# b".write(to: directory.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "# a".write(to: directory.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: directory.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("notes"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        let defaults = UserDefaults(suiteName: "MarkdownKitChecks-\(UUID().uuidString)") ?? .standard
        let store = WorkspaceStore(defaults: defaults)
        store.openFolder(directory)

        let nodes = await waitForChildren(of: store, in: directory)
        runner.expect(nodes.map(\.name) == ["notes", "a.md", "b.md"], "目录优先并按名称排序")
        runner.expect(nodes.first?.isDirectory == true, "目录节点标记正确")
        runner.expect(nodes.dropFirst().allSatisfy { !$0.isDirectory }, "文件节点标记正确")
        runner.expect(!nodes.contains { $0.name == "data.json" }, "过滤非 Markdown 文件")
        runner.expect(!nodes.contains { $0.name == ".git" }, "过滤忽略目录")

        let nested = directory.appendingPathComponent("chapters/part-1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("intro.md")
        try "# intro".write(to: file, atomically: true, encoding: .utf8)

        store.reveal(file)
        runner.expect(
            store.isExpanded(directory.appendingPathComponent("chapters")),
            "reveal 展开一级父目录"
        )
        runner.expect(store.isExpanded(nested), "reveal 展开二级父目录")

        // 搜索：跨层级命中 Markdown 文件，忽略大小写与非 Markdown 文件。
        runner.expect(
            (await store.search("intro")).map(\.name) == ["intro.md"],
            "搜索命中嵌套文件"
        )
        runner.expect(
            (await store.search("INTRO")).map(\.name) == ["intro.md"],
            "搜索不区分大小写"
        )
        runner.expect((await store.search("data")).isEmpty, "搜索忽略非 Markdown 文件")
        runner.expect((await store.search("   ")).isEmpty, "空白查询返回空结果")

        // 文件夹历史：收起文件树后仍可从最近文件夹恢复。
        let second = try makeTemporaryDirectory(prefix: "Workspace2")
        defer { try? FileManager.default.removeItem(at: second) }

        store.closeFolder()
        runner.expect(store.rootURL == nil, "关闭文件夹后文件树收起")
        runner.expect(store.recentFolders.first?.path == directory.path, "关闭的文件夹进入历史")

        store.openFolder(second)
        runner.expect(store.recentFolders.first?.path == second.path, "新打开的文件夹排在最前")
        runner.expect(
            store.recentFolders.contains { $0.path == directory.path },
            "旧文件夹保留在历史中"
        )
    }

    // MARK: - 工具

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iMarkDownChecks-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private static func waitForChildren(of store: WorkspaceStore, in directory: URL) async -> [FileNode] {
        for _ in 0..<100 {
            if store.hasLoaded(directory) {
                return store.children(of: directory)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return store.children(of: directory)
    }
}

/// 极简断言收集器，替代 XCTest 的失败汇总。
final class CheckRunner {
    private var passed = 0
    private var failures: [String] = []
    private var currentScope = ""

    func run(_ scope: String, _ body: () throws -> Void) {
        currentScope = scope
        do {
            try body()
        } catch {
            failures.append("[\(scope)] 抛出错误：\(error)")
        }
    }

    func run(_ scope: String, _ body: () async throws -> Void) async {
        currentScope = scope
        do {
            try await body()
        } catch {
            failures.append("[\(scope)] 抛出错误：\(error)")
        }
    }

    func expect(_ condition: Bool, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failures.append("[\(currentScope)] \(name)  (\(file):\(line))")
            print("✗ \(currentScope)：\(name)")
        }
    }

    func finish() -> Never {
        print("")
        if failures.isEmpty {
            print("✅ 全部 \(passed) 项检查通过")
            exit(0)
        }

        print("❌ \(failures.count) 项检查失败（通过 \(passed) 项）")
        for failure in failures {
            print("  - \(failure)")
        }
        exit(1)
    }
}
