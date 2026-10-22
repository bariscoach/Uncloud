import Foundation
import Testing
@testable import Uncloud

/// R18 wiring: Browse Backup gets the signed-in account's iCloud catalog from BackupTools.
@MainActor
@Suite("Browse's iCloud catalog wiring (R18)")
struct BackupToolsBrowseWiringTests {
    @Test func browseReceivesTheSignedInAccountsCatalog() async throws {
        let saved = ICloudAccount.appleID
        defer { ICloudAccount.appleID = saved }
        let tools = BackupTools(model: ExportModel())
        let destination = FileManager.default.temporaryDirectory.appending(path: "browse-wiring", directoryHint: .isDirectory)

        ICloudAccount.appleID = nil
        #expect(await tools.browse.iCloudCatalog(destination) == nil)

        ICloudAccount.appleID = "wiring-\(UUID().uuidString.prefix(8))@example.invalid"
        #expect(await tools.browse.iCloudCatalog(destination) != nil)
    }
}
