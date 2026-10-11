import Foundation
import Testing
@testable import TodayCore

@Suite struct LongTermTests {
    @Test func addCompleteUndoReorder() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        let goals = try ["Learn Rust", "Run a half marathon", "Read 20 books"].map {
            try s.addTask(title: $0, placement: .longTerm, context: c)
        }
        try s.addTask(title: "homework", context: c)
        #expect(s.longTermRows().map(\.title) == ["Learn Rust", "Run a half marathon", "Read 20 books"])
        #expect(s.activeTitles(c) == ["homework"], "goals never appear on the daily list")

        s.moveLongTerm(fromOffsets: [2], toOffset: 0, context: c)
        #expect(s.longTermRows().map(\.title) == ["Read 20 books", "Learn Rust", "Run a half marathon"])

        let changed = s.complete(goals[0], context: c)
        #expect(changed)
        let again = s.complete(goals[0], context: c)
        #expect(!again)
        #expect(s.longTermRows().map(\.title) == ["Read 20 books", "Run a half marathon"])
        #expect(s.completedRows(today: c.today).map(\.title) == ["Learn Rust"])

        s.uncomplete(goals[0], context: c)
        #expect(s.longTermRows().map(\.title) == ["Read 20 books", "Learn Rust", "Run a half marathon"])
    }

    @Test func goalsNeverCarryAndLeaveWhenDone() throws {
        var s = TodayState()
        let ref = try s.addTask(title: "goal", placement: .longTerm, context: ctx("2026-10-02"))
        s.reconcile(today: day("2026-10-09"))
        #expect(s.longTermRows().first?.carryLabel == nil)
        s.complete(ref, context: ctx("2026-10-09"))
        s.reconcile(today: day("2026-10-10"))
        #expect(s.longTerm.isEmpty)
        #expect(s.record(for: day("2026-10-09"))?.entries.map(\.kind) == [.longTerm])
    }

    @Test func doTodayMovesToTop() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        try s.addTask(title: "a", context: c)
        try s.addTask(title: "b", context: c)
        let goal = try s.addTask(title: "goal", placement: .longTerm, context: c)
        try s.doToday(goal.orderID, context: c)
        #expect(s.activeTitles(c) == ["goal", "a", "b"])
        #expect(s.longTerm.isEmpty)
        #expect(s.activeRows(today: c.today)[0].ref == .oneOff(goal.orderID), "id is preserved")
    }

    @Test func moveBetweenListsKeepsIdentity() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        let ref = try s.addTask(title: "a", context: c)
        try s.addTask(title: "b", context: c)
        try s.editTask(id: ref.orderID, title: "a goal", placement: .longTerm, context: c)
        #expect(s.activeTitles(c) == ["b"])
        #expect(s.longTermRows().map(\.title) == ["a goal"])
        #expect(!s.order.contains(ref.orderID))

        try s.editTask(id: ref.orderID, title: "a daily", placement: .repeating(.daily), context: c)
        #expect(s.longTerm.isEmpty)
        #expect(s.activeTitles(c) == ["b", "a daily"])
        #expect(s.placement(of: ref.orderID, today: c.today) == .repeating(.daily))
    }
}

@Suite struct PlannedTaskTests {
    @Test func hiddenUntilItsDayThenArrivesOnTop() throws {
        var s = TodayState()
        let fri = ctx("2026-10-02")
        try s.addTask(title: "existing", context: fri)
        try s.addTask(title: "daily", recurrence: .daily, context: fri)
        try s.addTask(title: "call dentist", placement: .day(day("2026-10-05")), context: fri)
        #expect(s.activeTitles(fri) == ["existing", "daily"])
        #expect(s.plannedRows(on: day("2026-10-05")).map(\.title) == ["call dentist"])
        #expect(s.projectedRows(on: day("2026-10-04"), today: fri.today).map(\.title) == ["existing", "daily"])

        let mon = ctx("2026-10-05")
        let projected = s.projectedRows(on: mon.today, today: fri.today)
        #expect(projected.map(\.title) == ["call dentist", "existing", "daily"])
        s.reconcile(today: mon.today)
        #expect(s.activeRows(today: mon.today) == projected, "projection equals the lived day")
        #expect(s.activeRows(today: mon.today)[0].carryLabel == nil, "carry counts from its planned day")

        s.reconcile(today: day("2026-10-06"))
        #expect(s.activeRows(today: day("2026-10-06"))[0].carryLabel == "From yesterday")
    }

    @Test func arrivalOrderIsTheSameWhetherOrNotTheAppRuns() throws {
        var base = TodayState()
        let fri = ctx("2026-10-02")
        try base.addTask(title: "x", context: fri)
        try base.addTask(title: "sat 1", placement: .day(day("2026-10-03")), context: fri)
        try base.addTask(title: "sat 2", placement: .day(day("2026-10-03")), context: fri)
        try base.addTask(title: "sun", placement: .day(day("2026-10-04")), context: fri)

        var daily = base
        daily.reconcile(today: day("2026-10-03"))
        daily.reconcile(today: day("2026-10-04"))
        var skipped = base
        skipped.reconcile(today: day("2026-10-04"))
        let expected = ["sun", "sat 1", "sat 2", "x"]
        #expect(daily.activeRows(today: day("2026-10-04")).map(\.title) == expected)
        #expect(skipped.activeRows(today: day("2026-10-04")).map(\.title) == expected)
        #expect(base.projectedRows(on: day("2026-10-04"), today: fri.today).map(\.title) == expected)
    }

    @Test func plannedTasksCannotBeCompletedEarly() throws {
        var s = TodayState()
        let fri = ctx("2026-10-02")
        let ref = try s.addTask(title: "later", placement: .day(day("2026-10-05")), context: fri)
        let changed = s.complete(ref, context: fri)
        #expect(!changed)
    }

    @Test func reorderPlanned() throws {
        var s = TodayState()
        let fri = ctx("2026-10-02")
        let mon = day("2026-10-05")
        try s.addTask(title: "today", context: fri)
        for t in ["a", "b", "c"] { try s.addTask(title: t, placement: .day(mon), context: fri) }
        s.movePlanned(on: mon, fromOffsets: [2], toOffset: 0, context: fri)
        #expect(s.plannedRows(on: mon).map(\.title) == ["c", "a", "b"])
        #expect(s.activeTitles(fri) == ["today"])
        s.reconcile(today: mon)
        #expect(s.activeRows(today: mon).map(\.title) == ["c", "a", "b", "today"])
    }

    @Test func postponeAndPullForward() throws {
        var s = TodayState()
        let fri = ctx("2026-10-02")
        let a = try s.addTask(title: "a", context: fri)
        try s.addTask(title: "b", context: fri)
        try s.editTask(id: a.orderID, title: "a", placement: .day(day("2026-10-04")), context: fri)
        #expect(s.activeTitles(fri) == ["b"])
        #expect(s.placement(of: a.orderID, today: fri.today) == .day(day("2026-10-04")))
        // Changing just the title keeps the planned date.
        try s.editTask(id: a.orderID, title: "a2", recurrence: nil, context: fri)
        #expect(s.plannedRows(on: day("2026-10-04")).map(\.title) == ["a2"])
        // Pulling it back to today puts it on top.
        try s.doToday(a.orderID, context: fri)
        #expect(s.activeTitles(fri) == ["a2", "b"])
    }

    @Test func plannedSnapshotForNoonCard() throws {
        var s = TodayState()
        let fri = ctx("2026-10-02")
        try s.addTask(title: "dentist", placement: .day(day("2026-10-03")), context: fri)
        #expect(s.snapshot(for: day("2026-10-03"), today: fri.today).rows.map(\.title) == ["dentist"])
        #expect(s.snapshot(for: fri.today, today: fri.today).isAllDone, "nothing shows today")
    }
}

@Suite struct HistoryTests {
    @Test func closedDayRecordsOutcomes() throws {
        var s = TodayState()
        let fri = ctx("2026-10-02")
        let done = try s.addTask(title: "done thing", context: fri)
        try s.addTask(title: "open thing", context: fri)
        try s.addTask(title: "daily", recurrence: .daily, context: fri)
        s.complete(done, context: ctx("2026-10-02", 15))
        s.reconcile(today: day("2026-10-03"))

        let record = try #require(s.record(for: fri.today))
        #expect(record.entries.map(\.title) == ["open thing", "daily", "done thing"])
        #expect(record.entries.map(\.outcome) == [.carried, .missed, .done])
        #expect(record.doneCount == 1)
        #expect(s.record(for: day("2026-10-03")) == nil, "today is live, not history")
    }

    @Test func carriedTaskAppearsOnEveryOpenDay() throws {
        var s = TodayState()
        let ref = try s.addTask(title: "present", context: ctx("2026-10-01"))
        s.reconcile(today: day("2026-10-02"))
        s.complete(ref, context: ctx("2026-10-03"))
        s.reconcile(today: day("2026-10-04"))
        #expect(s.record(for: day("2026-10-01"))?.entries.map(\.outcome) == [.carried])
        #expect(s.record(for: day("2026-10-02"))?.entries.first?.carryLabel == "From yesterday")
        #expect(s.record(for: day("2026-10-03"))?.entries.map(\.outcome) == [.done])
    }

    @Test func unattendedDaysAreReconstructed() throws {
        var s = TodayState()
        try s.addTask(title: "open", context: ctx("2026-10-01"))
        try s.addTask(title: "gym", recurrence: .weekdays([.friday]), context: ctx("2026-10-01"))
        try s.addTask(title: "planned", placement: .day(day("2026-10-03")), context: ctx("2026-10-01"))
        // App not opened again until Monday.
        s.reconcile(today: day("2026-10-05"))
        #expect(s.record(for: day("2026-10-01"))?.entries.map(\.title) == ["open"])
        #expect(s.record(for: day("2026-10-02"))?.entries.map(\.title) == ["open", "gym"])
        #expect(s.record(for: day("2026-10-03"))?.entries.map(\.title) == ["planned", "open"])
        #expect(s.record(for: day("2026-10-04"))?.entries.first?.carryLabel == "From yesterday")
        #expect(s.record(for: day("2026-10-02"))?.entries.last?.outcome == .missed)
        #expect(s.history.map(\.day) == (1...4).map { day("2026-10-0\($0)") }, "sorted, one per day")
    }

    @Test func repeatedReconcileDoesNotDuplicate() throws {
        var s = TodayState()
        try s.addTask(title: "a", context: ctx("2026-10-01"))
        for _ in 0..<3 { s.reconcile(today: day("2026-10-03")) }
        #expect(s.history.count == 2)
    }

    @Test func emptyDaysAreNotRecorded() throws {
        var s = TodayState()
        s.reconcile(today: day("2026-10-01"))
        s.reconcile(today: day("2026-10-05"))
        #expect(s.history.isEmpty)
    }
}

@Suite struct LockScreenModeTests {
    @Test func offerAppearsOnlyAfterFinishingToday() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        try s.addTask(title: "goal", placement: .longTerm, context: c)
        // No daily tasks at all: nothing to show, no offer.
        #expect(s.snapshot(for: c.today, today: c.today).isAllDone)

        let task = try s.addTask(title: "task", context: c)
        #expect(s.snapshot(for: c.today, today: c.today).longTermOffer == 0)
        s.complete(task, context: c)
        let snap = s.snapshot(for: c.today, today: c.today)
        #expect(!snap.hasTasks && snap.longTermOffer == 1 && !snap.isAllDone)
    }

    @Test func longTermModeShowsGoalsAndResetsNextDay() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        let goals = try ["g1", "g2", "g3", "g4"].map { try s.addTask(title: $0, placement: .longTerm, context: c) }
        try s.addTask(title: "daily", recurrence: .daily, context: c)
        s.lockScreen.longTermDay = c.today
        let snap = s.snapshot(for: c.today, today: c.today)
        #expect(snap.mode == .longTerm)
        #expect(snap.rows.map(\.title) == ["g1", "g2", "g3"])
        #expect(snap.rows[0].ref == goals[0].description)
        #expect(snap.moreCount == 1)

        s.reconcile(today: day("2026-10-03"))
        #expect(s.lockScreen.longTermDay == nil)
        #expect(s.snapshot(for: day("2026-10-03"), today: day("2026-10-03")).mode == .daily)
    }

    @Test func allGoalsDoneEndsTheCard() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        let goal = try s.addTask(title: "g", placement: .longTerm, context: c)
        s.lockScreen.longTermDay = c.today
        s.complete(goal, context: c)
        #expect(s.snapshot(for: c.today, today: c.today).isAllDone)
    }

    @Test func previousBuildContentStillDecodes() throws {
        let old = #"{"completedCount":1,"day":"2026-10-02","moreCount":0,"rows":[{"ref":"o:1","title":"x"}]}"#
        let snap = try JSONDecoder().decode(ActivitySnapshot.self, from: Data(old.utf8))
        #expect(snap.mode == .daily && snap.longTermOffer == 0 && snap.rows.count == 1)
    }
}

@Suite struct MigrationTests {
    @Test func v1FileLoadsWithEverythingIntact() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("state.json")
        try Data(schemaV1Fixture.utf8).write(to: url)

        final class Clock: @unchecked Sendable { var now = day("2026-10-02").date(hour: 11, in: newYork) }
        let clock = Clock()
        let repo = TaskRepository(storage: FileStateStorage(url: url), now: { clock.now }, timeZone: { newYork })
        let (state, c) = try await repo.current()

        #expect(state.schemaVersion == 2)
        #expect(state.activeRows(today: c.today).map(\.title) == ["Buy a birthday present", "Gym"])
        #expect(state.activeRows(today: c.today)[0].carryLabel == "From yesterday")
        #expect(state.completedRows(today: c.today).map(\.title) == ["LeetCode 30 min"])
        #expect(state.lockScreen.enabled && state.lockScreen.privacyAcknowledged)
        // Yesterday's completion moved from the old log into history.
        let oct1 = try #require(state.record(for: day("2026-10-01")))
        #expect(oct1.entries.map(\.title) == ["Text back John"])
        #expect(oct1.entries.map(\.outcome) == [.done])
        #expect(state.record(for: day("2026-10-02")) == nil, "today's completion stays live")

        // The upgrade is written to disk immediately, without the old key.
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk.contains("\"schemaVersion\":2"))
        #expect(!onDisk.contains("completionLog"))

        // Tomorrow, today closes into history in full.
        clock.now = day("2026-10-03").date(hour: 9, in: newYork)
        let next = try await repo.current().state
        #expect(next.record(for: day("2026-10-02"))?.entries.map(\.title) == ["Buy a birthday present", "Gym", "LeetCode 30 min"])
        #expect(next.record(for: day("2026-10-01"))?.entries.map(\.title) == ["Text back John"], "migrated record kept")
    }

    @Test func migrationIsIdempotent() throws {
        var s = try JSONDecoder.today.decode(TodayState.self, from: Data(schemaV1Fixture.utf8))
        s.migrate(timeZone: newYork)
        let once = s
        s.migrate(timeZone: newYork)
        #expect(s == once)
    }
}

@Suite struct CardRowTests {
    @Test func overdueWordingAndUrgency() {
        #expect(CarryLabel.text(forDays: 1) == "From yesterday")
        #expect(CarryLabel.text(forDays: 4) == "4 days overdue")
        #expect(!CarryLabel.isUrgent(days: 3))
        #expect(CarryLabel.isUrgent(days: 4))
    }

    @Test func snapshotRowsCarryDayCount() throws {
        var s = TodayState()
        try s.addTask(title: "old", context: ctx("2026-10-01"))
        s.reconcile(today: day("2026-10-05"))
        let row = s.snapshot(for: day("2026-10-05"), today: day("2026-10-05")).rows[0]
        #expect(row.carriedDays == 4)
        #expect(row.isUrgent)
        #expect(!row.done)
    }

    @Test func markingDoneTicksOnlyThatRow() throws {
        var s = TodayState()
        let a = try s.addTask(title: "a", context: ctx("2026-10-02"))
        try s.addTask(title: "b", context: ctx("2026-10-02"))
        let snap = s.snapshot(for: day("2026-10-02"), today: day("2026-10-02"))
        let marked = try #require(snap.markingDone(a.description))
        #expect(marked.rows.map(\.done) == [true, false])
        #expect(marked.markingDone(a.description) == nil, "already ticked")
        #expect(snap.markingDone("o:missing") == nil)
    }

    @Test func rowsFromThePreviousBuildStillDecode() throws {
        let json = #"{"ref":"o:1","title":"Text John","carryLabel":"3 days carried"}"#
        let row = try JSONDecoder().decode(ActivitySnapshot.Row.self, from: Data(json.utf8))
        #expect(row.carriedDays == 0 && !row.done)
    }
}
