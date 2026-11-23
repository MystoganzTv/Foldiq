// DuplicateDetector.swift
// Groups MediaFiles by SHA-256 content hash to find exact duplicates.
// Also does a fast pre-pass using fileSize to skip obvious non-duplicates.
//
// Strategy: within each duplicate group the "best" file (richest metadata) is
// kept as the original (isDuplicate stays false) so it lands in the organized
// folder structure. Every other copy gets isDuplicate = true and is routed to
// Duplicates/Exact Duplicates/ by the planner.
//
// CONCURRENCY NOTE: detect() is @MainActor so SwiftData model reads/writes are
// always on the correct actor. SHA-256 computation is dispatched to
// Task.detached using Sendable value-type snapshots, never touching @Model objects
// off the main actor.

import Foundation
import CryptoKit
import SwiftData

final class DuplicateDetector {

    // MARK: - Public

    struct Progress {
        var processed: Int
        var total: Int
        var currentFile: String
    }

    /// Assigns `isDuplicate = true` and `duplicateGroupID` to duplicate extras.
    /// The best file in each group keeps `isDuplicate = false` so it stays organized.
    /// Returns the number of duplicate groups found.
    @MainActor
    func detect(
        files: [MediaFile],
        onProgress: @MainActor @escaping (Progress) -> Void
    ) async -> Int {

        // ── 1. Snapshot: read @Model properties on @MainActor ─────────────
        // FileSnapshot is a plain Sendable struct — safe to cross actor boundaries.
        struct FileSnapshot: Sendable {
            let id: UUID
            let url: URL
            let fileSize: Int64
            let hasDateTaken: Bool
            let hasGPS: Bool
            let pathLength: Int
        }

        let snapshots: [FileSnapshot] = files.map { f in
            FileSnapshot(
                id:          f.id,
                url:         f.url,
                fileSize:    f.fileSize,
                hasDateTaken: f.dateTaken != nil,
                hasGPS:      f.latitude != nil,
                pathLength:  f.filePath.count
            )
        }

        // ── 2. Pre-group by file size (cheap, stays on @MainActor) ────────
        var bySize: [Int64: [FileSnapshot]] = [:]
        for snap in snapshots {
            bySize[snap.fileSize, default: []].append(snap)
        }
        let total = bySize.values.reduce(0) { count, bucket in
            count + (bucket.count > 1 ? bucket.count : 0)
        }

        // ── 3. Hash candidates (only same-size buckets) off main thread ───
        // A few files are hashed at once: hashing is mostly waiting for the
        // disk, and one at a time left it idle on big libraries.
        let candidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        var idToHash: [UUID: String] = [:]
        idToHash.reserveCapacity(candidates.count)
        var processed = 0
        let workers = Self.workerCount

        await withTaskGroup(of: (UUID, URL, String?).self) { group in
            var nextToStart = 0
            var inFlight = 0

            func startMore() {
                while nextToStart < candidates.count, inFlight < workers {
                    let snap = candidates[nextToStart]   // Sendable ✓
                    nextToStart += 1
                    inFlight += 1
                    group.addTask { (snap.id, snap.url, Self.hashFile(at: snap.url)) }
                }
            }

            startMore()
            while let (id, url, hash) = await group.next() {
                inFlight -= 1
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let hash { idToHash[id] = hash }
                processed += 1
                if processed % 10 == 0 || processed == total {
                    onProgress(Progress(processed: processed, total: total,
                                        currentFile: url.lastPathComponent))
                }
                startMore()
            }
        }

        // A cancelled scan must not write back: its files may already have been
        // deleted by the Welcome screen's purge.
        guard !Task.isCancelled else { return 0 }

        // ── 4. Group snapshots by hash ────────────────────────────────────
        var byHash: [String: [FileSnapshot]] = [:]
        for snap in snapshots {
            guard let hash = idToHash[snap.id] else { continue }
            byHash[hash, default: []].append(snap)
        }

        // ── 5. Elect originals, mark extras — write back to @Model on @MainActor
        let fileByID = Dictionary(uniqueKeysWithValues: files.filter(\.isUsable).map { ($0.id, $0) })
        var groupCount = 0

        for (_, group) in byHash where group.count > 1 {
            let gid = UUID()
            groupCount += 1

            // Sort: prefer EXIF date → GPS → shorter path (less nested = more original)
            let ranked = group.sorted { a, b in
                if a.hasDateTaken != b.hasDateTaken { return a.hasDateTaken }
                if a.hasGPS != b.hasGPS { return a.hasGPS }
                return a.pathLength < b.pathLength
            }

            for (index, snap) in ranked.enumerated() {
                guard let file = fileByID[snap.id] else { continue }
                file.duplicateGroupID = gid
                file.contentHash      = idToHash[snap.id]
                // index 0 = elected original → stays organized (isDuplicate stays false)
                // index 1+ = extras → routed to Duplicates/ folder
                if index > 0 {
                    file.isDuplicate = true
                }
            }
        }

        return groupCount
    }

    // MARK: - Hash computation (off main thread)

    /// Files hashed at the same time.
    static var workerCount: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 4)
    }

    /// SHA-256 of the whole file, or nil when it can't be read. Blocking; only
    /// called from child tasks, never on the main actor.
    static func hashFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
