import AppIntents
import Foundation

// These intents are compiled into both the app and the widget extension so
// the Live Activity's buttons can reference them. Apple documents that a
// LiveActivityIntent included in the app target runs in the app's process,
// so `perform()` only does real work when compiled with TODAY_APP and the
// extension never touches task storage.

/// The checkbox on the Lock Screen card. Idempotent: the reference names one
/// specific task (and day, for recurring tasks), so a duplicate or stale tap
/// can never complete a different task or un-complete a finished one.
struct CompleteTaskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Complete Task"
    static let isDiscoverable = false

    @Parameter(title: "Task")
    var taskRef: String

    init() {}

    init(taskRef: String) {
        self.taskRef = taskRef
    }

    func perform() async throws -> some IntentResult {
        #if TODAY_APP
        await TodayStore.shared.completeFromLockScreen(refString: taskRef)
        #endif
        return .result()
    }
}

/// Starts (or refreshes) today's Lock Screen card. Exposed to Shortcuts so a
/// personal "Time of Day" automation can serve as a renewal fallback.
struct ShowTodayOnLockScreenIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Show Today on Lock Screen"
    static let description = IntentDescription("Starts or refreshes today's task card on the Lock Screen.")

    init() {}

    func perform() async throws -> some IntentResult {
        #if TODAY_APP
        await TodayStore.shared.startTodayFromIntent()
        #endif
        return .result()
    }
}
