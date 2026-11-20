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
        \(articleHTML)
        </article>
        </body>
        </html>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
