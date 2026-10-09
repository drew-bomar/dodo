import Foundation
import Testing
@testable import TodayCore

let newYork = TimeZone(identifier: "America/New_York")!
let tokyo = TimeZone(identifier: "Asia/Tokyo")!
let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

func day(_ s: String) -> LocalDay { LocalDay(string: s)! }

func ctx(_ s: String, _ hour: Int = 9, _ minute: Int = 0, tz: TimeZone = newYork) -> DayContext {
    DayContext(now: day(s).date(hour: hour, minute: minute, in: tz), timeZone: tz)
}

extension TodayState {
    func activeTitles(_ c: DayContext) -> [String] { activeRows(today: c.today).map(\.title) }
}

@Suite struct LocalDayTests {
    @Test func ordinalRoundTrip() {
        for o in [-800_000, -1, 0, 1, 19_000, 20_728, 60_000] {
            #expect(LocalDay(ordinal: o).ordinal == o)
        }
        #expect(day("1970-01-01").ordinal == 0)
        #expect(day("2026-10-02").adding(days: 30) == day("2026-11-01"))
        #expect(day("2028-02-28").adding(days: 1) == day("2028-02-29"))
    }

    @Test func weekdays() {
        #expect(day("1970-01-01").weekday == .thursday)
        #expect(day("2026-10-02").weekday == .friday)
        #expect(day("2026-10-04").weekday == .sunday)
        #expect(day("2026-10-03").weekday == .saturday)
    }

    @Test func dstDaysAreCalendarDays() {
        // 2026-11-01 is a 25-hour day in New York; 2026-03-08 is a 23-hour day.
        let fallBack = day("2026-11-01")
        #expect(LocalDay(fallBack.date(hour: 23, minute: 30, in: newYork), in: newYork) == fallBack)
        #expect(LocalDay(fallBack.date(hour: 0, minute: 30, in: newYork), in: newYork) == fallBack)
        let springForward = day("2026-03-08")
        let noon = springForward.date(hour: 12, in: newYork)
        #expect(LocalDay(noon, in: newYork) == springForward)
        // 02:30 does not exist; it must still land on the same calendar day.
        #expect(LocalDay(springForward.date(hour: 2, minute: 30, in: newYork), in: newYork) == springForward)
    }

    @Test func codableAsISOString() throws {
        let data = try JSONEncoder().encode([day("2026-01-05")])
        #expect(String(decoding: data, as: UTF8.self) == "[\"2026-01-05\"]")
        #expect(try JSONDecoder().decode([LocalDay].self, from: data) == [day("2026-01-05")])
    }
}

@Suite struct TaskRefTests {
    @Test func roundTrip() {
        let id = UUID()
        for ref in [TaskRef.oneOff(id), .occurrence(seriesID: id, day: day("2026-10-02"))] {
            #expect(TaskRef(string: ref.description) == ref)
        }
        #expect(TaskRef(string: "x:nope") == nil)
        #expect(TaskRef(string: "r:\(id.uuidString):garbage") == nil)
    }
}

@Suite struct CrudTests {
    @Test func addTrimsAndRejectsBlank() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        try s.addTask(title: "  finish homework \n", context: c)
        #expect(s.activeTitles(c) == ["finish homework"])
        #expect(throws: TaskError.emptyTitle) { try s.addTask(title: "   \n", context: c) }
        #expect(throws: TaskError.invalidRecurrence) { try s.addTask(title: "x", recurrence: .weekdays([]), context: c) }
        #expect(s.order.count == 1)
    }

    @Test func newTasksGoToBottom() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        for t in ["a", "b", "c"] { try s.addTask(title: t, context: c) }
        try s.addTask(title: "daily", recurrence: .daily, context: c)
        #expect(s.activeTitles(c) == ["a", "b", "c", "daily"])
    }

    @Test func editAndConvert() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        let ref = try s.addTask(title: "a", context: c)
        try s.addTask(title: "b", context: c)
        try s.editTask(id: ref.orderID, title: "a2", recurrence: nil, context: c)
        #expect(s.activeTitles(c) == ["a2", "b"])

        // One-off -> recurring keeps its slot.
        try s.editTask(id: ref.orderID, title: "a3", recurrence: .daily, context: c)
        #expect(s.activeTitles(c) == ["a3", "b"])
        #expect(s.oneOffs.count == 1 && s.series.count == 1)
        #expect(s.activeRows(today: c.today)[0].ref == .occurrence(seriesID: ref.orderID, day: c.today))

        // Recurring -> one-off keeps its slot too.
        try s.editTask(id: ref.orderID, title: "a4", recurrence: nil, context: c)
        #expect(s.activeTitles(c) == ["a4", "b"])
        #expect(s.series.isEmpty && s.occurrences.isEmpty)

        #expect(throws: TaskError.notFound) { try s.editTask(id: UUID(), title: "x", recurrence: nil, context: c) }
        #expect(throws: TaskError.emptyTitle) { try s.editTask(id: ref.orderID, title: " ", recurrence: nil, context: c) }
    }

    @Test func editingSeriesTitleAppliesToday() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        let ref = try s.addTask(title: "LeetCode 30 min", recurrence: .daily, context: c)
        try s.editTask(id: ref.orderID, title: "LeetCode 45 min", recurrence: .daily, context: c)
        #expect(s.activeTitles(c) == ["LeetCode 45 min"])
        #expect(s.occurrences.count == 1)
    }

    @Test func deleteAndSkip() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        let a = try s.addTask(title: "a", context: c)
        let r = try s.addTask(title: "r", recurrence: .daily, context: c)
        s.skipToday(seriesID: r.orderID, context: c)
        #expect(s.activeTitles(c) == ["a"])
        s.reconcile(today: c.today)
        #expect(s.activeTitles(c) == ["a"], "skipped occurrence must not regenerate the same day")
        let tomorrow = ctx("2026-10-03")
        #expect(s.projectedRows(on: tomorrow.today, today: c.today).map(\.title) == ["a", "r"])
        s.reconcile(today: tomorrow.today)
        #expect(s.activeTitles(tomorrow) == ["a", "r"])

        s.deleteSeries(r.orderID, context: tomorrow)
        s.deleteOneOff(a.orderID, context: tomorrow)
        #expect(s.activeTitles(tomorrow).isEmpty)
        #expect(s.order.isEmpty && s.occurrences.isEmpty)
    }
}

@Suite struct CompletionTests {
    @Test func completeIsIdempotentAndPromotesNext() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        let refs = try ["a", "b", "c", "d"].map { try s.addTask(title: $0, context: c) }
        #expect(ActivitySnapshot(day: c.today, active: s.activeRows(today: c.today), completedCount: 0).rows.map(\.title) == ["a", "b", "c"])

        let changed1 = s.complete(refs[1], context: c)
        #expect(changed1)
        let changed2 = s.complete(refs[1], context: c)
        #expect(!changed2, "duplicate tap must be a no-op")
        let changed3 = s.complete(.oneOff(UUID()), context: c)
        #expect(!changed3)
        #expect(s.activeTitles(c) == ["a", "c", "d"])
        #expect(s.completedRows(today: c.today).map(\.title) == ["b"])

        let snap = s.snapshot(for: c.today, today: c.today)
        #expect(snap.rows.map(\.title) == ["a", "c", "d"])
        #expect(snap.moreCount == 0 && snap.completedCount == 1)
    }

    @Test func undoRestoresManualPosition() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        let refs = try ["a", "b", "c"].map { try s.addTask(title: $0, context: c) }
        s.complete(refs[0], context: c)
        let changed4 = s.uncomplete(refs[0], context: c)
        #expect(changed4)
        let changed5 = s.uncomplete(refs[0], context: c)
        #expect(!changed5)
        #expect(s.activeTitles(c) == ["a", "b", "c"])
    }

    @Test func staleOccurrenceTapIsNoOp() throws {
        var s = TodayState()
        let yesterday = ctx("2026-10-01")
        let ref = try s.addTask(title: "r", recurrence: .daily, context: yesterday)
        let today = ctx("2026-10-02")
        let changed6 = s.complete(ref, context: today)
        #expect(!changed6, "yesterday's card must not complete today's occurrence")
        #expect(s.activeTitles(today) == ["r"])
    }

    @Test func completedYesterdayLeaves() throws {
        var s = TodayState()
        let c = ctx("2026-10-02", 23, 50)
        let ref = try s.addTask(title: "a", context: c)
        s.complete(ref, context: c)
        let next = ctx("2026-10-03", 0, 10)
        s.reconcile(today: next.today)
        #expect(s.completedRows(today: next.today).isEmpty)
        #expect(s.oneOffs.isEmpty)
        #expect(s.record(for: day("2026-10-02"))?.entries.map(\.outcome) == [.done], "history keeps it")
    }
}

@Suite struct CarryAndRecurrenceTests {
    @Test func carryLabels() throws {
        var s = TodayState()
        try s.addTask(title: "present", context: ctx("2026-10-02", 22))
        #expect(s.activeRows(today: day("2026-10-02"))[0].carryLabel == nil)
        s.reconcile(today: day("2026-10-03"))
        #expect(s.activeRows(today: day("2026-10-03"))[0].carryLabel == "From yesterday")
        s.reconcile(today: day("2026-10-05"))
        #expect(s.activeRows(today: day("2026-10-05"))[0].carryLabel == "3 days carried")
    }

    @Test func carryAcrossMidnightIsCalendarNotHours() throws {
        var s = TodayState()
        try s.addTask(title: "a", context: ctx("2026-10-02", 23, 59))
        let justAfter = ctx("2026-10-03", 0, 1)
        s.reconcile(today: justAfter.today)
        #expect(s.activeRows(today: justAfter.today)[0].carriedDays == 1)
    }

    @Test func recurringNeverAccumulates() throws {
        var s = TodayState()
        let ref = try s.addTask(title: "LeetCode", recurrence: .daily, context: ctx("2026-10-01"))
        // Miss four days without opening the app.
        let later = ctx("2026-10-05")
        for _ in 0..<3 { s.reconcile(today: later.today) }
        #expect(s.activeTitles(later) == ["LeetCode"])
        #expect(s.occurrences.count == 1)
        #expect(s.occurrences[0].day == later.today)
        #expect(s.activeRows(today: later.today)[0].carryLabel == nil)
        _ = ref
    }

    @Test func freshOccurrenceAfterCompletion() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        let ref = try s.addTask(title: "r", recurrence: .daily, context: c)
        s.complete(ref, context: c)
        #expect(s.activeTitles(c).isEmpty)
        let next = ctx("2026-10-03")
        s.reconcile(today: next.today)
        #expect(s.activeTitles(next) == ["r"])
        #expect(s.occurrences.count == 1)
    }

    @Test func selectedWeekdays() throws {
        var s = TodayState()
        // 2026-10-02 is a Friday.
        try s.addTask(title: "gym", recurrence: .weekdays([.monday, .wednesday, .friday]), context: ctx("2026-10-02"))
        let expected: [(String, Bool)] = [
            ("2026-10-02", true), ("2026-10-03", false), ("2026-10-04", false),
            ("2026-10-05", true), ("2026-10-06", false), ("2026-10-07", true),
        ]
        for (d, present) in expected {
            s.reconcile(today: day(d))
            #expect(s.activeRows(today: day(d)).isEmpty == !present, "\(d)")
        }
    }

    @Test func seriesCreatedOnUnscheduledDayStartsLater() throws {
        var s = TodayState()
        let saturday = ctx("2026-10-03")
        try s.addTask(title: "weekday thing", recurrence: .weekdays([.monday]), context: saturday)
        #expect(s.activeTitles(saturday).isEmpty)
        #expect(s.projectedRows(on: day("2026-10-05"), today: saturday.today).map(\.title) == ["weekday thing"])
    }

    @Test func reconcileIsIdempotent() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        try s.addTask(title: "a", context: c)
        try s.addTask(title: "r", recurrence: .daily, context: c)
        s.reconcile(today: day("2026-10-04"))
        let once = s
        let changed7 = s.reconcile(today: day("2026-10-04"))
        #expect(!changed7)
        #expect(s == once)
    }

    @Test func timeZoneChangeKeepsSingleOccurrence() throws {
        var s = TodayState()
        // 08:00 Friday in New York is 21:00 Friday in Tokyo...
        let ny = ctx("2026-10-02", 8, tz: newYork)
        let ref = try s.addTask(title: "r", recurrence: .daily, context: ny)
        s.complete(ref, context: ny)
        // ...and 14:00 New York is 03:00 Saturday in Tokyo: a new calendar day.
        let tk = DayContext(now: day("2026-10-02").date(hour: 14, in: newYork), timeZone: tokyo)
        #expect(tk.today == day("2026-10-03"))
        s.reconcile(today: tk.today)
        #expect(s.activeTitles(tk) == ["r"])
        #expect(s.occurrences.count == 1)

        // Flying back west to Friday: today's completed occurrence was expired,
        // but the list never shows two copies.
        let back = DayContext(now: day("2026-10-02").date(hour: 20, in: losAngeles), timeZone: losAngeles)
        s.reconcile(today: back.today)
        #expect(s.activeTitles(back).count <= 1)
        #expect(Set(s.occurrences.map { "\($0.seriesID)\($0.day)" }).count == s.occurrences.count)
    }
}

@Suite struct ReorderTests {
    @Test func moveWithinVisible() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        for t in ["a", "b", "c", "d"] { try s.addTask(title: t, context: c) }
        s.moveActive(fromOffsets: [3], toOffset: 0, context: c)
        #expect(s.activeTitles(c) == ["d", "a", "b", "c"])
        s.moveActive(fromOffsets: [0], toOffset: 4, context: c)
        #expect(s.activeTitles(c) == ["a", "b", "c", "d"])
        s.moveActive(fromOffsets: [1], toOffset: 3, context: c)
        #expect(s.activeTitles(c) == ["a", "c", "b", "d"])
    }

    @Test func hiddenItemsKeepTheirSlots() throws {
        var s = TodayState()
        let fri = ctx("2026-10-02")
        try s.addTask(title: "a", context: fri)
        try s.addTask(title: "mon", recurrence: .weekdays([.monday]), context: fri)
        try s.addTask(title: "b", context: fri)
        let done = try s.addTask(title: "c", context: fri)
        s.complete(done, context: fri)
        #expect(s.activeTitles(fri) == ["a", "b"])
        s.moveActive(fromOffsets: [1], toOffset: 0, context: fri)
        #expect(s.activeTitles(fri) == ["b", "a"])
        // The Monday series keeps its slot between the two visible tasks.
        #expect(s.projectedRows(on: day("2026-10-05"), today: fri.today).map(\.title) == ["b", "mon", "a"])
        // Undoing the completed task brings it back at its old slot (bottom).
        s.uncomplete(done, context: fri)
        #expect(s.activeTitles(fri) == ["b", "a", "c"])
    }
}

@Suite struct SnapshotTests {
    @Test func futureProjection() throws {
        var s = TodayState()
        let fri = ctx("2026-10-02")
        let daily = try s.addTask(title: "LeetCode 30 min", recurrence: .daily, context: fri)
        try s.addTask(title: "homework", context: fri)
        let texted = try s.addTask(title: "text back John", context: fri)
        try s.addTask(title: "weekend", recurrence: .weekdays([.saturday]), context: fri)
        try s.addTask(title: "present", context: fri)
        s.complete(daily, context: fri)
        s.complete(texted, context: fri)

        let sat = s.snapshot(for: day("2026-10-03"), today: fri.today)
        // Today's completed daily task returns fresh; completed one-offs don't.
        #expect(sat.rows.map(\.title) == ["LeetCode 30 min", "homework", "weekend"])
        #expect(sat.rows.map(\.carryLabel) == [nil, "From yesterday", nil])
        #expect(sat.moreCount == 1)
        #expect(sat.completedCount == 0)

        let sun = s.snapshot(for: day("2026-10-04"), today: fri.today)
        #expect(sun.rows.map(\.title) == ["LeetCode 30 min", "homework", "present"])
        #expect(sun.rows[1].carryLabel == "2 days carried")
        #expect(sun.moreCount == 0)

        // The projection must equal what reconciliation produces on that day.
        var lived = s
        lived.reconcile(today: day("2026-10-04"))
        #expect(lived.snapshot(for: day("2026-10-04"), today: day("2026-10-04")) == sun)
    }

    @Test func emptyDayIsAllDone() {
        let s = TodayState()
        #expect(s.snapshot(for: day("2026-10-03"), today: day("2026-10-02")).isAllDone)
    }

    @Test func payloadStaysSmall() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        let long = String(repeating: "🧠 very long task title ", count: 40)
        for _ in 0..<10 { try s.addTask(title: long, context: c) }
        let snap = s.snapshot(for: c.today, today: c.today)
        #expect(snap.rows.allSatisfy { $0.title.count <= ActivitySnapshot.maxTitleLength })
        let bytes = try JSONEncoder().encode(snap).count
        #expect(bytes < 2048, "content state must leave headroom under ActivityKit's 4 KB limit (got \(bytes))")
    }
}

@Suite struct RepositoryTests {
    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    @Test func persistsAcrossRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = FileStateStorage(url: dir.appendingPathComponent("state.json"))
        let clock = Clock(day("2026-10-02").date(hour: 9, in: newYork))
        let repo = TaskRepository(storage: storage, now: { clock.now }, timeZone: { newYork })
        try await repo.mutate { s, c in
            for t in ["a", "b", "c"] { try s.addTask(title: t, context: c) }
            s.moveActive(fromOffsets: [2], toOffset: 0, context: c)
        }
        let done = try await repo.current().state.activeRows(today: day("2026-10-02"))[0].ref
        try await repo.mutate { s, c in s.complete(done, context: c) }

        // "Terminate and reopen": a fresh repository reading the same file.
        let reopened = TaskRepository(storage: storage, now: { clock.now }, timeZone: { newYork })
        let state = try await reopened.current().state
        #expect(state.activeRows(today: day("2026-10-02")).map(\.title) == ["a", "b"])
        #expect(state.completedRows(today: day("2026-10-02")).map(\.title) == ["c"])
    }

    @Test func concurrentCompletionsDoNotLoseWrites() async throws {
        let storage = InMemoryStorage()
        let clock = Clock(day("2026-10-02").date(hour: 9, in: newYork))
        let repo = TaskRepository(storage: storage, now: { clock.now }, timeZone: { newYork })
        let refs = try await repo.mutate { s, c in
            try (0..<20).map { try s.addTask(title: "t\($0)", context: c) }
        }.result
        await withTaskGroup(of: Void.self) { group in
            for ref in refs + refs { // every completion twice, interleaved
                group.addTask { _ = try? await repo.mutate { s, c in s.complete(ref, context: c) } }
            }
        }
        let state = try await repo.current().state
        #expect(state.activeRows(today: day("2026-10-02")).isEmpty)
        #expect(state.completedRows(today: day("2026-10-02")).count == 20)
    }

    @Test func dayRollsOverOnAccess() async throws {
        let storage = InMemoryStorage()
        let clock = Clock(day("2026-10-02").date(hour: 23, in: newYork))
        let repo = TaskRepository(storage: storage, now: { clock.now }, timeZone: { newYork })
        try await repo.mutate { s, c in try s.addTask(title: "r", recurrence: .daily, context: c) }
        let ref = try await repo.current().state.activeRows(today: day("2026-10-02"))[0].ref
        try await repo.mutate { s, c in s.complete(ref, context: c) }
        clock.now = day("2026-10-03").date(hour: 7, in: newYork)
        let (state, c) = try await repo.current()
        #expect(c.today == day("2026-10-03"))
        #expect(state.activeRows(today: c.today).map(\.title) == ["r"])
    }

    @Test func unreadableFileIsBackedUpNotWiped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("state.json")
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try FileStateStorage(url: url).load() }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.contains("unreadable") })
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }
}
