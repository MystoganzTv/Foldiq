// ProbableDuplicateDetectorTests.swift
// Tests for ProbableDuplicateDetector — scoring, election, and detect() behaviour.
//
// All tests run on @MainActor because ProbableDuplicateDetector is @MainActor
// and MediaFile is a SwiftData @Model (must be accessed on main thread).

import XCTest
import SwiftData
@testable import Foldiq

@MainActor
final class ProbableDuplicateDetectorTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    // MARK: - Set up / tear down

    override func setUp() async throws {
        let schema = Schema([
            MediaFile.self,
            ScanSession.self,
            OrganizationPlan.self,
            UndoManifest.self,
            UndoEntry.self,
        ])
        let cfg = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [cfg])
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    // MARK: - normalizedStem

    func testNormalizedStemStripsExtensionAndLowercases() {
        XCTAssertEqual(ProbableDuplicateDetector.normalizedStem("IMG_1234.HEIC"), "img_1234")
        XCTAssertEqual(ProbableDuplicateDetector.normalizedStem("DSC00001.JPG"),  "dsc00001")
        XCTAssertEqual(ProbableDuplicateDetector.normalizedStem("photo.jpeg"),    "photo")
        XCTAssertEqual(ProbableDuplicateDetector.normalizedStem("VID_2026.MOV"),  "vid_2026")
    }

    func testNormalizedStemHandlesNoExtension() {
        XCTAssertEqual(ProbableDuplicateDetector.normalizedStem("NoExtension"), "noextension")
    }

    func testNormalizedStemHandlesMultipleDots() {
        // Only the final extension is stripped
        XCTAssertEqual(ProbableDuplicateDetector.normalizedStem("backup.IMG_1234.JPG"), "backup.img_1234")
    }

    // MARK: - High-confidence pair detection

    func testDetectFindsProbableDuplicateAboveThreshold() async {
        // Stem match (50) + size ≈1% (25) + ts <5min (20) + dimensions match (10) = 105 → capped 100
        let now = Date()
        let heic = makeFile(path: "/Photos/IMG_0001.HEIC", filename: "IMG_0001.HEIC",
                            fileSize: 4_000_000, date: now, width: 4032, height: 3024)
        let jpg  = makeFile(path: "/Export/IMG_0001.JPG",  filename: "IMG_0001.JPG",
                            fileSize: 3_960_000, date: now + 30, width: 4032, height: 3024)

        let count = await ProbableDuplicateDetector().detect(files: [heic, jpg]) { _ in }

        XCTAssertEqual(count, 1, "One probable-duplicate group should be detected")
        let dupSide = [heic, jpg].filter(\.isProbableDuplicate)
        XCTAssertEqual(dupSide.count, 1, "Exactly one file should be marked as the duplicate")
        let inGroup = [heic, jpg].filter { $0.probableDuplicateGroupID != nil }
        XCTAssertEqual(inGroup.count, 2, "Both files should share a group ID")
        XCTAssertEqual(heic.probableDuplicateGroupID, jpg.probableDuplicateGroupID,
                       "Group IDs must match on both sides")
    }

    // MARK: - Below-threshold pair is ignored

    func testDetectIgnoresPairBelowThreshold() async {
        // Stem match only (50pts) — well below threshold of 90.
        let now = Date()
        let a = makeFile(path: "/a/IMG_5678.HEIC", filename: "IMG_5678.HEIC",
                         fileSize: 4_000_000, date: now)
        let b = makeFile(path: "/b/IMG_5678.JPG",  filename: "IMG_5678.JPG",
                         fileSize: 1_000_000, date: now + 86_400 * 7)  // week apart, wildly different size

        let count = await ProbableDuplicateDetector().detect(files: [a, b]) { _ in }

        XCTAssertEqual(count, 0)
        XCTAssertFalse(a.isProbableDuplicate)
        XCTAssertFalse(b.isProbableDuplicate)
        XCTAssertNil(a.probableDuplicateGroupID)
        XCTAssertNil(b.probableDuplicateGroupID)
    }

    // MARK: - Election: non-archive file wins as original

    func testElectsNonArchiveFileAsOriginal() async {
        let now = Date()
        // Both files identical in size, date, and dimensions — only origin differs.
        let folderFile  = makeFile(path: "/Photos/IMG_9999.JPG",       filename: "IMG_9999.JPG",
                                   fileSize: 3_000_000, date: now, width: 3024, height: 4032,
                                   isFromArchive: false)
        let archiveFile = makeFile(path: "/tmp/extracted/IMG_9999.JPG", filename: "IMG_9999.JPG",
                                   fileSize: 3_000_000, date: now, width: 3024, height: 4032,
                                   isFromArchive: true)

        _ = await ProbableDuplicateDetector().detect(files: [folderFile, archiveFile]) { _ in }

        XCTAssertTrue(archiveFile.isProbableDuplicate,
                      "Archive-sourced file should be elected as the duplicate")
        XCTAssertFalse(folderFile.isProbableDuplicate,
                       "Folder file should be elected as the original")
    }

    // MARK: - Election: EXIF date wins over file without date

    func testElectsFileWithExifDateAsOriginal() async {
        let now = Date()
        let withDate    = makeFile(path: "/a/IMG_7777.JPG", filename: "IMG_7777.JPG",
                                   fileSize: 3_000_000, date: now, width: 3024, height: 4032)
        let withoutDate = makeFile(path: "/b/IMG_7777.JPG", filename: "IMG_7777.JPG",
                                   fileSize: 3_000_000, date: nil, width: 3024, height: 4032)

        _ = await ProbableDuplicateDetector().detect(files: [withDate, withoutDate]) { _ in }

        XCTAssertTrue(withoutDate.isProbableDuplicate,
                      "File without EXIF date should be the duplicate")
        XCTAssertFalse(withDate.isProbableDuplicate,
                       "File with EXIF date should be the original")
    }

    // MARK: - Exact duplicates excluded from second-pass

    func testExactDuplicatesAreExcludedFromProbableDetection() async {
        let now = Date()
        let exact = makeFile(path: "/a/IMG_1234.JPG", filename: "IMG_1234.JPG",
                             fileSize: 3_000_000, date: now, width: 3024, height: 4032)
        exact.isDuplicate = true   // already marked by exact SHA-256 pass — must be excluded

        let normal = makeFile(path: "/b/IMG_1234.JPG", filename: "IMG_1234.JPG",
                              fileSize: 3_000_000, date: now, width: 3024, height: 4032)

        let count = await ProbableDuplicateDetector().detect(files: [exact, normal]) { _ in }

        // `exact` is excluded; `normal` has no stem-match partner → 0 probable dup groups
        XCTAssertEqual(count, 0)
        XCTAssertFalse(normal.isProbableDuplicate)
    }

    // MARK: - Each file participates in at most one pair

    func testEachFileParticipatesInAtMostOnePair() async {
        let now = Date()
        // a ↔ b: strong match (stem 50 + size ≈0% 25 + ts <5min 20 + dims 10 = 105 → 100)
        let a = makeFile(path: "/a/IMG_2000.JPG",  filename: "IMG_2000.JPG",
                         fileSize: 3_000_000, date: now, width: 3024, height: 4032)
        let b = makeFile(path: "/b/IMG_2000.HEIC", filename: "IMG_2000.HEIC",
                         fileSize: 3_000_000, date: now + 10, width: 3024, height: 4032)
        // c: same stem but wildly different size and a week apart → won't exceed threshold alone
        let c = makeFile(path: "/c/IMG_2000.PNG",  filename: "IMG_2000.PNG",
                         fileSize: 8_000_000, date: now + 86_400 * 7)

        let count = await ProbableDuplicateDetector().detect(files: [a, b, c]) { _ in }

        XCTAssertEqual(count, 1, "Only the a-b pair should be detected")
        let inGroup = [a, b, c].filter { $0.probableDuplicateGroupID != nil }
        XCTAssertEqual(inGroup.count, 2, "Exactly a and b should be in the group")
        XCTAssertNil(c.probableDuplicateGroupID, "c must not be in any group")
    }

    // MARK: - Unique filenames produce no matches

    func testFilesWithDifferentStemsProduceNoMatches() async {
        let now = Date()
        let a = makeFile(path: "/a/IMG_1111.JPG", filename: "IMG_1111.JPG",
                         fileSize: 3_000_000, date: now)
        let b = makeFile(path: "/b/IMG_2222.JPG", filename: "IMG_2222.JPG",
                         fileSize: 3_000_000, date: now)

        let count = await ProbableDuplicateDetector().detect(files: [a, b]) { _ in }

        XCTAssertEqual(count, 0)
    }

    // MARK: - Empty input

    func testDetectHandlesEmptyInput() async {
        let count = await ProbableDuplicateDetector().detect(files: []) { _ in }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Score reasons string populated

    func testMatchReasonsStringIsPopulatedForDetectedPair() async {
        let now = Date()
        let a = makeFile(path: "/x/IMG_3333.HEIC", filename: "IMG_3333.HEIC",
                         fileSize: 5_000_000, date: now, width: 4032, height: 3024)
        let b = makeFile(path: "/y/IMG_3333.JPG",  filename: "IMG_3333.JPG",
                         fileSize: 4_975_000, date: now + 60, width: 4032, height: 3024)

        _ = await ProbableDuplicateDetector().detect(files: [a, b]) { _ in }

        let dupSide = [a, b].first(where: \.isProbableDuplicate)
        XCTAssertNotNil(dupSide?.probableMatchReasons,
                        "Reasons string should be set on the duplicate side")
        XCTAssertFalse(dupSide?.probableMatchReasons?.isEmpty ?? true,
                        "Reasons string must not be empty")
    }

    // MARK: - Helpers

    private func makeFile(
        path: String,
        filename: String,
        fileSize: Int64 = 1_000_000,
        date: Date? = nil,
        width: Int? = nil,
        height: Int? = nil,
        isFromArchive: Bool = false
    ) -> MediaFile {
        let f = MediaFile(
            filePath: path,
            filename: filename,
            ext: (filename as NSString).pathExtension.lowercased(),
            kind: .photo,
            fileSize: fileSize
        )
        f.dateTaken     = date
        f.pixelWidth    = width
        f.pixelHeight   = height
        if isFromArchive {
            f.archiveSourcePath = "/archive/backup.zip"
        }
        context.insert(f)
        return f
    }
}
