import AppKit

/// Starts automatic backups when the destination drive mounts and once a day.
@MainActor
final class AutoBackupController {
    private let model: ExportModel
    private let settings: AutoBackupSettings
    private var mountObserver: NSObjectProtocol?
    private var dailyScheduler: NSBackgroundActivityScheduler?
    private var driveBackupTask: Task<Void, Never>?
    private var startupBackupTask: Task<Void, Never>?

    private static let day: TimeInterval = 24 * 60 * 60

    init(model: ExportModel, settings: AutoBackupSettings) {
        self.model = model
        self.settings = settings
    }

    func start() {
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor [weak self] in
                self?.volumeDidMount(volume)
            }
        }

        let identifier = "\(Bundle.main.bundleIdentifier ?? "Uncloud").daily-backup"
        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.interval = Self.day
        scheduler.tolerance = 60 * 60
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                self?.runDailyBackupIfDue(olderThan: Self.day - 4 * 60 * 60)
                completion(.finished)
            }
        }
        dailyScheduler = scheduler

        // Catch up on a day that was missed while the app wasn't running.
        if settings.backUpDaily, isBackupStale(olderThan: Self.day) {
            startupBackupTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.runDailyBackupIfDue(olderThan: Self.day)
            }
        }
    }

    private func volumeDidMount(_ mountedVolume: URL?) {
        guard settings.backUpWhenDriveConnects else { return }
        model.reconnectDestination()

        guard let mountedVolume, let destinationVolume = model.destinationVolumeURL,
              destinationVolume.standardizedFileURL.path == mountedVolume.standardizedFileURL.path
        else { return }

        driveBackupTask?.cancel()
        driveBackupTask = Task { [weak self] in
            // Give the drive a moment to settle before reading from it.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.model.backUpAutomatically(reason: "drive connected")
        }
    }

    private func runDailyBackupIfDue(olderThan threshold: TimeInterval) {
        guard settings.backUpDaily, isBackupStale(olderThan: threshold) else { return }
        model.backUpAutomatically(reason: "daily backup")
    }

    private func isBackupStale(olderThan threshold: TimeInterval) -> Bool {
        guard let last = model.lastBackupDate else { return true }
        return Date.now.timeIntervalSince(last) > threshold
    }
}
