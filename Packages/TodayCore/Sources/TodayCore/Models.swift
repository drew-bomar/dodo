import Foundation

public enum Recurrence: Codable, Hashable, Sendable {
    case daily
    /// Selected weekdays. An empty set never occurs; the editor prevents saving it.
    case weekdays(Set<Weekday>)

    public func occurs(on day: LocalDay) -> Bool {
        switch self {
        case .daily: true
        case .weekdays(let days): days.contains(day.weekday)
        }
    }

    public var isValid: Bool {
        if case .weekdays(let days) = self { return !days.isEmpty }
        return true
    }
}

/// A task that exists once and carries forward until completed.
public struct OneOffTask: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    /// Local date the task joined the daily list; carryover age is measured
    /// from this. For a task planned ahead, it becomes the planned date on arrival.
    public var createdDay: LocalDay
    public var completedAt: Date?
    /// Local date the task was completed, so yesterday's completions leave the list.
    public var completedDay: LocalDay?
    /// Planned for a future date and not yet arrived. Hidden until that day,
    /// when it moves to the top of the list and this is cleared.
    public var scheduledDay: LocalDay?
}

/// A recurrence template. Its position in `TodayState.order` is stable across days.
public struct RecurringSeries: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var recurrence: Recurrence
    public var createdAt: Date
    public var createdDay: LocalDay
}

/// One dated instance of a series. `(seriesID, day)` is unique.
public struct Occurrence: Codable, Hashable, Sendable {
    public let seriesID: UUID
    public let day: LocalDay
    public var completedAt: Date?
    /// The user removed just this day's instance.
    public var skipped: Bool = false
}

/// A goal on the long-term list. Never dated, never carried; it stays until done.
public struct LongTermTask: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var completedAt: Date?
    public var completedDay: LocalDay?
}

/// Schema v1 completion log. Read only to migrate into `history`.
public struct CompletionRecord: Codable, Hashable, Sendable {
    public let ref: TaskRef
    public let title: String
    public let completedAt: Date
}

/// What happened to one task on one past day.
public struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case task, recurring, longTerm }
    public enum Outcome: String, Codable, Sendable {
        case done
        /// A one-off left unfinished; it moved on to the next day.
        case carried
        /// A recurring occurrence left unfinished; it expired.
        case missed
    }

    public let ref: TaskRef
    public let title: String
    public let kind: Kind
    public let outcome: Outcome
    public let completedAt: Date?
    /// Days the task had already been carried on that day.
    public let carriedDays: Int

    public var id: String { ref.description }
    public var carryLabel: String? { CarryLabel.text(forDays: carriedDays) }
}

/// The closed list of one past day.
public struct DayRecord: Codable, Hashable, Sendable, Identifiable {
    public let day: LocalDay
    public var entries: [HistoryEntry]

    public var id: LocalDay { day }
    public var doneCount: Int { entries.filter { $0.outcome == .done }.count }
}

/// Lock Screen preferences and per-day bookkeeping for the Live Activity.
public struct LockScreenPreferences: Codable, Hashable, Sendable {
    /// Explicit opt-in; nothing is shown on the Lock Screen until this is true.
    public var enabled = false
    /// Schedule a noon card for days the app is not opened in the morning.
    public var autoNoonStart = true
    /// The user accepted that task titles are visible on the Lock Screen.
    public var privacyAcknowledged = false
    /// Day the user swiped the card away; it is not resurrected that day.
    public var dismissedDay: LocalDay?
    /// Day the app itself ended the card (all done, disabled). An end the app
    /// did not perform is either a user dismissal or the system's 8-hour limit.
    public var endedByAppDay: LocalDay?
    /// When today's card was last seen running, to tell a user dismissal
    /// (before 8 hours) from the system's active-duration limit.
    public var cardDay: LocalDay?
    public var cardStartedAt: Date?
    /// Day the user asked the card to show the long-term list instead.
    public var longTermDay: LocalDay?

    public init() {}
}

/// Stable reference to an actionable task row, used by intents and the UI.
/// Encoded as `o:<uuid>`, `r:<uuid>:<yyyy-MM-dd>` or `l:<uuid>`.
public enum TaskRef: Hashable, Sendable {
    case oneOff(UUID)
    case occurrence(seriesID: UUID, day: LocalDay)
    case longTerm(UUID)

    /// The id of the underlying task, series or goal.
    public var orderID: UUID {
        switch self {
        case .oneOff(let id): id
        case .occurrence(let id, _): id
        case .longTerm(let id): id
        }
    }
}

extension TaskRef: Codable, CustomStringConvertible {
    public var description: String {
        switch self {
        case .oneOff(let id): "o:\(id.uuidString)"
        case .occurrence(let id, let day): "r:\(id.uuidString):\(day)"
        case .longTerm(let id): "l:\(id.uuidString)"
        }
    }

    public init?(string: String) {
        let parts = string.split(separator: ":", maxSplits: 2).map(String.init)
        switch (parts.first, parts.count) {
        case ("o", 2):
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .oneOff(id)
        case ("l", 2):
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .longTerm(id)
        case ("r", 3):
            guard let id = UUID(uuidString: parts[1]), let day = LocalDay(string: parts[2]) else { return nil }
            self = .occurrence(seriesID: id, day: day)
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = TaskRef(string: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad TaskRef \(raw)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// Where a task lives: on a day (today or planned ahead), repeating, or on
/// the long-term list.
public enum TaskPlacement: Hashable, Sendable {
    case day(LocalDay)
    case repeating(Recurrence)
    case longTerm
}

/// The complete durable state. One JSON file, versioned.
public struct TodayState: Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion = TodayState.currentSchemaVersion
    public var oneOffs: [OneOffTask] = []
    public var series: [RecurringSeries] = []
    public var occurrences: [Occurrence] = []
    /// Manual priority order of one-off ids and series ids.
    public var order: [UUID] = []
    /// The long-term list, in manual order.
    public var longTerm: [LongTermTask] = []
    /// Closed past days, oldest first.
    public var history: [DayRecord] = []
    public var lockScreen = LockScreenPreferences()
    public var lastReconciledDay: LocalDay?
    /// v1's completion log, pending migration into `history`. Never written.
    public var legacyCompletionLog: [CompletionRecord] = []

    public init() {}
}

extension TodayState: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, oneOffs, series, occurrences, order, longTerm, history, lockScreen, lastReconciledDay
        case completionLog
    }

    /// Every field is optional on decode so older files (and newer files read
    /// by an older build after a rollback) never fail to load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        oneOffs = try c.decodeIfPresent([OneOffTask].self, forKey: .oneOffs) ?? []
        series = try c.decodeIfPresent([RecurringSeries].self, forKey: .series) ?? []
        occurrences = try c.decodeIfPresent([Occurrence].self, forKey: .occurrences) ?? []
        order = try c.decodeIfPresent([UUID].self, forKey: .order) ?? []
        longTerm = try c.decodeIfPresent([LongTermTask].self, forKey: .longTerm) ?? []
        history = try c.decodeIfPresent([DayRecord].self, forKey: .history) ?? []
        lockScreen = try c.decodeIfPresent(LockScreenPreferences.self, forKey: .lockScreen) ?? LockScreenPreferences()
        lastReconciledDay = try c.decodeIfPresent(LocalDay.self, forKey: .lastReconciledDay)
        legacyCompletionLog = try c.decodeIfPresent([CompletionRecord].self, forKey: .completionLog) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(oneOffs, forKey: .oneOffs)
        try c.encode(series, forKey: .series)
        try c.encode(occurrences, forKey: .occurrences)
        try c.encode(order, forKey: .order)
        try c.encode(longTerm, forKey: .longTerm)
        try c.encode(history, forKey: .history)
        try c.encode(lockScreen, forKey: .lockScreen)
        try c.encodeIfPresent(lastReconciledDay, forKey: .lastReconciledDay)
    }
}

/// A row as displayed in the app or projected for a future day.
public struct TaskRow: Identifiable, Hashable, Sendable {
    public let ref: TaskRef
    public let title: String
    /// Non-nil for rows that come from a series.
    public let recurrence: Recurrence?
    /// Whole calendar days a one-off has been carried; 0 for new or recurring tasks.
    public let carriedDays: Int
    public let completedAt: Date?

    public var id: String { ref.description }
    public var isCompleted: Bool { completedAt != nil }
    public var carryLabel: String? { CarryLabel.text(forDays: carriedDays) }
    public var isLongTerm: Bool {
        if case .longTerm = ref { return true }
        return false
    }
}

public enum CarryLabel {
    /// "From yesterday", "2 days carried", or nil when not carried.
    public static func text(forDays days: Int) -> String? {
        switch days {
        case ..<1: nil
        case 1: "From yesterday"
        default: "\(days) days carried"
        }
    }
}
