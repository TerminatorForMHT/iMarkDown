#!/usr/bin/env bash
# 拉取 Web 编辑器依赖到本地 vendor 目录，保证应用完全离线可用。
# 依赖全部为可直接在浏览器中使用的单文件 UMD / CSS 产物，无需 Node 构建链。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Sources/iMarkDown/Resources/Web/vendor"
mkdir -p "$VENDOR/codemirror/mode" "$VENDOR/codemirror/addon" "$VENDOR/highlight" "$VENDOR/github-markdown"

# cdnjs 为主镜像；jsDelivr 偶发连接重置，作为备选。
CDNJS="https://cdnjs.cloudflare.com/ajax/libs"

fetch() {
  local relative="$1" out="$2"
  local url="$CDNJS/$relative"
  echo "  ↓ $relative"
  curl -fsSL --retry 2 --retry-delay 1 --max-time 60 "$url" -o "$out" \
    || curl -fsSL --retry 3 --retry-delay 1 --max-time 60 "https://cdn.jsdelivr.net/$relative" -o "$out" \
    || { echo "!! 下载失败: $relative"; exit 1; }
}

echo "CodeMirror 5.65.16"
CM="codemirror/5.65.16"
fetch "$CM/codemirror.min.js" "$VENDOR/codemirror/codemirror.min.js"
fetch "$CM/codemirror.min.css" "$VENDOR/codemirror/codemirror.min.css"
fetch "$CM/addon/scroll/simplescrollbars.min.js" "$VENDOR/codemirror/addon/simplescrollbars.min.js"
fetch "$CM/addon/scroll/simplescrollbars.min.css" "$VENDOR/codemirror/addon/simplescrollbars.min.css"
fetch "$CM/addon/edit/closebrackets.min.js" "$VENDOR/codemirror/addon/closebrackets.min.js"
fetch "$CM/addon/edit/matchbrackets.min.js" "$VENDOR/codemirror/addon/matchbrackets.min.js"
fetch "$CM/addon/selection/active-line.min.js" "$VENDOR/codemirror/addon/active-line.min.js"
for mode in markdown xml javascript css yaml clike; do
  fetch "$CM/mode/$mode/$mode.min.js" "$VENDOR/codemirror/mode/$mode.min.js"
done

echo "marked 12.0.2 / DOMPurify 3.2.4"
fetch "marked/12.0.2/marked.min.js" "$VENDOR/marked.min.js"
fetch "dompurify/3.2.4/purify.min.js" "$VENDOR/purify.min.js"

echo "highlight.js 11.11.1"
fetch "highlight.js/11.11.1/highlight.min.js" "$VENDOR/highlight/highlight.min.js"
fetch "highlight.js/11.11.1/styles/github.min.css" "$VENDOR/highlight/github.min.css"
fetch "highlight.js/11.11.1/styles/github-dark.min.css" "$VENDOR/highlight/github-dark.min.css"

echo "github-markdown-css 5.8.1"
fetch "github-markdown-css/5.8.1/github-markdown.min.css" "$VENDOR/github-markdown/github-markdown.css"
fetch "github-markdown-css/5.8.1/github-markdown-dark.min.css" "$VENDOR/github-markdown/github-markdown-dark.css"

echo "完成，vendor 体积：$(du -sh "$VENDOR" | cut -f1)"
