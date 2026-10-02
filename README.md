# Today

A personal iPhone checklist. It keeps your next three tasks on the Lock Screen as a Live Activity, and you can tick tasks off from the Lock Screen. It targets iOS 26.1 (iPhone 14) and installs from Xcode with a free Personal Team.

See [docs/FEASIBILITY.md](docs/FEASIBILITY.md) for:

- what the Lock Screen card can and can't do
- daily renewal coverage and gaps
- the checks still to run on a real device

## Layout

```
Packages/TodayCore/   Domain layer (pure Foundation) and its tests
  LocalDay            calendar-day math (DST- and time-zone-safe)
  Models, TaskEngine  one-off tasks, recurring series and occurrences, reconcile, carryover, reorder
  ActivitySnapshot    the ≤3-row Lock Screen payload, including future-day projection
  TaskRepository      actor and atomic JSON file; one write path
Shared/               Compiled into app and widget: activity attributes and intents
Today/                App: SwiftUI screens, TodayStore, LiveActivityCoordinator
TodayWidget/          Live Activity UI (Lock Screen card)
project.yml           XcodeGen spec; Today.xcodeproj is generated from it
scripts/test-core.sh  Runs the domain tests with plain swiftc
```

## One-time Mac setup

1. **Install Xcode 26.1 or later** from the Mac App Store. The Xcode 16.2 currently on this Mac:
   - can't build for iOS 26
   - fails to load on macOS 26
2. Open Xcode once. Accept the license and let it install the iOS platform.
3. Optionally, make it the default for command-line tools:
   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   ```
4. In **Xcode → Settings → Accounts**, add your Apple ID. A free account creates a "Personal Team".

## Signing and bundle ID

1. Open `Today.xcodeproj`.
2. For **both** the `Today` and `TodayWidgetExtension` targets, go to **Signing & Capabilities** and set **Team = (your name) (Personal Team)**.
3. The bundle IDs are `com.drewbomar.today` and `com.drewbomar.today.widget`.
4. If Xcode says an ID is unavailable, change both, keeping the widget ID as `<app id>.widget`. Then keep those IDs forever: the same IDs are what make weekly reinstalls keep your data.

To avoid redoing this after regenerating the project, put your team ID in `project.yml` (`DEVELOPMENT_TEAM`). Then run `xcodegen generate`.

No entitlements or App Groups are needed.

## First install on the iPhone

1. Connect the iPhone by cable and tap **Trust**.
2. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode**, then restart. That menu appears after Xcode has seen the phone once.
3. In Xcode, pick your iPhone as the run destination and press **⌘R**.
4. The first launch is blocked until you trust yourself: **Settings → General → VPN & Device Management → (your Apple ID) → Trust**. Then run again.
5. In the app, tap the gear and turn on **Show on Lock Screen**. You'll be told once that task titles will be visible while the phone is locked.
6. Make sure **Settings → Today → Live Activities** is on.

## Weekly renewal (free signing expires after 7 days)

1. Connect the iPhone and open `Today.xcodeproj`.
2. Press **⌘R**.

This installs over the existing app, so tasks and settings are kept.

- **Do not delete the app to renew.** Deleting the app deletes its data, which lives only on the phone.
- Keep the same team and bundle IDs.
- If the profile has already expired, the app won't open until you rebuild. Nothing is lost.

## Building and testing from the command line

```sh
# Domain tests (works even with just Command Line Tools)
scripts/test-core.sh

# With Xcode 26 selected (or prefix commands with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer)
xcodebuild -project Today.xcodeproj -scheme Today -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Today.xcodeproj -scheme Today -destination 'platform=iOS Simulator,name=iPhone 17' test
swift test --package-path Packages/TodayCore

# After changing project.yml or adding files
xcodegen generate
```

## Using it

- **Add tasks** with the "Add a task" field. They are added at the bottom.
- **Drag** to reorder. The top three unfinished tasks are what the Lock Screen shows.
- **Tap** a task to edit its title or repeat setting (Never / Every day / Selected days).
- **Recurring tasks:** a fresh copy appears on each scheduled day, and missed days don't pile up. Deleting one asks whether to delete the series or skip today.
- **Unfinished one-offs** carry forward with an amber "From yesterday" or "N days carried" label.
- **Completed tasks** go to the collapsible Completed section. Tap the check there to undo.
- **Lock Screen:** only the circle completes a task. Tapping anywhere else opens the app.
- **Your data** is a JSON file in the app's container, included in device backups. Nothing leaves the phone.
