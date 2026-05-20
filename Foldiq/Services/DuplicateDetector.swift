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

        let total = snapshots.count

        // ── 2. Pre-group by file size (cheap, stays on @MainActor) ────────
        var bySize: [Int64: [FileSnapshot]] = [:]
        for snap in snapshots {
            bySize[snap.fileSize, default: []].append(snap)
        }

        // ── 3. Hash candidates (only same-size buckets) off main thread ───
        var idToHash: [UUID: String] = [:]
        var processed = 0

        for (_, bucket) in bySize where bucket.count > 1 {
            for snap in bucket {
                processed += 1
                if processed % 10 == 0 {
                    let p = Progress(processed: processed, total: total,
                                     currentFile: snap.url.lastPathComponent)
                    onProgress(p)   // already @MainActor
                }

                // Hashing runs off the main thread; snap is Sendable ✓
                if let hash = await Self.computeHash(url: snap.url) {
                    idToHash[snap.id] = hash
                }
            }
        }

        // ── 4. Group snapshots by hash ────────────────────────────────────
        var byHash: [String: [FileSnapshot]] = [:]
        for snap in snapshots {
            guard let hash = idToHash[snap.id] else { continue }
            byHash[hash, default: []].append(snap)
        }

        // ── 5. Elect originals, mark extras — write back to @Model on @MainActor
        let fileByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
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

    private static func computeHash(url: URL) async -> String? {
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return nil
            }
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
