import Foundation
import Testing
@testable import Uncloud

/// The bridge download protocol of the sessions plan (C1): startRank, ranks, the flat layout, full
/// paths, and Apple's throttle ending a download as a retryable error.
@Suite struct ICloudBridgeDownloadTests {
    private final class BundleToken {}

    private func fakeBridge(root: URL, options: [String]) throws -> (ICloudBridge, URL) {
        let python = try #require(ICloudAccount.helperURL ?? ICloudAccount.helperOverride?.executableURL)
        let fake = try #require(Bundle(for: BundleToken.self).url(forResource: "fake_bridge", withExtension: "py"))
        let log = root.appending(path: "launch.log")
        let appleID = "fake-\(UUID().uuidString.prefix(8))@example.invalid"
        let bridge = ICloudBridge(
            appleID: appleID,
            executableURL: python,
            arguments: ["-I", "-B", fake.path(percentEncoded: false), "--rate", "0",
                        "--launch-log", log.path(percentEncoded: false)] + options
                + ["--", "-u", appleID, "--cookie-directory", root.path(percentEncoded: false)]
        )
        return (bridge, log)
    }

    // MARK: - Through the fake bridge

    @Test(.timeLimit(.minutes(1))) func throttleEndsTheDownloadAsARetryableServiceUnavailable() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, _) = try fakeBridge(root: root, options: ["--total", "20", "--throttle-after", "3"])
            defer { bridge.terminate() }
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)
            let download = try await bridge.download(
                ICloudBridgeDownloadOptions(mode: .allExcept, destination: destination)
            )
            var downloaded: [ICloudBridgeItemResult] = []
            var failures = 0
            var sawDone = false
            var thrown: Error?
            do {
                for try await event in download.events {
                    switch event {
                    case .downloaded(let item): downloaded.append(item)
                    case .failed: failures += 1
                    case .done: sawDone = true
                    default: break
                    }
                }
            } catch {
                thrown = error
            }
            let error = try #require(thrown, "A throttled download should end with an error")
            #expect(error as? ICloudError == .failed(.serviceUnavailable))
            #expect(AutoResumePolicy.isRetryable(error))
            #expect(AutoResumePolicy.reason(for: error) == "Apple is limiting downloads")
            // The items before the throttle are downloaded; nothing is reported failed item by item.
            #expect(downloaded.map(\.asset) == ["asset-0", "asset-1", "asset-2"])
            #expect(downloaded.map(\.rank) == [0, 1, 2])
            #expect(failures == 0)
            #expect(!sawDone)
        }
    }

    @Test(.timeLimit(.minutes(1))) func startRankAndFlatLayoutReachTheBridge() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, log) = try fakeBridge(root: root, options: ["--total", "12"])
            defer { bridge.terminate() }
            let destination = root.appending(path: "Flat", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let download = try await bridge.download(
                ICloudBridgeDownloadOptions(mode: .allExcept, ids: ["asset-6"], destination: destination,
                                            layout: .none, startRank: 5)
            )
            var items: [ICloudBridgeItemResult] = []
            var done: ICloudBridgeDownloadEvent?
            for try await event in download.events {
                switch event {
                case .downloaded(let item), .skipped(let item): items.append(item)
                case .done: done = event
                default: break
                }
            }
            #expect(done == .done(downloaded: 6, skipped: 0, failed: 0, cancelled: false))
            #expect(items.map(\.rank) == [5, 7, 8, 9, 10, 11])
            #expect(items.map(\.asset) == ["asset-5", "asset-7", "asset-8", "asset-9", "asset-10", "asset-11"])
            for item in items {
                // Absolute paths, directly in the destination for the flat layout.
                #expect(item.files == [destination.appending(path: item.filename).path(percentEncoded: false)])
                #expect(item.paths == item.files)
                #expect(item.files.allSatisfy { FileManager.default.fileExists(atPath: $0) })
            }
            let launches = try String(contentsOf: log, encoding: .utf8)
            #expect(launches.contains("download-start \(download.id) startRank=5 mode=allExcept layout=none"))
        }
    }

    // MARK: - Protocol

    @Test func optionsEncodeTheNewFieldsAndStayCompatible() throws {
        let destination = URL(filePath: "/Volumes/Backup/Photos", directoryHint: .isDirectory)
        func json(_ request: ICloudBridgeRequest) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        }
        let flat = try json(ICloudBridgeDownloadOptions(mode: .allExcept, ids: ["a"], destination: destination,
                                                       layout: .none, startRank: 9207).request)
        #expect(flat["cmd"] as? String == "download")
        #expect(flat["mode"] as? String == "allExcept")
        #expect(flat["layout"] as? String == "none")
        #expect(flat["startRank"] as? Int == 9207)
        #expect(flat["ids"] as? [String] == ["a"])
        #expect((flat["dest"] as? String)?.hasPrefix("/Volumes/Backup/Photos") == true)

        // A walk from the start leaves startRank out, as requests made before it existed do.
        let month = try json(ICloudBridgeDownloadOptions(mode: .only, ids: ["b"], destination: destination,
                                                        rankHints: ["b": 3]).request)
        #expect(month["startRank"] == nil)
        #expect(month["layout"] as? String == "month")
        #expect(month["hints"] as? [String: Int] == ["b": 3])
        let legacy = try json(ICloudBridgeRequest(cmd: "download", mode: "only", ids: [], dest: "/x", layout: "month"))
        #expect(legacy["startRank"] == nil)
    }

    @Test func downloadEventsCarryRankAssetAndFiles() throws {
        func event(_ line: String) throws -> ICloudBridgeDownloadEvent? {
            ICloudBridgeDownloadEvent(try JSONDecoder().decode(ICloudBridgeMessage.self, from: Data(line.utf8)))
        }
        let downloaded = try event("""
            {"id":3,"event":"downloaded","asset":"AVk3","rank":9206,"filename":"IMG_0001.HEIC",
             "path":"/D/2024/01/IMG_0001.HEIC","paths":["/D/2024/01/IMG_0001.HEIC","/D/2024/01/IMG_0001.MOV"],
             "files":["/D/2024/01/IMG_0001.HEIC","/D/2024/01/IMG_0001.MOV","/D/2024/01/IMG_0001.HEIC.xmp"]}
            """)
        #expect(downloaded == .downloaded(ICloudBridgeItemResult(
            asset: "AVk3", rank: 9206, filename: "IMG_0001.HEIC",
            paths: ["/D/2024/01/IMG_0001.HEIC", "/D/2024/01/IMG_0001.MOV"],
            files: ["/D/2024/01/IMG_0001.HEIC", "/D/2024/01/IMG_0001.MOV", "/D/2024/01/IMG_0001.HEIC.xmp"]
        )))
        // An older bridge's skip: one path, no rank, no files.
        let skipped = try event(#"{"id":3,"event":"skipped","asset":"X","filename":"A.JPG","path":"/D/A.JPG"}"#)
        #expect(skipped == .skipped(ICloudBridgeItemResult(asset: "X", rank: nil, filename: "A.JPG",
                                                          paths: ["/D/A.JPG"], files: ["/D/A.JPG"])))
        let done = try event(#"{"id":3,"event":"done","downloaded":2,"skipped":5,"failed":1,"cancelled":false}"#)
        #expect(done == .done(downloaded: 2, skipped: 5, failed: 1, cancelled: false))
        // A walk past items on the drive reports its rank; without one it's ignored.
        #expect(try event(#"{"id":3,"event":"walked","rank":4999}"#) == .walked(rank: 4999))
        #expect(try event(#"{"id":3,"event":"walked"}"#) == nil)
        #expect(try event(#"{"id":3,"event":"pong"}"#) == nil)
    }

    @Test func runEndingBridgeErrorsAreRetryable() {
        let throttle = ICloudBridge.error(kind: "PyiCloudServiceUnavailableException",
                                          message: "Apple iCloud is temporary refusing to serve icloudpd")
        #expect(throttle as? ICloudError == .failed(.serviceUnavailable))
        #expect(AutoResumePolicy.isRetryable(throttle))
        // By kind, whatever the message says.
        let bare = ICloudBridge.error(kind: "PyiCloudServiceUnavailableException", message: "")
        #expect(bare as? ICloudError == .failed(.serviceUnavailable))
        let offline = ICloudBridge.error(kind: "PyiCloudConnectionErrorException",
                                         message: "Cannot connect to Apple iCloud service")
        #expect(offline as? ICloudError == .failed(.network))
        #expect(AutoResumePolicy.isRetryable(offline))
    }
}
