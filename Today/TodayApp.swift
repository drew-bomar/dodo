import SwiftUI
import UIKit

@main
struct TodayApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = TodayStore.shared

    var body: some Scene {
        WindowGroup {
            TodayView()
                .environment(store)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { Task { await store.refresh() } }
                }
                // A calendar boundary alone never wakes the app; these fire
                // while it is running (midnight, time-zone and clock changes).
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    Task { await store.refresh() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    Task { await store.timeZoneChanged() }
                }
        }
    }
}
