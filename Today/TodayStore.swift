import Foundation
import Observation
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
    private(set) var lockScreen = LockScreenPreferences()
    private(set) var lockReport = LockScreenReport()
    /// A load or save failure the user should see. Data is never wiped to recover.
    private(set) var storageError: String?

    @ObservationIgnored private let repository: TaskRepository
    @ObservationIgnored private let coordinator = LiveActivityCoordinator()
    /// Set when durable storage could not be opened; shown until relaunch.
    @ObservationIgnored private var storageWarning: String?

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

    var totalCount: Int { active.count + completed.count }

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
    func add(title: String, recurrence: Recurrence? = nil) async -> Bool {
        await mutate { s, c in try s.addTask(title: title, recurrence: recurrence, context: c) }
    }

    @discardableResult
    func edit(orderID: UUID, title: String, recurrence: Recurrence?) async -> Bool {
        await mutate { s, c in try s.editTask(id: orderID, title: title, recurrence: recurrence, context: c) }
    }

    func complete(_ ref: TaskRef) async {
        await mutate { s, c in s.complete(ref, context: c) }
    }

    func uncomplete(_ ref: TaskRef) async {
        await mutate { s, c in s.uncomplete(ref, context: c) }
    }

    func delete(_ ref: TaskRef) async {
        await mutate { s, c in
            switch ref {
            case .oneOff(let id): s.deleteOneOff(id, context: c)
            case .occurrence(let id, _): s.deleteSeries(id, context: c)
            }
        }
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

    func series(_ id: UUID) async -> RecurringSeries? {
        try? await repository.current().state.series(id)
    }

    // MARK: - Lock Screen intents (run in the app process, possibly in the background)

    func completeFromLockScreen(refString: String) async {
        guard let ref = TaskRef(string: refString) else { return }
        // canStart: LiveActivityIntent is allowed to start/schedule activities.
        await mutate(canStart: true) { s, c in s.complete(ref, context: c) }
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
        today = context.today
        active = state.activeRows(today: context.today)
        completed = state.completedRows(today: context.today)
        lockScreen = state.lockScreen
        storageError = storageWarning
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
