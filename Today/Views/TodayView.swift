import SwiftUI
import TodayCore

struct TodayView: View {
    @Environment(TodayStore.self) private var store
    @State private var newTitle = ""
    @State private var editing: TaskRow?
    @State private var showingSettings = false
    @State private var showCompleted = false
    @State private var pendingDelete: TaskRow?
    @FocusState private var addFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if let error = store.storageError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    ForEach(store.active) { row in
                        TaskRowView(row: row) {
                            Task { await store.complete(row.ref) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = row }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { requestDelete(row) }
                        }
                    }
                    .onMove { from, to in store.move(fromOffsets: from, toOffset: to) }

                    quickAdd
                } header: {
                    header
                } footer: {
                    if store.active.isEmpty && store.completed.isEmpty {
                        Text("Add what you want to get done today. Drag to set priority — the top three appear on your Lock Screen.")
                    }
                }

                if !store.completed.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showCompleted) {
                            ForEach(store.completed) { row in
                                TaskRowView(row: row) {
                                    Task { await store.uncomplete(row.ref) }
                                }
                            }
                        } label: {
                            Text("Completed (\(store.completed.count))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .animation(.default, value: store.active.map(\.id))
            .animation(.default, value: store.completed.map(\.id))
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.active.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
            .sheet(item: $editing) { row in
                TaskEditorSheet(row: row)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheet()
            }
            .confirmationDialog(deleteTitle, isPresented: deleteDialogShown, titleVisibility: .visible, presenting: pendingDelete) { row in
                if case .occurrence(let id, _) = row.ref {
                    Button("Delete Series", role: .destructive) { Task { await store.delete(row.ref) } }
                    Button("Skip Today Only") { Task { await store.skipToday(seriesID: id) } }
                } else {
                    Button("Delete", role: .destructive) { Task { await store.delete(row.ref) } }
                }
            } message: { row in
                if row.recurrence != nil {
                    Text("“\(row.title)” repeats. Delete removes every future occurrence.")
                }
            }
            .sensoryFeedback(.success, trigger: store.completed.count) { old, new in new > old }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.today.date(hour: 12, in: .current).formatted(.dateTime.weekday(.wide).month(.wide).day()))
            Spacer()
            if store.totalCount > 0 {
                Text("\(store.completed.count) of \(store.totalCount) done")
                    .monospacedDigit()
                    .accessibilityLabel("\(store.completed.count) of \(store.totalCount) tasks done")
            }
        }
        .textCase(nil)
    }

    private var quickAdd: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            TextField("Add a task", text: $newTitle)
                .focused($addFocused)
                .submitLabel(.done)
                .onSubmit(submit)
        }
    }

    private func submit() {
        let title = newTitle
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        newTitle = ""
        addFocused = true
        Task { await store.add(title: title) }
    }

    private func requestDelete(_ row: TaskRow) {
        if row.recurrence == nil {
            Task { await store.delete(row.ref) }
        } else {
            pendingDelete = row
        }
    }

    private var deleteTitle: String { "Delete repeating task?" }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

struct TaskRowView: View {
    let row: TaskRow
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: row.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(row.isCompleted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(row.isCompleted ? "Mark “\(row.title)” not done" : "Complete “\(row.title)”")

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .strikethrough(row.isCompleted)
                    .foregroundStyle(row.isCompleted ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let carry = row.carryLabel, !row.isCompleted {
                        Text(carry).foregroundStyle(.orange)
                    }
                    if let recurrence = row.recurrence {
                        Label(recurrence.shortDescription, systemImage: "repeat")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

extension Recurrence {
    var shortDescription: String {
        switch self {
        case .daily: return "Daily"
        case .weekdays(let days):
            let set = Set(days)
            if set == [.monday, .tuesday, .wednesday, .thursday, .friday] { return "Weekdays" }
            if set == [.saturday, .sunday] { return "Weekends" }
            let symbols = Calendar.current.shortWeekdaySymbols
            return days.sorted().map { symbols[$0.rawValue - 1] }.joined(separator: ", ")
        }
    }
}
