import SwiftUI
import TodayCore

struct TaskEditorSheet: View {
    enum Repeat: Hashable { case never, daily, days }

    @Environment(TodayStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let row: TaskRow
    @State private var title: String
    @State private var repeatMode: Repeat
    @State private var days: Set<Weekday>
    @State private var confirmDelete = false

    init(row: TaskRow) {
        self.row = row
        _title = State(initialValue: row.title)
        switch row.recurrence {
        case nil:
            _repeatMode = State(initialValue: .never)
            _days = State(initialValue: [])
        case .daily:
            _repeatMode = State(initialValue: .daily)
            _days = State(initialValue: [])
        case .weekdays(let selected):
            _repeatMode = State(initialValue: .days)
            _days = State(initialValue: selected)
        }
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var recurrence: Recurrence? {
        switch repeatMode {
        case .never: nil
        case .daily: .daily
        case .days: .weekdays(days)
        }
    }

    private var canSave: Bool { !trimmed.isEmpty && (recurrence?.isValid ?? true) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Task", text: $title, axis: .vertical)
                        .lineLimit(1...5)
                }

                Section {
                    Picker("Repeat", selection: $repeatMode) {
                        Text("Never").tag(Repeat.never)
                        Text("Every day").tag(Repeat.daily)
                        Text("Selected days").tag(Repeat.days)
                    }
                    if repeatMode == .days {
                        WeekdayPicker(selection: $days)
                    }
                } footer: {
                    if row.recurrence != nil {
                        Text("Changes apply to today's unfinished task and every future day.")
                    } else if repeatMode != .never {
                        Text("A fresh copy appears on each scheduled day. Missed days don't pile up.")
                    }
                }

                Section {
                    Button(row.recurrence == nil ? "Delete Task" : "Delete…", role: .destructive) {
                        if row.recurrence == nil {
                            Task { await store.delete(row.ref); dismiss() }
                        } else {
                            confirmDelete = true
                        }
                    }
                }
            }
            .navigationTitle("Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await store.edit(orderID: row.ref.orderID, title: trimmed, recurrence: recurrence) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .confirmationDialog("Delete repeating task?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Series", role: .destructive) {
                    Task { await store.delete(row.ref); dismiss() }
                }
                if case .occurrence(let id, _) = row.ref {
                    Button("Skip Today Only") {
                        Task { await store.skipToday(seriesID: id); dismiss() }
                    }
                }
            } message: {
                Text("Delete Series removes “\(row.title)” from every future day.")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Weekday>

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let full = Calendar.current.weekdaySymbols
        // Respect the user's first weekday (Monday in many locales).
        let first = Calendar.current.firstWeekday
        let ordered = (0..<7).map { Weekday(rawValue: (first - 1 + $0) % 7 + 1)! }

        HStack {
            ForEach(ordered, id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(symbols[day.rawValue - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: Circle())
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(full[day.rawValue - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
