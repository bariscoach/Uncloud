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

    /// Saves the watermark when an export of everything finished completely. Called as a run ends.
    func recordNewPhotosWatermark(_ result: Phase, selection: LibrarySelection) {
        let outcome: RunOutcome
        switch result {
        case .completed: outcome = .completed
        case .cancelled: outcome = .cancelled
        case .failed: outcome = .failed
        default: return
        }
        guard NewPhotosWatermarkPolicy.shouldRecord(outcome: outcome, isEverything: selection.isEverything, failedCount: failedCount),
              let context = newPhotosContext else { return }
        newPhotos.recordWatermark(context)
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
