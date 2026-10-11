import Foundation
import Observation
import SwiftUI
import TodayCore
import UIKit

/// The app's single entry point for reading and changing tasks. The UI and
/// the Lock Screen intents both route through here, so every mutation is
/// reconciled, saved, and only then published to the Live Activity.
@MainActor
@Observable
final class TodayStore {
    static let shared = TodayStore()

    private(set) var today: LocalDay
    private(set) var active: [TaskRow] = []
    private(set) var completed: [TaskRow] = []
    private(set) var longTerm: [TaskRow] = []
    /// The full reconciled state, for history and planning views.
    private(set) var state = TodayState()
    private(set) var lockScreen = LockScreenPreferences()
    private(set) var lockReport = LockScreenReport()
    /// A load or save failure the user should see. Data is never wiped to recover.
    private(set) var storageError: String?

    @ObservationIgnored private let repository: TaskRepository
    @ObservationIgnored private let coordinator = LiveActivityCoordinator()
    /// Set when durable storage could not be opened; shown until relaunch.
    @ObservationIgnored private var storageWarning: String?
    @ObservationIgnored private var hasLoaded = false

    init(repository: TaskRepository? = nil) {
        var fallbackError: String?
        let storage: StateStorage
        do {
            storage = try FileStateStorage.defaultLocation()
        } catch {
            storage = InMemoryStorage()
            fallbackError = "Couldn't open storage (\(error.localizedDescription)). Changes won't be saved."
        }
        self.repository = repository ?? TaskRepository(storage: storage)
        self.today = LocalDay(Date(), in: .current)
        self.storageWarning = fallbackError
        self.storageError = fallbackError
        coordinator.onSystemChange = { [weak self] in
            Task { await self?.refresh(canStart: false) }
        }
    }

    /// Today's daily tasks, done or not (goals are counted separately).
    var totalCount: Int { active.count + completed.filter { !$0.isLongTerm }.count }
    var dailyDoneCount: Int { completed.filter { !$0.isLongTerm }.count }

    // MARK: - Other days

    func record(for day: LocalDay) -> DayRecord? { state.record(for: day) }

    /// Tasks planned for a future day (editable, reorderable).
    func planned(on day: LocalDay) -> [TaskRow] { state.plannedRows(on: day) }

    /// Everything else that will be on a future day's list: recurring tasks
    /// and unfinished tasks carried that far.
    func alsoOn(_ day: LocalDay) -> [TaskRow] {
        let planned = Set(state.plannedRows(on: day).map(\.ref))
        return state.projectedRows(on: day, today: today).filter { !planned.contains($0.ref) }
    }

    func placement(of id: UUID) -> TaskPlacement? { state.placement(of: id, today: today) }

    // MARK: - Lifecycle

    /// Foreground entry, day change, time-zone change: reconcile and publish.
    func refresh(canStart: Bool = true) async {
        do {
            let (state, context) = try await repository.current()
            apply(state, context)
            await publish(state, context, canStart: canStart && isForeground)
        } catch {
            storageError = "Couldn't read your tasks: \(error.localizedDescription). Nothing was deleted."
        }
    }

    /// The system's time zone or day changed; drop cached "today" and recompute.
    func timeZoneChanged() async {
        NSTimeZone.resetSystemTimeZone()
        await refresh()
    }

    private var isForeground: Bool {
        UIApplication.shared.applicationState != .background
    }

    // MARK: - Task mutations

    @discardableResult
    func add(title: String, placement: TaskPlacement? = nil) async -> Bool {
        await mutate { s, c in try s.addTask(title: title, placement: placement ?? .day(c.today), context: c) }
    }

    @discardableResult
    func edit(orderID: UUID, title: String, placement: TaskPlacement) async -> Bool {
        await mutate { s, c in try s.editTask(id: orderID, title: title, placement: placement, context: c) }
    }

    /// Moves a goal or planned task to the top of today's list.
    func doToday(_ id: UUID) async {
        await mutate { s, c in try s.doToday(id, context: c) }
    }

    func complete(_ ref: TaskRef) async {
        await mutate { s, c in s.complete(ref, context: c) }
    }

    func uncomplete(_ ref: TaskRef) async {
        await mutate { s, c in s.uncomplete(ref, context: c) }
    }

    /// Deletes a task, a whole series, or a goal.
    func delete(_ ref: TaskRef) async {
        await mutate { s, c in s.delete(ref, context: c) }
    }

    func skipToday(seriesID: UUID) async {
        await mutate { s, c in s.skipToday(seriesID: seriesID, context: c) }
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        // Update the list immediately so the drag doesn't snap back.
        var rows = active
        rows.move(fromOffsets: fromOffsets, toOffset: toOffset)
        active = rows
        Task { await mutate { s, c in s.moveActive(fromOffsets: fromOffsets, toOffset: toOffset, context: c) } }
    }

    func moveLongTerm(fromOffsets: IndexSet, toOffset: Int) {
        var rows = longTerm
        rows.move(fromOffsets: fromOffsets, toOffset: toOffset)
        longTerm = rows
        Task { await mutate { s, c in s.moveLongTerm(fromOffsets: fromOffsets, toOffset: toOffset, context: c) } }
    }

    func movePlanned(on day: LocalDay, fromOffsets: IndexSet, toOffset: Int) {
        Task { await mutate { s, c in s.movePlanned(on: day, fromOffsets: fromOffsets, toOffset: toOffset, context: c) } }
    }

    // MARK: - Lock Screen intents (run in the app process, possibly in the background)

    func completeFromLockScreen(refString: String) async {
        guard let ref = TaskRef(string: refString) else { return }
        let ticked = Date()
        let showedTick = await coordinator.showTicked(refString, today: LocalDay(ticked, in: .current), tz: .current)
        do {
            let r = try await repository.mutate { s, c -> Bool in
                s.complete(ref, context: c)
                return true
            }
            apply(r.state, r.context)
            // Let the tick register before the row slides away.
            if showedTick {
                let wait = Self.tickHold - Date().timeIntervalSince(ticked)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
            // canStart: LiveActivityIntent is allowed to start/schedule activities.
            await publish(r.state, r.context, canStart: true)
        } catch {
            storageError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// How long a ticked row stays on the card before it is removed.
    private static let tickHold: TimeInterval = 0.6

    /// "See long-term list" on the finished card: show goals for the rest of today.
    func showLongTermOnLockScreen() async {
        await mutate(canStart: true) { s, c in s.lockScreen.longTermDay = c.today }
    }

    func startTodayFromIntent() async {
        do {
            let r = try await repository.mutate { s, c in
                // An explicit request overrides an earlier swipe-away today.
                if s.lockScreen.dismissedDay == c.today { s.lockScreen.dismissedDay = nil }
            }
            apply(r.state, r.context)
            await publish(r.state, r.context, canStart: true)
        } catch {
            storageError = error.localizedDescription
        }
    }

    // MARK: - Lock Screen settings

    func setLockScreenEnabled(_ enabled: Bool) async {
        await mutate { s, _ in
            s.lockScreen.enabled = enabled
            if enabled { s.lockScreen.privacyAcknowledged = true }
        }
    }

    func setAutoNoonStart(_ on: Bool) async {
        await mutate { s, _ in s.lockScreen.autoNoonStart = on }
    }

    /// Recovery action after the user swiped today's card away.
    func showTodayAgain() async {
        await mutate { s, c in
            if s.lockScreen.dismissedDay == c.today { s.lockScreen.dismissedDay = nil }
        }
    }

    // MARK: - Plumbing

    @discardableResult
    private func mutate(canStart: Bool? = nil, _ body: @escaping (inout TodayState, DayContext) throws -> Void) async -> Bool {
        do {
            let (state, context, _) = try await repository.mutate { s, c -> Bool in
                try body(&s, c)
                return true
            }
            apply(state, context)
            await publish(state, context, canStart: canStart ?? isForeground)
            return true
        } catch TaskError.emptyTitle, TaskError.invalidRecurrence, TaskError.notFound {
            return false
        } catch {
            storageError = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    private func apply(_ state: TodayState, _ context: DayContext) {
        // Changes land after an await, outside any view transaction, so the
        // list would snap between sizes. Animate them here instead, except
        // for the first load, which should just appear.
        withAnimation(hasLoaded ? .smooth(duration: 0.35) : nil) {
            today = context.today
            active = state.activeRows(today: context.today)
            completed = state.completedRows(today: context.today)
            longTerm = state.longTermRows()
            self.state = state
            lockScreen = state.lockScreen
            storageError = storageWarning
        }
        hasLoaded = true
    }

    /// Saved state first, then the Live Activity. Bookkeeping the coordinator
    /// learns (dismissal, card start) is written back field by field.
    private func publish(_ state: TodayState, _ context: DayContext, canStart: Bool) async {
        let (prefs, report) = await coordinator.sync(state: state, context: context, canStart: canStart)
        lockReport = report
        guard prefs != state.lockScreen else { return }
        if let saved = try? await repository.mutate({ s, _ -> Bool in
            s.lockScreen.dismissedDay = prefs.dismissedDay
            s.lockScreen.endedByAppDay = prefs.endedByAppDay
            s.lockScreen.cardDay = prefs.cardDay
            s.lockScreen.cardStartedAt = prefs.cardStartedAt
            return true
        }) {
            apply(saved.state, saved.context)
        }
    }

    // MARK: - DEBUG

    #if DEBUG
    func debugScheduleTestCard(in seconds: TimeInterval) async -> String {
        guard let current = try? await repository.current() else { return "No state" }
        return coordinator.scheduleTestCard(in: seconds, state: current.state, context: current.context)
    }

    func debugEndTestCards() async { await coordinator.endTestCards() }

    func debugActivities() -> String { coordinator.debugDescription() }
    #endif
}
