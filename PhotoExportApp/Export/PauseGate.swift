import os

/// Lets the export loop wait between items while the user has paused.
final class PauseGate: Sendable {
    private struct State {
        var isPaused = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func pause() {
        state.withLock { $0.isPaused = true }
    }

    func resume() {
        let waiters = state.withLock { state in
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
}
