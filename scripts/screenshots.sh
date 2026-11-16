#!/bin/bash
# App Store screenshots (1320 × 2868) from an iPhone Pro Max simulator.
#   scripts/screenshots.sh         sample data + the in-app shots, then leaves DoDo open
#   scripts/screenshots.sh lock    the Lock Screen shot (lock the simulator in Device Hub first)
# Shots land in screenshots/ (not committed).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
OUT=screenshots
BUILD="${TMPDIR:-/tmp}/dodo-screenshots"
BUNDLE=com.drewbomar.today
mkdir -p "$OUT" "$BUILD"

DEV="$(xcrun simctl list devices available | grep -m1 'Pro Max' | grep -oE '[0-9A-F-]{36}')"
xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl bootstatus "$DEV" -b >/dev/null
shot() { xcrun simctl io "$DEV" screenshot "$OUT/$1.png" >/dev/null 2>&1 && echo "$OUT/$1.png"; }

if [[ "${1:-}" == lock ]]; then
    shot 1-lock-screen
    exit
fi

cp scripts/screenshot-data.swift "$BUILD/main.swift"  # top-level code needs main.swift
xcrun swiftc -o "$BUILD/screenshot-data" Packages/TodayCore/Sources/TodayCore/*.swift "$BUILD/main.swift"
"$BUILD/screenshot-data" "$BUILD/state.json"

xcodebuild -project Today.xcodeproj -scheme Today -destination "id=$DEV" -derivedDataPath "$BUILD/dd" -quiet build
xcrun simctl install "$DEV" "$BUILD/dd/Build/Products/Debug-iphonesimulator/Today.app"
DATA="$(xcrun simctl get_app_container "$DEV" $BUNDLE data)/Library/Application Support/Today"
xcrun simctl terminate "$DEV" $BUNDLE 2>/dev/null || true
mkdir -p "$DATA" && cp "$BUILD/state.json" "$DATA/state.json"
xcrun simctl status_bar "$DEV" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3

# Launch arguments are debug-only (see TodayView); the view settles after a few seconds.
open_on() {
    xcrun simctl terminate "$DEV" $BUNDLE 2>/dev/null || true
    xcrun simctl launch "$DEV" $BUNDLE "$@" >/dev/null
    sleep 6
}
open_on;                          shot 2-today-list
open_on -screenshotDayOffset 3;   shot 3-planned-day
open_on -screenshotDaysAgo 2;     shot 4-past-day
open_on
echo "DoDo is open with today's card. Lock the simulator in Device Hub, then run: scripts/screenshots.sh lock"
