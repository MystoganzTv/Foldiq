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
        defer { TempWorkspace.remove(result.tempDirectory) }

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
        defer { TempWorkspace.remove(result.tempDirectory) }

        XCTAssertEqual(result.mediaURLs.map(\.lastPathComponent), ["test.jpg"])
        XCTAssertEqual(try String(contentsOf: result.mediaURLs[0], encoding: .utf8), "test text document\r\n")
        XCTAssertEqual(try Data(contentsOf: archiveURL), archiveBefore)
        #endif
    }

    // MARK: - ZIP64 (Google Takeout exports over 4 GB)

    /// Builds a ZIP64 archive the way large exporters write it: every size and
    /// offset in the headers is 0xFFFFFFFF, the real values live in the 0x0001
    /// extra field, and the EOCD defers to a ZIP64 end record via a locator.
    /// (CRCs are left at 0; Foldiq checks sizes, not CRCs.)
    private func makeZip64(_ entries: [(name: String, payload: Data, deflate: Bool)]) throws -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let stored = entry.deflate
                ? try (entry.payload as NSData).compressed(using: .zlib) as Data   // raw DEFLATE
                : entry.payload
            let method: UInt16 = entry.deflate ? 8 : 0
            let offset = UInt64(out.count)

            out += le(UInt32(0x04034b50)) + le(UInt16(45)) + le(UInt16(0)) + le(method)
            out += le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0))
            out += le(UInt32.max) + le(UInt32.max) + le(UInt16(name.count)) + le(UInt16(20))
            out += name + le(UInt16(1)) + le(UInt16(16)) + le(UInt64(entry.payload.count)) + le(UInt64(stored.count))
            out += stored

            central += le(UInt32(0x02014b50)) + le(UInt16(45)) + le(UInt16(45)) + le(UInt16(0)) + le(method)
            central += le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0))
            central += le(UInt32.max) + le(UInt32.max) + le(UInt16(name.count)) + le(UInt16(28))
            central += le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0)) + le(UInt32.max)
            central += name + le(UInt16(1)) + le(UInt16(24))
            central += le(UInt64(entry.payload.count)) + le(UInt64(stored.count)) + le(offset)
        }
        let centralOffset = UInt64(out.count)
        out += central
        let zip64RecordOffset = UInt64(out.count)
        out += le(UInt32(0x06064b50)) + le(UInt64(44)) + le(UInt16(45)) + le(UInt16(45))
        out += le(UInt32(0)) + le(UInt32(0)) + le(UInt64(entries.count)) + le(UInt64(entries.count))
        out += le(UInt64(central.count)) + le(centralOffset)
        out += le(UInt32(0x07064b50)) + le(UInt32(0)) + le(zip64RecordOffset) + le(UInt32(1))
        out += le(UInt32(0x06054b50)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16.max) + le(UInt16.max)
        out += le(UInt32.max) + le(UInt32.max) + le(UInt16(0))
        return out
    }

    private func writeArchive(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeout-\(UUID().uuidString).zip")
        try data.write(to: url)
        return url
    }

    func testExtractsZip64TakeoutArchive() async throws {
        let stored = Data("stored photo bytes".utf8)
        let deflated = Data(String(repeating: "deflated photo ", count: 200).utf8)
        let sidecar = Data(#"{"photoTakenTime":{"timestamp":"1600000000"}}"#.utf8)
        let archiveURL = try writeArchive(try makeZip64([
            ("Takeout/Google Photos/IMG_0001.jpg", stored, false),
            ("Takeout/Google Photos/IMG_0002.jpg", deflated, true),
            ("Takeout/Google Photos/IMG_0002.jpg.json", sidecar, false),
        ]))
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let result = try await ArchiveExtractor().extract(archiveURL)
        defer { TempWorkspace.remove(result.tempDirectory) }

        let byName = Dictionary(uniqueKeysWithValues: result.mediaURLs.map { ($0.lastPathComponent, $0) })
        XCTAssertEqual(Set(byName.keys), ["IMG_0001.jpg", "IMG_0002.jpg"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(byName["IMG_0001.jpg"])), stored)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(byName["IMG_0002.jpg"])), deflated)
        // The Takeout sidecar is extracted next to its photo so its date can be read.
        let json = result.tempDirectory.appendingPathComponent("Takeout/Google Photos/IMG_0002.jpg.json")
        XCTAssertEqual(try Data(contentsOf: json), sidecar)
    }

    func testCorruptDeflateEntryFailsInsteadOfWritingGarbage() async throws {
        var archive = try makeZip64([
            ("IMG_0003.jpg", Data(String(repeating: "x", count: 5_000).utf8), true),
        ])
        // Overwrite the start of the compressed stream: 0xFF declares a DEFLATE
        // block type that doesn't exist, so the data is corrupt.
        let headerLength = 30 + "IMG_0003.jpg".utf8.count + 20
        archive.replaceSubrange(headerLength ..< headerLength + 4, with: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        let archiveURL = try writeArchive(archive)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        do {
            let result = try await ArchiveExtractor().extract(archiveURL)
            TempWorkspace.remove(result.tempDirectory)
            XCTFail("a corrupt entry must not extract")
        } catch {
            // Expected: the extractor reports the archive as damaged.
        }
    }

    // MARK: - Temporary workspaces

    private func makeScratchParent() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("TempWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent
    }

    /// A workspace folder as a crashed or quit copy of Foldiq leaves it:
    /// lock file present, nobody holding the lock.
    private func makeFolder(_ name: String, in parent: URL, withLockFile: Bool) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("copy".utf8).write(to: url.appendingPathComponent("IMG_0001.JPG"))
        if withLockFile {
            try Data().write(to: url.appendingPathComponent(TempWorkspace.lockFileName))
        }
        return url
    }

    func testSweepRemovesAbandonedWorkspacesAndKeepsOnesInUse() throws {
        let fm = FileManager.default
        let parent = try makeScratchParent()
        defer { try? fm.removeItem(at: parent) }

        let abandoned = try makeFolder(TempWorkspace.photosPrefix + UUID().uuidString, in: parent, withLockFile: true)
        let abandonedArchive = try makeFolder(TempWorkspace.archivePrefix + UUID().uuidString, in: parent, withLockFile: true)

        // Locked by another "process": a second open file description conflicts.
        let inUse = try makeFolder(TempWorkspace.photosPrefix + UUID().uuidString, in: parent, withLockFile: true)
        let fd = open(inUse.appendingPathComponent(TempWorkspace.lockFileName).path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { close(fd) }

        let owned = try TempWorkspace.create(prefix: TempWorkspace.photosPrefix, in: parent)
        defer { TempWorkspace.remove(owned) }

        let unrelated = try makeFolder("Foldiq-Photos-unrelated", in: parent, withLockFile: true)

        // Older versions made folders without a lock file.
        let oldLegacy = try makeFolder(TempWorkspace.archivePrefix + UUID().uuidString, in: parent, withLockFile: false)
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: oldLegacy.path)
        let recentLegacy = try makeFolder(TempWorkspace.photosPrefix + UUID().uuidString, in: parent, withLockFile: false)

        let removed = TempWorkspace.sweepAbandoned(in: parent)

        XCTAssertFalse(fm.fileExists(atPath: abandoned.path))
        XCTAssertFalse(fm.fileExists(atPath: abandonedArchive.path))
        XCTAssertFalse(fm.fileExists(atPath: oldLegacy.path))
        XCTAssertTrue(fm.fileExists(atPath: inUse.path), "a running copy's folder must survive")
        XCTAssertTrue(fm.fileExists(atPath: owned.path), "this process's own folder must survive")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path), "only Foldiq's prefixes are touched")
        XCTAssertTrue(fm.fileExists(atPath: recentLegacy.path), "unlocked folders get a grace period")
        XCTAssertEqual(Set(removed.map(\.lastPathComponent)),
                       [abandoned.lastPathComponent, abandonedArchive.lastPathComponent, oldLegacy.lastPathComponent])
    }

    func testCreatedWorkspaceIsLockedAndOwnedUntilRemoved() throws {
        let fm = FileManager.default
        let parent = try makeScratchParent()
        defer { try? fm.removeItem(at: parent) }

        let workspace = try TempWorkspace.create(prefix: TempWorkspace.archivePrefix, in: parent)
        let resolved = workspace.resolvingSymlinksInPath().path
        XCTAssertTrue(TempWorkspace.ownedWorkspaces().map { $0.resolvingSymlinksInPath().path }.contains(resolved))

        // Another launch can't take the lock while this process holds it.
        let fd = open(workspace.appendingPathComponent(TempWorkspace.lockFileName).path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        close(fd)

        TempWorkspace.remove(workspace)
        XCTAssertFalse(fm.fileExists(atPath: workspace.path))
        XCTAssertFalse(TempWorkspace.ownedWorkspaces().map { $0.resolvingSymlinksInPath().path }.contains(resolved))
    }
}
