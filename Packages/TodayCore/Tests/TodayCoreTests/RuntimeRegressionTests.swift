import Foundation
import Testing
@testable import TodayCore

@Suite struct RuntimeRegressionTests {
    @Test func malformedStoredDaysAreRejectedWithoutOverflow() {
        for raw in ["2026-02-30", "2025-02-29", "2026-04-31", "2026-extra-10-02",
                    "2026--10-02", "9223372036854775807-10-02", "0000-01-01", "2026-1-2"] {
            #expect(LocalDay(string: raw) == nil)
        }
        #expect(LocalDay(string: "2024-02-29")?.description == "2024-02-29")
        #expect(LocalDay(string: "2026-10-02")?.description == "2026-10-02")
    }

    @MainActor final class PublicationProbe {
        var saved = 0
        var published: [Int] = []

        func publish(using gate: OperationGate) async {
            await gate.acquire()
            defer { gate.release() }
            saved += 1
            let snapshot = saved
            // Simulate ActivityKit suspending while another refresh,
            // completion or system-state notification arrives.
            for _ in 0..<5 { await Task.yield() }
            #expect(saved == snapshot)
            published.append(snapshot)
        }
    }

    @Test @MainActor func publicationsCannotOvertakeSavedState() async {
        let gate = OperationGate()
        let probe = PublicationProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask { await probe.publish(using: gate) }
            }
        }
        #expect(probe.published == Array(1...30))
    }

    @Test @MainActor func cancelledActionStillReleasesGate() async {
        let gate = OperationGate()
        await gate.acquire()
        let action = Task { @MainActor in
            await gate.acquire()
            defer { gate.release() }
            return true
        }
        await Task.yield()
        action.cancel()
        gate.release()
        #expect(await action.value)
        await gate.acquire()
        gate.release()
    }

    @Test func emojiAndEscapedTitlesFitLiveActivityBudget() throws {
        let c = ctx("2026-10-02")
        let titles = [String(repeating: "👨‍👩‍👧‍👦", count: 100),
                      String(repeating: "\u{0001}\\\"", count: 100),
                      "a" + String(repeating: "\u{0301}", count: 4_000)]
        var state = TodayState()
        for title in titles { try state.addTask(title: title, context: c) }
        let snapshot = state.snapshot(for: c.today, today: c.today)
        for row in snapshot.rows {
            #expect(row.title.count <= ActivitySnapshot.maxTitleLength)
            #expect(try JSONEncoder().encode(row.title).count <= ActivitySnapshot.maxTitleBytes)
            #expect(row.title.hasSuffix("…"))
        }
        #expect(try JSONEncoder().encode(snapshot).count < 3_072)
        #expect(state.activeRows(today: c.today).map(\.title) == titles)
    }

    @Test func queuedReorderSurvivesCompletionAndInsertion() throws {
        let c = ctx("2026-10-02")
        var state = TodayState()
        let refs = try ["a", "b", "c", "d"].map { try state.addTask(title: $0, context: c) }
        // The user drags d to the front while a completion is being saved.
        let desired = [refs[3], refs[0], refs[1], refs[2]].map(\.orderID)
        state.complete(refs[0], context: c)
        try state.addTask(title: "new", context: c)
        state.reorderActive(desired, context: c)
        #expect(state.activeRows(today: c.today).map(\.title) == ["d", "b", "c", "new"])
        state.uncomplete(refs[0], context: c)
        #expect(state.activeRows(today: c.today).map(\.title) == ["a", "d", "b", "c", "new"])
    }

    @Test func queuedGoalReorderIgnoresMovedAndDuplicateIDs() throws {
        let c = ctx("2026-10-02")
        var state = TodayState()
        let refs = try ["a", "b", "c"].map { try state.addTask(title: $0, placement: .longTerm, context: c) }
        try state.doToday(refs[0].orderID, context: c)
        state.reorderLongTerm([refs[2], refs[0], refs[1], refs[2]].map(\.orderID), context: c)
        #expect(state.longTermRows().map(\.title) == ["c", "b"])
        #expect(state.activeRows(today: c.today).map(\.title) == ["a"])
    }

    @Test func plannedReorderCannotMoveTasksAfterArrival() throws {
        let c = ctx("2026-10-02")
        let tomorrow = c.today.adding(days: 1)
        var state = TodayState()
        let refs = try ["a", "b"].map { try state.addTask(title: $0, placement: .day(tomorrow), context: c) }
        state.reorderPlanned(refs.reversed().map(\.orderID), on: tomorrow, context: ctx("2026-10-03"))
        #expect(state.activeRows(today: tomorrow).map(\.title) == ["a", "b"])
    }

    final class FailingStorage: StateStorage, @unchecked Sendable {
        enum Failure: Error { case diskFull }
        private let lock = NSLock()
        private var state: TodayState
        private var failNext = true

        init(_ state: TodayState) { self.state = state }
        func load() throws -> TodayState? { lock.withLock { state } }
        func save(_ state: TodayState) throws {
            try lock.withLock {
                if failNext {
                    failNext = false
                    throw Failure.diskFull
                }
                self.state = state
            }
        }
    }

    @Test func failedCompletionDoesNotPoisonCacheAndCanRetry() async throws {
        let c = ctx("2026-10-02")
        var initial = TodayState()
        let ref = try initial.addTask(title: "Keep me", context: c)
        let storage = FailingStorage(initial)
        let repo = TaskRepository(storage: storage, now: { c.now }, timeZone: { c.timeZone })
        do {
            try await repo.mutate { s, c in s.complete(ref, context: c) }
            Issue.record("Expected the first completion save to fail")
        } catch FailingStorage.Failure.diskFull {}
        let unchanged = try await repo.current().state
        #expect(unchanged.activeRows(today: c.today).map(\.title) == ["Keep me"])
        #expect(try storage.load() == initial)
        try await repo.mutate { s, c in s.complete(ref, context: c) }
        let reopened = TaskRepository(storage: storage, now: { c.now }, timeZone: { c.timeZone })
        #expect(try await reopened.current().state.completedRows(today: c.today).map(\.title) == ["Keep me"])
    }
}
