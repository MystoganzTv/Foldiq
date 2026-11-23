import XCTest
import SwiftData
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

    // MARK: Retry runs and leftover files

    func testUndoReversesEveryRunOfTheSessionNewestFirst() {
        let session = UUID()
        let first = UndoManifest(sessionID: session, rootPath: "/Photos", operation: .move)
        first.createdAt = Date(timeIntervalSince1970: 1_000)
        let retry = UndoManifest(sessionID: session, rootPath: "/Photos", operation: .move)
        retry.createdAt = Date(timeIntervalSince1970: 2_000)
        let alreadyUndone = UndoManifest(sessionID: session, rootPath: "/Photos", operation: .move)
        alreadyUndone.createdAt = Date(timeIntervalSince1970: 3_000)
        alreadyUndone.wasUndone = true

        let order = UndoManifest.pendingUndoOrder([first, alreadyUndone, retry])
        XCTAssertEqual(order.map(\.id), [retry.id, first.id])
    }

    @MainActor
    func testLeftoverFilesSetAsideAreRecordedSoUndoPutsThemBack() async throws {
        let schema = Schema([MediaFile.self, ScanSession.self, OrganizationPlan.self, UndoManifest.self, UndoEntry.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)

        let output = try temporaryDirectory().appendingPathComponent("Organized Media", isDirectory: true)
        let planned = output.appendingPathComponent("2024/2024-08 August/photo.jpg")
        let leftover = output.appendingPathComponent("Old Folder/leftover.jpg")
        for url in [planned, leftover] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(url.lastPathComponent.utf8).write(to: url)
        }

        let manifest = UndoManifest(sessionID: UUID(), rootPath: output.path, operation: .move)
        context.insert(manifest)
        try context.save()

        let result = await FileMover().shelveResidualFilesForReview(
            under: [output],
            expectedDestinationPaths: [planned.path],
            outputFolderName: "Organized Media",
            reviewFolderName: "Needs Review",
            manifest: manifest,
            checkpoint: { try context.save() }
        )

        let shelved = output.appendingPathComponent("Needs Review/Old Folder/leftover.jpg")
        XCTAssertEqual(result.moved, 1)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shelved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: planned.path))

        let entry = try XCTUnwrap(manifest.entries.first)
        XCTAssertEqual(manifest.entries.count, 1)
        XCTAssertTrue(entry.wasCompleted)
        XCTAssertEqual(entry.newPath, shelved.path)

        try FileMover.undoEntry(
            organizedURL: shelved,
            originalURL: leftover,
            operation: entry.operation,
            isFromArchive: entry.isFromArchive,
            expectedHash: entry.contentHash,
            outputRoot: output
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelved.path))
    }

    // MARK: - Stopping partway (big libraries)

    @MainActor
    func testStoppingLeavesTheRestPendingAndContinuingFinishesThem() async throws {
        let schema = Schema([MediaFile.self, ScanSession.self, OrganizationPlan.self, UndoManifest.self, UndoEntry.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)

        let root = try temporaryDirectory()
        let sessionID = UUID()
        var plans: [OrganizationPlan] = []
        for index in 1...3 {
            let source = root.appendingPathComponent("source/photo\(index).jpg")
            let destination = root.appendingPathComponent("Organized Media/2026/photo\(index).jpg")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("photo \(index)".utf8).write(to: source)
            let plan = OrganizationPlan(
                sessionID: sessionID,
                mediaFileID: UUID(),
                source: source.path,
                destination: destination.path,
                op: .move
            )
            context.insert(plan)
            plans.append(plan)
        }
        let firstRun = UndoManifest(sessionID: sessionID, rootPath: root.path, operation: .move)
        context.insert(firstRun)
        try context.save()

        // Stop is asked before every file: let the first one through, then stop.
        var asked = 0
        let stopped = await FileMover().apply(
            plans: plans,
            manifest: firstRun,
            checkpoint: { try context.save() },
            shouldStop: { asked += 1; return asked > 1 }
        ) { _ in }

        XCTAssertTrue(stopped)
        XCTAssertEqual(plans.map(\.status), [.done, .pending, .pending])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plans[0].destinationAbsPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plans[0].sourceAbsPath))
        for plan in plans.dropFirst() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: plan.sourceAbsPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destinationAbsPath))
        }
        XCTAssertEqual(firstRun.entries.count, 1)
        XCTAssertTrue(try XCTUnwrap(firstRun.entries.first).wasCompleted)

        // The finished file's result must be saved even though the run stopped.
        let saved = try context.fetch(FetchDescriptor<OrganizationPlan>())
        XCTAssertEqual(saved.filter { $0.status == .done }.count, 1)

        // "Continue Organizing" applies the pending plans in a second run.
        let pending = plans.filter { $0.status == .pending }
        let secondRun = UndoManifest(sessionID: sessionID, rootPath: root.path, operation: .move)
        context.insert(secondRun)
        try context.save()
        let stoppedAgain = await FileMover().apply(
            plans: pending,
            manifest: secondRun,
            checkpoint: { try context.save() }
        ) { _ in }

        XCTAssertFalse(stoppedAgain)
        XCTAssertEqual(plans.map(\.status), [.done, .done, .done])
        XCTAssertEqual(secondRun.entries.count, 2)
        XCTAssertTrue(secondRun.entries.allSatisfy(\.wasCompleted))
        for plan in plans {
            XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destinationAbsPath))
        }
    }

    @MainActor
    func testAFileThatCannotBeReadLeavesNoJournalEntry() async throws {
        let schema = Schema([MediaFile.self, ScanSession.self, OrganizationPlan.self, UndoManifest.self, UndoEntry.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)

        let root = try temporaryDirectory()
        let good = root.appendingPathComponent("source/good.jpg")
        try FileManager.default.createDirectory(at: good.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("good".utf8).write(to: good)
        let missing = root.appendingPathComponent("source/missing.jpg")

        let sessionID = UUID()
        let plans = [missing, good].map { source in
            OrganizationPlan(
                sessionID: sessionID,
                mediaFileID: UUID(),
                source: source.path,
                destination: root.appendingPathComponent("Organized Media/\(source.lastPathComponent)").path,
                op: .copy
            )
        }
        plans.forEach { context.insert($0) }
        let manifest = UndoManifest(sessionID: sessionID, rootPath: root.path, operation: .copy)
        context.insert(manifest)
        try context.save()

        var lastProgress: FileMover.ApplyProgress?
        let stopped = await FileMover().apply(
            plans: plans,
            manifest: manifest,
            checkpoint: { try context.save() }
        ) { lastProgress = $0 }

        XCTAssertFalse(stopped)
        XCTAssertEqual(plans.map(\.status), [.error, .done])
        XCTAssertEqual(manifest.entries.count, 1)
        XCTAssertEqual(manifest.entries.first?.originalPath, good.path)
        XCTAssertEqual(lastProgress?.done, 2)
        XCTAssertEqual(lastProgress?.errors.count, 1)
    }
}
