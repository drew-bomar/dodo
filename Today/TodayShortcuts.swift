import AppIntents

struct TodayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowTodayOnLockScreenIntent(),
            phrases: ["Show \(.applicationName) on Lock Screen"],
            shortTitle: "Show on Lock Screen",
            systemImageName: "checklist"
        )
    }
}
