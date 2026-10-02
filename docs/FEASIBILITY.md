# Feasibility note: daily Lock Screen renewal

Researched 2026-10-02 against Apple's documentation (JSON doc endpoints, so the quotes are exact).
The iOS 26 SDK was not available on this Mac yet (only Xcode 16.2 / iOS 18.2 was installed), so iOS 26 APIs are **documented but not compiled or device-tested**. Items are marked:

- **Verified:** quoted from Apple.
- **Inferred:** my reading of the docs.
- **Device check:** has to be confirmed on the iPhone.

## Verified facts

| Topic | Fact | Source |
|---|---|---|
| Scheduled start | `Activity.request(attributes:content:pushType:style:alertConfiguration:start:)`, iOS 26.0, synchronous `throws`. The `startDate:` variant is deprecated. | [activity/request(…start:)](https://developer.apple.com/documentation/activitykit/activity/request(attributes:content:pushtype:style:alertconfiguration:start:)) |
| Starts unattended | "The system starts the Live Activity at the specified date, even if the app is in the background." | same |
| Pending state | "The ActivityState for a scheduled but not yet started Live Activity is `pending`." | same, [ActivityState](https://developer.apple.com/documentation/activitykit/activitystate) |
| Limits | "The system limits the number of simultaneous ongoing Live Activities. Scheduled Live Activities count towards this limit." No number is given. | same |
| Who may start | Only from the foreground, "unless you adopt AppIntents and start the Live Activity using a LiveActivityIntent". Background `request` fails with `ActivityAuthorizationError.visibility`. | same, [ActivityAuthorizationError](https://developer.apple.com/documentation/activitykit/activityauthorizationerror) |
| Duration | Active for up to 8 hours, then ended by the system. It may stay on the Lock Screen up to 4 more hours (12 hours maximum). | [Displaying live data](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) |
| Payload | Static plus dynamic data must stay under 4 KB. | same |
| Intent process | "If you adopt the `LiveActivityIntent`… the system runs the app intent in the app's process." | [Adding interactivity](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities) |
| Locked device | The intent `authenticationPolicy` default `.alwaysAllowed` runs "including when the device is locked". | AppIntent docs |
| Free team | App Groups and Background Modes are allowed. Push Notifications, iCloud and Time Sensitive notifications are not. Profiles expire after 7 days; limit of 3 apps per device and 10 App IDs per 7 days. | [Supported capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios), [Compare memberships](https://developer.apple.com/support/compare-memberships/) |
| Info.plist | `NSSupportsLiveActivities = YES` on the app. Frequent-updates is push-only, so it is not needed. | Displaying live data |

**Not documented (device checks):**

- How far ahead a start date may be.
- The exact pending-activity limit.
- Whether `update` and `end` work on a *pending* activity.
- Whether pending activities appear in `Activity.activities`.

## Design decisions that follow

- **No App Group, no entitlements.** The Lock Screen checkbox runs `CompleteTaskIntent: LiveActivityIntent` in the **app process**, so the app owns the only data file (`Application Support/Today/state.json`). The widget extension only renders the content Apple hands it and never reads storage.
  - Shared `UserDefaults` is not used anywhere.
  - The file uses `completeUntilFirstUserAuthentication` protection, so a locked phone (after the first unlock since boot) can still save a completion.
- **One write path.** UI and intents both go `TodayStore` → `TaskRepository` (an actor) → save → `LiveActivityCoordinator.sync`. Saves happen before activity updates.

## Chosen renewal strategy: rolling noon schedule

Every sync runs on:

- app foreground
- any edit
- every Lock Screen completion, since a LiveActivityIntent may schedule

Each sync does three things:

1. **Today.** If a card for today is running, update it. If not, and we may start (foreground or intent), start one now and cancel today's pending noon card. This is the "opened before noon" case.
2. **Next 3 days.** Make sure each has exactly one pending card starting at **12:00 local time**, holding that day's **projected** content: fresh recurring occurrences, one-offs with their carry age on that day, and nothing completed.
   - Days with no tasks get no card.
   - Pending cards are updated after every change.
   - If noon moved because of a time-zone change, the card is rescheduled.
   - The projection is proven equal to the real reconciled state in `SnapshotTests.futureProjection`.
3. **Cleanup.** Cards from earlier days are ended, and duplicate cards for one day are collapsed to one.

Three days is a conservative guess because the pending limit is undocumented. If a capacity error appears, the window stops there and today's card takes priority, ending the furthest pending card.

## What this coverage honestly is

| Situation | What you see |
|---|---|
| App opened at 08:00 | Card from 08:00 to about 16:00 (8 h active). It may linger, frozen, until about 20:00. Open the app again for a fresh 8 h. |
| App not opened that day (within the window) | Card appears at **noon by itself**, stays active until about 20:00 and may linger until midnight. |
| Overnight | **No card** from when the last one leaves until noon or the next app open. This is a platform limit; a scheduled start does not remove the 8 h cap. |
| App not opened for more than 3 days and no Lock Screen taps | Pre-scheduled cards run out after day 3. Nothing appears until the app is opened. |
| Lock Screen completion on a day without opening the app | Completing from the Lock Screen also extends the window by a day (intent runs in the app process). **Device check.** |
| Signing expired (7 days) | The app will not launch, so Lock Screen taps cannot run. Already-scheduled cards may still start (**device check**). Rebuild weekly. |

**Maximum verified unattended coverage:** none yet, because device testing is still pending.

**Designed coverage:** today plus 3 more noon cards without opening the app. The window extends every time the app is opened or a task is completed from the Lock Screen.

**This is not indefinite self-renewal.**

### Fallbacks, in order

1. **Shortcuts automation (optional, user-created).** `ShowTodayOnLockScreenIntent` is a LiveActivityIntent exposed as an App Shortcut. Set it up under Automation → Time of Day → Run Immediately.
   - It would keep renewing even if the app is never opened.
   - Community reports say time automations sometimes don't fire, or fail while locked. **Device check.** I did not create any automation.
2. **Reminder notification:** not built. It needs a tap, so it would be a degraded substitute.
3. **ActivityKit push:** needs a paid membership (push isn't available on a free team), APNs credentials and a server. Out of scope.

## Physical-device checks still to do

Use **Settings → Debug** (Debug builds only) to schedule a test card 1 or 3 minutes ahead.

1. Schedule a test card, background the app, lock the phone. Does it appear without reopening?
2. "List activities": does a pending card appear in the list? (This decides whether we can cancel or update it.)
3. Open the app the morning after a noon card was scheduled. Is the noon card cancelled, with no duplicate at noon?
4. Edit a task, then wait for tomorrow's noon card. Does it show the edited content?
5. Tap the checkbox on the locked phone (Face ID not yet matched). Does it complete, or does it ask for an unlock?
6. Force quit, then tap a Lock Screen checkbox. Does it still complete? Reboot, then do the same before the first unlock.
7. Leave the phone unopened for 2 or more days. Do noon cards appear each day with correct carry labels?
8. Turn Live Activities off in iOS Settings → Today. Settings should show "turned off" with an Open Settings button.
9. Swipe today's card away, then reopen the app. It should not come back today, and "Show Today's Card Again" should restore it.
