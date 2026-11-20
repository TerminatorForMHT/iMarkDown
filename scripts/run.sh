#!/usr/bin/env bash
# 构建并启动应用（默认 debug，便于快速迭代）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"

"$ROOT/scripts/build-app.sh" "$CONFIG"
open "$ROOT/dist/iMarkDown.app"
