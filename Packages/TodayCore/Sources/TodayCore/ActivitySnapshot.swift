import Foundation

/// What the Lock Screen card shows. Kept deliberately small: ActivityKit
/// limits the combined static + dynamic payload to 4 KB, so this carries at
/// most three truncated titles and counts, never the task history.
public struct ActivitySnapshot: Codable, Hashable, Sendable {
    public struct Row: Codable, Hashable, Sendable, Identifiable {
        /// `TaskRef` string; passed back to the completion intent.
        public let ref: String
        public let title: String
        public let carryLabel: String?
        public var id: String { ref }

        public init(ref: String, title: String, carryLabel: String?) {
            self.ref = ref
            self.title = title
            self.carryLabel = carryLabel
        }
    }

    public static let maxRows = 3
    public static let maxTitleLength = 100

    public let day: LocalDay
    public let rows: [Row]
    /// Unfinished tasks beyond the visible rows.
    public let moreCount: Int
    public let completedCount: Int

    public init(day: LocalDay, rows: [Row], moreCount: Int, completedCount: Int) {
        self.day = day
        self.rows = rows
        self.moreCount = moreCount
        self.completedCount = completedCount
    }

    public var isAllDone: Bool { rows.isEmpty }

    public init(day: LocalDay, active: [TaskRow], completedCount: Int) {
        let shown = active.prefix(Self.maxRows).map { row in
            Row(ref: row.ref.description, title: Self.truncate(row.title), carryLabel: row.carryLabel)
        }
        self.init(day: day, rows: Array(shown), moreCount: max(0, active.count - shown.count),
                  completedCount: completedCount)
    }

    static func truncate(_ title: String) -> String {
        guard title.count > maxTitleLength else { return title }
        return String(title.prefix(maxTitleLength - 1)) + "…"
    }
}

extension TodayState {
    /// The card content for `day`. For today it reflects real state; for a
    /// future day it is the projection (completed count starts at zero).
    public func snapshot(for day: LocalDay, today: LocalDay) -> ActivitySnapshot {
        let rows = projectedRows(on: day, today: today)
        let done = day == today ? completedRows(today: today).count : 0
        return ActivitySnapshot(day: day, active: rows, completedCount: done)
    }
}
