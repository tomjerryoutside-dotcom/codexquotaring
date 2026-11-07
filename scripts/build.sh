#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${RESEARCH_TMP:?Run build through the research-storage runner}"
app_dir="$project_dir/QuotaRing.app"
mkdir -p "$build_dir/module-cache" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$build_dir/module-cache"
/usr/bin/swiftc -swift-version 5 -target arm64-apple-macos13.0 -O -module-cache-path "$build_dir/module-cache" \
  -framework AppKit -framework ApplicationServices \
  "$project_dir/Sources/QuotaModel.swift" "$project_dir/Sources/QuotaClient.swift" "$project_dir/Sources/APIBalanceClient.swift" \
  "$project_dir/Sources/Overlay.swift" "$project_dir/Sources/Tests.swift" "$project_dir/Sources/main.swift" \
  -o "$build_dir/QuotaRing"
QUOTARING_PREVIEW_PATH="$build_dir/card-preview.png" "$build_dir/QuotaRing" --self-test
/bin/cp "$build_dir/QuotaRing" "$app_dir/Contents/MacOS/QuotaRing"
/bin/cp "$project_dir/Resources/sync-api-balance.js" "$app_dir/Contents/Resources/sync-api-balance.js"
/usr/bin/python3 - "$app_dir/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'CFBundleIdentifier':'local.zhumo.quota-ring', 'CFBundleName':'额度环',
      'CFBundleDisplayName':'额度环', 'CFBundleExecutable':'QuotaRing', 'CFBundlePackageType':'APPL',
      'CFBundleShortVersionString':'0.1.4', 'CFBundleVersion':'5', 'LSMinimumSystemVersion':'13.0',
      'LSUIElement':True, 'NSHighResolutionCapable':True}, f)
PY
/usr/bin/codesign --force --sign - --identifier local.zhumo.quota-ring "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
