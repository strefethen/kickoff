#!/bin/bash
set -euo pipefail

task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
task_build="$task_root/build"
task_bundle="$task_build/Kickoff.app"

/usr/bin/plutil -lint "$task_root/Info.plist"
/usr/bin/swift build --package-path "$task_root" -c release --product Kickoff
/bin/mkdir -p "$task_bundle/Contents/MacOS" "$task_bundle/Contents/Resources"

/bin/cp "$task_root/.build/release/Kickoff" "$task_bundle/Contents/MacOS/Kickoff"
/bin/cp "$task_root/Info.plist" "$task_bundle/Contents/Info.plist"
"$task_root/scripts/build-icon.sh" "$task_root/Resources/AppIcon.png" "$task_bundle/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --timestamp=none "$task_bundle"
/usr/bin/codesign --verify --strict "$task_bundle"
printf 'Built %s\n' "$task_bundle"
