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
    /// Local date of creation; carryover age is measured from this.
    public var createdDay: LocalDay
    public var completedAt: Date?
    /// Local date the task was completed, so yesterday's completions leave the list.
    public var completedDay: LocalDay?
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

/// Lightweight local completion log. No dashboard reads it; it exists so
/// completion history is not silently discarded.
public struct CompletionRecord: Codable, Hashable, Sendable {
    public let ref: TaskRef
    public let title: String
    public let completedAt: Date
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

    public init() {}
}

/// Stable reference to an actionable task row, used by intents and the UI.
/// Encoded as `o:<uuid>` or `r:<uuid>:<yyyy-MM-dd>`.
public enum TaskRef: Hashable, Sendable {
    case oneOff(UUID)
    case occurrence(seriesID: UUID, day: LocalDay)

    /// The id that holds this task's slot in the manual order.
    public var orderID: UUID {
        switch self {
        case .oneOff(let id): id
        case .occurrence(let id, _): id
        }
    }
}

extension TaskRef: Codable, CustomStringConvertible {
    public var description: String {
        switch self {
        case .oneOff(let id): "o:\(id.uuidString)"
        case .occurrence(let id, let day): "r:\(id.uuidString):\(day)"
        }
    }

    public init?(string: String) {
        let parts = string.split(separator: ":", maxSplits: 2).map(String.init)
        switch (parts.first, parts.count) {
        case ("o", 2):
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .oneOff(id)
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

/// The complete durable state. One JSON file, versioned.
public struct TodayState: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = TodayState.currentSchemaVersion
    public var oneOffs: [OneOffTask] = []
    public var series: [RecurringSeries] = []
    public var occurrences: [Occurrence] = []
    /// Manual priority order of one-off ids and series ids.
    public var order: [UUID] = []
    public var completionLog: [CompletionRecord] = []
    public var lockScreen = LockScreenPreferences()
    public var lastReconciledDay: LocalDay?

    public init() {}
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
