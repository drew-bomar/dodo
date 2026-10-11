import SwiftUI
import TodayCore

struct TodayView: View {
    @Environment(TodayStore.self) private var store
    /// nil follows today, so the view rolls over at midnight by itself.
    @State private var selectedDay: LocalDay?
    @State private var editing: TaskRow?
    @State private var showingSettings = false
    @State private var showingCalendar = false

    private var day: LocalDay { selectedDay ?? store.today }

    var body: some View {
        NavigationStack {
            List {
                if let error = store.storageError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                if day == store.today {
                    TodaySections(editing: $editing)
                } else if day < store.today {
                    PastDaySections(day: day)
                } else {
                    FutureDaySections(day: day, editing: $editing)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(DayNames.title(for: day, today: store.today))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    DayNavigator(day: day, today: store.today, select: select, openCalendar: { showingCalendar = true })
                }
                if day != store.today {
                    ToolbarItem(placement: .topBarLeading) {
                        BackToTodayButton(day: day, today: store.today) { select(store.today) }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
            .sheet(item: $editing) { row in
                TaskEditorSheet(row: row, placement: store.placement(of: row.ref.orderID) ?? .day(store.today),
                                today: store.today)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheet()
            }
            .sheet(isPresented: $showingCalendar) {
                CalendarSheet(day: day, today: store.today, select: select)
            }
            .onChange(of: store.today) { _, _ in selectedDay = nil }
        }
    }

    private func select(_ newDay: LocalDay) {
        withAnimation(.snappy) {
            selectedDay = newDay == store.today ? nil : newDay
        }
    }
}

// MARK: - Today

private struct TodaySections: View {
    @Environment(TodayStore.self) private var store
    @Binding var editing: TaskRow?
    @State private var showCompleted = false
    @State private var pendingDelete: TaskRow?

    var body: some View {
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

            QuickAddRow(prompt: "Add a task") { title in
                await store.add(title: title)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Tasks")
                Spacer()
                if store.totalCount > 0 {
                    Text("\(store.dailyDoneCount) of \(store.totalCount) done")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(store.dailyDoneCount)))
                        .accessibilityLabel("\(store.dailyDoneCount) of \(store.totalCount) tasks done")
                }
            }
        } footer: {
            if store.active.isEmpty && store.completed.isEmpty {
                Text("Add what you want to get done today. Drag to set priority — the top three appear on your Lock Screen.")
            }
        }
        .confirmationDialog("Delete repeating task?", isPresented: deleteDialogShown, titleVisibility: .visible,
                            presenting: pendingDelete) { row in
            if case .occurrence(let id, _) = row.ref {
                Button("Delete Series", role: .destructive) { Task { await store.delete(row.ref) } }
                Button("Skip Today Only") { Task { await store.skipToday(seriesID: id) } }
            }
        } message: { row in
            Text("“\(row.title)” repeats. Delete Series removes every future occurrence.")
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
                        .contentTransition(.numericText(value: Double(store.completed.count)))
                        .foregroundStyle(.secondary)
                }
            }
        }

        LongTermSection(editing: $editing)
    }

    private func requestDelete(_ row: TaskRow) {
        if row.recurrence == nil {
            Task { await store.delete(row.ref) }
        } else {
            pendingDelete = row
        }
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

private struct LongTermSection: View {
    @Environment(TodayStore.self) private var store
    @Binding var editing: TaskRow?

    var body: some View {
        Section {
            ForEach(store.longTerm) { row in
                TaskRowView(row: row) {
                    Task { await store.complete(row.ref) }
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = row }
                .swipeActions(edge: .leading) {
                    Button("Do Today", systemImage: "arrow.up.to.line") {
                        Task { await store.doToday(row.ref.orderID) }
                    }
                    .tint(.accentColor)
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await store.delete(row.ref) }
                    }
                }
            }
            .onMove { from, to in store.moveLongTerm(fromOffsets: from, toOffset: to) }

            QuickAddRow(prompt: "Add a long-term goal") { title in
                await store.add(title: title, placement: .longTerm)
            }
        } header: {
            Label("Long-term", systemImage: "flag")
        } footer: {
            Text("Goals without a date. Swipe right to do one today. Once today's list is done, the Lock Screen offers your top three.")
        }
    }
}

// MARK: - Past day

private struct PastDaySections: View {
    @Environment(TodayStore.self) private var store
    let day: LocalDay

    var body: some View {
        if let record = store.record(for: day) {
            Section {
                ForEach(record.entries) { entry in
                    HistoryRowView(entry: entry)
                }
            } header: {
                HStack {
                    Text("Your list")
                    Spacer()
                    Text("\(record.doneCount) of \(record.entries.count) done").monospacedDigit()
                }
            }
        } else {
            Section {
                ContentUnavailableView("Nothing Recorded", systemImage: "calendar",
                                       description: Text("There were no tasks on this day."))
            }
        }
    }
}

private struct HistoryRowView: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: entry.outcome == .done ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(entry.outcome == .done ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .foregroundStyle(entry.outcome == .done ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    switch entry.outcome {
                    case .done:
                        if let at = entry.completedAt {
                            Text("Done \(at.formatted(date: .omitted, time: .shortened))")
                        }
                    case .carried:
                        Text("Not done · carried forward").foregroundStyle(.orange)
                    case .missed:
                        Text("Missed")
                    }
                    if entry.kind == .recurring {
                        Image(systemName: "repeat").accessibilityLabel("Repeating")
                    } else if entry.kind == .longTerm {
                        Image(systemName: "flag").accessibilityLabel("Long-term")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(entry.outcome == .done ? "Done" : entry.outcome == .missed ? "Missed" : "Not done")
    }
}

// MARK: - Future day

private struct FutureDaySections: View {
    @Environment(TodayStore.self) private var store
    let day: LocalDay
    @Binding var editing: TaskRow?

    var body: some View {
        let planned = store.planned(on: day)
        let alsoOn = store.alsoOn(day)

        Section {
            ForEach(planned) { row in
                PlannedRowView(title: row.title, systemImage: "calendar")
                    .contentShape(Rectangle())
                    .onTapGesture { editing = row }
                    .swipeActions(edge: .leading) {
                        Button("Do Today", systemImage: "arrow.up.to.line") {
                            Task { await store.doToday(row.ref.orderID) }
                        }
                        .tint(.accentColor)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await store.delete(row.ref) }
                        }
                    }
            }
            .onMove { from, to in store.movePlanned(on: day, fromOffsets: from, toOffset: to) }

            QuickAddRow(prompt: "Plan a task for this day") { title in
                await store.add(title: title, placement: .day(day))
            }
        } header: {
            Text("Planned")
        } footer: {
            Text("Planned tasks join the top of your list on \(DayNames.title(for: day, today: store.today).lowercasedIfRelative) and appear on the Lock Screen then.")
        }
        .animation(.default, value: planned.map(\.id))

        if !alsoOn.isEmpty {
            Section {
                ForEach(alsoOn) { row in
                    PlannedRowView(title: row.title,
                                   systemImage: row.recurrence != nil ? "repeat" : "arrow.turn.down.right",
                                   detail: row.recurrence?.shortDescription ?? row.carryLabel.map { "If not done · \($0.lowercased())" })
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Also on this day")
            }
        }
    }
}

private struct PlannedRowView: View {
    let title: String
    let systemImage: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared rows

struct QuickAddRow: View {
    let prompt: String
    let add: (String) async -> Bool
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            TextField(prompt, text: $title)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(submit)
        }
    }

    private func submit() {
        let text = title
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        title = ""
        // Put the keyboard away; tapping the field again starts the next task.
        focused = false
        Task { _ = await add(text) }
    }
}

struct TaskRowView: View {
    let row: TaskRow
    let toggle: () -> Void

    /// Completing plays out in place before the row leaves the list:
    /// check + haptic, then a strike drawn left to right, then `toggle`.
    @State private var finishing = false
    @State private var strike: CGFloat = 0

    private static let checkBeat: Duration = .milliseconds(180)
    private static let strikeDuration = 0.4
    private static let holdAfterStrike: Duration = .milliseconds(400)

    private var showsDone: Bool { row.isCompleted || finishing }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: tap) {
                Image(systemName: showsDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(showsDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .disabled(finishing)
            .sensoryFeedback(.success, trigger: finishing) { _, new in new }
            .accessibilityLabel(row.isCompleted ? "Mark “\(row.title)” not done" : "Complete “\(row.title)”")

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .strikethrough(row.isCompleted)
                    .foregroundStyle(showsDone ? .secondary : .primary)
                    // The animated strike: a struck-through copy of the title,
                    // revealed from the leading edge.
                    .overlay(alignment: .leading) {
                        if finishing {
                            Text(row.title)
                                .strikethrough(color: .secondary)
                                .foregroundStyle(.clear)
                                .mask(alignment: .leading) {
                                    Rectangle().scaleEffect(x: strike, anchor: .leading)
                                }
                                .accessibilityHidden(true)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let carry = row.carryLabel, !row.isCompleted {
                        Text(carry)
                            .foregroundStyle(CarryLabel.isUrgent(days: row.carriedDays) ? .red : .orange)
                    }
                    if let recurrence = row.recurrence {
                        Label(recurrence.shortDescription, systemImage: "repeat")
                            .foregroundStyle(.secondary)
                    }
                    if row.isLongTerm && row.isCompleted {
                        Label("Long-term", systemImage: "flag")
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

    private func tap() {
        // Un-completing (from the Completed section) is immediate.
        guard !row.isCompleted else { return toggle() }
        Task { @MainActor in
            withAnimation(.snappy(duration: 0.2)) { finishing = true }
            try? await Task.sleep(for: Self.checkBeat)
            withAnimation(.easeInOut(duration: Self.strikeDuration)) { strike = 1 }
            try? await Task.sleep(for: .seconds(Self.strikeDuration) + Self.holdAfterStrike)
            toggle()
        }
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
