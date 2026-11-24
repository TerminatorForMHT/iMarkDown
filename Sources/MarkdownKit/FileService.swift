import Foundation
import UniformTypeIdentifiers

public enum FileServiceError: LocalizedError {
    case unsupportedEncoding
    case accessDenied(String)
    case externallyModified

    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            return "无法识别文件编码，请将文件转换为 UTF-8 后重试。"
        case .accessDenied(let path):
            return "没有权限访问：\(path)"
        case .externallyModified:
            return "文件已被其他程序修改或移除，未覆盖磁盘内容。"
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

    public static func write(_ text: String, to url: URL, expectedText: String? = nil) throws {
        // 写入前再次核对磁盘版本；原子替换本身并不能防止覆盖外部编辑。
        if let expectedText {
            guard let disk = try? read(from: url), disk == expectedText else {
                throw FileServiceError.externallyModified
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 仅授权已选文档目录内的图片，拒绝路径越界和指向目录外的符号链接。
    public static func localImageURL(_ source: String, directory: URL) -> URL? {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        guard root.isFileURL else { return nil }
        let base = URL(fileURLWithPath: root.path, isDirectory: true)
        // 保留已经编码的 %20，同时编码中文；避免 Foundation 二次编码混合路径。
        let allowed = CharacterSet.urlFragmentAllowed.union(CharacterSet(charactersIn: "%"))
        guard let encoded = source.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: encoded, relativeTo: base)?.absoluteURL,
              url.isFileURL else { return nil }
        let file = url.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(prefix),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let type = UTType(filenameExtension: file.pathExtension),
              type.conforms(to: .image) else { return nil }
        return file
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
