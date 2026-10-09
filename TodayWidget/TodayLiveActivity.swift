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
            let left = context.state.rows.count + context.state.moreCount
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

struct LockScreenCard: View {
    let snapshot: ActivitySnapshot
    var isStale = false

    private var remaining: Int { snapshot.rows.count + snapshot.moreCount }
    private var isLongTerm: Bool { snapshot.mode == .longTerm }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                }
            }
            .accessibilityElement(children: .combine)

            if snapshot.hasTasks {
                ForEach(snapshot.rows) { row in
                    LockScreenTaskRow(row: row)
                }
                if snapshot.moreCount > 0 {
                    Text("+\(snapshot.moreCount) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 36)
                }
            } else {
                Label(isLongTerm ? "All done" : "All done for today", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(isStale ? 0.6 : 1)
    }
}

struct LockScreenTaskRow: View {
    let row: ActivitySnapshot.Row
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Only the checkbox completes; tapping elsewhere opens the app.
            Button(intent: CompleteTaskIntent(taskRef: row.ref)) {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(row.title)")

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(typeSize.isAccessibilitySize ? 1 : 2)
                if let carry = row.carryLabel, !typeSize.isAccessibilitySize {
                    Text(carry)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
    }
}

#Preview("Lock Screen", as: .content, using: TodayActivityAttributes(day: "2026-10-02", scheduledStart: nil, isTest: false)) {
    TodayLiveActivity()
} contentStates: {
    ActivitySnapshot(day: LocalDay(year: 2026, month: 10, day: 2), rows: [
        .init(ref: "o:1", title: "30 minutes of LeetCode prep", carryLabel: nil),
        .init(ref: "o:2", title: "Finish homework for the algorithms class, including the extra problem set", carryLabel: "From yesterday"),
        .init(ref: "o:3", title: "Text back John", carryLabel: "3 days carried"),
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
