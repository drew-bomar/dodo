import SwiftUI
import TodayCore
import UIKit

struct SettingsSheet: View {
    @Environment(TodayStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showPrivacyNote = false
    #if DEBUG
    @State private var debugMessage = ""
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show on Lock Screen", isOn: Binding(
                        get: { store.lockScreen.enabled },
                        set: { on in
                            if on && !store.lockScreen.privacyAcknowledged {
                                showPrivacyNote = true
                            } else {
                                Task { await store.setLockScreenEnabled(on) }
                            }
                        }
                    ))
                    Toggle("Start automatically at noon", isOn: Binding(
                        get: { store.lockScreen.autoNoonStart },
                        set: { on in Task { await store.setAutoNoonStart(on) } }
                    ))
                    .disabled(!store.lockScreen.enabled)
                } footer: {
                    Text("Opening Today starts the card right away. On days you don't, the card appears at noon by itself. Your top three unfinished tasks are shown, and the checkbox completes a task without opening the app.")
                }

                if store.lockScreen.enabled {
                    Section("Status") {
                        statusRow
                        if let error = store.lockReport.lastError {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Text("iOS keeps a card active for up to 8 hours, then removes it from the Lock Screen within 4 more. A card started at noon lasts into the evening; opening Today later starts a fresh one. Nothing shows overnight until the next card starts.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("How long the card stays")
                    }
                    Section {
                        Text("If the noon cards ever run out (for example after several days without opening Today), you can add a Shortcuts automation: Automation → Time of Day → “Show Today on Lock Screen”, set to Run Immediately.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Optional backup")
                    }
                }

                #if DEBUG
                Section("Debug") {
                    Button("Schedule test card in 1 minute") {
                        Task { debugMessage = await store.debugScheduleTestCard(in: 60) }
                    }
                    Button("Schedule test card in 3 minutes") {
                        Task { debugMessage = await store.debugScheduleTestCard(in: 180) }
                    }
                    Button("End test cards") {
                        Task { await store.debugEndTestCards(); debugMessage = store.debugActivities() }
                    }
                    Button("List activities") { debugMessage = store.debugActivities() }
                    if !debugMessage.isEmpty {
                        Text(debugMessage).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Tasks on your Lock Screen", isPresented: $showPrivacyNote) {
                Button("Cancel", role: .cancel) {}
                Button("Show on Lock Screen") {
                    Task { await store.setLockScreenEnabled(true) }
                }
            } message: {
                Text("Task titles will be visible on your Lock Screen, even while your iPhone is locked. Everything stays on this iPhone.")
            }
            .task { await store.refresh() }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch store.lockReport.status {
        case .off:
            Label("Off", systemImage: "lock")
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                Label("Live Activities are turned off for Today", systemImage: "exclamationmark.triangle")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .showing:
            Label("Showing on the Lock Screen now", systemImage: "checkmark.circle")
            coverage
        case .scheduled(let date):
            Label("Next card \(date.formatted(.relative(presentation: .named))) at \(date.formatted(date: .omitted, time: .shortened))",
                  systemImage: "clock")
            coverage
        case .dismissedToday:
            VStack(alignment: .leading, spacing: 8) {
                Label("Hidden for today", systemImage: "eye.slash")
                Button("Show Today's Card Again") { Task { await store.showTodayAgain() } }
            }
            coverage
        case .doneToday:
            Label("All done today", systemImage: "checkmark.seal")
            coverage
        case .nothingScheduled:
            Label("Nothing scheduled", systemImage: "calendar.badge.exclamationmark")
        }
    }

    @ViewBuilder private var coverage: some View {
        if store.lockScreen.autoNoonStart, let through = store.lockReport.coveredThrough {
            Text("Noon cards are set through \(through.date(hour: 12, in: .current).formatted(.dateTime.weekday(.wide).month().day())). Opening Today extends this.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
