import Foundation

public enum TaskError: Error, Equatable, Sendable {
    case emptyTitle
    case invalidRecurrence
    case notFound
}

/// Everything time-dependent a mutation needs. Injected so tests control the clock.
public struct DayContext: Sendable {
    public let now: Date
    public let timeZone: TimeZone

    public init(now: Date, timeZone: TimeZone) {
        self.now = now
        self.timeZone = timeZone
    }

    public var today: LocalDay { LocalDay(now, in: timeZone) }
}

/// Past days kept in history (about three years).
let historyLimit = 1100
/// When the app hasn't run for a long time, unattended days are reconstructed
/// for at most this many days back.
let historyGapLimit = 60

extension TodayState {
    // MARK: - Reconciliation

    /// Brings the state up to `today`. Idempotent: running it any number of
    /// times on the same day yields the same state.
    ///
    /// - Closes every day since the last run into `history`.
    /// - Completed one-offs and goals from earlier days leave the state.
    /// - Recurring occurrences from earlier days expire (missed ones never carry).
    /// - Planned tasks whose day has come arrive at the top of the list.
    /// - Each series scheduled today gets exactly one occurrence.
    /// - `order` is repaired to reference exactly the live tasks and series.
    /// - Returns: whether anything changed.
    @discardableResult
    public mutating func reconcile(today: LocalDay) -> Bool {
        let before = self

        if let last = lastReconciledDay, last < today {
            closeDays(from: last, until: today)
        }

        oneOffs.removeAll { task in
            guard let done = task.completedDay else { return false }
            return done < today
        }
        longTerm.removeAll { goal in
            guard let done = goal.completedDay else { return false }
            return done < today
        }

        let liveSeries = Set(series.map(\.id))
        // Future-dated occurrences survive only for a westward time-zone change.
        occurrences.removeAll { $0.day < today || !liveSeries.contains($0.seriesID) }

        arrivePlanned(through: today)

        for s in series where s.createdDay <= today && s.recurrence.occurs(on: today) {
            if !occurrences.contains(where: { $0.seriesID == s.id && $0.day == today }) {
                occurrences.append(Occurrence(seriesID: s.id, day: today))
            }
        }

        let live = Set(oneOffs.map(\.id)).union(liveSeries)
        var seen = Set<UUID>()
        order = order.filter { live.contains($0) && seen.insert($0).inserted }
        for id in oneOffs.map(\.id) + series.map(\.id) where !seen.contains(id) {
            order.append(id)
            seen.insert(id)
        }

        if let d = lockScreen.dismissedDay, d < today { lockScreen.dismissedDay = nil }
        if let d = lockScreen.endedByAppDay, d < today { lockScreen.endedByAppDay = nil }
        if let d = lockScreen.longTermDay, d < today { lockScreen.longTermDay = nil }
        if let d = lockScreen.cardDay, d < today {
            lockScreen.cardDay = nil
            lockScreen.cardStartedAt = nil
        }
        lastReconciledDay = today

        return self != before
    }

    /// Records `last` as it actually ended, then every day the app did not
    /// run, reconstructed by projection: nothing changes without the app or
    /// an intent running (and both reconcile), so those days are exact.
    private mutating func closeDays(from last: LocalDay, until today: LocalDay) {
        var records = [closingRecord(for: last)]
        let firstGap = max(last.adding(days: 1), today.adding(days: -historyGapLimit))
        var day = firstGap
        while day < today {
            let entries = projectedRows(on: day, today: last).map { HistoryEntry(row: $0, outcome: nil) }
            records.append(DayRecord(day: day, entries: entries))
            day = day.adding(days: 1)
        }
        for record in records where !record.entries.isEmpty {
            upsert(record)
        }
    }

    private func closingRecord(for day: LocalDay) -> DayRecord {
        let open = activeRows(today: day).map { HistoryEntry(row: $0, outcome: nil) }
        let done = completedRows(today: day)
            .sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
            .map { HistoryEntry(row: $0, outcome: .done) }
        return DayRecord(day: day, entries: open + done)
    }

    private mutating func upsert(_ record: DayRecord) {
        if let i = history.firstIndex(where: { $0.day == record.day }) {
            history[i] = record
        } else {
            let at = history.firstIndex { $0.day > record.day } ?? history.endIndex
            history.insert(record, at: at)
        }
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    /// Planned tasks due by `day`, as they will be ordered on arrival: the
    /// latest planned date first, ties in their existing relative order.
    /// This rule gives the same order whether the app runs every day or not.
    private func arrivals(through day: LocalDay) -> [OneOffTask] {
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return oneOffs
            .filter { $0.completedAt == nil && ($0.scheduledDay.map { $0 <= day } ?? false) }
            .sorted { a, b in
                if a.scheduledDay != b.scheduledDay { return a.scheduledDay! > b.scheduledDay! }
                return (index[a.id] ?? .max) < (index[b.id] ?? .max)
            }
    }

    private mutating func arrivePlanned(through today: LocalDay) {
        let arriving = arrivals(through: today)
        guard !arriving.isEmpty else { return }
        let ids = arriving.map(\.id)
        order.removeAll { ids.contains($0) }
        order.insert(contentsOf: ids, at: 0)
        for task in arriving {
            guard let i = oneOffs.firstIndex(where: { $0.id == task.id }) else { continue }
            oneOffs[i].createdDay = task.scheduledDay!
            oneOffs[i].scheduledDay = nil
        }
    }

    // MARK: - Queries

    /// Today's unfinished tasks in manual order. Call after `reconcile(today:)`.
    public func activeRows(today: LocalDay) -> [TaskRow] {
        order.compactMap { id in
            if let task = oneOff(id) {
                guard task.completedAt == nil, task.scheduledDay == nil else { return nil }
                return row(for: task, on: today)
            }
            if let s = series(id), let occ = occurrence(s.id, today), occ.completedAt == nil, !occ.skipped {
                return TaskRow(ref: .occurrence(seriesID: s.id, day: today), title: s.title,
                               recurrence: s.recurrence, carriedDays: 0, completedAt: nil)
            }
            return nil
        }
    }

    /// Daily tasks and goals finished today, most recent first.
    public func completedRows(today: LocalDay) -> [TaskRow] {
        var rows: [TaskRow] = oneOffs.compactMap { task in
            guard let done = task.completedDay, done >= today else { return nil }
            return row(for: task, on: today)
        }
        for occ in occurrences where occ.day == today && occ.completedAt != nil && !occ.skipped {
            guard let s = series(occ.seriesID) else { continue }
            rows.append(TaskRow(ref: .occurrence(seriesID: s.id, day: today), title: s.title,
                                recurrence: s.recurrence, carriedDays: 0, completedAt: occ.completedAt))
        }
        for goal in longTerm {
            guard let done = goal.completedDay, done >= today else { continue }
            rows.append(row(for: goal))
        }
        return rows.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// Unfinished long-term goals in manual order.
    public func longTermRows() -> [TaskRow] {
        longTerm.filter { $0.completedAt == nil }.map(row(for:))
    }

    /// What the daily list will be on `day` if nothing else happens before
    /// then: planned tasks that have arrived (on top), unfinished one-offs
    /// with their carry age on that day, plus a fresh occurrence of every
    /// series scheduled that day. For `today` this is the real active list.
    /// Used for pre-scheduled Lock Screen snapshots and history gaps.
    public func projectedRows(on day: LocalDay, today: LocalDay) -> [TaskRow] {
        guard day > today else { return activeRows(today: today) }
        let arrived = arrivals(through: day).map { task in
            TaskRow(ref: .oneOff(task.id), title: task.title, recurrence: nil,
                    carriedDays: max(0, task.scheduledDay!.days(until: day)), completedAt: nil)
        }
        let rest: [TaskRow] = order.compactMap { id in
            if let task = oneOff(id) {
                guard task.completedAt == nil, task.scheduledDay == nil else { return nil }
                return row(for: task, on: day)
            }
            if let s = series(id), s.createdDay <= day, s.recurrence.occurs(on: day) {
                if let occ = occurrence(s.id, day), occ.completedAt != nil || occ.skipped { return nil }
                return TaskRow(ref: .occurrence(seriesID: s.id, day: day), title: s.title,
                               recurrence: s.recurrence, carriedDays: 0, completedAt: nil)
            }
            return nil
        }
        return arrived + rest
    }

    /// Tasks planned specifically for `day`, in the order they will arrive.
    public func plannedRows(on day: LocalDay) -> [TaskRow] {
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return oneOffs
            .filter { $0.scheduledDay == day && $0.completedAt == nil }
            .sorted { (index[$0.id] ?? .max) < (index[$1.id] ?? .max) }
            .map { TaskRow(ref: .oneOff($0.id), title: $0.title, recurrence: nil, carriedDays: 0, completedAt: nil) }
    }

    /// The closed list for a past day, if anything was on it.
    public func record(for day: LocalDay) -> DayRecord? {
        history.first { $0.day == day }
    }

    /// The current placement of a task, for the editor.
    public func placement(of id: UUID, today: LocalDay) -> TaskPlacement? {
        if let task = oneOff(id) { return .day(task.scheduledDay ?? today) }
        if let s = series(id) { return .repeating(s.recurrence) }
        if longTermGoal(id) != nil { return .longTerm }
        return nil
    }

    private func row(for task: OneOffTask, on day: LocalDay) -> TaskRow {
        TaskRow(ref: .oneOff(task.id), title: task.title, recurrence: nil,
                carriedDays: max(0, task.createdDay.days(until: day)), completedAt: task.completedAt)
    }

    private func row(for goal: LongTermTask) -> TaskRow {
        TaskRow(ref: .longTerm(goal.id), title: goal.title, recurrence: nil, carriedDays: 0, completedAt: goal.completedAt)
    }

    private func occurrence(_ seriesID: UUID, _ day: LocalDay) -> Occurrence? {
        occurrences.first { $0.seriesID == seriesID && $0.day == day }
    }

    private func occurrenceIndex(_ seriesID: UUID, _ day: LocalDay) -> Int? {
        occurrences.firstIndex { $0.seriesID == seriesID && $0.day == day }
    }

    public func series(_ id: UUID) -> RecurringSeries? { series.first { $0.id == id } }
    public func oneOff(_ id: UUID) -> OneOffTask? { oneOffs.first { $0.id == id } }
    public func longTermGoal(_ id: UUID) -> LongTermTask? { longTerm.first { $0.id == id } }

    // MARK: - Adding and editing

    public static func validatedTitle(_ raw: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TaskError.emptyTitle }
        return title
    }

    /// Adds a task. Today's tasks go to the bottom of the list; planned tasks
    /// arrive at the top on their day; goals go to the bottom of the long-term list.
    @discardableResult
    public mutating func addTask(title rawTitle: String, placement: TaskPlacement,
                                 id: UUID = UUID(), context: DayContext) throws -> TaskRef {
        let title = try Self.validatedTitle(rawTitle)
        let today = context.today
        reconcile(today: today)
        switch placement {
        case .day(let day):
            order.append(id)
            oneOffs.append(OneOffTask(id: id, title: title, createdAt: context.now, createdDay: today,
                                      scheduledDay: day > today ? day : nil))
            return .oneOff(id)
        case .repeating(let recurrence):
            guard recurrence.isValid else { throw TaskError.invalidRecurrence }
            order.append(id)
            series.append(RecurringSeries(id: id, title: title, recurrence: recurrence,
                                          createdAt: context.now, createdDay: today))
            reconcile(today: today)
            return .occurrence(seriesID: id, day: today)
        case .longTerm:
            longTerm.append(LongTermTask(id: id, title: title, createdAt: context.now))
            return .longTerm(id)
        }
    }

    /// Adds a task for today, or a series when `recurrence` is set.
    @discardableResult
    public mutating func addTask(title: String, recurrence: Recurrence? = nil,
                                 id: UUID = UUID(), context: DayContext) throws -> TaskRef {
        try addTask(title: title, placement: recurrence.map(TaskPlacement.repeating) ?? .day(context.today),
                    id: id, context: context)
    }

    /// Edits title and placement of the task, series or goal `id`, keeping
    /// its id. Editing a series changes all future occurrences (and today's
    /// unfinished one). Rules for moves:
    /// - Between one-off and repeating, the task keeps its slot in the order.
    /// - Into today from the long-term list or a planned date, it goes to the top.
    /// - Onto the long-term list, it goes to the bottom of that list.
    public mutating func editTask(id: UUID, title rawTitle: String, placement: TaskPlacement,
                                  context: DayContext) throws {
        let title = try Self.validatedTitle(rawTitle)
        if case .repeating(let r) = placement, !r.isValid { throw TaskError.invalidRecurrence }
        let today = context.today
        reconcile(today: today)

        // Same kind: edit in place.
        switch placement {
        case .day(let day):
            if let i = oneOffs.firstIndex(where: { $0.id == id }) {
                oneOffs[i].title = title
                if day > today {
                    oneOffs[i].scheduledDay = day
                    oneOffs[i].completedAt = nil
                    oneOffs[i].completedDay = nil
                } else if oneOffs[i].scheduledDay != nil {
                    oneOffs[i].scheduledDay = nil
                    oneOffs[i].createdDay = today
                    moveToTop(id)
                }
                return
            }
        case .repeating(let recurrence):
            if let i = series.firstIndex(where: { $0.id == id }) {
                series[i].title = title
                series[i].recurrence = recurrence
                // Today's existing occurrence stays even if today is no longer scheduled.
                reconcile(today: today)
                return
            }
        case .longTerm:
            if let i = longTerm.firstIndex(where: { $0.id == id }) {
                longTerm[i].title = title
                return
            }
        }

        // Different kind: take the task out, keeping today's completion.
        let completedAt: Date?
        let fromLongTerm: Bool
        if let i = oneOffs.firstIndex(where: { $0.id == id }) {
            completedAt = oneOffs[i].completedDay == today ? oneOffs[i].completedAt : nil
            fromLongTerm = false
            oneOffs.remove(at: i)
        } else if let i = series.firstIndex(where: { $0.id == id }) {
            completedAt = occurrence(id, today)?.completedAt
            fromLongTerm = false
            series.remove(at: i)
            occurrences.removeAll { $0.seriesID == id }
        } else if let i = longTerm.firstIndex(where: { $0.id == id }) {
            completedAt = longTerm[i].completedDay == today ? longTerm[i].completedAt : nil
            fromLongTerm = true
            longTerm.remove(at: i)
        } else {
            throw TaskError.notFound
        }

        switch placement {
        case .day(let day):
            let planned = day > today
            oneOffs.append(OneOffTask(id: id, title: title, createdAt: context.now, createdDay: today,
                                      completedAt: planned ? nil : completedAt,
                                      completedDay: planned || completedAt == nil ? nil : today,
                                      scheduledDay: planned ? day : nil))
            if fromLongTerm {
                if planned { order.append(id) } else { moveToTop(id) }
            }
        case .repeating(let recurrence):
            series.append(RecurringSeries(id: id, title: title, recurrence: recurrence,
                                          createdAt: context.now, createdDay: today))
            if recurrence.occurs(on: today) {
                occurrences.append(Occurrence(seriesID: id, day: today, completedAt: completedAt))
            }
            if fromLongTerm { order.append(id) }
        case .longTerm:
            order.removeAll { $0 == id }
            longTerm.append(LongTermTask(id: id, title: title, createdAt: context.now,
                                         completedAt: completedAt, completedDay: completedAt == nil ? nil : today))
        }
        reconcile(today: today)
    }

    /// Edits title and recurrence; a one-off keeps its planned date.
    public mutating func editTask(id: UUID, title: String, recurrence: Recurrence?, context: DayContext) throws {
        let placement: TaskPlacement
        if let recurrence {
            placement = .repeating(recurrence)
        } else {
            placement = .day(oneOff(id)?.scheduledDay ?? context.today)
        }
        try editTask(id: id, title: title, placement: placement, context: context)
    }

    /// Moves a goal or planned task onto today's list, at the top.
    public mutating func doToday(_ id: UUID, context: DayContext) throws {
        guard let title = longTermGoal(id)?.title ?? oneOff(id)?.title else { throw TaskError.notFound }
        try editTask(id: id, title: title, placement: .day(context.today), context: context)
    }

    private mutating func moveToTop(_ id: UUID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    // MARK: - Completion

    /// Marks a task done. Idempotent: completing a finished task, an unknown
    /// task, a planned task, or a recurring occurrence from another day
    /// changes nothing.
    /// - Returns: whether the state changed.
    @discardableResult
    public mutating func complete(_ ref: TaskRef, context: DayContext) -> Bool {
        let today = context.today
        reconcile(today: today)
        switch ref {
        case .oneOff(let id):
            guard let i = oneOffs.firstIndex(where: { $0.id == id }),
                  oneOffs[i].completedAt == nil, oneOffs[i].scheduledDay == nil else { return false }
            oneOffs[i].completedAt = context.now
            oneOffs[i].completedDay = today
        case .occurrence(let id, let day):
            // A stale Lock Screen tap for yesterday's occurrence is a no-op.
            guard day == today, let i = occurrenceIndex(id, day),
                  occurrences[i].completedAt == nil, !occurrences[i].skipped,
                  series(id) != nil else { return false }
            occurrences[i].completedAt = context.now
        case .longTerm(let id):
            guard let i = longTerm.firstIndex(where: { $0.id == id }), longTerm[i].completedAt == nil else { return false }
            longTerm[i].completedAt = context.now
            longTerm[i].completedDay = today
        }
        return true
    }

    /// Undoes a completion from today. Idempotent.
    @discardableResult
    public mutating func uncomplete(_ ref: TaskRef, context: DayContext) -> Bool {
        let today = context.today
        reconcile(today: today)
        switch ref {
        case .oneOff(let id):
            guard let i = oneOffs.firstIndex(where: { $0.id == id }), oneOffs[i].completedAt != nil else { return false }
            oneOffs[i].completedAt = nil
            oneOffs[i].completedDay = nil
        case .occurrence(let id, let day):
            guard day == today, let i = occurrenceIndex(id, day), occurrences[i].completedAt != nil else { return false }
            occurrences[i].completedAt = nil
        case .longTerm(let id):
            guard let i = longTerm.firstIndex(where: { $0.id == id }), longTerm[i].completedAt != nil else { return false }
            longTerm[i].completedAt = nil
            longTerm[i].completedDay = nil
        }
        return true
    }

    // MARK: - Deleting

    /// Deletes a one-off, a whole series, or a goal.
    public mutating func delete(_ ref: TaskRef, context: DayContext) {
        switch ref {
        case .oneOff(let id): oneOffs.removeAll { $0.id == id }
        case .occurrence(let id, _): series.removeAll { $0.id == id }
        case .longTerm(let id): longTerm.removeAll { $0.id == id }
        }
        reconcile(today: context.today)
    }

    public mutating func deleteOneOff(_ id: UUID, context: DayContext) { delete(.oneOff(id), context: context) }

    /// Removes a series and all its occurrences.
    public mutating func deleteSeries(_ id: UUID, context: DayContext) {
        delete(.occurrence(seriesID: id, day: context.today), context: context)
    }

    /// Removes only today's occurrence of a series; it returns on its next scheduled day.
    public mutating func skipToday(seriesID: UUID, context: DayContext) {
        let today = context.today
        reconcile(today: today)
        if let i = occurrenceIndex(seriesID, today) { occurrences[i].skipped = true }
    }

    // MARK: - Reordering

    /// Reorders today's active list like `Array.move(fromOffsets:toOffset:)`.
    /// Items not currently visible (completed, planned, unscheduled series)
    /// keep their slots in the global order.
    public mutating func moveActive(fromOffsets source: IndexSet, toOffset destination: Int, context: DayContext) {
        let today = context.today
        reconcile(today: today)
        let visible = activeRows(today: today).map(\.ref.orderID)
        order = Self.reslot(order, visible: visible, from: source, to: destination)
    }

    /// Reorders the tasks planned for a future `day`.
    public mutating func movePlanned(on day: LocalDay, fromOffsets source: IndexSet, toOffset destination: Int,
                                     context: DayContext) {
        reconcile(today: context.today)
        let visible = plannedRows(on: day).map(\.ref.orderID)
        order = Self.reslot(order, visible: visible, from: source, to: destination)
    }

    /// Reorders the unfinished long-term goals.
    public mutating func moveLongTerm(fromOffsets source: IndexSet, toOffset destination: Int, context: DayContext) {
        reconcile(today: context.today)
        let all = longTerm.map(\.id)
        let visible = longTermRows().map(\.ref.orderID)
        let reordered = Self.reslot(all, visible: visible, from: source, to: destination)
        let byID = Dictionary(uniqueKeysWithValues: longTerm.map { ($0.id, $0) })
        longTerm = reordered.compactMap { byID[$0] }
    }

    /// Applies `move(fromOffsets:toOffset:)` to the `visible` subsequence of
    /// `full`, re-dealing the moved ids into the slots the visible ids already
    /// occupy so hidden ids never shift.
    static func reslot(_ full: [UUID], visible: [UUID], from source: IndexSet, to destination: Int) -> [UUID] {
        var visible = visible
        let moving = source.sorted().filter { $0 < visible.count }.map { visible[$0] }
        guard !moving.isEmpty else { return full }
        let insertAt = destination - source.filter { $0 < destination }.count
        visible.removeAll { moving.contains($0) }
        visible.insert(contentsOf: moving, at: max(0, min(insertAt, visible.count)))
        let visibleSet = Set(visible)
        var next = visible.makeIterator()
        return full.map { visibleSet.contains($0) ? next.next()! : $0 }
    }

    // MARK: - Migration

    /// Upgrades older schema data in place. Idempotent.
    /// - v1 → v2: the completion log becomes done-only history records for
    ///   days before the last reconciled day (that day is still live state
    ///   and is recorded in full when it closes).
    public mutating func migrate(timeZone: TimeZone) {
        guard schemaVersion < Self.currentSchemaVersion || !legacyCompletionLog.isEmpty else { return }
        let liveDay = lastReconciledDay
        var byDay: [LocalDay: [HistoryEntry]] = [:]
        for record in legacyCompletionLog {
            let day = LocalDay(record.completedAt, in: timeZone)
            if let liveDay, day >= liveDay { continue }
            let kind: HistoryEntry.Kind = {
                switch record.ref {
                case .oneOff: .task
                case .occurrence: .recurring
                case .longTerm: .longTerm
                }
            }()
            byDay[day, default: []].append(HistoryEntry(ref: record.ref, title: record.title, kind: kind,
                                                        outcome: .done, completedAt: record.completedAt, carriedDays: 0))
        }
        for (day, entries) in byDay where record(for: day) == nil {
            upsert(DayRecord(day: day, entries: entries))
        }
        legacyCompletionLog = []
        schemaVersion = Self.currentSchemaVersion
    }
}

extension HistoryEntry {
    /// `outcome: nil` means unfinished; it becomes carried or missed by kind.
    init(row: TaskRow, outcome: Outcome?) {
        let kind: Kind = switch row.ref {
        case .oneOff: .task
        case .occurrence: .recurring
        case .longTerm: .longTerm
        }
        self.init(ref: row.ref, title: row.title, kind: kind,
                  outcome: outcome ?? (kind == .recurring ? .missed : .carried),
                  completedAt: outcome == .done ? row.completedAt : nil,
                  carriedDays: row.carriedDays)
    }
}
