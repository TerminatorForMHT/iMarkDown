import Foundation
import MarkdownKit

/// 将预览 HTML 片段包装成可独立打开的完整文档。
/// 样式全部内联，导出的 HTML 不依赖应用资源目录。
enum HTMLComposer {
    /// 导出用途：屏幕版式用于独立 HTML，PDF 版式去掉屏幕版心，由导出服务控制分页与页边距。
    enum Layout {
        case screen
        case pdf
    }

    static func compose(
        articleHTML: String,
        title: String,
        dark: Bool,
        previewTheme: PreviewTheme,
        documentURL: URL?,
        layout: Layout = .screen
    ) -> String {
        var css = WebResources.text("vendor/github-markdown/github-markdown.css")
        css += "\n"
        css += WebResources.text("vendor/highlight/\(dark ? "github-dark" : "github").min.css")
        css += "\n"
        css += WebResources.text("css/preview.css")
        css += "\n"
        css += WebResources.text("css/export.css")
        if layout == .pdf {
            css += "\n"
            css += pdfCSS
        }

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
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: https: http:; base-uri file:; form-action 'none'">
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

    // MARK: - PDF 版式

    /// createPDF 按屏幕媒体渲染，不会应用 export.css 的 @media print，
    /// 所以这里用普通规则补齐打印版式（白底、无屏幕版心与内边距）。
    private static let pdfCSS = """
    html,
    body {
      background: #ffffff;
    }

    .markdown-body {
      max-width: none;
      padding: 0;
    }

    a {
      color: inherit;
      text-decoration: none;
    }

    pre {
      white-space: pre-wrap;
    }

    pre,
    blockquote,
    table,
    figure {
      break-inside: avoid;
    }
    """

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

            let decoded = src.replacingOccurrences(of: "&amp;", with: "&")
            guard let fileURL = FileService.localImageURL(decoded, directory: directory),
                  let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= imageSizeLimit,
                  let mime = mimeType(for: fileURL.pathExtension),
                  let data = try? Data(contentsOf: fileURL),
                  data.count <= imageSizeLimit else { continue }

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
