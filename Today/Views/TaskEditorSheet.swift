import SwiftUI
import TodayCore

struct TaskEditorSheet: View {
    enum ListKind: Hashable { case daily, longTerm }
    enum Repeat: Hashable { case never, daily, days }

    @Environment(TodayStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let row: TaskRow
    let original: TaskPlacement
    let today: LocalDay
    @State private var title: String
    @State private var list: ListKind
    @State private var date: Date
    @State private var repeatMode: Repeat
    @State private var days: Set<Weekday>
    @State private var confirmDelete = false

    init(row: TaskRow, placement: TaskPlacement, today: LocalDay) {
        self.row = row
        self.original = placement
        self.today = today
        _title = State(initialValue: row.title)
        var list = ListKind.daily
        var day = today
        var mode = Repeat.never
        var selected = Set<Weekday>()
        switch placement {
        case .day(let d): day = d
        case .repeating(.daily): mode = .daily
        case .repeating(.weekdays(let s)): mode = .days; selected = s
        case .longTerm: list = .longTerm
        }
        _list = State(initialValue: list)
        _date = State(initialValue: day.date(hour: 12, in: .current))
        _repeatMode = State(initialValue: mode)
        _days = State(initialValue: selected)
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var placement: TaskPlacement {
        switch (list, repeatMode) {
        case (.longTerm, _): .longTerm
        case (.daily, .never): .day(max(today, LocalDay(date, in: .current)))
        case (.daily, .daily): .repeating(.daily)
        case (.daily, .days): .repeating(.weekdays(days))
        }
    }

    private var canSave: Bool {
        guard !trimmed.isEmpty else { return false }
        if case .repeating(let r) = placement { return r.isValid }
        return true
    }

    private var isSeries: Bool { if case .repeating = original { true } else { false } }

    /// Planned for later or on the long-term list: offer pulling it into today.
    private var canDoToday: Bool {
        switch original {
        case .longTerm: true
        case .day(let d): d > today
        case .repeating: false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Task", text: $title, axis: .vertical)
                        .lineLimit(1...5)
                }

                Section {
                    Picker("List", selection: $list) {
                        Text("Daily").tag(ListKind.daily)
                        Text("Long-term").tag(ListKind.longTerm)
                    }
                    .pickerStyle(.segmented)

                    if list == .daily {
                        Picker("Repeat", selection: $repeatMode) {
                            Text("Never").tag(Repeat.never)
                            Text("Every day").tag(Repeat.daily)
                            Text("Selected days").tag(Repeat.days)
                        }
                        if repeatMode == .days {
                            WeekdayPicker(selection: $days)
                        }
                        if repeatMode == .never {
                            DatePicker("Day", selection: $date, in: today.date(hour: 0, in: .current)...,
                                       displayedComponents: .date)
                        }
                    }
                } footer: {
                    Text(footer)
                }

                if canDoToday {
                    Section {
                        Button("Do Today", systemImage: "arrow.up.to.line") {
                            Task {
                                await store.doToday(row.ref.orderID)
                                dismiss()
                            }
                        }
                    }
                }

                Section {
                    Button(isSeries ? "Delete…" : "Delete", role: .destructive) {
                        if isSeries {
                            confirmDelete = true
                        } else {
                            Task { await store.delete(row.ref); dismiss() }
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
                            if await store.edit(orderID: row.ref.orderID, title: trimmed, placement: placement) {
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
                if case .occurrence(let id, let day) = row.ref, day == today {
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

    private var footer: String {
        switch placement {
        case .longTerm:
            "No date. Shown below today's list, and on the Lock Screen once today is done."
        case .repeating:
            isSeries ? "Changes apply to today's unfinished task and every future day."
                     : "A fresh copy appears on each scheduled day. Missed days don't pile up."
        case .day(let d):
            d > today ? "Hidden until \(DayNames.title(for: d, today: today).lowercasedIfRelative), then added to the top of that day's list."
                      : "Stays on your list until done, carrying over each day."
        }
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
