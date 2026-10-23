import Foundation
import Testing
@testable import Uncloud

/// QC round 2: the layout-change question (D5) can't be bypassed while the folder's items are unknown or by
/// choosing a folder that already has exports, and the flat-folder warning shows before any check.
/// Part of ExportCancellationTests, so it never runs alongside the other suites that swap the helpers.
extension ExportCancellationTests {
    private static let holdResumes = AutoResumeTiming(delays: [.seconds(3600)], recheckInterval: .seconds(3600))

    /// `exported.tsv` with `count` iCloud items saved by month.
    private static func writeMonthExports(_ count: Int, in destination: URL) throws {
        let lines = (0..<count).map { "icloud-id:asset-\($0)\t2024/07/IMG_\($0).JPG\n" }.joined()
        try writeFile(lines, to: ".photo-export/exported.tsv", in: destination)
        for index in 0..<count {
            try writeFile("photo \(index)", to: "2024/07/IMG_\(index).JPG", in: destination)
        }
    }

    @Test @MainActor func aLayoutChangeAsksWhileTheFolderIsStillBeingRead() async throws {
        let fixture = try Fixture()
        try Self.writeMonthExports(3, in: fixture.destination)
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        // Right after the folder is chosen its items aren't known yet: ask anyway.
        #expect(!model.knowsICloudItemsByLayout)
        model.requestLayoutChange(to: .flat)
        let question = try #require(model.pendingLayoutChange)
        #expect(model.layout == .month)
        #expect(question.message.contains("can’t tell yet"))
        model.resolveLayoutChange(.cancel)

        // Once read, the real question.
        #expect(await harness.waitFor { model.knowsICloudItemsByLayout })
        model.requestLayoutChange(to: .flat)
        #expect(model.pendingLayoutChange?.itemsSaved == 3)
        model.resolveLayoutChange(.cancel)
        #expect(model.layout == .month)
        await harness.tearDown()
    }

    @Test @MainActor func aLayoutChangeAsksWhenTheFolderCanNotBeRead() async throws {
        let fixture = try Fixture()
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        let unplugged = fixture.root.appending(path: "Unplugged Drive", directoryHint: .isDirectory)
        model.chooseDestination(.success(unplugged))
        #expect(model.destinationIssue != nil)
        // Give any read a chance: an unreadable folder never counts as "no items".
        _ = await harness.waitFor(.milliseconds(300)) { false }
        #expect(!model.knowsICloudItemsByLayout)
        model.requestLayoutChange(to: .album)
        let question = try #require(model.pendingLayoutChange)
        #expect(question.message.contains("can’t read “Unplugged Drive”"))
        #expect(model.layout == .month)
        model.resolveLayoutChange(.cancel)
        await harness.tearDown()
    }

    @Test @MainActor func choosingTheSameFolderForTheNewLayoutAsksAgain() async throws {
        let fixture = try Fixture()
        try Self.writeMonthExports(2, in: fixture.destination)
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        #expect(await harness.waitFor { model.knowsICloudItemsByLayout })
        model.requestLayoutChange(to: .flat)
        model.resolveLayoutChange(.chooseNewFolder)
        #expect(model.isChoosingDestination)
        model.chooseDestination(.success(fixture.destination))
        // Not a silent "Download Again Here".
        #expect(model.layout == .month)
        #expect(model.pendingLayoutChange?.to == .flat)
        model.resolveLayoutChange(.cancel)
        #expect(model.layout == .month)
        await harness.tearDown()
    }

    @Test @MainActor func choosingAnotherFolderThatHasExportsInAnotherLayoutAsks() async throws {
        let fixture = try Fixture()
        try Self.writeMonthExports(1, in: fixture.destination)
        let other = fixture.root.appending(path: "Other Backup", directoryHint: .isDirectory)
        try Self.writeMonthExports(2, in: other)
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        #expect(await harness.waitFor { model.knowsICloudItemsByLayout })
        model.requestLayoutChange(to: .flat)
        model.resolveLayoutChange(.chooseNewFolder)
        model.chooseDestination(.success(other))
        #expect(model.destination?.url.standardizedFileURL == other.standardizedFileURL)
        #expect(await harness.waitFor { model.pendingLayoutChange != nil })
        #expect(model.layout == .month)
        let question = try #require(model.pendingLayoutChange)
        #expect(question.itemsSaved == 2)
        #expect(question.message.contains("“Other Backup” already has 2 photos organized by month"))
        model.resolveLayoutChange(.downloadAgainHere)
        #expect(model.layout == .flat)
        model.requestLayoutChange(to: .month)
        await harness.tearDown()
    }

    @Test @MainActor func theFlatFolderWarningShowsBeforeAnyCheckOrExport() async throws {
        let fixture = try Fixture()
        try writeFile("my CV", to: "Resume.pdf", in: fixture.destination)
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ExportModel.bookmarkKey)
        defaults.set(LibrarySource.iCloud.rawValue, forKey: "librarySource")
        defaults.set(FolderLayout.flat.rawValue, forKey: "folderLayout")
        // Signed out: no drive check can run, so only the quick listing can tell.
        ICloudAccount.appleID = nil
        let model = ExportModel()
        model.chooseDestination(.success(fixture.destination))
        #expect(model.layout == .flat)
        #expect(await Self.wait(timeout: .seconds(10)) { model.flatFolderWarning != nil } != nil)
        #expect(model.lastDriveCheck == nil)
        #expect(model.flatFolderWarning?.hasSuffix("A file with the same name and size as a photo counts as backed up.") == true)
        defaults.set(FolderLayout.month.rawValue, forKey: "folderLayout")
        defaults.removeObject(forKey: ExportModel.bookmarkKey)
        fixture.tearDown()
    }

    /// `exported.tsv` with `count` iCloud items saved all in one folder, and the folder's layout record.
    private static func writeFlatExports(_ count: Int, in destination: URL) throws {
        try writeFile("flat", to: ".photo-export/layout", in: destination)
        let lines = (0..<count).map { "icloud-id:asset-\($0)\tIMG_\($0).JPG\n" }.joined()
        try writeFile(lines, to: ".photo-export/exported.tsv", in: destination)
        for index in 0..<count {
            try writeFile("photo \(index)", to: "IMG_\(index).JPG", in: destination)
        }
    }

    /// Whether an export has started, as the activity list records it.
    @MainActor
    private static func startedExport(_ harness: ModelHarness) async -> Bool {
        await harness.waitFor { harness.model.activity.contains { $0.message.hasPrefix("Starting export") } }
    }

    @Test @MainActor func aFolderOrganizedAnotherWayHoldsTheExportBackAndOffersItsLayout() async throws {
        let fixture = try Fixture()
        try Self.writeFlatExports(3, in: fixture.destination)
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        #expect(await harness.waitFor { model.knowsICloudItemsByLayout })
        #expect(model.layout == .month)

        model.exportAll()
        #expect(await harness.waitFor { model.pendingLayoutChange != nil })
        let question = try #require(model.pendingLayoutChange)
        #expect(question.recorded == .flat)
        #expect(question.to == .month)
        #expect(question.itemsSaved == 3)
        #expect(question.message.contains("is organized all in one folder, but the Folders setting is By Month"))
        // The question shows in Export Settings under Folder Organization, where the layout picker is.
        #expect(model.pane == .backup)
        #expect(model.exportSettingsSection == .folders)
        // Nothing started, and the folder's record is untouched.
        #expect(!model.isExporting && !model.isEngineRunning)
        #expect(!model.activity.contains { $0.message.hasPrefix("Starting export") })
        #expect(ExportManifest.layout(in: fixture.destination) == .flat)
        #expect(model.layout == .month)

        // Use All in One Folder: the setting follows the folder, and the held-back export starts.
        model.resolveLayoutChange(.useRecorded)
        #expect(model.layout == .flat)
        #expect(model.pendingLayoutChange == nil)
        #expect(await Self.startedExport(harness))
        await harness.tearDown()
    }

    @Test @MainActor func aFolderOrganizedTheSettingsWayStartsNormally() async throws {
        let fixture = try Fixture()
        try Self.writeMonthExports(2, in: fixture.destination)
        try writeFile("month", to: ".photo-export/layout", in: fixture.destination)
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        #expect(await harness.waitFor { model.knowsICloudItemsByLayout })

        model.exportAll()
        #expect(await Self.startedExport(harness))
        #expect(model.pendingLayoutChange == nil)
        #expect(!model.activity.contains { $0.message.hasPrefix("Export not started") })
        await harness.tearDown()
    }

    @Test @MainActor func aFolderWithNoRecordedLayoutStartsNormally() async throws {
        let fixture = try Fixture()
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        #expect(ExportManifest.layout(in: fixture.destination) == nil)

        model.exportAll()
        #expect(await Self.startedExport(harness))
        #expect(model.pendingLayoutChange == nil)
        await harness.tearDown()
    }

    @Test @MainActor func aConfirmedDownloadAgainStartsWithTheNewLayout() async throws {
        let fixture = try Fixture()
        try Self.writeMonthExports(2, in: fixture.destination)
        try writeFile("month", to: ".photo-export/layout", in: fixture.destination)
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        #expect(await harness.waitFor { model.knowsICloudItemsByLayout })

        model.requestLayoutChange(to: .flat)
        #expect(model.pendingLayoutChange?.itemsSaved == 2)
        model.resolveLayoutChange(.downloadAgainHere)
        #expect(model.layout == .flat)

        // The folder still records month until the export writes flat, so the owner's confirmation lets it start.
        model.exportAll()
        #expect(await Self.startedExport(harness))
        #expect(model.pendingLayoutChange == nil)
        #expect(!model.activity.contains { $0.message.hasPrefix("Export not started") })
        await harness.tearDown()
    }

    @Test @MainActor func everyLayoutChangeIsLoggedWithItsCause() async throws {
        let fixture = try Fixture()
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        // Once the (empty) folder is read, a change asks nothing and is logged as the picker's.
        #expect(await harness.waitFor { model.knowsICloudItemsByLayout })

        model.requestLayoutChange(to: .flat)
        #expect(model.layout == .flat)
        #expect(model.activity.first?.message == "Folders set to All in One Folder (picker).")
        model.setLayout(.album, reason: "source not available")
        #expect(model.activity.first?.message == "Folders set to By Album (source not available).")
        // The same layout again is no change, so nothing is logged.
        let count = model.activity.count
        model.setLayout(.album, reason: "picker")
        #expect(model.activity.count == count)
        await harness.tearDown()
    }

    @Test @MainActor func aMissingLayoutDefaultTakesTheSavedFolderLayout() async throws {
        let fixture = try Fixture()
        try Self.writeFlatExports(2, in: fixture.destination)
        let defaults = UserDefaults.standard
        defaults.set(LibrarySource.iCloud.rawValue, forKey: "librarySource")
        defaults.removeObject(forKey: "folderLayout")
        defaults.set(try fixture.destination.bookmarkData(options: .withSecurityScope), forKey: ExportModel.bookmarkKey)
        ICloudAccount.appleID = fixture.appleID
        let model = ExportModel()
        // Not By Month, the fallback for a folder without a record: the folder says how it's organized.
        #expect(model.layout == .flat)
        #expect(defaults.string(forKey: "folderLayout") == FolderLayout.flat.rawValue)
        #expect(model.activity.first?.message == "Folders set to All in One Folder (restored from folder).")
        ICloudAccount.appleID = nil
        defaults.removeObject(forKey: ExportModel.bookmarkKey)
        defaults.set(FolderLayout.month.rawValue, forKey: "folderLayout")
        fixture.tearDown()
    }
}

@Suite("Session detail wording")
struct SessionDetailWordingTests {
    @Test func aSelectionRunUsesTheSourcesVerb() {
        let selection = ExportSession.Continuation(strategy: .selection, startRank: nil, fallbackReason: nil)
        #expect(ExportSessionDetailView.continuationText(selection, source: .iCloud) == "Exported only the selected photos")
        #expect(ExportSessionDetailView.continuationText(selection, source: .photosLibrary) == "Exported only the selected photos")
    }
}
