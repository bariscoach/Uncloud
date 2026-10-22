import Foundation

/// Shared state for the Verify Backup, Find Duplicates and Free Up Space sheets, so both the
/// Backup pane and the Export menu can open them.
@MainActor
@Observable
final class BackupTools {
    enum Sheet: Identifiable {
        case verify
        case duplicates
        case freeUpSpace

        var id: Self { self }
    }

    var sheet: Sheet?
    let verification: BackupVerification
    let cleanup: LibraryCleanup
    let duplicates: DuplicateCleanup
    /// Browse Backup's index and places. It lives here so the index keeps building while the pane isn't shown.
    let browse: BrowseBackup
    private let model: ExportModel

    init(model: ExportModel) {
        self.model = model
        verification = BackupVerification(model: model)
        cleanup = LibraryCleanup(model: model)
        duplicates = DuplicateCleanup(model: model)
        browse = BrowseBackup(
            isExportRunning: { [weak model] in
                model.map { $0.isExporting || $0.isEngineRunning } ?? false
            },
            iCloudCatalog: BackupTools.browseICloudCatalog
        )
        // Re-export isn't included: it starts an export itself and re-checks before changing the manifest.
        model.isExportBlocked = { [weak self] in
            guard let self else { return false }
            return verification.isChecking || cleanup.isBusy || duplicates.isBusy || model.iCloudCleanup?.isRunning == true
        }
    }

    /// The iCloud catalog Browse reads for a destination: the signed-in account's (R18). A destination exported with
    /// another Apple ID finds no rows there, which is fine: its items are read from the files. Nil without an Apple ID.
    static func browseICloudCatalog(_ destination: URL) async -> ICloudCatalog? {
        guard let appleID = ICloudAccount.appleID else { return nil }
        return ICloudCatalogStore.shared(appleID: appleID)
    }

    var canOpenVerify: Bool {
        sheet == nil && !model.isExporting && !model.isEngineRunning && model.destination != nil && model.destinationIssue == nil
    }

    var canOpenDuplicates: Bool {
        canOpenVerify
    }

    var canOpenFreeUpSpace: Bool {
        canOpenVerify && model.source == .photosLibrary && model.hasPhotosAccess
    }

    func showVerify() {
        guard canOpenVerify else { return }
        verification.reset()
        sheet = .verify
    }

    func showDuplicates() {
        guard canOpenDuplicates else { return }
        duplicates.reset()
        sheet = .duplicates
    }

    func showFreeUpSpace() {
        guard canOpenFreeUpSpace else { return }
        cleanup.reset()
        sheet = .freeUpSpace
    }

    /// Stops any check still running when a sheet closes.
    func sheetDismissed() {
        verification.cancel()
        cleanup.cancel()
        duplicates.cancel()
    }
}
