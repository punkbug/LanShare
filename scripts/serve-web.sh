#!/bin/bash
set -e

PORT=${1:-8080}
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "🌐 LanShare 웹페이지를 http://localhost:$PORT 에서 실행합니다..."
echo "종료하려면 Ctrl+C 를 누르세요."

python3 -m http.server "$PORT" --directory "$ROOT_DIR/web"
