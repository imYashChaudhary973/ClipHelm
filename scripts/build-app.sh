#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo_dir/.build/phase1"
app_dir="$repo_dir/build/ClipHelm.app"

cd "$repo_dir"
mkdir -p "$repo_dir/.build/clang-cache" "$repo_dir/.build/cache" "$app_dir/Contents/MacOS"
CLANG_MODULE_CACHE_PATH="$repo_dir/.build/clang-cache" \
XDG_CACHE_HOME="$repo_dir/.build/cache" \
swift build --disable-sandbox --scratch-path "$build_dir" --product ClipHelmApp

cp "$build_dir/debug/ClipHelmApp" "$app_dir/Contents/MacOS/ClipHelmApp"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"

echo "$app_dir"
