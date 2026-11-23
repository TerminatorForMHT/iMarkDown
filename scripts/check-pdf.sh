#!/usr/bin/env bash
# PDF 导出回归：用真实 PDFExportService 渲染一份多页文档，校验页数、A4 尺寸与耗时。
# 背景：macOS 26 的 WKWebView.printOperation 会无限生成页面（FB20581927），
# 这里锁住 createPDF 分页实现，避免回退到打印链路。
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/main.swift" <<'SWIFT'
import AppKit
import PDFKit

let repo = ProcessInfo.processInfo.environment["REPO"] ?? "."
let webRoot = repo + "/Sources/iMarkDown/Resources/Web"

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

let css = [
    read(webRoot + "/vendor/github-markdown/github-markdown.css"),
    read(webRoot + "/vendor/highlight/github.min.css"),
    read(webRoot + "/css/preview.css"),
    read(webRoot + "/css/export.css"),
    """
    html, body { background: #ffffff; }
    .markdown-body { max-width: none; padding: 0; }
    pre { white-space: pre-wrap; }
    """
].joined(separator: "\n")

let paragraphs = String(
    repeating: "<p>分页回归测试段落，包含中英文混排 Mixed Latin Text 与标点。</p>\n",
    count: 80
)
let html = """
<!doctype html>
<html lang="zh-CN" data-appearance="light"><head><meta charset="utf-8">
<style>\(css)</style></head><body>
<article class="markdown-body"><h1>PDF 分页回归</h1>\(paragraphs)</article>
</body></html>
"""

let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PDF_OUT"] ?? "/tmp/imd-pdf-check.pdf")

Task { @MainActor in
    let start = Date()
    do {
        try await PDFExportService.export(html: html, baseURL: nil, to: output)
        let elapsed = Date().timeIntervalSince(start)
        guard let document = PDFDocument(url: output) else {
            print("FAIL: 无法读取生成的 PDF")
            exit(1)
        }
        guard document.pageCount >= 2 else {
            print("FAIL: 期望多页，实际 \(document.pageCount) 页")
            exit(1)
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                print("FAIL: 第 \(index + 1) 页缺失")
                exit(1)
            }
            let box = page.bounds(for: .mediaBox)
            if abs(box.width - 595.2) > 1 || abs(box.height - 841.8) > 1 {
                print("FAIL: 第 \(index + 1) 页不是 A4，实际 \(box.size)")
                exit(1)
            }
        }
        print(String(format: "PDF check passed: %d pages in %.2fs", document.pageCount, elapsed))
        NSApp.terminate(nil)
    } catch {
        print("FAIL: 导出失败 \(error)")
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
SWIFT

swiftc -O -o "$tmp/check" \
    Sources/iMarkDown/Services/PDFExportService.swift \
    "$tmp/main.swift" \
    -framework AppKit -framework WebKit

REPO="$root" PDF_OUT="$tmp/out.pdf" perl -e 'alarm 60; exec @ARGV' -- "$tmp/check"
