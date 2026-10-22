import Foundation
import Testing
@testable import Uncloud

/// R12g: an export's walk feeds the local catalog, and only a walk that visits everything proves deletions. Runs the
/// real engine against the fake bridge, as the cancellation tests do.
extension ExportCancellationTests {
    private static func row(_ id: String, seenAt: Date) -> ICloudCatalog.Row {
        ICloudCatalog.Row(id: id, master: nil, added: nil, created: nil, filename: "\(id).JPG", isVideo: false,
                          size: nil, bytes: nil, latitude: nil, longitude: nil, timeZoneOffset: nil,
                          rank: 0, rankCount: 300, seenAt: seenAt)
    }

    @Test func aFullWalkFeedsTheCatalogAndPrunesWhatItDidNotSee() async throws {
        let fixture = try Fixture(bridge: ["--total", "300", "--rate", "0"])
        defer { fixture.tearDown() }
        let catalog = try #require(ICloudCatalogStore.shared(appleID: fixture.appleID))
        // An item the library doesn't have, last seen before the walk: the walk must prove it gone.
        try await catalog.upsert([Self.row("ghost", seenAt: Date())])

        let run = fixture.engine().start()
        let collector = Collector()
        await collector.read(run).value
        let counts = collector.snapshot
        #expect(counts.error == nil)
        // The listed pages changed no count: the export still exports 300 items, once each.
        #expect(counts.exported == 300)
        #expect(counts.processed == 300)

        let status = try await catalog.status()
        #expect(status.rowCount == 300)
        #expect(status.fullWalkEndedAt != nil)
        let ghost = try await catalog.rows(ids: ["ghost"])
        #expect(ghost.isEmpty)
    }

    @Test func aWalkThatEndsEarlyNeverPrunes() async throws {
        let fixture = try Fixture(bridge: ["--total", "300", "--rate", "0", "--throttle-after", "50"])
        defer { fixture.tearDown() }
        let catalog = try #require(ICloudCatalogStore.shared(appleID: fixture.appleID))
        try await catalog.upsert([Self.row("ghost", seenAt: Date())])

        let run = fixture.engine().start()
        let collector = Collector()
        await collector.read(run).value
        #expect(collector.snapshot.error != nil)

        // The walk stopped at the throttle: it proved nothing, so the old row stays, and no full walk ended.
        let status = try await catalog.status()
        #expect(status.fullWalkEndedAt == nil)
        let ghost = try await catalog.rows(ids: ["ghost"])
        #expect(!ghost.isEmpty)
        #expect(status.rowCount > 1)
    }
}
