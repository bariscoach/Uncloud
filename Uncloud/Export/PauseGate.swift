import Foundation
import os

/// Lets the export loop wait between items while the user has paused, and lets
/// an engine that runs a helper process follow pause and resume as they happen.
final class PauseGate: Sendable {
    private struct State {
        var isPaused = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isPaused: Bool {
        state.withLock { $0.isPaused }
    }

    // Observers are told outside the lock: yielding can resume a task, which takes that task's own
    // lock, and a task being cancelled at the same moment holds that lock while its stream's
    // termination handler waits for this one. Two changes can then arrive out of order, so observers
    // act on `isPaused` rather than on the value they were sent.

    func pause() {
        let observers = state.withLock { state -> [AsyncStream<Bool>.Continuation] in
            guard !state.isPaused else { return [] }
            state.isPaused = true
            return Array(state.observers.values)
        }
        observers.forEach { $0.yield(true) }
    }

    func resume() {
        let (waiters, observers) = state.withLock { state in
            let observers = state.isPaused ? Array(state.observers.values) : []
            state.isPaused = false
            defer { state.waiters = [] }
            return (state.waiters, observers)
        }
        observers.forEach { $0.yield(false) }
        waiters.forEach { $0.resume() }
    }

    func waitWhilePaused() async {
        await withCheckedContinuation { continuation in
            let isPaused = state.withLock { state in
                if state.isPaused {
                    state.waiters.append(continuation)
                }
                return state.isPaused
            }
            if !isPaused {
                continuation.resume()
            }
        }
    }

    /// The current paused state, then every change to it. Ends when the consumer stops iterating.
    /// Changes made at the same moment can arrive out of order: check `isPaused` for the current state.
    func changes() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let isPaused = state.withLock { state in
            state.observers[id] = continuation
            return state.isPaused
        }
        continuation.yield(isPaused)
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
        return stream
    }
}
