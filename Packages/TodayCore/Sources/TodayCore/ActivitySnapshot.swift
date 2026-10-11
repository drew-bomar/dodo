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
        /// Days carried, for colouring the label; 0 when not carried.
        public let carriedDays: Int
        /// Ticked on the card and about to be removed: shown checked for a
        /// moment so the tap gets immediate feedback before the row slides out.
        public var done: Bool
        public var id: String { ref }

        public init(ref: String, title: String, carryLabel: String?, carriedDays: Int = 0, done: Bool = false) {
            self.ref = ref
            self.title = title
            self.carryLabel = carryLabel
            self.carriedDays = carriedDays
            self.done = done
        }

        public var isUrgent: Bool { CarryLabel.isUrgent(days: carriedDays) }

        enum CodingKeys: String, CodingKey { case ref, title, carryLabel, carriedDays, done }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ref = try c.decode(String.self, forKey: .ref)
            title = try c.decode(String.self, forKey: .title)
            carryLabel = try c.decodeIfPresent(String.self, forKey: .carryLabel)
            carriedDays = try c.decodeIfPresent(Int.self, forKey: .carriedDays) ?? 0
            done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        }
    }

    public enum Mode: String, Codable, Sendable {
        /// Today's tasks.
        case daily
        /// The user asked to see the long-term list after finishing today.
        case longTerm
    }

    public static let maxRows = 3
    public static let maxTitleLength = 100

    public let day: LocalDay
    public let mode: Mode
    public internal(set) var rows: [Row]
    /// Unfinished tasks beyond the visible rows.
    public let moreCount: Int
    public let completedCount: Int
    /// Unfinished long-term goals offered once today's list is done; 0 hides the offer.
    public let longTermOffer: Int

    public init(day: LocalDay, mode: Mode = .daily, rows: [Row], moreCount: Int, completedCount: Int,
                longTermOffer: Int = 0) {
        self.day = day
        self.mode = mode
        self.rows = rows
        self.moreCount = moreCount
        self.completedCount = completedCount
        self.longTermOffer = longTermOffer
    }

    public init(day: LocalDay, mode: Mode = .daily, active: [TaskRow], completedCount: Int, longTermOffer: Int = 0) {
        let shown = active.prefix(Self.maxRows).map { row in
            Row(ref: row.ref.description, title: Self.truncate(row.title), carryLabel: row.carryLabel,
                carriedDays: row.carriedDays)
        }
        self.init(day: day, mode: mode, rows: Array(shown), moreCount: max(0, active.count - shown.count),
                  completedCount: completedCount, longTermOffer: longTermOffer)
    }

    /// There are tasks to tick off.
    public var hasTasks: Bool { !rows.isEmpty }
    /// Nothing left to show at all: the card should say "All done" and end.
    public var isAllDone: Bool { rows.isEmpty && longTermOffer == 0 }

    /// The same card with `ref` shown ticked, or nil if it isn't on the card.
    public func markingDone(_ ref: String) -> ActivitySnapshot? {
        guard let i = rows.firstIndex(where: { $0.ref == ref }), !rows[i].done else { return nil }
        var copy = self
        copy.rows[i].done = true
        return copy
    }

    static func truncate(_ title: String) -> String {
        guard title.count > maxTitleLength else { return title }
        return String(title.prefix(maxTitleLength - 1)) + "…"
    }

    enum CodingKeys: String, CodingKey {
        case day, mode, rows, moreCount, completedCount, longTermOffer
    }

    /// Tolerates content written by the previous build (no mode or offer), so
    /// a card already on the Lock Screen still renders after an update.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(LocalDay.self, forKey: .day)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .daily
        rows = try c.decode([Row].self, forKey: .rows)
        moreCount = try c.decode(Int.self, forKey: .moreCount)
        completedCount = try c.decode(Int.self, forKey: .completedCount)
        longTermOffer = try c.decodeIfPresent(Int.self, forKey: .longTermOffer) ?? 0
    }
}

extension TodayState {
    /// The card content for `day`. For today it reflects real state; for a
    /// future day it is the projection (completed count starts at zero, and
    /// the long-term list is never offered on a day that hasn't happened).
    public func snapshot(for day: LocalDay, today: LocalDay) -> ActivitySnapshot {
        if day == today && lockScreen.longTermDay == today {
            let done = completedRows(today: today).filter(\.isLongTerm).count
            return ActivitySnapshot(day: day, mode: .longTerm, active: longTermRows(), completedCount: done)
        }
        let rows = projectedRows(on: day, today: today)
        guard day == today else { return ActivitySnapshot(day: day, active: rows, completedCount: 0) }
        let done = completedRows(today: today).filter { !$0.isLongTerm }.count
        // Offer the long-term list only after actually finishing today's list.
        let offer = rows.isEmpty && done > 0 ? longTermRows().count : 0
        return ActivitySnapshot(day: day, active: rows, completedCount: done, longTermOffer: offer)
    }
}
