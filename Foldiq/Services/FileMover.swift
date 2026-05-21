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

    // MARK: - Apply

    /// Execute all plans in `plans`. Updates plan statuses and appends UndoEntries.
    func apply(
        plans: [OrganizationPlan],
        manifest: UndoManifest,
        onProgress: @MainActor @escaping (ApplyProgress) -> Void
    ) async {
        let total = plans.count
        var done = 0
        var errors: [String] = []

        for plan in plans {
            done += 1

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

                // 2. Move or copy
                try await Task.detached(priority: .utility) {
                    switch op {
                    case .move: try FileManager.default.moveItem(at: srcURL, to: destURL)
                    case .copy: try FileManager.default.copyItem(at: srcURL, to: destURL)
                    }
                }.value

                // Back on @MainActor: safe to touch SwiftData models
                Self.preserveDates(source: srcURL, destination: destURL, operation: op)
                plan.status    = .done
                plan.appliedAt = Date()

                let entry = UndoEntry(
                    originalPath: srcPath,
                    newPath: destPath,
                    hash: hash,
                    operation: op,
                    isFromArchive: plan.archiveSourcePath != nil
                )
                manifest.entries.append(entry)

            } catch {
                let human = Self.humanizeError(error)
                plan.status       = .error
                plan.errorMessage = human
                errors.append(srcURL.lastPathComponent + ": " + human)
            }
        }
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

    // MARK: - Undo

    /// Reverse every entry in the manifest.
    func undo(manifest: UndoManifest, onProgress: @MainActor @escaping (ApplyProgress) -> Void) async {
        let entries = manifest.entries.reversed() as [UndoEntry]
        let total   = entries.count
        var done    = 0

        for entry in entries {
            done += 1
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

            await Task.detached(priority: .utility) {
                if fromArchive {
                    // The file was extracted from a .zip that was never touched.
                    // "Undo" means removing the organized copy — the original
                    // content remains safely inside the untouched archive.
                    try? FileManager.default.removeItem(at: newURL)
                    Self.pruneEmptyAncestorChain(startingAt: newURL.deletingLastPathComponent())
                } else {
                    let origDir = originalURL.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: origDir, withIntermediateDirectories: true)
                    switch op {
                    case .move:
                        try? FileManager.default.moveItem(at: newURL, to: originalURL)
                        Self.pruneEmptyAncestorChain(startingAt: newURL.deletingLastPathComponent())
                    case .copy:
                        try? FileManager.default.removeItem(at: newURL)
                        Self.pruneEmptyAncestorChain(startingAt: newURL.deletingLastPathComponent())
                    }
                }
            }.value
        }

        // @MainActor: safe SwiftData write
        manifest.wasUndone = true
    }

    private nonisolated static func pruneEmptyAncestorChain(startingAt url: URL) {
        let fm = FileManager.default
        var current = url

        while true {
            let remainingItems = (try? fm.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isHiddenKey],
                options: []
            )) ?? []
            let visibleItems = remainingItems.filter { item in
                let values = try? item.resourceValues(forKeys: [.isHiddenKey])
                return values?.isHidden != true
            }

            guard visibleItems.isEmpty else { break }

            for hiddenItem in remainingItems {
                let values = try? hiddenItem.resourceValues(forKeys: [.isHiddenKey])
                if values?.isHidden == true {
                    try? fm.removeItem(at: hiddenItem)
                }
            }

            guard (try? fm.removeItem(at: current)) != nil else { break }

            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path, !parent.path.isEmpty, parent.path != "/" else { break }
            current = parent
        }
    }

    // MARK: - Archive temp directory cleanup

    /// Delete temporary directories that were created when extracting .zip archives
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
    func shelveResidualFilesForReview(
        under roots: [URL],
        expectedDestinationPaths: Set<String>,
        outputFolderName: String,
        reviewFolderName: String
    ) async -> Int {
        await Task.detached(priority: .utility) {
            roots.reduce(0) { count, root in
                guard root.lastPathComponent == outputFolderName else { return count }
                return count + Self.shelveResidualFiles(
                    under: root,
                    expectedDestinationPaths: expectedDestinationPaths,
                    reviewFolderName: reviewFolderName
                )
            }
        }.value
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
            let visibleItems = remainingItems.filter { item in
                let values = try? item.resourceValues(forKeys: [.isHiddenKey])
                return values?.isHidden != true
            }

            if visibleItems.isEmpty {
                if !dryRun {
                    for hiddenItem in remainingItems {
                        let values = try? hiddenItem.resourceValues(forKeys: [.isHiddenKey])
                        if values?.isHidden == true {
                            try? fm.removeItem(at: hiddenItem)
                        }
                    }
                }

                if !dryRun { try? fm.removeItem(at: url) }
                count += 1
            }
        }
        return count
    }

    private nonisolated static func shelveResidualFiles(
        under root: URL,
        expectedDestinationPaths: Set<String>,
        reviewFolderName: String
    ) -> Int {
        let fm = FileManager.default
        let reviewRoot = root.appendingPathComponent(reviewFolderName)

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var residualFiles: [URL] = []

        for case let fileURL as URL in enumerator {
            let path = fileURL.path
            if path.hasPrefix(reviewRoot.path + "/") { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            if expectedDestinationPaths.contains(path) { continue }
            residualFiles.append(fileURL)
        }

        var movedCount = 0
        for fileURL in residualFiles {
            let relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
            var destination = reviewRoot.appendingPathComponent(relativePath)
            let destDir = destination.deletingLastPathComponent()
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            destination = resolveFileCollision(destination)

            do {
                try fm.moveItem(at: fileURL, to: destination)
                movedCount += 1
            } catch {
                continue
            }
        }

        return movedCount
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
    /// True when the URL points to a file with a .zip extension.
    var isZipFile: Bool { pathExtension.lowercased() == "zip" }

    /// Compute SHA-256 of file contents. Returns nil if file is unreadable.
    func sha256() -> String? {
        guard let data = try? Data(contentsOf: self, options: .mappedIfSafe) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
