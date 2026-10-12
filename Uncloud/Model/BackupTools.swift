import Foundation

/// Shared state for the Verify Backup and Free Up Space sheets, so both the
/// Backup pane and the Export menu can open them.
@MainActor
@Observable
final class BackupTools {
    enum Sheet: Identifiable {
        case verify
        case freeUpSpace

        var id: Self { self }
    }

    var sheet: Sheet?
    let verification: BackupVerification
    let cleanup: LibraryCleanup
    private let model: ExportModel

    init(model: ExportModel) {
        self.model = model
        verification = BackupVerification(model: model)
        cleanup = LibraryCleanup(model: model)
        // Re-export isn't included: it starts an export itself and re-checks before changing the manifest.
        model.isExportBlocked = { [weak self] in
            guard let self else { return false }
            return verification.isChecking || cleanup.isBusy
        }
    }

    var canOpenVerify: Bool {
        sheet == nil && !model.isExporting && model.destination != nil && model.destinationIssue == nil
    }

    var canOpenFreeUpSpace: Bool {
        canOpenVerify && model.source == .photosLibrary && model.hasPhotosAccess
    }

    func showVerify() {
        guard canOpenVerify else { return }
        verification.reset()
        sheet = .verify
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
    }
}
