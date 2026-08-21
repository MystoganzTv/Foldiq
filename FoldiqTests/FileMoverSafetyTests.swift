import XCTest
@testable import Foldiq

final class FileMoverSafetyTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Foldiq-FileMoverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUndoRefusesToDeleteChangedOrganizedCopy() throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("source/photo.jpg")
        let organized = root.appendingPathComponent("output/2026/photo.jpg")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: organized.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: original)
        let expectedHash = try XCTUnwrap(original.sha256())
        try Data("changed later".utf8).write(to: organized)

        XCTAssertThrowsError(try FileMover.undoEntry(
            organizedURL: organized,
            originalURL: original,
            operation: .copy,
            isFromArchive: false,
            expectedHash: expectedHash,
            outputRoot: root.appendingPathComponent("output")
        ))
        XCTAssertEqual(try Data(contentsOf: organized), Data("changed later".utf8))
    }

    func testUndoRestoresInterruptedMoveIntent() throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("source/photo.jpg")
        let outputRoot = root.appendingPathComponent("output")
        let organized = outputRoot.appendingPathComponent("2026/08/photo.jpg")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: organized.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: organized)
        let expectedHash = try XCTUnwrap(organized.sha256())

        try FileMover.undoEntry(
            organizedURL: organized,
            originalURL: original,
            operation: .move,
            isFromArchive: false,
            expectedHash: expectedHash,
            outputRoot: outputRoot
        )

        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: organized.path))
    }

    func testUndoNeverRemovesHiddenUserFilesWhilePruning() throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("source/photo.jpg")
        let outputRoot = root.appendingPathComponent("output")
        let organizedFolder = outputRoot.appendingPathComponent("2026/08")
        let organized = organizedFolder.appendingPathComponent("photo.jpg")
        let hidden = organizedFolder.appendingPathComponent(".keep")
        try FileManager.default.createDirectory(at: organizedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: original)
        try Data("original".utf8).write(to: organized)
        try Data("do not delete".utf8).write(to: hidden)
        let expectedHash = try XCTUnwrap(organized.sha256())

        try FileMover.undoEntry(
            organizedURL: organized,
            originalURL: original,
            operation: .copy,
            isFromArchive: false,
            expectedHash: expectedHash,
            outputRoot: outputRoot
        )

        XCTAssertEqual(try Data(contentsOf: hidden), Data("do not delete".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: organizedFolder.path))
    }

    /// Undoing a Copy deletes the organized duplicate. When the user has already
    /// removed the originals, that duplicate is the only surviving version of the
    /// file — Undo must refuse instead of destroying it.
    func testUndoRefusesToDeleteOrganizedCopyWhenOriginalIsMissing() throws {
        let root = try temporaryDirectory()
        let outputRoot = root.appendingPathComponent("output")
        let original = root.appendingPathComponent("source/photo.jpg")
        let organized = outputRoot.appendingPathComponent("2026/08/photo.jpg")
        try FileManager.default.createDirectory(at: organized.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the only remaining copy".utf8).write(to: organized)
        let expectedHash = try XCTUnwrap(organized.sha256())
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))

        XCTAssertThrowsError(try FileMover.undoEntry(
            organizedURL: organized,
            originalURL: original,
            operation: .copy,
            isFromArchive: false,
            expectedHash: expectedHash,
            outputRoot: outputRoot
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: organized.path))
        XCTAssertEqual(try Data(contentsOf: organized), Data("the only remaining copy".utf8))
    }

    /// The original still exists but its contents changed after organizing, so the
    /// organized copy is no longer a redundant duplicate. Undo must not delete it.
    func testUndoRefusesToDeleteOrganizedCopyWhenOriginalChanged() throws {
        let root = try temporaryDirectory()
        let outputRoot = root.appendingPathComponent("output")
        let original = root.appendingPathComponent("source/photo.jpg")
        let organized = outputRoot.appendingPathComponent("2026/08/photo.jpg")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: organized.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: organized)
        let expectedHash = try XCTUnwrap(organized.sha256())
        try Data("edited after organizing".utf8).write(to: original)

        XCTAssertThrowsError(try FileMover.undoEntry(
            organizedURL: organized,
            originalURL: original,
            operation: .copy,
            isFromArchive: false,
            expectedHash: expectedHash,
            outputRoot: outputRoot
        ))

        XCTAssertEqual(try Data(contentsOf: organized), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: original), Data("edited after organizing".utf8))
    }

    /// The happy path must keep working: an intact, byte-identical original means
    /// the organized copy really is redundant and Undo removes it.
    func testUndoDeletesOrganizedCopyWhenOriginalIsIntact() throws {
        let root = try temporaryDirectory()
        let outputRoot = root.appendingPathComponent("output")
        let original = root.appendingPathComponent("source/photo.jpg")
        let organized = outputRoot.appendingPathComponent("2026/08/photo.jpg")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: organized.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: original)
        try Data("original".utf8).write(to: organized)
        let expectedHash = try XCTUnwrap(organized.sha256())

        try FileMover.undoEntry(
            organizedURL: organized,
            originalURL: original,
            operation: .copy,
            isFromArchive: false,
            expectedHash: expectedHash,
            outputRoot: outputRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: organized.path))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
    }

    /// Archive-sourced entries point at a temp extraction path that no longer
    /// exists by the time Undo runs. Removing them stays safe because Foldiq never
    /// modifies the archive itself, so the new original check must not block them.
    func testUndoStillRemovesArchiveExtractedFileWithoutOriginal() throws {
        let root = try temporaryDirectory()
        let outputRoot = root.appendingPathComponent("output")
        let extractedOriginal = root.appendingPathComponent("tmp-extract/photo.jpg")
        let organized = outputRoot.appendingPathComponent("2026/08/photo.jpg")
        try FileManager.default.createDirectory(at: organized.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("extracted".utf8).write(to: organized)
        let expectedHash = try XCTUnwrap(organized.sha256())
        XCTAssertFalse(FileManager.default.fileExists(atPath: extractedOriginal.path))

        try FileMover.undoEntry(
            organizedURL: organized,
            originalURL: extractedOriginal,
            operation: .copy,
            isFromArchive: true,
            expectedHash: expectedHash,
            outputRoot: outputRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: organized.path))
    }
}
