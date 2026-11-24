#!/usr/bin/env bash
# 编译真实的原生桥接与 Web 编辑器进行隔离回归，不启动用户正在编辑的应用。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/editor-checks"
SDK="${IMARKDOWN_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
mkdir -p "$OUT"

swiftc -O -swift-version 5 -sdk "$SDK" -emit-library -static -emit-module \
  -module-name MarkdownKit "$ROOT"/Sources/MarkdownKit/*.swift \
  -emit-module-path "$OUT/MarkdownKit.swiftmodule" -o "$OUT/libMarkdownKit.a"

swiftc -O -swift-version 5 -sdk "$SDK" -D IMARKDOWN_CHECKS -parse-as-library \
  -I "$OUT" "$OUT/libMarkdownKit.a" \
  "$ROOT"/Sources/iMarkDown/Editor/*.swift \
  "$ROOT/Sources/iMarkDown/Design/DesignSystem.swift" \
  "$ROOT/Sources/iMarkDown/App/AppState.swift" \
  "$ROOT/Sources/iMarkDown/Models/EditorMode.swift" \
  "$ROOT/Sources/iMarkDown/Services/DraftStore.swift" \
  "$ROOT/Sources/iMarkDown/Services/HTMLComposer.swift" \
  "$ROOT/Sources/iMarkDown/Services/PDFExportService.swift" \
  "$ROOT/Tests/EditorChecks/Checks.swift" -o "$OUT/check-editor"

codesign --force --sign - "$OUT/check-editor"
codesign --verify --strict "$OUT/check-editor"

if [ "${1:-}" = "--build-only" ]; then
  echo "编辑器回归程序编译与签名校验通过（未运行测试）"
  exit 0
fi

IMARKDOWN_WEB_ROOT="$ROOT/Sources/iMarkDown/Resources/Web" \
  perl -e 'alarm 90; exec @ARGV' -- "$OUT/check-editor"
