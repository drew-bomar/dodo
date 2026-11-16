import Foundation
import Testing
@testable import TodayCore

@Suite struct BackupTests {
    @Test func roundTripKeepsEverything() throws {
        var s = TodayState()
        let c = ctx("2026-10-02")
        try s.addTask(title: "one-off", context: c)
        try s.addTask(title: "daily", recurrence: .daily, context: c)
        try s.addTask(title: "goal", placement: .longTerm, context: c)
        try s.addTask(title: "planned", placement: .day(day("2026-10-05")), context: c)
        s.lockScreen.enabled = true
        s.lockScreen.privacyAcknowledged = true

        let restored = try Backup.restore(from: Backup.data(for: s), timeZone: newYork)
        #expect(restored == s)
    }

    @Test func clearsCardBookkeepingButKeepsSettings() throws {
        var s = TodayState()
        s.lockScreen.enabled = true
        s.lockScreen.autoNoonStart = false
        s.lockScreen.cardDay = day("2026-10-02")
        s.lockScreen.cardStartedAt = Date()
        s.lockScreen.dismissedDay = day("2026-10-02")
        s.lockScreen.endedByAppDay = day("2026-10-02")

        let r = try Backup.restore(from: Backup.data(for: s), timeZone: newYork).lockScreen
        #expect(r.enabled && !r.autoNoonStart)
        #expect(r.cardDay == nil && r.cardStartedAt == nil && r.dismissedDay == nil && r.endedByAppDay == nil)
    }

    @Test func rejectsFilesThatAreNotBackups() {
        for bad in ["{}", "[1,2]", "not json", #"{"schemaVersion":"two"}"#] {
            #expect(throws: Backup.Failure.notABackup) {
                try Backup.restore(from: Data(bad.utf8), timeZone: newYork)
            }
        }
        #expect(throws: Backup.Failure.newerVersion(99)) {
            try Backup.restore(from: Data(#"{"schemaVersion":99}"#.utf8), timeZone: newYork)
        }
    }

    @Test func restoresTheFirstVersionsFormat() throws {
        let state = try Backup.restore(from: Data(schemaV1Fixture.utf8), timeZone: newYork)
        #expect(state.schemaVersion == TodayState.currentSchemaVersion)
        #expect(state.oneOffs.map(\.title).contains("Buy a birthday present"))
    }

    @Test func replaceClosesDaysSinceTheBackup() async throws {
        var old = TodayState()
        let then = ctx("2026-10-02")
        try old.addTask(title: "carried", context: then)
        old.reconcile(today: then.today)

        let storage = InMemoryStorage(TodayState())
        let repo = TaskRepository(storage: storage, now: { day("2026-10-04").date(hour: 9, in: newYork) },
                                  timeZone: { newYork })
        let restored = try Backup.restore(from: Backup.data(for: old), timeZone: newYork)
        let (state, c) = try await repo.replace(with: restored)

        #expect(state.activeRows(today: c.today).first?.carryLabel == "2 days overdue")
        #expect(state.record(for: day("2026-10-02")) != nil, "the backup's last day becomes history")
        #expect(try storage.load() == state, "saved")
    }
}
