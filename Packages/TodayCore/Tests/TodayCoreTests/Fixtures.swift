import Foundation

/// A state file written by schema version 1 (the first build installed on
/// the phone), captured verbatim from that build's encoder. Clock: New York.
/// - Oct 1: "Buy a birthday present" (open), "Text back John" (done 10:00),
///   daily "LeetCode 30 min".
/// - Oct 2: LeetCode done 09:00; "Gym" (Mon/Fri) added. Last reconciled Oct 2.
let schemaV1Fixture = #"""
{"completionLog":[{"completedAt":"2026-10-01T14:00:00Z","ref":"o:33333333-3333-3333-3333-333333333333","title":"Text back John"},{"completedAt":"2026-10-02T13:00:00Z","ref":"r:22222222-2222-2222-2222-222222222222:2026-10-02","title":"LeetCode 30 min"}],"lastReconciledDay":"2026-10-02","lockScreen":{"autoNoonStart":true,"enabled":true,"privacyAcknowledged":true},"occurrences":[{"completedAt":"2026-10-02T13:00:00Z","day":"2026-10-02","seriesID":"22222222-2222-2222-2222-222222222222","skipped":false},{"day":"2026-10-02","seriesID":"44444444-4444-4444-4444-444444444444","skipped":false}],"oneOffs":[{"createdAt":"2026-10-01T13:00:00Z","createdDay":"2026-10-01","id":"11111111-1111-1111-1111-111111111111","title":"Buy a birthday present"}],"order":["11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222","44444444-4444-4444-4444-444444444444"],"schemaVersion":1,"series":[{"createdAt":"2026-10-01T13:00:00Z","createdDay":"2026-10-01","id":"22222222-2222-2222-2222-222222222222","recurrence":{"daily":{}},"title":"LeetCode 30 min"},{"createdAt":"2026-10-02T12:00:00Z","createdDay":"2026-10-02","id":"44444444-4444-4444-4444-444444444444","recurrence":{"weekdays":{"_0":[2,6]}},"title":"Gym"}]}
"""#
