/// Keeps a read/save/publish transaction exclusive across suspension points.
/// Actor isolation alone does not do this: other calls can enter at each await.
@MainActor
public final class OperationGate {
    private var occupied = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Cancellation deliberately does not drop an accepted user action.
    /// Every acquisition must be paired with `defer { release() }`.
    public func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    public func release() {
        precondition(occupied)
        if waiting.isEmpty {
            occupied = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
