import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建文档") { state.newDocument() }
                .keyboardShortcut("n", modifiers: .command)

            Button("打开…") { state.openDocument() }
                .keyboardShortcut("o", modifiers: .command)

            Menu("打开最近文件") {
                if state.recents.items.isEmpty {
                    Text("暂无记录")
                } else {
                    ForEach(state.recents.items) { entry in
                        Button(entry.name) {
                            state.requestOpen(url: entry.url)
                        }
                    }
                }
            }

            Button("打开文件夹…") { state.openFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("保存") { state.save() }
                .keyboardShortcut("s", modifiers: .command)

            Button("另存为…") { state.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            Button("导出为 HTML…") { state.exportHTML() }
            Button("导出为 PDF…") { state.exportPDF() }
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("查找…") { state.editor.openFind() }
                .keyboardShortcut("f", modifiers: .command)

            Button("查找下一个") { state.editor.findNext() }
                .keyboardShortcut("g", modifiers: .command)

            Button("查找上一个") { state.editor.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandMenu("格式") {
            Button("加粗") { state.wrap("**", "**") }
                .keyboardShortcut("b", modifiers: .command)
            Button("斜体") { state.wrap("_", "_") }
                .keyboardShortcut("i", modifiers: .command)
            Button("行内代码") { state.wrap("`", "`") }
                .keyboardShortcut("k", modifiers: .command)
            Button("链接") { state.wrap("[", "](https://)") }
                .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Button("引用") { state.wrap("> ", "") }
            Button("无序列表") { state.wrap("- ", "") }
            Button("任务清单") { state.wrap("- [ ] ", "") }
        }

        CommandGroup(after: .sidebar) {
            Divider()

            Button("源码模式") { state.setMode(.source) }
                .keyboardShortcut("1", modifiers: .command)
            Button("分栏模式") { state.setMode(.split) }
                .keyboardShortcut("2", modifiers: .command)
            Button("预览模式") { state.setMode(.preview) }
                .keyboardShortcut("3", modifiers: .command)
        }
    }
}
