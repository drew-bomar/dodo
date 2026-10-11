import ActivityKit
import AppIntents
import SwiftUI
import TodayCore
import WidgetKit

@main
struct TodayWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayLiveActivity()
    }
}

struct TodayLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TodayActivityAttributes.self) { context in
            LockScreenCard(snapshot: context.state, isStale: context.isStale)
                .activitySystemActionForegroundColor(.accentColor)
        } dynamicIsland: { context in
            // Required by ActivityKit; kept minimal since the target phone has no Dynamic Island.
            let left = context.state.rows.count(where: { !$0.done }) + context.state.moreCount
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Today", systemImage: "checklist").font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(left == 0 ? "Done" : "\(left) left").monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let first = context.state.rows.first {
                        Text(first.title).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "checklist")
            } compactTrailing: {
                Text(left == 0 ? "✓" : "\(left)").monospacedDigit()
            } minimal: {
                Text(left == 0 ? "✓" : "\(left)").monospacedDigit()
            }
        }
    }
}

/// The Lock Screen card. iOS caps a Live Activity's Lock Screen height
/// (about 160 pt) and clips anything taller, so the layout is budgeted to fit
/// three one-line rows: the header carries the remaining count instead of a
/// separate "+n more" line, and carry labels sit beside the title.
struct LockScreenCard: View {
    let snapshot: ActivitySnapshot
    var isStale = false

    private var remaining: Int { snapshot.rows.count(where: { !$0.done }) + snapshot.moreCount }
    private var isLongTerm: Bool { snapshot.mode == .longTerm }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(isLongTerm ? "Long-term" : "Today", systemImage: isLongTerm ? "flag" : "checklist")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                if snapshot.hasTasks {
                    Text("\(remaining) left")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(remaining)))
                }
            }
            .accessibilityElement(children: .combine)

            if snapshot.hasTasks {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.rows) { row in
                        LockScreenTaskRow(row: row)
                            .id(row.ref)
                            // A finished row fades out in place while the rows
                            // below slide up; the next task enters from below.
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity))
                    }
                }
            } else {
                Label(isLongTerm ? "All done" : "All done for today", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                if snapshot.longTermOffer > 0 {
                    Button(intent: ShowLongTermIntent()) {
                        Label("See long-term list (\(snapshot.longTermOffer))", systemImage: "flag")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .opacity(isStale ? 0.6 : 1)
    }
}

struct LockScreenTaskRow: View {
    let row: ActivitySnapshot.Row

    var body: some View {
        HStack(spacing: 10) {
            // Only the checkbox completes; tapping elsewhere opens the app.
            Button(intent: CompleteTaskIntent(taskRef: row.ref)) {
                Image(systemName: row.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(row.done)
            .accessibilityLabel(row.done ? "\(row.title), done" : "Complete \(row.title)")

            Text(row.title)
                .font(.body)
                .lineLimit(1)
                .strikethrough(row.done)
                .foregroundStyle(row.done ? .secondary : .primary)
                .layoutPriority(1)

            Spacer(minLength: 4)

            if let carry = row.carryLabel, !row.done {
                Text(carry)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(row.isUrgent ? .red : .orange)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Lock Screen", as: .content, using: TodayActivityAttributes(day: "2026-10-02", scheduledStart: nil, isTest: false)) {
    TodayLiveActivity()
} contentStates: {
    ActivitySnapshot(day: LocalDay(year: 2026, month: 10, day: 2), rows: [
        .init(ref: "o:1", title: "30 minutes of LeetCode prep", carryLabel: nil),
        .init(ref: "o:2", title: "Finish homework for the algorithms class, including the extra problem set", carryLabel: "From yesterday", carriedDays: 1, done: true),
        .init(ref: "o:3", title: "Text back John", carryLabel: "4 days overdue", carriedDays: 4),
    ], moreCount: 2, completedCount: 1)
    ActivitySnapshot(day: LocalDay(year: 2026, month: 10, day: 2), rows: [
        .init(ref: "o:1", title: "Buy a birthday present", carryLabel: nil),
    ], moreCount: 0, completedCount: 4)
    ActivitySnapshot(day: LocalDay(year: 2026, month: 10, day: 2), rows: [], moreCount: 0, completedCount: 5,
                     longTermOffer: 4)
    ActivitySnapshot(day: LocalDay(year: 2026, month: 10, day: 2), mode: .longTerm, rows: [
        .init(ref: "l:1", title: "Learn Rust", carryLabel: nil),
        .init(ref: "l:2", title: "Run a half marathon", carryLabel: nil),
    ], moreCount: 0, completedCount: 0)
    ActivitySnapshot(day: LocalDay(year: 2026, month: 10, day: 2), rows: [], moreCount: 0, completedCount: 5)
}
