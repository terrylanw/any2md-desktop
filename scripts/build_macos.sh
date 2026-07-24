#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT/converter"
uv sync --dev
uv run pyinstaller --noconfirm --clean any2md_converter.spec

cd "$REPO_ROOT"
flutter build macos --release

APP_RESOURCES="$REPO_ROOT/build/macos/Build/Products/Release/Any2MD.app/Contents/Resources"
mkdir -p "$APP_RESOURCES/converter"
cp -R "$REPO_ROOT/converter/dist/any2md_converter/." "$APP_RESOURCES/converter/"

echo "Any2MD.app is ready. Sign nested converter binaries before notarization."
