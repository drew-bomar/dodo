import Foundation

public protocol StateStorage: Sendable {
    /// Returns nil when nothing has been saved yet.
    func load() throws -> TodayState?
    func save(_ state: TodayState) throws
}

/// One JSON file written atomically. Lives in the app's own container: the
/// widget extension never reads it, because Lock Screen completions run the
/// intent in the app process.
public struct FileStateStorage: StateStorage {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `Application Support/Today/state.json`. Included in device backups.
    public static func defaultLocation() throws -> FileStateStorage {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Today", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileStateStorage(url: dir.appendingPathComponent("state.json"))
    }

    public func load() throws -> TodayState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder.today.decode(TodayState.self, from: data)
        } catch {
            // Never silently discard user data: keep the unreadable file beside
            // the new one so it can be recovered by hand.
            let backup = url.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            throw error
        }
    }

    public func save(_ state: TodayState) throws {
        let data = try JSONEncoder.today.encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

public final class InMemoryStorage: StateStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TodayState?
    public private(set) var saveCount = 0

    public init(_ state: TodayState? = nil) { stored = state }

    public func load() throws -> TodayState? { lock.withLock { stored } }

    public func save(_ state: TodayState) throws {
        lock.withLock {
            stored = state
            saveCount += 1
        }
    }
}

extension JSONEncoder {
    static var today: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var today: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Serializes every read and write of the task state. The app UI and the
/// Lock Screen intent share one instance (both run in the app process), so
/// concurrent operations queue on the actor instead of losing writes.
/// Every mutation reconciles to today, is saved, and only then returns, so
/// callers publish Live Activity updates from persisted state.
public actor TaskRepository {
    private let storage: StateStorage
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone
    private var cached: TodayState?
    /// The cached state differs from disk (a migration ran on load).
    private var unsaved = false

    public init(storage: StateStorage,
                now: @escaping @Sendable () -> Date = { Date() },
                timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current }) {
        self.storage = storage
        self.now = now
        self.timeZone = timeZone
    }

    public var context: DayContext { DayContext(now: now(), timeZone: timeZone()) }

    /// The reconciled state for today. Saves if reconciliation changed anything.
    public func current() throws -> (state: TodayState, context: DayContext) {
        let r = try mutate { _, _ in }
        return (r.state, r.context)
    }

    @discardableResult
    public func mutate<T: Sendable>(_ body: (inout TodayState, DayContext) throws -> T) throws -> (state: TodayState, context: DayContext, result: T) {
        let ctx = context
        var state = try loadedState()
        let original = state
        state.reconcile(today: ctx.today)
        let result = try body(&state, ctx)
        if state != original || unsaved {
            try storage.save(state)
            cached = state
            unsaved = false
        }
        return (state, ctx, result)
    }

    private func loadedState() throws -> TodayState {
        if let cached { return cached }
        var loaded = try storage.load() ?? TodayState()
        let before = loaded
        loaded.migrate(timeZone: timeZone())
        unsaved = loaded != before
        cached = loaded
        return loaded
    }

    /// Drops the in-memory copy so the next access re-reads disk.
    public func invalidate() { cached = nil }
}
