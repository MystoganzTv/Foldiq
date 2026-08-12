import XCTest
@testable import Foldiq

final class ArchiveExtractorTests: XCTestCase {
    func testDesktopRecognizesZipRarAndSevenZip() {
        #if os(macOS)
        XCTAssertTrue(ArchiveExtractor.isExtractable("zip"))
        XCTAssertTrue(ArchiveExtractor.isExtractable("RAR"))
        XCTAssertTrue(ArchiveExtractor.isExtractable("7z"))
        XCTAssertFalse(ArchiveExtractor.isExtractable("tar"))
        #endif
    }

    func testExtractsRealSevenZipMediaAndLeavesArchiveUntouched() async throws {
        #if os(macOS)
        let fixture = Bundle(for: Self.self).url(forResource: "archive-media", withExtension: "7z")
        let archiveURL = try XCTUnwrap(fixture)
        let archiveBefore = try Data(contentsOf: archiveURL)

        let result = try await ArchiveExtractor().extract(archiveURL)
        defer { try? FileManager.default.removeItem(at: result.tempDirectory) }

        XCTAssertEqual(result.mediaURLs.map(\.lastPathComponent), ["photo.jpg"])
        XCTAssertEqual(try String(contentsOf: result.mediaURLs[0], encoding: .utf8), "foldiq archive fixture\n")
        XCTAssertEqual(try Data(contentsOf: archiveURL), archiveBefore)
        #endif
    }

    func testExtractsRealRARMediaAndLeavesArchiveUntouched() async throws {
        #if os(macOS)
        let fixture = Bundle(for: Self.self).url(forResource: "archive-media", withExtension: "rar")
        let archiveURL = try XCTUnwrap(fixture)
        let archiveBefore = try Data(contentsOf: archiveURL)

        let result = try await ArchiveExtractor().extract(archiveURL)
        defer { try? FileManager.default.removeItem(at: result.tempDirectory) }

        XCTAssertEqual(result.mediaURLs.map(\.lastPathComponent), ["test.jpg"])
        XCTAssertEqual(try String(contentsOf: result.mediaURLs[0], encoding: .utf8), "test text document\r\n")
        XCTAssertEqual(try Data(contentsOf: archiveURL), archiveBefore)
        #endif
    }
}
