import Foundation
import os

/// The signed-in Apple ID and where icloudpd keeps its session cookies.
enum ICloudAccount {
    private static let appleIDKey = "icloudAppleID"

    /// The Apple ID the app signs in with, stored in UserDefaults.
    static var appleID: String? {
        get { UserDefaults.standard.string(forKey: appleIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: appleIDKey) }
    }

    /// Session cookies and tokens for icloudpd. Created on first access.
    static var sessionDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let identifier = Bundle.main.bundleIdentifier ?? "Uncloud"
        let directory = support.appending(path: identifier).appending(path: "icloud-session", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Forgets the Apple ID: clears its session, its saved password, and the stored ID.
    static func signOut() {
        if let appleID {
            ICloudCredentialStore.deletePassword(for: appleID)
        }
        let fileManager = FileManager.default
        let directory = sessionDirectory
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for item in contents {
            try? fileManager.removeItem(at: item)
        }
        appleID = nil
    }

    /// The bundled Python that runs icloudpd, or nil when it isn't in the app.
    static var helperURL: URL? {
        #if DEBUG
        if let override = helperOverride {
            return override.executableURL
        }
        #endif
        let url = runtimeURL.appending(path: "python/bin/python3.13")
        return FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Arguments that make the bundled Python run icloudpd: isolated from user site-packages,
    /// and never writing bytecode into the signed app.
    static var helperLeadingArguments: [String] {
        #if DEBUG
        if let override = helperOverride {
            return override.icloudpdArguments
        }
        #endif
        return ["-I", "-B", runtimeURL.appending(path: "run_icloudpd.py").path(percentEncoded: false)]
    }

    /// Arguments that make the bundled Python run Uncloud's JSON-lines bridge to pyicloud_ipd
    /// (`photo_bridge.py`, embedded next to `run_icloudpd.py`), followed by the account and session.
    static func bridgeArguments(appleID: String) -> [String] {
        bridgeLeadingArguments + ["-u", appleID, "--cookie-directory", sessionDirectory.path(percentEncoded: false)]
    }

    /// The Python flags and the bridge script; see `helperLeadingArguments`.
    static var bridgeLeadingArguments: [String] {
        #if DEBUG
        if let override = helperOverride {
            return override.bridgeArguments
        }
        #endif
        return ["-I", "-B", runtimeURL.appending(path: "photo_bridge.py").path(percentEncoded: false)]
    }

    #if DEBUG
    /// Test-only: runs fake helpers instead of the bundled icloudpd and bridge. Never set in the app.
    struct HelperOverride: Sendable {
        let executableURL: URL
        /// Replaces `helperLeadingArguments`: the interpreter flags and a fake icloudpd script.
        let icloudpdArguments: [String]
        /// Replaces `bridgeLeadingArguments`: the interpreter flags and a fake bridge script.
        let bridgeArguments: [String]
    }

    private static let helperOverrideLock = OSAllocatedUnfairLock<HelperOverride?>(initialState: nil)

    /// Set by tests and the debug harness only.
    static var helperOverride: HelperOverride? {
        get { helperOverrideLock.withLock { $0 } }
        set { helperOverrideLock.withLock { $0 = newValue } }
    }
    #endif

    private static var runtimeURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Resources/icloudpd-runtime", directoryHint: .isDirectory)
    }
}
