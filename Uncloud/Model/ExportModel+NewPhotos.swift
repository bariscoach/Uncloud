import Foundation

/// The new-photos glue between ExportModel and NewPhotosTracker: which context applies now, when to recount,
/// and when to save a watermark. The rules themselves are in NewPhotos.swift.
extension ExportModel {
    /// The scope the count applies to now. Nil without a folder, or with iCloud and no signed-in account.
    var newPhotosContext: NewPhotosContext? {
        guard let destination else { return nil }
        if source == .iCloud {
            guard let appleID = ICloudAccount.appleID else { return nil }
            return NewPhotosContext(destination: destination.url, source: .iCloud, appleID: appleID)
        }
        return NewPhotosContext(destination: destination.url, source: source, appleID: nil)
    }

    /// What is new since the last complete export of this folder and source. Nil when there's no such export yet,
    /// or when the count is for another folder or source.
    var newPhotosStatus: NewPhotosStatus? {
        guard let context = newPhotosContext, newPhotos.statusContext == context else { return nil }
        return newPhotos.status
    }

    /// Recounts new photos while the app is idle. Without `force`, a recount happens at most once a minute.
    func refreshNewPhotos(force: Bool = false) {
        guard let context = newPhotosContext, canBackUpAutomatically else { return }
        newPhotos.refresh(context, force: force)
    }

    /// Cancels a count in progress, such as when an export starts.
    func cancelNewPhotosRefresh() {
        newPhotos.cancelRefresh()
    }

    /// Captures the watermark a run of everything would save, as the run starts and before its walk. Called from
    /// startExport. Returns nil when there's no folder or account, or the run isn't of everything.
    func captureNewPhotosCandidate(for selection: LibrarySelection) async -> NewPhotosCandidate? {
        guard selection.isEverything, let context = newPhotosContext else { return nil }
        return await newPhotos.captureCandidate(context, at: currentDate())
    }

    /// Saves the watermark captured when the run started, if the run completed an export of everything. Called as a
    /// run ends. Items added during the run are not in the candidate, so they stay new.
    func recordNewPhotosWatermark(_ result: Phase, selection: LibrarySelection) {
        let candidate = newPhotosCandidate
        newPhotosCandidate = nil
        let outcome: RunOutcome
        switch result {
        case .completed: outcome = .completed
        case .cancelled: outcome = .cancelled
        case .failed: outcome = .failed
        default: return
        }
        guard NewPhotosWatermarkPolicy.shouldRecord(outcome: outcome, isEverything: selection.isEverything, failedCount: failedCount),
              let candidate else { return }
        newPhotos.recordWatermark(candidate)
    }

    /// The periodic check, every few hours while the app runs: recounts, and posts the reminder when it's due.
    func checkForNewPhotos(reminder: NewPhotosReminderSettings, automaticBackupOn: Bool) async {
        guard let context = newPhotosContext, canBackUpAutomatically else { return }
        let connected = FileManager.default.fileExists(atPath: context.destination.path(percentEncoded: false))
        let decision = await newPhotos.checkForReminder(
            context,
            connected: connected,
            automaticBackupOn: automaticBackupOn,
            frequency: reminder.frequency,
            lastReminder: reminder.lastReminder,
            isEnabled: reminder.isEnabled
        )
        if case .remind = decision {
            reminder.recordReminder(at: currentDate())
        }
    }
}
