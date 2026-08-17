import Foundation

/// A non-reentrant gate that guards a single in-flight task, confined to the main actor.
///
/// This is not a thread-safe lock: it is a simple latch that is safe precisely because all access
/// happens on the main actor. Use it to prevent a task from starting while another task guarded by
/// the same gate is still running.
@MainActor
public final class TaskGate {

    /// Whether the gate is currently closed (a guarded task is in flight).
    public private(set) var isClosed = false

    public init() {}

    /// Attempts to close the gate. Returns `false` if it was already closed.
    @discardableResult
    func tryClose() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        return true
    }

    /// Opens the gate, allowing the next guarded task to run.
    func open() {
        isClosed = false
    }
}

/// A lazily-populated collection of `TaskGate`s keyed by a value, confined to the main actor.
@MainActor
public final class TaskGateMap<Key: Hashable> {

    public init() {}

    public subscript(key: Key) -> TaskGate {
        if let gate = gates[key] {
            return gate
        }
        let gate = TaskGate()
        gates[key] = gate
        return gate
    }
    
    
    //---------------
    // MARK: Private
    //---------------
    
    private var gates: [Key: TaskGate] = [:]
}
