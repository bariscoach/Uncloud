import Foundation
import os

/// Every icloudpd helper and bridge process the app has running, for quitting.
enum ICloudProcesses {
    /// True while any helper or bridge process runs.
    static var areRunning: Bool {
        !ICloudHelperProcess.runningHelpers.isEmpty || !ICloudBridge.runningBridges.isEmpty
    }

    /// Stops every helper and bridge: SIGCONT then SIGTERM to each process group (so a paused helper
    /// stops too), up to `grace` for them to exit, then SIGKILL to whatever is left, and up to
    /// `killWait` more for that. icloudpd and the bridge leave `.part` files that the next run resumes.
    static func shutDownAll(grace: Duration = .seconds(2), killWait: Duration = .seconds(1)) async {
        await shutDown(
            helpers: ICloudHelperProcess.runningHelpers,
            bridges: ICloudBridge.runningBridges,
            grace: grace,
            killWait: killWait
        )
    }

    /// `shutDownAll` for the given processes only.
    static func shutDown(
        helpers: [ICloudHelperProcess],
        bridges: [ICloudBridge],
        grace: Duration = .seconds(2),
        killWait: Duration = .seconds(1)
    ) async {
        guard !helpers.isEmpty || !bridges.isEmpty else { return }
        helpers.forEach { $0.terminate() }
        bridges.forEach { $0.terminate() }

        func allExited() -> Bool {
            helpers.allSatisfy { $0.exitStatus != nil || $0.processIdentifier == nil }
                && bridges.allSatisfy { $0.processIdentifier == nil }
        }
        if await wait(upTo: grace, until: allExited) {
            // A helper's own children (PyInstaller's bootloader starts one) may outlive it in its group.
            helpers.forEach { $0.kill() }
            return
        }
        helpers.forEach { $0.kill() }
        bridges.forEach { $0.kill() }
        _ = await wait(upTo: killWait, until: allExited)
    }

    /// Polls `condition` until it holds or `timeout` passes. Not cut short by cancellation.
    private static func wait(upTo timeout: Duration, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

extension Task where Success == Void, Failure == Never {
    /// Waits for the task to end, but no longer than `timeout`. True if it ended in time.
    func value(timeout: Duration) async -> Bool {
        let task = self
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            Task<Void, Never> {
                await task.value
                if once.claim() { continuation.resume(returning: true) }
            }
            Task<Void, Never> {
                try? await Task<Never, Never>.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }
}

/// True for the first caller of `claim()` only.
private final class OnceFlag: Sendable {
    private let claimed = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}
