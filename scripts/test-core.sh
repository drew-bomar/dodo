#!/bin/bash
# Runs the TodayCore domain tests on macOS with plain swiftc.
# Prefer `swift test --package-path Packages/TodayCore` or Xcode's test action
# when SwiftPM works; this exists because some Command Line Tools installs
# ship a PackageDescription library that fails to link manifests.
set -euo pipefail
cd "$(dirname "$0")/../Packages/TodayCore"
OUT="${TMPDIR:-/tmp}/todaycore-tests"
mkdir -p "$OUT"
DEV="$(xcode-select -p)"
[[ "$DEV" == *CommandLineTools* ]] && FW="$DEV/Library/Developer/Frameworks" || FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"
cat > "$OUT/main.swift" <<'MAIN'
import Testing
@main struct Runner { static func main() async { await Testing.__swiftPMEntryPoint() as Never } }
MAIN
swiftc -parse-as-library -swift-version 6 -module-name TodayCore -emit-module -emit-module-path "$OUT/TodayCore.swiftmodule" \
  -enable-testing -emit-library -static -o "$OUT/libTodayCore.a" Sources/TodayCore/*.swift
swiftc -parse-as-library -swift-version 6 -I "$OUT" -L "$OUT" -lTodayCore -F "$FW" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$FW/../usr/lib" \
  -o "$OUT/run-tests" Tests/TodayCoreTests/*.swift "$OUT/main.swift"
"$OUT/run-tests" "$@"
