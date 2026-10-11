import ActivityKit
import Foundation
import TodayCore

/// Plain-language Lock Screen status for the settings sheet.
enum LockScreenStatus: Equatable {
    case off
    /// Live Activities are turned off for this app in iOS Settings.
    case unavailable
    case showing
    case scheduled(Date)
    case dismissedToday
    case doneToday
    case nothingScheduled
}

struct LockScreenReport: Equatable {
    var status: LockScreenStatus = .off
    /// Last future day with a scheduled noon card (or verified to need none).
    var coveredThrough: LocalDay?
    var lastError: String?
}

/// Keeps the system's Live Activities in line with the persisted task state.
///
/// Strategy (see docs/FEASIBILITY.md):
/// - Today: when the app is in use (or a LiveActivityIntent runs), make sure
///   exactly one card for today is running and up to date. A running card
///   makes today's pre-scheduled noon card redundant, so that one is cancelled.
/// - Future: pre-schedule one card at noon for each of the next
///   `futureDays` days using the iOS 26 scheduled-start request, each with
///   that day's *projected* content (fresh recurring tasks, carried one-offs).
///   The system starts those without running the app. Every sync rewrites
///   them, so edits and completions keep the pending snapshots current.
/// - Activities are reconciled against `Activity.activities`, never just
///   against cached ids.
@MainActor
final class LiveActivityCoordinator {
    typealias TodayActivity = Activity<TodayActivityAttributes>

    static let noonHour = 12
    /// Days after today that get a pre-scheduled noon card. Scheduled cards
    /// count toward the system's undocumented limit of simultaneous Live
    /// Activities, so this stays small; on-device testing may justify more.
    static let futureDays = 3
    /// ActivityKit ends a Live Activity after eight hours active.
    static let activeLimit: TimeInterval = 8 * 3600
    /// How long the "All done" card lingers before it is dismissed.
    static let allDoneLinger: TimeInterval = 8

    private var observed = Set<String>()
    /// Called when the system reports an activity state change while the app runs.
    var onSystemChange: (() -> Void)?

    /// Brings Live Activities in line with `state`.
    /// - Parameter canStart: true in the foreground or inside a LiveActivityIntent,
    ///   the only contexts where ActivityKit allows starting or scheduling.
    /// - Returns: updated Lock Screen bookkeeping to persist, and a status report.
    func sync(state: TodayState, context: DayContext, canStart: Bool) async -> (LockScreenPreferences, LockScreenReport) {
        var prefs = state.lockScreen
        var report = LockScreenReport()
        let today = context.today
        let now = context.now
        let tz = context.timeZone

        let all = TodayActivity.activities
        all.forEach(observe)
        let live = all.filter { Self.isLive($0.activityState) && !$0.attributes.isTest }

        // Cards from earlier days are always removed, test cards included.
        for a in all where Self.isLive(a.activityState) && (a.attributes.localDay ?? today) < today {
            await a.end(nil, dismissalPolicy: .immediate)
        }

        guard prefs.enabled else {
            for a in live { await a.end(nil, dismissalPolicy: .immediate) }
            if !live.isEmpty { prefs.endedByAppDay = today }
            report.status = .off
            return (prefs, report)
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            report.status = .unavailable
            return (prefs, report)
        }

        // MARK: Today

        let snapshot = state.snapshot(for: today, today: today)
        let todays = all.filter { $0.attributes.localDay == today && !$0.attributes.isTest }
        var running = todays.filter { $0.activityState == .active || $0.activityState == .stale }
        let pendingToday = todays.filter { $0.activityState == .pending }

        // Never show two cards for one day; keep the oldest.
        for extra in running.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        running = Array(running.prefix(1))

        if let card = running.first {
            if prefs.cardDay != today {
                prefs.cardDay = today
                prefs.cardStartedAt = card.attributes.scheduledStart ?? now
            }
        } else if prefs.cardDay == today, prefs.endedByAppDay != today, let started = prefs.cardStartedAt {
            // Today's card ended without the app ending it. Before the 8-hour
            // limit that can only be the user swiping it away: respect that.
            if now.timeIntervalSince(started) < Self.activeLimit - 300 {
                prefs.dismissedDay = today
            }
            prefs.cardDay = nil
            prefs.cardStartedAt = nil
        }

        // Start a card only for real tasks; a running card may stay up to
        // offer the long-term list, and ends only when nothing is left.
        let wantsCard = snapshot.hasTasks && prefs.dismissedDay != today

        if let card = running.first {
            if snapshot.isAllDone {
                await card.end(content(snapshot, tz), dismissalPolicy: .after(now.addingTimeInterval(Self.allDoneLinger)))
                prefs.endedByAppDay = today
                prefs.cardDay = nil
                prefs.cardStartedAt = nil
            } else if card.content.state != snapshot {
                await card.update(content(snapshot, tz))
            }
            for p in pendingToday { await p.end(nil, dismissalPolicy: .immediate) }
        } else if wantsCard && canStart {
            // Opened before noon (or after the previous card expired): start
            // now and drop today's noon fallback so it cannot duplicate.
            for p in pendingToday { await p.end(nil, dismissalPolicy: .immediate) }
            for old in todays where old.activityState == .ended { await old.end(nil, dismissalPolicy: .immediate) }
            if await startToday(snapshot, today: today, tz: tz, report: &report) {
                prefs.cardDay = today
                prefs.cardStartedAt = now
                prefs.endedByAppDay = nil
                running = TodayActivity.activities.filter { $0.attributes.localDay == today && $0.activityState == .active }
            }
        } else if !wantsCard || !prefs.autoNoonStart {
            // Nothing to show, dismissed, or noon start turned off.
            for p in pendingToday { await p.end(nil, dismissalPolicy: .immediate) }
        } else {
            for p in pendingToday where p.content.state != snapshot { await p.update(content(snapshot, tz)) }
        }

        // MARK: Future noon cards

        let future = live.filter { ($0.attributes.localDay ?? today) > today }
        if prefs.autoNoonStart {
            for offset in 1...Self.futureDays {
                let day = today.adding(days: offset)
                let snap = state.snapshot(for: day, today: today)
                let start = day.date(hour: Self.noonHour, in: tz)
                var existing = future.filter { $0.attributes.localDay == day }
                for extra in existing.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
                existing = Array(existing.prefix(1))

                if !snap.hasTasks {
                    // Suppress empty cards on days with nothing to do.
                    for e in existing { await e.end(nil, dismissalPolicy: .immediate) }
                    report.coveredThrough = day
                    continue
                }
                if let e = existing.first {
                    let drift = abs((e.attributes.scheduledStart ?? start).timeIntervalSince(start))
                    if drift < 60 {
                        if e.content.state != snap { await e.update(content(snap, tz)) }
                        report.coveredThrough = day
                        continue
                    }
                    // Time zone changed: noon moved. Reschedule.
                    await e.end(nil, dismissalPolicy: .immediate)
                }
                guard canStart else { break }
                guard schedule(snap, day: day, start: start, tz: tz, report: &report) else { break }
                report.coveredThrough = day
            }
            let horizon = today.adding(days: Self.futureDays)
            for e in future where (e.attributes.localDay ?? today) > horizon {
                await e.end(nil, dismissalPolicy: .immediate)
            }
        } else {
            for e in future { await e.end(nil, dismissalPolicy: .immediate) }
        }

        // MARK: Status

        if !running.isEmpty && !snapshot.isAllDone {
            report.status = .showing
        } else if prefs.dismissedDay == today {
            report.status = .dismissedToday
        } else if !snapshot.hasTasks && prefs.endedByAppDay == today {
            report.status = .doneToday
        } else if let next = TodayActivity.activities
            .filter({ $0.activityState == .pending && !$0.attributes.isTest })
            .compactMap(\.attributes.scheduledStart).min() {
            report.status = .scheduled(next)
        } else {
            report.status = snapshot.hasTasks ? .nothingScheduled : .doneToday
        }
        return (prefs, report)
    }

    // MARK: - Requests

    private func startToday(_ snapshot: ActivitySnapshot, today: LocalDay, tz: TimeZone,
                            report: inout LockScreenReport) async -> Bool {
        let attributes = TodayActivityAttributes(day: today.description, scheduledStart: nil, isTest: false)
        for attempt in 0..<2 {
            do {
                let activity = try TodayActivity.request(attributes: attributes, content: content(snapshot, tz), pushType: nil)
                observe(activity)
                return true
            } catch let error as ActivityAuthorizationError where attempt == 0 && Self.isCapacity(error) {
                // Today's card matters more than the furthest pre-scheduled one.
                guard await freeOneSlot(today: today) else {
                    report.lastError = Self.describe(error)
                    return false
                }
            } catch {
                report.lastError = Self.describe(error)
                return false
            }
        }
        return false
    }

    private func schedule(_ snapshot: ActivitySnapshot, day: LocalDay, start: Date, tz: TimeZone,
                          report: inout LockScreenReport) -> Bool {
        let attributes = TodayActivityAttributes(day: day.description, scheduledStart: start, isTest: false)
        do {
            let activity = try TodayActivity.request(
                attributes: attributes,
                content: content(snapshot, tz),
                pushType: nil,
                style: .standard,
                alertConfiguration: alert(for: snapshot),
                start: start
            )
            observe(activity)
            return true
        } catch {
            // Capacity limits end the rolling window here; earlier days stay scheduled.
            if let e = error as? ActivityAuthorizationError, Self.isCapacity(e) { return false }
            report.lastError = Self.describe(error)
            return false
        }
    }

    private func freeOneSlot(today: LocalDay) async -> Bool {
        let furthest = TodayActivity.activities
            .filter { $0.activityState == .pending && ($0.attributes.localDay ?? today) > today }
            .max { ($0.attributes.localDay ?? today) < ($1.attributes.localDay ?? today) }
        guard let furthest else { return false }
        await furthest.end(nil, dismissalPolicy: .immediate)
        return true
    }

    private func content(_ snapshot: ActivitySnapshot, _ tz: TimeZone) -> ActivityContent<ActivitySnapshot> {
        // Stale at the next midnight: an old day's tasks should look old.
        ActivityContent(state: snapshot, staleDate: snapshot.day.adding(days: 1).date(in: tz), relevanceScore: 100)
    }

    private func alert(for snapshot: ActivitySnapshot) -> AlertConfiguration {
        let count = snapshot.rows.count + snapshot.moreCount
        return AlertConfiguration(
            title: "Today",
            body: "\(count) \(count == 1 ? "task" : "tasks") for today",
            sound: .default
        )
    }

    private func observe(_ activity: TodayActivity) {
        guard observed.insert(activity.id).inserted else { return }
        Task { [weak self] in
            for await _ in activity.activityStateUpdates {
                self?.onSystemChange?()
            }
        }
    }

    /// Immediate feedback for a tap on the card: redraw today's card with
    /// that row ticked, before any storage work. The following `sync` then
    /// removes the row, which the card animates as a slide-up.
    /// - Returns: true if a card was redrawn.
    func showTicked(_ ref: String, today: LocalDay, tz: TimeZone) async -> Bool {
        let card = TodayActivity.activities.first {
            $0.attributes.localDay == today && !$0.attributes.isTest
                && ($0.activityState == .active || $0.activityState == .stale)
        }
        guard let card, let ticked = card.content.state.markingDone(ref) else { return false }
        await card.update(content(ticked, tz))
        return true
    }

    // MARK: - Helpers

    static func isLive(_ state: ActivityState) -> Bool {
        switch state {
        case .active, .stale, .pending: true
        case .ended, .dismissed: false
        @unknown default: false
        }
    }

    static func isCapacity(_ error: ActivityAuthorizationError) -> Bool {
        switch error {
        case .targetMaximumExceeded, .globalMaximumExceeded: true
        default: false
        }
    }

    static func describe(_ error: Error) -> String {
        guard let e = error as? ActivityAuthorizationError else { return error.localizedDescription }
        switch e {
        case .denied: return "Live Activities are turned off for Today in Settings."
        case .visibility: return "The card can only be started while Today is open."
        case .targetMaximumExceeded, .globalMaximumExceeded: return "Too many Live Activities are running right now."
        case .attributesTooLarge: return "The card's content was too large."
        default: return "The Lock Screen card could not be started (\(e))."
        }
    }

    // MARK: - DEBUG experiments

    #if DEBUG
    /// Schedules a throwaway card `seconds` from now with today's content, to
    /// test scheduled starts while the app is backgrounded and the phone locked.
    func scheduleTestCard(in seconds: TimeInterval, state: TodayState, context: DayContext) -> String {
        let today = context.today
        let start = context.now.addingTimeInterval(seconds)
        let attributes = TodayActivityAttributes(day: today.description, scheduledStart: start, isTest: true)
        do {
            let a = try TodayActivity.request(
                attributes: attributes,
                content: content(state.snapshot(for: today, today: today), context.timeZone),
                pushType: nil, style: .standard,
                alertConfiguration: AlertConfiguration(title: "Today (test)", body: "Scheduled test card", sound: .default),
                start: start)
            observe(a)
            return "Scheduled \(a.id.prefix(8)) for \(start.formatted(date: .omitted, time: .standard))"
        } catch {
            return "Failed: \(Self.describe(error))"
        }
    }

    func endTestCards() async {
        for a in TodayActivity.activities where a.attributes.isTest {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    func debugDescription() -> String {
        let rows = TodayActivity.activities.map { a in
            let start = a.attributes.scheduledStart.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "now"
            return "\(a.attributes.day)\(a.attributes.isTest ? " test" : "") · \(a.activityState) · start \(start) · \(a.content.state.rows.count) rows"
        }
        return rows.isEmpty ? "No activities" : rows.joined(separator: "\n")
    }
    #endif
}
