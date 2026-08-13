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
}
