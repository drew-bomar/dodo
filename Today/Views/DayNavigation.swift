import SwiftUI
import TodayCore

enum DayNames {
    /// "Today", "Yesterday", "Tomorrow", or "Wed, Oct 7" (with the year when it differs).
    static func title(for day: LocalDay, today: LocalDay) -> String {
        switch today.days(until: day) {
        case 0: return "Today"
        case -1: return "Yesterday"
        case 1: return "Tomorrow"
        default:
            let date = day.date(hour: 12, in: .current)
            let style: Date.FormatStyle = day.year == today.year
                ? .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                : .dateTime.weekday(.abbreviated).month(.abbreviated).day().year()
            return date.formatted(style)
        }
    }

    static func long(_ day: LocalDay) -> String {
        day.date(hour: 12, in: .current).formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

extension String {
    /// "Tomorrow" → "tomorrow" inside a sentence; dates stay as they are.
    var lowercasedIfRelative: String {
        ["Today", "Yesterday", "Tomorrow"].contains(self) ? lowercased() : self
    }
}

/// The navigation bar's title: ‹ Today ›, with the date beneath relative
/// names. Tapping the title opens the calendar.
struct DayNavigator: View {
    let day: LocalDay
    let today: LocalDay
    let select: (LocalDay) -> Void
    let openCalendar: () -> Void

    private var title: String { DayNames.title(for: day, today: today) }
    /// "Today" etc. get the date underneath; explicit dates already say it.
    private var isRelative: Bool { abs(today.days(until: day)) <= 1 }

    var body: some View {
        HStack(spacing: 0) {
            Button { select(day.adding(days: -1)) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous day")

            Button(action: openCalendar) {
                VStack(spacing: 0) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if isRelative {
                        Text(day.date(hour: 12, in: .current).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .frame(minWidth: 110, minHeight: 36)
                .contentShape(Rectangle())
                .contentTransition(.numericText())
            }
            .accessibilityLabel("\(DayNames.long(day)). Choose a date")

            Button { select(day.adding(days: 1)) } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next day")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}

/// Shown while viewing another day. The U-turn points the way back:
/// forward from a past day, backward from a future one.
struct BackToTodayButton: View {
    let day: LocalDay
    let today: LocalDay
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Today", systemImage: day < today ? "arrow.uturn.forward" : "arrow.uturn.backward")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel("Back to today")
    }
}

struct CalendarSheet: View {
    let day: LocalDay
    let today: LocalDay
    let select: (LocalDay) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(day: LocalDay, today: LocalDay, select: @escaping (LocalDay) -> Void) {
        self.day = day
        self.today = today
        self.select = select
        _date = State(initialValue: day.date(hour: 12, in: .current))
    }

    var body: some View {
        NavigationStack {
            DatePicker("Day", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                .onChange(of: date) { _, new in
                    select(LocalDay(new, in: .current))
                    dismiss()
                }
                .navigationTitle("Go to Day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Today") {
                            select(today)
                            dismiss()
                        }
                    }
                }
            Spacer()
        }
        .presentationDetents([.medium, .large])
    }
}
