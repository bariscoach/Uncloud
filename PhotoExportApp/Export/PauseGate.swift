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

    func pause() {
        // Observers are told inside the lock, so they see changes in order.
        state.withLock { state in
            guard !state.isPaused else { return }
            state.isPaused = true
            state.observers.values.forEach { $0.yield(true) }
        }
    }

    func resume() {
        let waiters = state.withLock { state in
            if state.isPaused {
                state.observers.values.forEach { $0.yield(false) }
            }
            state.isPaused = false
            defer { state.waiters = [] }
            return state.waiters
        }
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
    func changes() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { state in
            state.observers[id] = continuation
            continuation.yield(state.isPaused)
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
        return stream
    }
}
