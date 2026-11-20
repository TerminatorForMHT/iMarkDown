import Foundation

/// 文档层级的最小统计信息，由 Web 编辑器计算后回传，避免原生侧重复解析 Markdown。
public struct DocumentStats: Codable, Equatable, Sendable {
    /// 字符数（不含空白）。
    public var characters: Int
    /// 字数：中日韩逐字计数 + 拉丁语系按词计数。
    public var words: Int
    public var lines: Int
    public var readingMinutes: Int

    public init(characters: Int = 0, words: Int = 0, lines: Int = 0, readingMinutes: Int = 0) {
        self.characters = characters
        self.words = words
        self.lines = lines
        self.readingMinutes = readingMinutes
    }

    public static let zero = DocumentStats()

    public static func from(text: String) -> DocumentStats {
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        let words = Self.countWords(in: text)
        return DocumentStats(
            characters: text.filter { !$0.isWhitespace }.count,
            words: words,
            lines: lines,
            readingMinutes: words == 0 ? 0 : max(1, Int(ceil(Double(words) / 300.0)))
        )
    }

    private static func countWords(in text: String) -> Int {
        var cjk = 0
        var latinRuns = 0
        var inLatinRun = false

        for scalar in text.unicodeScalars {
            if Self.isCJK(scalar) {
                cjk += 1
                inLatinRun = false
            } else if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "-" {
                if !inLatinRun {
                    latinRuns += 1
                    inLatinRun = true
                }
            } else {
                inLatinRun = false
            }
        }
        return cjk + latinRuns
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}
