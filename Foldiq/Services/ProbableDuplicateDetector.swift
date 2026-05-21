// ProbableDuplicateDetector.swift
// Second-level duplicate detection: finds files that are visually the same
// but fail SHA-256 due to EXIF rewrites, format conversion (HEIC→JPEG), etc.
//
// Strategy:
//   1. Pre-group by filename stem (lowercase, no extension) — O(n), avoids O(n²).
//   2. Score every pair within a group using filename, size, timestamp, dimensions.
//   3. Pairs scoring ≥ threshold are elected: one side = original, other = probable dup.
//
// Performance: designed for 50k+ file libraries.
//   - No file I/O during scoring — only in-memory @Model property reads.
//   - All @Model reads happen on @MainActor via value-type snapshots.
//   - All @Model writes happen on @MainActor after scoring is complete.
//
// Architecture: structured to accommodate a perceptual hash (pHash) signal
// as an additional scoring term in the future without structural changes.
// To add pHash: add a `pHashHex: String?` field to FileSnapshot, populate it
// asynchronously in the snapshot phase, and add a Score.pHashMatch constant.

import Foundation

// MARK: ─── ProbableDuplicateDetector ─────────────────────────────────────────

@MainActor
final class ProbableDuplicateDetector {

    // MARK: - Progress

    struct Progress {
        var processed: Int
        var total: Int
        var currentFile: String
    }

    // MARK: - Scoring weights
    // These are intentionally named constants so they can be tuned without
    // hunting through the scoring function.

    private enum Weight {
        static let filenameStemExact  = 50   // stems match (case-insensitive, no ext)
        static let sizeWithin1Pct     = 25   // |sizeA - sizeB| / larger ≤ 1 %
        static let sizeWithin3Pct     = 10   // |sizeA - sizeB| / larger ≤ 3 %
        static let tsWithin5Min       = 20   // |dateA - dateB| ≤ 5 min
        static let tsWithin1Hour      = 17   // |dateA - dateB| ≤ 1 h
        static let tsWithin24Hours    = 10   // |dateA - dateB| ≤ 24 h
        static let dimensionsMatch    = 10   // same pixel width × height
        // Future: static let pHashMatch = 30
    }

    /// Pairs scoring at or above this threshold are surfaced as probable duplicates.
    static let threshold = 90

    // MARK: - Sendable snapshot (crosses actor boundaries safely)

    private struct FileSnapshot: Sendable {
        let id: UUID
        let filename: String
        let stem: String          // normalized: lowercase, no extension
        let fileSize: Int64
        let bestDate: Date?       // dateTaken ?? dateCreated ?? dateModified
        let pixelWidth: Int?
        let pixelHeight: Int?
        let isExactDuplicate: Bool
        let isFromArchive: Bool   // zip-extracted files are preferred as duplicates
        let pathDepth: Int        // fewer path components = more "original"
    }

    // MARK: - Match result (pure value type, assembled before any @Model write)

    struct MatchResult {
        let originalID: UUID
        let duplicateID: UUID
        let score: Int
        let reasons: String        // pre-formatted display string
        let peerFilename: String   // the original's filename (shown in drill sheet)
    }

    // MARK: - Public API

    /// Detect probable duplicates across `files` and write results back to @Model
    /// objects on @MainActor. Returns the number of probable-duplicate groups found.
    @discardableResult
    func detect(
        files: [MediaFile],
        onProgress: @MainActor @escaping (Progress) -> Void
    ) async -> Int {

        // ── 1. Snapshot @Model properties on @MainActor ───────────────────
        let snapshots: [FileSnapshot] = files.map { f in
            FileSnapshot(
                id:              f.id,
                filename:        f.filename,
                stem:            Self.normalizedStem(f.filename),
                fileSize:        f.fileSize,
                bestDate:        f.dateTaken ?? f.dateCreated ?? f.dateModified,
                pixelWidth:      f.pixelWidth,
                pixelHeight:     f.pixelHeight,
                isExactDuplicate: f.isDuplicate,
                isFromArchive:   f.archiveSourcePath != nil,
                pathDepth:       f.filePath.components(separatedBy: "/").count
            )
        }

        // Exclude files already identified as exact SHA-256 duplicates.
        let candidates = snapshots.filter { !$0.isExactDuplicate }

        // ── 2. Pre-group by filename stem — O(n) ─────────────────────────
        // Files that share no stem can never be probable duplicates of each other.
        var byStem: [String: [FileSnapshot]] = [:]
        byStem.reserveCapacity(candidates.count)
        for snap in candidates {
            byStem[snap.stem, default: []].append(snap)
        }

        // ── 3. Score pairs within each stem group ─────────────────────────
        // Groups of size 1 produce no pairs → skipped automatically.
        var matches: [MatchResult] = []
        var processed = 0
        let total = candidates.count

        for (_, group) in byStem where group.count > 1 {
            for i in 0 ..< group.count {
                for j in (i + 1) ..< group.count {
                    processed += 1
                    if processed % 100 == 0 {
                        let p = Progress(processed: processed, total: total,
                                         currentFile: group[i].filename)
                        onProgress(p)
                    }

                    let a = group[i], b = group[j]
                    let (score, reasons) = Self.score(a, b)
                    guard score >= Self.threshold else { continue }

                    let (orig, dup) = Self.electOriginal(a, b)
                    matches.append(MatchResult(
                        originalID:   orig.id,
                        duplicateID:  dup.id,
                        score:        score,
                        reasons:      reasons,
                        peerFilename: orig.filename
                    ))
                }
            }
        }

        // ── 4. Assign results — each file participates in at most one pair ─
        // Sort by score descending so the strongest matches are assigned first.
        let ranked = matches.sorted { $0.score > $1.score }
        var assigned = Set<UUID>()

        let fileByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        var groupCount = 0

        for match in ranked {
            // Skip if either side already belongs to a group.
            guard !assigned.contains(match.duplicateID),
                  !assigned.contains(match.originalID) else { continue }

            guard let dupFile  = fileByID[match.duplicateID],
                  let origFile = fileByID[match.originalID] else { continue }

            let gid = UUID()
            groupCount += 1

            // Duplicate side — will be routed to Duplicates/Probable Duplicates/
            dupFile.isProbableDuplicate       = true
            dupFile.probableDuplicateGroupID  = gid
            dupFile.probableMatchScore        = match.score
            dupFile.probableMatchReasons      = match.reasons
            dupFile.probableMatchPeerFilename = match.peerFilename

            // Original side — stays in normal organized structure,
            // but tagged so it appears in the "Probable Duplicates" drill sheet.
            origFile.probableDuplicateGroupID = gid

            assigned.insert(match.duplicateID)
            assigned.insert(match.originalID)
        }

        return groupCount
    }

    // MARK: - Scoring

    /// Returns (totalScore, humanReadableReasons) for a candidate pair.
    /// Scores are capped at 100 to avoid overflow in display.
    private static func score(_ a: FileSnapshot, _ b: FileSnapshot) -> (Int, String) {
        var total = 0
        var parts: [String] = []

        // ── Filename stem (guaranteed to match since we group by stem,
        //    but we annotate the extension difference if any) ────────────
        let extA = (a.filename as NSString).pathExtension.lowercased()
        let extB = (b.filename as NSString).pathExtension.lowercased()
        total += Weight.filenameStemExact
        if extA == extB {
            parts.append("Same filename")
        } else {
            parts.append("Same name (\(extA.uppercased()) vs \(extB.uppercased()))")
        }

        // ── File size ────────────────────────────────────────────────────
        if a.fileSize > 0 && b.fileSize > 0 {
            let larger  = Double(max(a.fileSize, b.fileSize))
            let smaller = Double(min(a.fileSize, b.fileSize))
            let ratio   = (larger - smaller) / larger
            if ratio <= 0.01 {
                total += Weight.sizeWithin1Pct
                let pct = String(format: "%.1f", ratio * 100)
                parts.append("Size ±\(pct)%")
            } else if ratio <= 0.03 {
                total += Weight.sizeWithin3Pct
                let pct = String(format: "%.1f", ratio * 100)
                parts.append("Size ±\(pct)%")
            }
        }

        // ── Timestamp ────────────────────────────────────────────────────
        if let ta = a.bestDate, let tb = b.bestDate {
            let diff = abs(ta.timeIntervalSince(tb))
            if diff <= 300 {          // 5 minutes
                total += Weight.tsWithin5Min
                let m = Int(diff / 60), s = Int(diff) % 60
                parts.append(m > 0 ? "Timestamp Δ\(m)m \(s)s" : "Timestamp Δ\(s)s")
            } else if diff <= 3600 {  // 1 hour
                total += Weight.tsWithin1Hour
                parts.append("Timestamp Δ\(Int(diff / 60))m")
            } else if diff <= 86_400 { // 24 hours
                total += Weight.tsWithin24Hours
                parts.append("Timestamp Δ\(Int(diff / 3600))h")
            }
        }

        // ── Image dimensions ─────────────────────────────────────────────
        if let wA = a.pixelWidth, let hA = a.pixelHeight,
           let wB = b.pixelWidth, let hB = b.pixelHeight,
           wA > 0 && hA > 0, wA == wB && hA == hB {
            total += Weight.dimensionsMatch
            parts.append("Dimensions \(wA)×\(hA)")
        }

        // Future pHash signal would be inserted here as an additional if-block.

        return (min(total, 100), parts.joined(separator: " · "))
    }

    // MARK: - Original election

    /// Decides which file is the "original" to keep organized and which is the
    /// probable duplicate to move to Duplicates/Probable Duplicates/.
    ///
    /// Priority (highest first):
    ///   1. Non-archive file preferred as original (folder files beat zip-extracted)
    ///   2. File with EXIF date preferred (richer metadata)
    ///   3. Shallower directory depth (less nested = more "root" copy)
    private static func electOriginal(_ a: FileSnapshot, _ b: FileSnapshot)
        -> (original: FileSnapshot, duplicate: FileSnapshot)
    {
        func rank(_ s: FileSnapshot) -> Int {
            var r = 0
            if !s.isFromArchive { r += 100 }
            if s.bestDate != nil { r += 10 }
            r -= s.pathDepth          // deeper path = lower rank
            return r
        }
        return rank(a) >= rank(b) ? (a, b) : (b, a)
    }

    // MARK: - Helpers

    /// Normalize a filename to its stem for grouping:
    /// "IMG_1234.HEIC" → "img_1234", "DSC00001.JPG" → "dsc00001"
    static func normalizedStem(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension.lowercased()
    }
}
