import Foundation
import os

/// A thread-safe holder for in-flight tasks, so they can be cancelled together.
///
/// Access is guarded by a lock rather than an actor so a `nonisolated deinit` can call
/// `cancelAll()` — the whole point is to cancel the interactor's work as it is torn down.
final class CancellationBag: Sendable {

    /// Registers a task under the given identifier so it can be cancelled later.
    ///
    /// If a task already exists for `id`, it is replaced (the previous one is not cancelled).
    ///
    /// - Parameter id: A unique identifier used to track and later remove the task.
    /// - Parameter task: The in-flight task to retain until it completes or is cancelled.
    func insert(_ id: UUID, _ task: Task<Void, Never>) {
        tasks.withLock { $0[id] = task }
    }

    /// Stops tracking the task associated with the given identifier.
    ///
    /// Call this when a task finishes so the bag doesn't hold onto completed work.
    /// The task itself is not cancelled — it is simply removed from the bag.
    ///
    /// - Parameter id: The identifier of the task to drop.
    func remove(_ id: UUID) {
        tasks.withLock { $0[id] = nil }
    }

    /// Cancels every tracked task and empties the bag.
    ///
    /// The tasks are collected and removed under the lock, then cancelled outside of it
    /// to avoid holding the lock while running cancellation handlers.
    func cancelAll() {
        let inflight = tasks.withLock { state -> [Task<Void, Never>] in
            let all = Array(state.values)
            state.removeAll()
            return all
        }
        inflight.forEach { $0.cancel() }
    }
    
    
    //---------------
    // MARK: Private
    //---------------
    
    private let tasks = OSAllocatedUnfairLock<[UUID: Task<Void, Never>]>(initialState: [:])
}
