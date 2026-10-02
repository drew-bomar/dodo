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

/// Upper bound on completion history kept on disk.
let completionLogLimit = 1000

extension TodayState {
    // MARK: - Reconciliation

    /// Brings the state up to `today`. Idempotent: running it any number of
    /// times on the same day yields the same state.
    ///
    /// - Completed one-offs from earlier days leave the state.
    /// - Recurring occurrences from earlier days expire (missed ones never carry).
    /// - Each series scheduled today gets exactly one occurrence.
    /// - `order` is repaired to reference exactly the live tasks and series.
    /// - Returns: whether anything changed.
    @discardableResult
    public mutating func reconcile(today: LocalDay) -> Bool {
        let before = self

        oneOffs.removeAll { task in
            guard let done = task.completedDay else { return false }
            return done < today
        }

        let liveSeries = Set(series.map(\.id))
        // Future-dated occurrences survive only for a westward time-zone change.
        occurrences.removeAll { $0.day < today || !liveSeries.contains($0.seriesID) }

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
        if let d = lockScreen.cardDay, d < today {
            lockScreen.cardDay = nil
            lockScreen.cardStartedAt = nil
        }
        lastReconciledDay = today

        return self != before
    }

    // MARK: - Queries

    /// Today's unfinished tasks in manual order. Call after `reconcile(today:)`.
    public func activeRows(today: LocalDay) -> [TaskRow] {
        order.compactMap { id in
            if let task = oneOffs.first(where: { $0.id == id }) {
                guard task.completedAt == nil else { return nil }
                return row(for: task, on: today)
            }
            if let s = series.first(where: { $0.id == id }),
               let occ = occurrence(s.id, today), occ.completedAt == nil, !occ.skipped {
                return TaskRow(ref: .occurrence(seriesID: s.id, day: today), title: s.title,
                               recurrence: s.recurrence, carriedDays: 0, completedAt: nil)
            }
            return nil
        }
    }

    /// Tasks finished today, most recent first.
    public func completedRows(today: LocalDay) -> [TaskRow] {
        var rows: [TaskRow] = oneOffs.compactMap { task in
            guard let done = task.completedDay, done >= today else { return nil }
            return row(for: task, on: today)
        }
        for occ in occurrences where occ.day == today && occ.completedAt != nil && !occ.skipped {
            guard let s = series.first(where: { $0.id == occ.seriesID }) else { continue }
            rows.append(TaskRow(ref: .occurrence(seriesID: s.id, day: today), title: s.title,
                                recurrence: s.recurrence, carriedDays: 0, completedAt: occ.completedAt))
        }
        return rows.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// What the active list will be on `day` if nothing else happens before
    /// then: unfinished one-offs with their carry age on that day, plus a
    /// fresh occurrence of every series scheduled that day. For `today` this is
    /// the real active list. Used for pre-scheduled Lock Screen snapshots.
    public func projectedRows(on day: LocalDay, today: LocalDay) -> [TaskRow] {
        guard day > today else { return activeRows(today: today) }
        return order.compactMap { id in
            if let task = oneOffs.first(where: { $0.id == id }) {
                guard task.completedAt == nil else { return nil }
                return row(for: task, on: day)
            }
            if let s = series.first(where: { $0.id == id }),
               s.createdDay <= day, s.recurrence.occurs(on: day) {
                if let occ = occurrence(s.id, day), occ.completedAt != nil || occ.skipped { return nil }
                return TaskRow(ref: .occurrence(seriesID: s.id, day: day), title: s.title,
                               recurrence: s.recurrence, carriedDays: 0, completedAt: nil)
            }
            return nil
        }
    }

    public func row(for ref: TaskRef, today: LocalDay) -> TaskRow? {
        (activeRows(today: today) + completedRows(today: today)).first { $0.ref == ref }
    }

    private func row(for task: OneOffTask, on day: LocalDay) -> TaskRow {
        TaskRow(ref: .oneOff(task.id), title: task.title, recurrence: nil,
                carriedDays: max(0, task.createdDay.days(until: day)), completedAt: task.completedAt)
    }

    private func occurrence(_ seriesID: UUID, _ day: LocalDay) -> Occurrence? {
        occurrences.first { $0.seriesID == seriesID && $0.day == day }
    }

    private func occurrenceIndex(_ seriesID: UUID, _ day: LocalDay) -> Int? {
        occurrences.firstIndex { $0.seriesID == seriesID && $0.day == day }
    }

    // MARK: - Mutations

    public static func validatedTitle(_ raw: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TaskError.emptyTitle }
        return title
    }

    /// Adds a task at the bottom of today's list. A non-nil `recurrence` creates a series.
    @discardableResult
    public mutating func addTask(title rawTitle: String, recurrence: Recurrence? = nil,
                                 id: UUID = UUID(), context: DayContext) throws -> TaskRef {
        let title = try Self.validatedTitle(rawTitle)
        let today = context.today
        reconcile(today: today)
        order.append(id)
        if let recurrence {
            guard recurrence.isValid else { order.removeLast(); throw TaskError.invalidRecurrence }
            series.append(RecurringSeries(id: id, title: title, recurrence: recurrence,
                                          createdAt: context.now, createdDay: today))
            reconcile(today: today)
            return .occurrence(seriesID: id, day: today)
        }
        oneOffs.append(OneOffTask(id: id, title: title, createdAt: context.now, createdDay: today))
        return .oneOff(id)
    }

    /// Edits title and recurrence of the task in order slot `id`. Changing a
    /// series edits all its future occurrences (and today's unfinished one).
    /// Switching between one-off and recurring keeps the same order slot.
    public mutating func editTask(id: UUID, title rawTitle: String, recurrence: Recurrence?,
                                  context: DayContext) throws {
        let title = try Self.validatedTitle(rawTitle)
        if let recurrence, !recurrence.isValid { throw TaskError.invalidRecurrence }
        let today = context.today
        reconcile(today: today)

        if let i = oneOffs.firstIndex(where: { $0.id == id }) {
            guard let recurrence else {
                oneOffs[i].title = title
                return
            }
            let task = oneOffs.remove(at: i)
            series.append(RecurringSeries(id: id, title: title, recurrence: recurrence,
                                          createdAt: context.now, createdDay: today))
            if recurrence.occurs(on: today) {
                occurrences.append(Occurrence(seriesID: id, day: today, completedAt: task.completedAt))
            }
            reconcile(today: today)
            return
        }

        if let i = series.firstIndex(where: { $0.id == id }) {
            guard recurrence == nil else {
                series[i].title = title
                series[i].recurrence = recurrence!
                // Today's existing occurrence stays even if today is no longer scheduled.
                reconcile(today: today)
                return
            }
            let todays = occurrence(id, today)
            series.remove(at: i)
            occurrences.removeAll { $0.seriesID == id }
            let done = todays?.completedAt
            oneOffs.append(OneOffTask(id: id, title: title, createdAt: context.now, createdDay: today,
                                      completedAt: done, completedDay: done == nil ? nil : today))
            reconcile(today: today)
            return
        }
        throw TaskError.notFound
    }

    /// Marks a task done. Idempotent: completing a finished task, an unknown
    /// task, or a recurring occurrence from another day changes nothing.
    /// - Returns: whether the state changed.
    @discardableResult
    public mutating func complete(_ ref: TaskRef, context: DayContext) -> Bool {
        let today = context.today
        reconcile(today: today)
        let title: String
        switch ref {
        case .oneOff(let id):
            guard let i = oneOffs.firstIndex(where: { $0.id == id }), oneOffs[i].completedAt == nil else { return false }
            oneOffs[i].completedAt = context.now
            oneOffs[i].completedDay = today
            title = oneOffs[i].title
        case .occurrence(let id, let day):
            // A stale Lock Screen tap for yesterday's occurrence is a no-op.
            guard day == today, let i = occurrenceIndex(id, day),
                  occurrences[i].completedAt == nil, !occurrences[i].skipped,
                  let s = series.first(where: { $0.id == id }) else { return false }
            occurrences[i].completedAt = context.now
            title = s.title
        }
        completionLog.append(CompletionRecord(ref: ref, title: title, completedAt: context.now))
        if completionLog.count > completionLogLimit {
            completionLog.removeFirst(completionLog.count - completionLogLimit)
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
        }
        if let last = completionLog.lastIndex(where: { $0.ref == ref }) {
            completionLog.remove(at: last)
        }
        return true
    }

    public mutating func deleteOneOff(_ id: UUID, context: DayContext) {
        oneOffs.removeAll { $0.id == id }
        reconcile(today: context.today)
    }

    /// Removes a series and all its occurrences.
    public mutating func deleteSeries(_ id: UUID, context: DayContext) {
        series.removeAll { $0.id == id }
        reconcile(today: context.today)
    }

    /// Removes only today's occurrence of a series; it returns on its next scheduled day.
    public mutating func skipToday(seriesID: UUID, context: DayContext) {
        let today = context.today
        reconcile(today: today)
        if let i = occurrenceIndex(seriesID, today) { occurrences[i].skipped = true }
    }

    /// Reorders today's active list like `Array.move(fromOffsets:toOffset:)`.
    /// Items not currently visible (completed one-offs, unscheduled series)
    /// keep their slots in the global order; visible items are re-dealt into
    /// the slots they already occupied.
    public mutating func moveActive(fromOffsets source: IndexSet, toOffset destination: Int, context: DayContext) {
        let today = context.today
        reconcile(today: today)
        var visible = activeRows(today: today).map(\.ref.orderID)
        let moving = source.sorted().filter { $0 < visible.count }.map { visible[$0] }
        guard !moving.isEmpty else { return }
        let insertAt = destination - source.filter { $0 < destination }.count
        visible.removeAll { moving.contains($0) }
        visible.insert(contentsOf: moving, at: max(0, min(insertAt, visible.count)))

        let visibleSet = Set(visible)
        var next = visible.makeIterator()
        order = order.map { visibleSet.contains($0) ? next.next()! : $0 }
    }

    public func series(_ id: UUID) -> RecurringSeries? { series.first { $0.id == id } }
    public func oneOff(_ id: UUID) -> OneOffTask? { oneOffs.first { $0.id == id } }
}
