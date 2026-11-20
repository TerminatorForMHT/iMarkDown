import Foundation
import MarkdownKit

/// 将预览 HTML 片段包装成可独立打开的完整文档。
/// 样式全部内联，导出的 HTML 不依赖应用资源目录。
enum HTMLComposer {
    static func compose(
        articleHTML: String,
        title: String,
        dark: Bool,
        previewTheme: PreviewTheme,
        documentURL: URL?
    ) -> String {
        var css = WebResources.text("vendor/github-markdown/github-markdown.css")
        css += "\n"
        css += WebResources.text("vendor/highlight/\(dark ? "github-dark" : "github").min.css")
        css += "\n"
        css += WebResources.text("css/preview.css")
        css += "\n"
        css += WebResources.text("css/export.css")

        var baseTag = ""
        if let documentURL {
            let directory = documentURL.deletingLastPathComponent().absoluteString
            let href = directory.hasSuffix("/") ? directory : directory + "/"
            baseTag = "<base href=\"\(escape(href))\">"
        }

        // 把可以读取到的本地图片内联为 data URI，让导出的 HTML 脱离原目录也能显示。
        let inlineArticle = inlineLocalImages(in: articleHTML, documentURL: documentURL)

        return """
        <!doctype html>
        <html lang="zh-CN" data-appearance="\(dark ? "dark" : "light")" data-preview="\(previewTheme.rawValue)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        \(baseTag)
        <style>
        \(css)
        </style>
        </head>
        <body>
        <article class="markdown-body">
        \(inlineArticle)
        </article>
        </body>
        </html>
        """
    }

    // MARK: - 本地图片内联

    private static let imageSizeLimit = 8 * 1024 * 1024

    private static func inlineLocalImages(in html: String, documentURL: URL?) -> String {
        guard let documentURL,
              let regex = try? NSRegularExpression(
                pattern: "(<img\\b[^>]*?\\bsrc=\")([^\"]+)(\")",
                options: [.caseInsensitive]
              ) else {
            return html
        }

        let directory = documentURL.deletingLastPathComponent()
        let source = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return html }

        var result = html
        // 从后往前替换，避免前一次插入改变后续 NSRange 的偏移。
        for match in matches.reversed() {
            let src = source.substring(with: match.range(at: 2))
            guard !src.hasPrefix("http://"),
                  !src.hasPrefix("https://"),
                  !src.hasPrefix("data:") else { continue }

            let fileURL: URL?
            if src.hasPrefix("file://") {
                fileURL = URL(string: src)
            } else {
                fileURL = URL(string: src, relativeTo: directory)?.standardizedFileURL
            }
            guard let fileURL, fileURL.isFileURL,
                  let data = try? Data(contentsOf: fileURL),
                  data.count <= imageSizeLimit,
                  let mime = mimeType(for: fileURL.pathExtension) else { continue }

            let dataURI = "data:\(mime);base64,\(data.base64EncodedString())"
            guard let range = Range(match.range(at: 2), in: result) else { continue }
            result.replaceSubrange(range, with: dataURI)
        }
        return result
    }

    private static func mimeType(for pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "avif": return "image/avif"
        default: return nil
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
