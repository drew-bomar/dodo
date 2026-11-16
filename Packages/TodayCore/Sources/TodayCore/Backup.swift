import Foundation

/// Moving all data between installs: the backup is the state file itself,
/// so any version's backup restores into any later version via `migrate`.
/// Needed because a build signed by a different team (for example the App
/// Store release after the free-team builds) can't install over the old app,
/// and deleting the app deletes its data.
public enum Backup {
    public enum Failure: Error, Equatable, LocalizedError {
        /// Not a backup from this app (wrong file, or damaged).
        case notABackup
        /// Written by a newer version that this one can't safely read.
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notABackup: "This file isn't a Today backup."
            case .newerVersion: "This backup is from a newer version of Today. Update the app, then restore."
            }
        }
    }

    public static func data(for state: TodayState) throws -> Data {
        try JSONEncoder.today.encode(state)
    }

    /// Decodes a backup ready to replace the current state. Lock Screen card
    /// bookkeeping is cleared: it describes cards on the old install, and
    /// left in place it could read as "you dismissed today's card".
    public static func restore(from data: Data, timeZone: TimeZone) throws -> TodayState {
        // State decoding is deliberately tolerant (every field is optional),
        // so any JSON object would decode as an empty list. Require the
        // version marker every saved state carries before trusting it.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int else {
            throw Failure.notABackup
        }
        guard version <= TodayState.currentSchemaVersion else { throw Failure.newerVersion(version) }
        var state: TodayState
        do {
            state = try JSONDecoder.today.decode(TodayState.self, from: data)
        } catch {
            throw Failure.notABackup
        }
        state.migrate(timeZone: timeZone)
        state.lockScreen.cardDay = nil
        state.lockScreen.cardStartedAt = nil
        state.lockScreen.dismissedDay = nil
        state.lockScreen.endedByAppDay = nil
        return state
    }

    /// File name for an export, e.g. "Today Backup 2026-11-01.json".
    public static func fileName(on day: LocalDay) -> String {
        "Today Backup \(day).json"
    }
}
