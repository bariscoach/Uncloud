#if DEBUG
import AppKit
import Foundation

/// Debug-only check that the bundled icloudpd helper runs inside the app's sandbox.
/// Launch with `--probe-helper`. The result goes to `<Caches>/helper-probe.txt`, then the app quits.
/// It uses a fake Apple ID and stops at the password prompt, so nothing is sent to Apple.
enum HelperProbe {
    @MainActor
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--probe-helper") else { return }
        Task { @MainActor in
            let report = await probe()
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try? report.write(to: caches.appending(path: "helper-probe.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private static func probe() async -> String {
        var lines: [String] = []
        let cookies = FileManager.default.temporaryDirectory.appending(path: "probe-cookies-\(UUID().uuidString)")
        let arguments = [
            "-u", "probe@example.invalid", "--auth-only",
            "--password-provider", "console", "--mfa-provider", "console",
            "--cookie-directory", cookies.path(percentEncoded: false), "--no-progress-bar",
        ]
        let helper = ICloudHelperProcess(arguments: arguments)
        do {
            let events = try helper.start()
            let started = ContinuousClock.now
            for await event in events {
                lines.append("event: \(event)")
                if case .passwordPrompt = event {
                    lines.append("password prompt after \(started.duration(to: .now))")
                    helper.terminate()
                }
            }
            lines.append("exit status \(await helper.waitUntilExit())")
        } catch {
            lines.append("start failed: \(error.localizedDescription)")
        }
        let wroteCookies = FileManager.default.fileExists(atPath: cookies.path(percentEncoded: false))
        lines.append("cookie directory created: \(wroteCookies)")
        lines.append("last message: \(helper.lastMessage ?? "-")")
        return lines.joined(separator: "\n") + "\n"
    }
}
#endif
