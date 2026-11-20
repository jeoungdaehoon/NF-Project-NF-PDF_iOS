#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d /private/tmp/nf-tool-popover-qa.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
app_dir="$test_root/ToolPopoverQA.app"
mkdir -p "$app_dir/Contents/MacOS"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>co.kr.NF.tool-popover-regression</string>
<key>CFBundleExecutable</key><string>ToolPopoverQA</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
sources=()
for source in "$project_dir"/NFMac/*.swift; do
    if [[ "$source" == */NFMacApp.swift ]]; then continue; fi
    if [[ "$source" == */MacPDFEditorView.swift && -n "${NF_TEST_EDITOR_SOURCE:-}" ]]; then
        sources+=("$NF_TEST_EDITOR_SOURCE")
    else sources+=("$source"); fi
done
for source in PortalMeeting PortalMeetingLiveCapture PortalMeetingRecordingSettings PortalMeetingAudioQuality; do
    sources+=("$project_dir/NF/Web/$source.swift")
done
xcrun swiftc -O -whole-module-optimization -parse-as-library -swift-version 5 -default-isolation MainActor -module-name ToolPopoverQA \
    "${sources[@]}" "$project_dir/Scripts/test-macos-pdf-tool-popover.swift" \
    -o "$app_dir/Contents/MacOS/ToolPopoverQA"
"$app_dir/Contents/MacOS/ToolPopoverQA"
