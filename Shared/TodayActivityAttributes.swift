import ActivityKit
import Foundation
import TodayCore

/// One Live Activity per local day. The day is static; the visible tasks are
/// the dynamic `ActivitySnapshot` (kept well under ActivityKit's 4 KB limit).
struct TodayActivityAttributes: ActivityAttributes {
    typealias ContentState = ActivitySnapshot

    /// `LocalDay` string ("2026-10-02") this card belongs to.
    let day: String
    /// The scheduled start for a pre-scheduled noon card; nil when started immediately.
    let scheduledStart: Date?
    /// DEBUG near-future scheduling experiments; ignored by reconciliation.
    let isTest: Bool

    var localDay: LocalDay? { LocalDay(string: day) }
}
