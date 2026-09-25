#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-debug}"
case "$configuration" in
  debug|release) ;;
  *) echo "Usage: scripts/build-app.sh [debug|release]" >&2; exit 2 ;;
esac
build_dir="$repo_dir/.build/phase1"
app_dir="$repo_dir/build/ClipHelm.app"

cd "$repo_dir"
mkdir -p "$repo_dir/.build/clang-cache" "$repo_dir/.build/cache"
CLANG_MODULE_CACHE_PATH="$repo_dir/.build/clang-cache" \
XDG_CACHE_HOME="$repo_dir/.build/cache" \
swift build --disable-sandbox --scratch-path "$build_dir" -c "$configuration" --product ClipHelmApp

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
cp "$build_dir/$configuration/ClipHelmApp" "$app_dir/Contents/MacOS/ClipHelmApp"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

# Compile the Icon Composer source into Assets.car (Liquid Glass icon) plus a
# ClipHelm.icns fallback for earlier macOS versions.
mkdir -p "$app_dir/Contents/Resources"
xcrun actool "$repo_dir/Resources/ClipHelm.icon" \
  --compile "$app_dir/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 \
  --app-icon ClipHelm \
  --output-partial-info-plist "$build_dir/icon-partial.plist" \
  --output-format human-readable-text >/dev/null
if [[ "$configuration" == release && -n "${CLIPHELM_SIGNING_IDENTITY:-}" ]]; then
  if [[ "$CLIPHELM_SIGNING_IDENTITY" == "-" ]]; then
    echo "Release signing requires a Developer ID Application identity." >&2
    exit 2
  fi
  codesign --force --options runtime --timestamp --sign "$CLIPHELM_SIGNING_IDENTITY" "$app_dir"
elif [[ "$configuration" == release ]]; then
  codesign --force --options runtime --sign - "$app_dir"
  echo "Ad hoc Release build for local testing only; external distribution requires Developer ID signing and notarization." >&2
else
  codesign --force --sign - "$app_dir"
fi

echo "$app_dir"
