// FileMover.swift
// Executes planned file operations safely:
//   • Creates destination directories
//   • Never overwrites (name collision already resolved by planner)
//   • Preserves original file dates via extended attributes / setAttributes
//   • Writes an UndoManifest so every action can be reversed
//   • Logs every step
//
// CONCURRENCY NOTE: FileMover is @MainActor so SwiftData model mutations are
// always on the correct actor. Actual file I/O (move/copy/hash) is dispatched
// to Task.detached(priority: .utility) to avoid blocking the main thread.

import Foundation
import CryptoKit
import SwiftData

// MARK: ─── FileMover ──────────────────────────────────────────────────────────

@MainActor
final class FileMover {

    // MARK: - Progress

    struct ApplyProgress {
        var done: Int
        var total: Int
        var currentFile: String
        var errors: [String]
    }

    struct UndoResult {
        var restored: Int
        var errors: [String]
    }

    // MARK: - Apply

    /// Execute all plans in `plans`. Updates plan statuses and appends UndoEntries.
    func apply(
        plans: [OrganizationPlan],
        manifest: UndoManifest,
        checkpoint: @MainActor @escaping () throws -> Void = {},
        onProgress: @MainActor @escaping (ApplyProgress) -> Void
    ) async {
        let total = plans.count
        var done = 0
        var errors: [String] = []

        for plan in plans {
            done += 1

            // The journal must exist before any file is touched; without it there
            // is no safe Undo, so stop. A purged plan just has nothing left to do.
            guard manifest.isUsable else { break }
            guard plan.isUsable else { continue }

            // Report progress for every file so the UI shows real-time file names.
            let p = ApplyProgress(
                done: done, total: total,
                currentFile: plan.sourceURL.lastPathComponent,
                errors: errors
            )
            onProgress(p)   // already @MainActor, no await needed

            // Create destination directory tree (fast metadata op, fine on main)
            let destDir = plan.destinationURL.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(
                    at: destDir,
                    withIntermediateDirectories: true
                )
            } catch {
                plan.status       = .error
                plan.errorMessage = "Could not create directory: \(error.localizedDescription)"
                errors.append(plan.sourceURL.lastPathComponent + ": " + (plan.errorMessage ?? ""))
                continue
            }

            // Safety: never overwrite
            if FileManager.default.fileExists(atPath: plan.destinationAbsPath) {
                plan.status       = .skipped
                plan.errorMessage = "Destination already exists — skipped."
                continue
            }

            // Snapshot paths before going off-actor (URLs are Sendable value types)
            let srcURL  = plan.sourceURL
            let destURL = plan.destinationURL
            let srcPath = plan.sourceAbsPath
            let destPath = plan.destinationAbsPath
            let op      = plan.operation

            // Hash + file I/O: both off the main thread, sequential (hash before move)
            do {
                // 1. Hash while the file is still at its source path
                let hash = await Task.detached(priority: .utility) {
                    srcURL.sha256() ?? ""
                }.value
                guard !hash.isEmpty else {
                    throw CocoaError(.fileReadUnknown)
                }
                // Nothing has been moved yet: if the journal or the plan went away
                // during the hash, skip this file instead of writing to them.
                guard manifest.isUsable else { break }
                guard plan.isUsable else { continue }

                // Persist Undo intent before touching either path. This makes a
                // crash between the file operation and the next UI update safe:
                // Undo can inspect both locations and resume idempotently.
                let entry = UndoEntry(
                    originalPath: srcPath,
                    newPath: destPath,
                    hash: hash,
                    operation: op,
                    isFromArchive: plan.archiveSourcePath != nil
                )
                // Register the entry with the model context BEFORE linking it to
                // the manifest. Writing a relationship from a model that is still
                // on SwiftData's default backing to one that is already managed
                // traps inside _DefaultBackingData.setRelationship. Setting the
                // to-one side keeps the manifest's `entries` in sync via the
                // declared inverse, without materialising the whole array.
                manifest.modelContext?.insert(entry)
                entry.manifest = manifest
                do {
                    try checkpoint()
                } catch {
                    Self.discard(entry, from: manifest)
                    throw error
                }

                // 2. Move or copy
                try await Task.detached(priority: .utility) {
                    try Self.performVerifiedOperation(
                        source: srcURL,
                        destination: destURL,
                        operation: op,
                        expectedHash: hash
                    )
                }.value
                if entry.isUsable { entry.wasCompleted = true }

                // Back on @MainActor: safe to touch SwiftData models — unless the
                // plan was purged meanwhile (the journal entry still records it).
                Self.preserveDates(source: srcURL, destination: destURL, operation: op)
                if plan.isUsable {
                    plan.status    = .done
                    plan.appliedAt = Date()
                }

                try checkpoint()

            } catch {
                let human = Self.humanizeError(error)
                if plan.isUsable {
                    plan.status       = .error
                    plan.errorMessage = human
                }
                errors.append(srcURL.lastPathComponent + ": " + human)
                // Remove a journal entry only when no destination exists and
                // the original is still present. Every ambiguous state remains
                // recorded for safe recovery.
                if manifest.isUsable,
                   FileManager.default.fileExists(atPath: srcPath),
                   !FileManager.default.fileExists(atPath: destPath),
                   let last = manifest.entries.last,
                   last.originalPath == srcPath,
                   last.newPath == destPath {
                    Self.discard(last, from: manifest)
                    try? checkpoint()
                }
            }
        }

        // The live update above happens before each operation so the active file
        // is visible. Publish a final snapshot as well, including any last error.
        onProgress(ApplyProgress(
            done: done,
            total: total,
            currentFile: plans.last?.sourceURL.lastPathComponent ?? "",
            errors: errors
        ))
    }

    // MARK: - Error humanization

    /// Converts low-level system errors into plain-English messages.
    private nonisolated static func humanizeError(_ error: Error) -> String {
        let nsErr = error as NSError
        // Map common POSIX / Cocoa error codes to friendly messages.
        switch (nsErr.domain, nsErr.code) {
        case (NSPOSIXErrorDomain, Int(ENOSPC)),
             (NSCocoaErrorDomain, 640):   // NSFileWriteOutOfSpaceError
            return "Disk full — free up space and try again."
        case (NSPOSIXErrorDomain, Int(EACCES)),
             (NSPOSIXErrorDomain, Int(EPERM)),
             (NSCocoaErrorDomain, 513),   // NSFileWriteNoPermissionError
             (NSCocoaErrorDomain, 642):   // NSFileWriteVolumeReadOnlyError
            return "Permission denied — check folder access settings."
        case (NSPOSIXErrorDomain, Int(EROFS)):
            return "The destination volume is read-only."
        case (NSPOSIXErrorDomain, Int(EXDEV)):
            return "Cannot move across volumes — use Copy instead of Move."
        case (NSCocoaErrorDomain, 516):   // NSFileWriteFileExistsError
            return "A file with this name already exists at the destination."
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Journal maintenance

    /// Remove a journal entry from the manifest *and* from the store.
    /// Detaching it from the relationship alone only nullifies the inverse and
    /// leaves an orphaned UndoEntry row behind; nothing else ever fetches
    /// UndoEntry directly, so the row would never be reachable again.
    private static func discard(_ entry: UndoEntry, from manifest: UndoManifest) {
        guard entry.isUsable else { return }
        if manifest.isUsable {
            manifest.entries.removeAll { $0.id == entry.id }
        }
        entry.modelContext?.delete(entry)
    }

    // MARK: - Undo

    /// Reverse every entry in the manifest without overwriting or deleting a
    /// file whose contents no longer match the Apply journal.
    func undo(
        manifest: UndoManifest,
        outputRoot: URL,
        checkpoint: @MainActor @escaping () throws -> Void = {},
        onProgress: @MainActor @escaping (ApplyProgress) -> Void
    ) async -> UndoResult {
        let entries = manifest.entries.reversed() as [UndoEntry]
        let total   = entries.count
        // Captured before the loop: each entry is deleted from the store as it is
        // reversed, and a deleted model must not be read from afterwards.
        let lastFilename = entries.last
            .map { URL(fileURLWithPath: $0.newPath).lastPathComponent } ?? ""
        var done    = 0
        var restored = 0
        var errors: [String] = []

        for entry in entries {
            done += 1
            // Skip a journal entry that was already removed (e.g. by a second
            // recovery pass); reading a deleted model traps inside SwiftData.
            guard entry.isUsable else { continue }
            let p = ApplyProgress(
                done: done, total: total,
                currentFile: URL(fileURLWithPath: entry.newPath).lastPathComponent,
                errors: []
            )
            onProgress(p)

            // Snapshot paths for off-actor dispatch
            let newURL        = URL(fileURLWithPath: entry.newPath)
            let originalURL   = URL(fileURLWithPath: entry.originalPath)
            let op            = entry.operation
            let fromArchive   = entry.isFromArchive

            let expectedHash = entry.contentHash
            do {
                try await Task.detached(priority: .utility) {
                    try Self.undoEntry(
                        organizedURL: newURL,
                        originalURL: originalURL,
                        operation: op,
                        isFromArchive: fromArchive,
                        expectedHash: expectedHash,
                        outputRoot: outputRoot
                    )
                }.value
                restored += 1
                Self.discard(entry, from: manifest)
                try checkpoint()
            } catch {
                errors.append("\(newURL.lastPathComponent): \(Self.humanizeError(error))")
            }
        }

        if manifest.isUsable {
            manifest.wasUndone = errors.isEmpty && manifest.entries.isEmpty
        }
        try? checkpoint()
        onProgress(ApplyProgress(
            done: done,
            total: total,
            currentFile: lastFilename,
            errors: errors
        ))
        return UndoResult(restored: restored, errors: errors)
    }

    private nonisolated static func pruneEmptyAncestorChain(startingAt url: URL, stopAt outputRoot: URL) {
        let fm = FileManager.default
        var current = url
        let stopPath = outputRoot.standardizedFileURL.path
        let startPath = current.standardizedFileURL.path
        guard startPath == stopPath || startPath.hasPrefix(stopPath + "/") else { return }

        while current.standardizedFileURL.path != stopPath {
            let remainingItems = (try? fm.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            guard remainingItems.isEmpty else { break }

            do { try fm.removeItem(at: current) } catch { break }

            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path, !parent.path.isEmpty, parent.path != "/" else { break }
            current = parent
        }
    }

    nonisolated static func performVerifiedOperation(
        source: URL,
        destination: URL,
        operation: FileOperation,
        expectedHash: String
    ) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        switch operation {
        case .copy:
            try fm.copyItem(at: source, to: destination)
        case .move:
            do {
                try fm.moveItem(at: source, to: destination)
            } catch {
                let nsError = error as NSError
                guard nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EXDEV) else { throw error }
                try fm.copyItem(at: source, to: destination)
                guard destination.sha256() == expectedHash else {
                    try? fm.removeItem(at: destination)
                    throw CocoaError(.fileWriteUnknown)
                }
                try fm.removeItem(at: source)
            }
        }

        guard destination.sha256() == expectedHash else {
            if fm.fileExists(atPath: source.path) { try? fm.removeItem(at: destination) }
            throw CocoaError(.fileWriteUnknown)
        }
    }

    nonisolated static func undoEntry(
        organizedURL: URL,
        originalURL: URL,
        operation: FileOperation,
        isFromArchive: Bool,
        expectedHash: String,
        outputRoot: URL
    ) throws {
        guard !expectedHash.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let fm = FileManager.default
        let organizedExists = fm.fileExists(atPath: organizedURL.path)
        let originalExists = fm.fileExists(atPath: originalURL.path)

        // An Apply intent can survive even when the process stopped before the
        // operation began. In that state there is nothing to reverse.
        if !organizedExists, originalExists, operation != .copy, originalURL.sha256() == expectedHash {
            return
        }

        if !organizedExists {
            if operation == .copy || isFromArchive { return }
            guard originalExists, originalURL.sha256() == expectedHash else {
                throw NSError(domain: "Foldiq.Undo", code: 1, userInfo: [NSLocalizedDescriptionKey: "The organized file is missing and the original could not be verified."])
            }
            return
        }

        guard organizedURL.sha256() == expectedHash else {
            throw NSError(domain: "Foldiq.Undo", code: 2, userInfo: [NSLocalizedDescriptionKey: "The organized file changed after organization; Undo was refused."])
        }

        if isFromArchive {
            // Archive-sourced files have no lasting original on disk: the entry's
            // original path points into a temp extraction directory that Foldiq
            // deletes after Apply. Removing the organized copy stays recoverable
            // because the archive the file came from was never modified.
            try fm.removeItem(at: organizedURL)
        } else if operation == .copy {
            // Undoing a Copy deletes the organized duplicate instead of moving it
            // back, which is only safe while the original is still on disk and
            // still byte-identical. If the user deleted or replaced the originals
            // after organizing — trusting the organized copy as the canonical one —
            // this copy is the last surviving version of the file, so deleting it
            // would destroy user data. Refuse and let the user remove it manually.
            guard originalExists else {
                throw NSError(domain: "Foldiq.Undo", code: 4, userInfo: [NSLocalizedDescriptionKey: "The original file is missing, so this organized copy is the only version left. Foldiq will not delete it — remove it yourself if you no longer need it."])
            }
            guard originalURL.sha256() == expectedHash else {
                throw NSError(domain: "Foldiq.Undo", code: 5, userInfo: [NSLocalizedDescriptionKey: "The original file changed after organization, so Foldiq will not delete this organized copy."])
            }
            try fm.removeItem(at: organizedURL)
        } else if originalExists {
            guard originalURL.sha256() == expectedHash else {
                throw NSError(domain: "Foldiq.Undo", code: 3, userInfo: [NSLocalizedDescriptionKey: "The original path is occupied; Foldiq will not overwrite it."])
            }
            try fm.removeItem(at: organizedURL)
        } else {
            try fm.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try performVerifiedOperation(source: organizedURL, destination: originalURL, operation: .move, expectedHash: expectedHash)
        }
        pruneEmptyAncestorChain(startingAt: organizedURL.deletingLastPathComponent(), stopAt: outputRoot)
    }

    // MARK: - Archive temp directory cleanup

    /// Delete temporary directories that were created when extracting archives.
    /// during the scan phase. Call this once after apply() completes successfully.
    func cleanupTempDirs(_ dirs: [URL]) async {
        guard !dirs.isEmpty else { return }
        await Task.detached(priority: .background) {
            for dir in dirs {
                try? FileManager.default.removeItem(at: dir)
            }
        }.value
    }

    // MARK: - Residual file shelving

    /// When re-organizing an already organized output folder, any leftover files
    /// that didn't end up in the new planned structure are moved into a dedicated
    /// review folder instead of being left scattered through the old hierarchy.
    /// Each move is written to the same Undo record as the rest of the run,
    /// before it happens, so Undo puts these files back too.
    func shelveResidualFilesForReview(
        under roots: [URL],
        expectedDestinationPaths: Set<String>,
        outputFolderName: String,
        reviewFolderName: String,
        manifest: UndoManifest,
        checkpoint: @MainActor @escaping () throws -> Void = {}
    ) async -> (moved: Int, errors: [String]) {
        let moves = await Task.detached(priority: .utility) {
            roots
                .filter { $0.lastPathComponent == outputFolderName }
                .flatMap {
                    Self.residualMoves(
                        under: $0,
                        expectedDestinationPaths: expectedDestinationPaths,
                        reviewFolderName: reviewFolderName
                    )
                }
        }.value

        var moved = 0
        var errors: [String] = []
        for move in moves {
            let source = move.source
            let destination = move.destination
            do {
                let hash = await Task.detached(priority: .utility) { source.sha256() ?? "" }.value
                guard !hash.isEmpty else { throw CocoaError(.fileReadUnknown) }

                let entry = UndoEntry(
                    originalPath: source.path,
                    newPath: destination.path,
                    hash: hash,
                    operation: .move
                )
                manifest.modelContext?.insert(entry)
                entry.manifest = manifest
                do {
                    try checkpoint()
                } catch {
                    Self.discard(entry, from: manifest)
                    throw error
                }

                do {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try await Task.detached(priority: .utility) {
                        try Self.performVerifiedOperation(
                            source: source,
                            destination: destination,
                            operation: .move,
                            expectedHash: hash
                        )
                    }.value
                } catch {
                    // Nothing moved: drop the record. Anything ambiguous stays recorded.
                    if FileManager.default.fileExists(atPath: source.path),
                       !FileManager.default.fileExists(atPath: destination.path) {
                        Self.discard(entry, from: manifest)
                        try? checkpoint()
                    }
                    throw error
                }
                entry.wasCompleted = true
                try? checkpoint()
                moved += 1
            } catch {
                errors.append(source.lastPathComponent + ": " + Self.humanizeError(error))
            }
        }
        return (moved, errors)
    }

    private nonisolated static func residualMoves(
        under root: URL,
        expectedDestinationPaths: Set<String>,
        reviewFolderName: String
    ) -> [(source: URL, destination: URL)] {
        let fm = FileManager.default
        let reviewRoot = root.appendingPathComponent(reviewFolderName)

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var moves: [(source: URL, destination: URL)] = []
        var reserved = Set<String>()
        for case let fileURL as URL in enumerator {
            let path = fileURL.path
            if path.hasPrefix(reviewRoot.path + "/") { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            if expectedDestinationPaths.contains(path) { continue }

            let relativePath = String(path.dropFirst(root.path.count + 1))
            var destination = resolveFileCollision(reviewRoot.appendingPathComponent(relativePath))
            var counter = 1
            while reserved.contains(destination.path) {
                let base = reviewRoot.appendingPathComponent(relativePath)
                let name = base.deletingPathExtension().lastPathComponent
                let ext = base.pathExtension
                destination = base.deletingLastPathComponent()
                    .appendingPathComponent(ext.isEmpty ? "\(name)_\(counter)" : "\(name)_\(counter).\(ext)")
                counter += 1
            }
            reserved.insert(destination.path)
            moves.append((fileURL, destination))
        }
        return moves
    }

    // MARK: - Empty folder cleanup

    /// Remove all empty subdirectories under `roots`, skipping any folder named
    /// `outputFolderName` (the organized output should not be touched).
    /// Root folders themselves are never deleted.
    /// Returns the number of directories removed.
    @discardableResult
    func removeEmptyFolders(under roots: [URL], skipping outputFolderName: String) async -> Int {
        await Task.detached(priority: .utility) {
            roots.reduce(0) { count, root in
                count + Self.pruneEmptyDirs(root, skip: outputFolderName, isRoot: true, dryRun: false)
            }
        }.value
    }

    /// Public static entry point used for counting without deleting (dry-run).
    nonisolated static func countEmptyDirs(_ url: URL, skip: String, isRoot: Bool) -> Int {
        pruneEmptyDirs(url, skip: skip, isRoot: isRoot, dryRun: true)
    }

    private nonisolated static func pruneEmptyDirs(_ url: URL, skip: String, isRoot: Bool, dryRun: Bool = false) -> Int {
        // Never touch the organized output folder
        guard isRoot || url.lastPathComponent != skip else { return 0 }

        // Never reach inside a package — a Photos library, an app, a Final Cut
        // library. Its empty folders are part of its structure.
        if PhotosLibrarySupport.isPhotosLibrary(url)
            || (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
            return 0
        }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return 0 }

        var count = 0
        // Recurse into subdirectories first so we clean bottom-up
        for item in contents {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                count += pruneEmptyDirs(item, skip: skip, isRoot: false, dryRun: dryRun)
            }
        }

        // After recursion, re-check whether this directory is now empty
        if !isRoot {
            let remainingItems = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isHiddenKey],
                options: []
            )) ?? []
            if remainingItems.isEmpty {
                if !dryRun { try? fm.removeItem(at: url) }
                count += 1
            }
        }
        return count
    }

    private nonisolated static func resolveFileCollision(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        let dir = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1

        while true {
            let candidateName = ext.isEmpty ? "\(name)_\(counter)" : "\(name)_\(counter).\(ext)"
            let candidate = dir.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    // MARK: - Date preservation

    private static func preserveDates(source: URL, destination: URL, operation: FileOperation) {
        guard operation == .copy else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: source.path) else { return }
        var newAttrs: [FileAttributeKey: Any] = [:]
        if let c = attrs[.creationDate]     { newAttrs[.creationDate]     = c }
        if let m = attrs[.modificationDate] { newAttrs[.modificationDate] = m }
        try? FileManager.default.setAttributes(newAttrs, ofItemAtPath: destination.path)
    }
}

// MARK: ─── URL + SHA-256 ──────────────────────────────────────────────────────

extension URL {
    /// True when the URL points to a supported compressed archive.
    var isArchiveFile: Bool { MediaTypes.archiveExtensions.contains(pathExtension.lowercased()) }

    /// Compute SHA-256 of file contents. Returns nil if file is unreadable.
    func sha256() -> String? {
        guard let stream = InputStream(url: self) else { return nil }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
