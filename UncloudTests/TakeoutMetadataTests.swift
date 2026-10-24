import Foundation
import Testing
@testable import Uncloud

@Suite("Takeout metadata")
struct TakeoutMetadataTests {
    private static let sample = """
    {"title":"IMG_1234.JPG","description":"","imageViews":"3",\
    "creationTime":{"timestamp":"1561000000","formatted":"Jun 20, 2019, 3:06:40 AM UTC"},\
    "photoTakenTime":{"timestamp":"1560990000","formatted":"Jun 20, 2019, 12:20:00 AM UTC"},\
    "geoData":{"latitude":41.9,"longitude":12.5,"altitude":21.0,"latitudeSpan":0.0,"longitudeSpan":0.0},\
    "geoDataExif":{"latitude":41.9,"longitude":12.5,"altitude":21.0,"latitudeSpan":0.0,"longitudeSpan":0.0},\
    "favorited":true,"url":"https://photos.google.com/photo/AF1QipExample",\
    "googlePhotosOrigin":{"mobileUpload":{"deviceType":"ANDROID_PHONE"}}}
    """

    private static func parse(_ json: String) -> TakeoutMetadata? {
        TakeoutMetadata.parse(Data(json.utf8))
    }

    @Test func parsesSampleSidecar() throws {
        let metadata = try #require(TakeoutMetadata.parse(Data(Self.sample.utf8)))
        #expect(metadata.title == "IMG_1234.JPG")
        #expect(metadata.description == "")
        #expect(metadata.favorited == true)
        #expect(metadata.url == "https://photos.google.com/photo/AF1QipExample")
        #expect(metadata.takenDate == Date(timeIntervalSince1970: 1_560_990_000))
        #expect(metadata.coordinate == TakeoutMetadata.Coordinate(latitude: 41.9, longitude: 12.5, altitude: 21.0))
    }

    @Test func stringTimestampsParse() {
        let metadata = Self.parse(#"{"photoTakenTime":{"timestamp":"1560990000"}}"#)
        #expect(metadata?.takenDate == Date(timeIntervalSince1970: 1_560_990_000))
    }

    @Test func numericTimestampsParse() {
        let metadata = Self.parse(#"{"photoTakenTime":{"timestamp":1560990000}}"#)
        #expect(metadata?.takenDate == Date(timeIntervalSince1970: 1_560_990_000))
    }

    @Test func malformedTimestampReadsAsNil() {
        let metadata = Self.parse(#"{"photoTakenTime":{"timestamp":"soon"}}"#)
        #expect(metadata != nil)
        #expect(metadata?.takenDate == nil)
    }

    @Test func takenDateFallsBackToCreationTime() {
        let metadata = Self.parse(#"{"creationTime":{"timestamp":"1561000000"}}"#)
        #expect(metadata?.takenDate == Date(timeIntervalSince1970: 1_561_000_000))
    }

    @Test func zeroGeoDataFallsBackToExif() {
        let metadata = Self.parse("""
        {"geoData":{"latitude":0.0,"longitude":0.0,"altitude":0.0},
         "geoDataExif":{"latitude":41.9,"longitude":12.5,"altitude":21.0}}
        """)
        #expect(metadata?.coordinate == TakeoutMetadata.Coordinate(latitude: 41.9, longitude: 12.5, altitude: 21.0))
    }

    @Test func bothZeroGeoReadsAsNil() {
        let metadata = Self.parse("""
        {"geoData":{"latitude":0.0,"longitude":0.0},"geoDataExif":{"latitude":0.0,"longitude":0.0}}
        """)
        #expect(metadata != nil)
        #expect(metadata?.coordinate == nil)
    }

    @Test func missingFieldsReadAsNil() {
        let empty = Self.parse("{}")
        #expect(empty != nil)
        #expect(empty?.title == nil)
        #expect(empty?.takenDate == nil)
        #expect(empty?.coordinate == nil)
        #expect(empty?.favorited == nil)

        let partial = Self.parse(#"{"title":"a.jpg","geoData":{"latitude":41.9}}"#)
        #expect(partial?.title == "a.jpg")
        #expect(partial?.coordinate == nil)
    }

    @Test func malformedJSONReadsAsNil() {
        #expect(Self.parse("{not json") == nil)
        #expect(Self.parse("[1,2,3]") == nil)
        #expect(TakeoutMetadata.parse(Data()) == nil)
    }

    @Test func albumMetadataNameIsOnlyMetadataJSON() {
        #expect(TakeoutSidecarMatcher.isAlbumMetadata("metadata.json"))
        #expect(!TakeoutSidecarMatcher.isAlbumMetadata("IMG_1.JPG.json"))
    }

    // MARK: - Sidecar matcher

    private static let longName = "Screenshot_20190101-123456_Some long app name here.jpg"
    /// Google cuts the sidecar to 51 characters including `.json`, so the stem is 46 characters.
    private static let truncatedLongJSON: String = {
        let json = String((longName + ".supplemental-metadata").prefix(46)) + ".json"
        precondition(json.count == 51)
        return json
    }()

    struct MatchCase: Sendable {
        let note: String
        let media: String
        let jsons: Set<String>
        var siblings: Set<String> = []
        let expected: String?
    }

    static let matchCases: [MatchCase] = [
        MatchCase(note: "plain", media: "IMG_1.JPG", jsons: ["IMG_1.JPG.json"], expected: "IMG_1.JPG.json"),
        MatchCase(note: "supplemental", media: "IMG_1.JPG", jsons: ["IMG_1.JPG.supplemental-metadata.json"],
                  expected: "IMG_1.JPG.supplemental-metadata.json"),
        MatchCase(note: "supplemental truncated", media: "IMG_1.JPG", jsons: ["IMG_1.JPG.supplemental-metad.json"],
                  expected: "IMG_1.JPG.supplemental-metad.json"),
        MatchCase(note: "duplicate counter", media: "IMG_1(1).JPG", jsons: ["IMG_1.JPG(1).json"],
                  expected: "IMG_1.JPG(1).json"),
        MatchCase(note: "duplicate counter with supplemental", media: "IMG_1(1).JPG",
                  jsons: ["IMG_1.JPG.supplemental-metadata(1).json"], expected: "IMG_1.JPG.supplemental-metadata(1).json"),
        MatchCase(note: "counter must match the json", media: "IMG_1(1).JPG", jsons: ["IMG_1.JPG.json"], expected: nil),
        MatchCase(note: "edited copy uses the original's sidecar", media: "IMG_1-edited.JPG", jsons: ["IMG_1.JPG.json"],
                  expected: "IMG_1.JPG.json"),
        MatchCase(note: "long name truncated to 51", media: longName, jsons: [truncatedLongJSON], expected: truncatedLongJSON),
        MatchCase(note: "truncation too short to trust", media: longName,
                  jsons: [String((longName + ".supplemental-metadata").prefix(30)) + ".json"], expected: nil),
        MatchCase(note: "live photo falls back to image sibling", media: "IMG_1.MP4", jsons: ["IMG_1.HEIC.json"],
                  siblings: ["IMG_1.HEIC"], expected: "IMG_1.HEIC.json"),
        MatchCase(note: "live photo sibling extension case-insensitive", media: "IMG_1.MOV", jsons: ["IMG_1.jpg.json"],
                  siblings: ["IMG_1.jpg"], expected: "IMG_1.jpg.json"),
        MatchCase(note: "movie without image sibling", media: "IMG_1.MOV", jsons: ["IMG_1.HEIC.json"], expected: nil),
        MatchCase(note: "IMG_10 is not IMG_1", media: "IMG_10.JPG", jsons: ["IMG_1.JPG.json"], expected: nil),
        MatchCase(note: "stem match is case-sensitive", media: "img_1.JPG", jsons: ["IMG_1.JPG.json"], expected: nil),
        MatchCase(note: "album metadata is never a photo's sidecar", media: "IMG_1.JPG", jsons: ["metadata.json"],
                  expected: nil),
        MatchCase(note: "album metadata skipped when a photo sidecar exists", media: "IMG_1.JPG",
                  jsons: ["metadata.json", "IMG_1.JPG.json"], expected: "IMG_1.JPG.json"),
    ]

    @Test(arguments: matchCases)
    func matcherFindsSidecar(_ testCase: MatchCase) {
        let found = TakeoutSidecarMatcher.sidecar(for: testCase.media, among: testCase.jsons, siblings: testCase.siblings)
        #expect(found == testCase.expected, "\(testCase.note): \(testCase.media)")
    }
}
