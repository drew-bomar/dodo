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

/// ‹  Friday, October 2  › with a jump-to-today button when elsewhere.
struct DayNavigator: View {
    let day: LocalDay
    let today: LocalDay
    let select: (LocalDay) -> Void
    let openCalendar: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { select(day.adding(days: -1)) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 36)
            }
            .accessibilityLabel("Previous day")

            Button(action: openCalendar) {
                HStack(spacing: 6) {
                    Text(DayNames.long(day))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Image(systemName: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("\(DayNames.long(day)). Choose a date")

            Button { select(day.adding(days: 1)) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 36)
            }
            .accessibilityLabel("Next day")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(alignment: .trailing) {
            if day != today {
                Button("Today") { select(today) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.mini)
                    .padding(.trailing, 52)
                    .transition(.opacity)
            }
        }
        .background(.bar)
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
