import Foundation

/// Shared state for the backup tools. Only Browse Backup is left, so both the window and the Export menu reach it here.
@MainActor
@Observable
final class BackupTools {
    /// Browse Backup's index and places. It lives here so the index keeps building while the pane isn't shown.
    let browse: BrowseBackup

    init(model: ExportModel) {
        let browse = BrowseBackup(
            isExportRunning: { [weak model] in
                model.map { $0.isExporting || $0.isEngineRunning } ?? false
            },
            iCloudCatalog: BackupTools.browseICloudCatalog
        )
        self.browse = browse
        // Browse refreshes when a run ends, whichever pane is showing. The app's own handler runs first and is kept.
        let previous = model.onRunFinished
        model.onRunFinished = { [weak browse] in
            previous()
            browse?.refresh()
        }
        // A Google Photos import adds photos to the backup too, so Browse refreshes when it ends.
        let previousImport = model.googleImport.onFinished
        model.googleImport.onFinished = { [weak browse] in
            previousImport()
            browse?.refresh()
        }
    }

    /// The iCloud catalog Browse reads for a destination: the signed-in account's (R18). A destination exported with
    /// another Apple ID finds no rows there, which is fine: its items are read from the files. Nil without an Apple ID.
    static func browseICloudCatalog(_ destination: URL) async -> ICloudCatalog? {
        guard let appleID = ICloudAccount.appleID else { return nil }
        return ICloudCatalogStore.shared(appleID: appleID)
    }
}
