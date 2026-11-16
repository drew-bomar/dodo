// Builds a believable week of sample data, ending today, for App Store
// screenshots. Compiled together with the TodayCore sources by screenshots.sh.
// Usage: screenshot-data <output state.json>
import Foundation

let tz = TimeZone.current
let today = LocalDay(Date(), in: tz)
func ctx(_ offset: Int, hour: Int = 9, minute: Int = 0) -> DayContext {
    DayContext(now: today.adding(days: offset).date(hour: hour, minute: minute, in: tz), timeZone: tz)
}
var s = TodayState()

// Five days ago
var c = ctx(-5)
try s.addTask(title: "Renew passport", context: c)
try s.addTask(title: "Morning run", recurrence: .weekdays([.monday, .wednesday, .friday]), context: c)
try s.addTask(title: "Read 20 pages", recurrence: .daily, context: c)
let dentist = try s.addTask(title: "Book dentist appointment", context: c)
try s.addTask(title: "Learn Spanish", placement: .longTerm, context: c)
try s.addTask(title: "Run a half marathon", placement: .longTerm, context: c)
try s.addTask(title: "Write a short story", placement: .longTerm, context: c)
_ = s.complete(dentist, context: ctx(-5, hour: 11))

// Four days ago to yesterday: finish most things, leave a few to carry over
for offset in -4 ... -1 {
    c = ctx(offset)
    s.reconcile(today: c.today)
    for row in s.activeRows(today: c.today) where row.recurrence != nil && offset != -3 {
        _ = s.complete(row.ref, context: ctx(offset, hour: 8, minute: 15))
    }
    let (kept, done, doneHour): (String?, String, Int) = switch offset {
    case -4: (nil, "Email landlord about the lease", 14)
    case -3: (nil, "Pick up dry cleaning", 17)
    case -2: ("Call mom", "Water the plants", 18)
    default: ("Finish quarterly report", "Grocery run", 19)
    }
    if let kept { try s.addTask(title: kept, context: c) }
    _ = s.complete(try s.addTask(title: done, context: c), context: ctx(offset, hour: doneHour))
}

// Today
c = ctx(0, hour: 8)
s.reconcile(today: c.today)
try s.addTask(title: "Prep slides for Monday standup", context: c)
try s.addTask(title: "Pay electricity bill", context: c)
_ = s.complete(try s.addTask(title: "Lunch with Sam", context: c), context: ctx(0, hour: 13))
if let read = s.activeRows(today: c.today).first(where: { $0.title == "Read 20 pages" }) {
    _ = s.complete(read.ref, context: ctx(0, hour: 7, minute: 30))
}

// The top three, which the Lock Screen shows
for (target, title) in ["Finish quarterly report", "Renew passport", "Call mom"].enumerated() {
    let from = s.activeRows(today: c.today).firstIndex { $0.title == title }!
    s.moveActive(fromOffsets: IndexSet(integer: from), toOffset: target, context: c)
}

// Planned
try s.addTask(title: "Mia's birthday — get a card", placement: .day(today.adding(days: 3)), context: c)
try s.addTask(title: "Car inspection", placement: .day(today.adding(days: 3)), context: c)
try s.addTask(title: "Flight to Denver ✈️", placement: .day(today.adding(days: 6)), context: c)

s.lockScreen.enabled = true
s.lockScreen.privacyAcknowledged = true

for r in s.activeRows(today: today) { print("active:", r.title, r.carryLabel ?? "") }
try Backup.data(for: s).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
