import Foundation

/// 文档大纲条目。`index` 对应预览渲染结果中同级标题的出现顺序，
/// 用于在不依赖标题 id 的情况下定位滚动目标。
public struct OutlineItem: Identifiable, Hashable, Sendable {
    public let index: Int
    public let level: Int
    public let title: String
    public let line: Int

    public var id: Int { index }

    /// 折叠只隐藏更深层级；遇到同级或更高层级后恢复，不依赖标题连续编号。
    public static func visibleItems(_ items: [OutlineItem], collapsed: Set<Int>) -> [OutlineItem] {
        var hiddenBelow: Int?
        return items.filter { item in
            if let level = hiddenBelow, item.level > level { return false }
            hiddenBelow = collapsed.contains(item.index) ? item.level : nil
            return true
        }
    }

    public init(index: Int, level: Int, title: String, line: Int) {
        self.index = index
        self.level = level
        self.title = title
        self.line = line
    }
}

/// 轻量 ATX 标题扫描：跳过围栏代码块，避免把代码里的 `#` 当成标题。
public enum OutlineParser {
    public static func parse(_ text: String) -> [OutlineItem] {
        guard !text.isEmpty else { return [] }

        var items: [OutlineItem] = []
        var inFence = false
        var fenceMarker = ""

        for (lineNumber, raw) in text.components(separatedBy: .newlines).enumerated() {
            // 4 空格或 Tab 起头属于缩进代码块，不参与大纲。
            if raw.hasPrefix("    ") || raw.hasPrefix("\t") { continue }

            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if inFence {
                    if marker == fenceMarker { inFence = false }
                } else {
                    inFence = true
                    fenceMarker = marker
                }
                continue
            }

            guard !inFence else { continue }

            let hashes = trimmed.prefix { $0 == "#" }
            let level = hashes.count
            guard (1...6).contains(level) else { continue }

            let rest = trimmed.dropFirst(level)
            guard let first = rest.first, first == " " || first == "\t" else { continue }

            let title = rest.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }

            items.append(
                OutlineItem(index: items.count, level: level, title: title, line: lineNumber)
            )
        }

        return items
    }
}
