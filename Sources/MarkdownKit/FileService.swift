import Foundation
import UniformTypeIdentifiers

public enum FileServiceError: LocalizedError {
    case unsupportedEncoding
    case accessDenied(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            return "无法识别文件编码，请将文件转换为 UTF-8 后重试。"
        case .accessDenied(let path):
            return "没有权限访问：\(path)"
        }
    }
}

public enum FileService {
    /// 兼容 UTF-8 / UTF-16 / Latin1 的文本读取，避免用户打开旧文件失败。
    public static func read(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.isEmpty { return "" }
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            }
        }
        throw FileServiceError.unsupportedEncoding
    }

    public static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public static var markdownContentTypes: [UTType] {
        var types: [UTType] = [.plainText]
        for ext in ["md", "markdown", "mdown", "mkd"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return Array(Set(types))
    }

    /// 第二个返回值表示：新建文档保存时是否需要补写 `.md` 扩展名。
    public static func suggestedFileName(for session: DocumentSession) -> String {
        session.url?.lastPathComponent ?? "未命名.md"
    }
}
