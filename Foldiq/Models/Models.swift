// Models.swift
// All SwiftData @Model types used throughout Foldiq.

import Foundation
import SwiftData

// MARK: ─── ScanSession ────────────────────────────────────────────────────────

/// One full scan of a root folder. Holds aggregate stats and owns all MediaFiles.
@Model
final class ScanSession {
    var id: UUID
    var rootPath: String
    var startedAt: Date
    var finishedAt: Date?
    var totalFiles: Int       // all items encountered
    var photoCount: Int
    var videoCount: Int
    var duplicateCount: Int
    var missingDateCount: Int
    var missingMetaCount: Int
    var errorCount: Int
    var archivesExtractedCount: Int   // number of .zip files extracted during scan
    var probableDuplicateCount: Int   // files marked isProbableDuplicate by second-pass detector

    @Relationship(deleteRule: .cascade, inverse: \MediaFile.session)
    var files: [MediaFile]

    init(rootPath: String) {
        self.id = UUID()
        self.rootPath = rootPath
        self.startedAt = Date()
        self.totalFiles = 0
        self.photoCount = 0
        self.videoCount = 0
        self.duplicateCount = 0
        self.missingDateCount = 0
        self.missingMetaCount = 0
        self.errorCount = 0
        self.archivesExtractedCount = 0
        self.probableDuplicateCount = 0
        self.files = []
    }

    var rootURL: URL { URL(fileURLWithPath: rootPath) }
}

// MARK: ─── MediaFile ──────────────────────────────────────────────────────────

/// Represents one photo or video found during a scan.
@Model
final class MediaFile {
    var id: UUID
    var filePath: String          // absolute path as of last scan
    var filename: String
    var fileExtension: String
    var mediaKindRaw: String      // "photo" | "video"
    var fileSize: Int64
    var contentHash: String?      // SHA-256, populated lazily

    // Temporal metadata
    var dateTaken: Date?          // EXIF DateTimeOriginal (gold standard)
    var dateCreated: Date?        // file system creation date
    var dateModified: Date?       // file system modification date

    // Camera / format metadata
    var cameraMake: String?
    var cameraModel: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var durationSeconds: Double?  // videos only

    // GPS metadata (raw, before reverse-geocoding)
    var latitude: Double?
    var longitude: Double?
    // Reverse-geocoded strings (filled asynchronously)
    var gpsCountry: String?
    var gpsState: String?
    var gpsCity: String?

    // Classification flags
    var isScreenshot: Bool
    var isDuplicate: Bool
    var duplicateGroupID: UUID?   // shared across a duplicate cluster
    var isOrganized: Bool         // true once moved/copied by apply step

    // Destination computed by the organization planner
    var plannedDestinationPath: String?

    // Archive origin — non-nil when this file was extracted from a .zip archive.
    // The value is the absolute path of the original archive file.
    var archiveSourcePath: String?

    // ── Probable duplicate detection ──────────────────────────────────────────
    // Set by ProbableDuplicateDetector after exact SHA-256 detection.
    // isProbableDuplicate == true  →  file is routed to Duplicates/Probable Duplicates/
    // probableDuplicateGroupID set on BOTH sides of a probable pair (original + duplicate).
    // Exact SHA-256 duplicates (isDuplicate) are never also marked isProbableDuplicate.
    var isProbableDuplicate: Bool       // routed to Probable Duplicates/ folder
    var probableDuplicateGroupID: UUID? // shared by both sides of the probable pair
    var probableMatchScore: Int         // confidence 0–100
    var probableMatchReasons: String?   // e.g. "Same filename · Size ±0.4% · Timestamp Δ3m"
    var probableMatchPeerFilename: String? // other file's filename for display

    @Relationship(deleteRule: .nullify)
    var session: ScanSession?

    init(filePath: String, filename: String, ext: String, kind: MediaKind, fileSize: Int64) {
        self.id = UUID()
        self.filePath = filePath
        self.filename = filename
        self.fileExtension = ext
        self.mediaKindRaw = kind.rawValue
        self.fileSize = fileSize
        self.isScreenshot = false
        self.isDuplicate = false
        self.isOrganized = false
        self.isProbableDuplicate = false
        self.probableMatchScore = 0
    }

    // MARK: Convenience

    var mediaKind: MediaKind { MediaKind(rawValue: mediaKindRaw) ?? .photo }
    var url: URL { URL(fileURLWithPath: filePath) }

    /// The authoritative capture date for organizing purposes.
    /// Photos and videos trust only EXIF/container metadata (dateTaken).
    /// Archives have no EXIF, so they fall back to file modification date —
    /// which is usually when the archive was last written, a reasonable proxy.
    /// A nil bestDate means the file goes to Unknown Date/.
    var bestDate: Date? {
        if let d = dateTaken { return d }
        if mediaKind == .archive { return dateModified }
        return nil
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var hasGPS: Bool { latitude != nil && longitude != nil }
    var hasDate: Bool { bestDate != nil }

    var yearString: String? {
        guard let d = bestDate else { return nil }
        return Calendar.current.component(.year, from: d).description
    }

    var monthFolderName: String? {
        guard let d = bestDate else { return nil }
        let cal = Calendar.current
        let year  = cal.component(.year,  from: d)
        let month = cal.component(.month, from: d)
        let name  = DateFormatter().monthSymbols[month - 1]
        return String(format: "%d-%02d %@", year, month, name)
    }

    var dayFolderName: String? {
        guard let d = bestDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: ─── MediaKind ──────────────────────────────────────────────────────────

enum MediaKind: String, Codable {
    case photo
    case video
    case archive
}

// MARK: ─── OrganizationPlan ──────────────────────────────────────────────────

/// One planned file operation (move or copy) generated before applying.
@Model
final class OrganizationPlan {
    var id: UUID
    var sessionID: UUID
    var mediaFileID: UUID
    var sourceAbsPath: String
    var destinationAbsPath: String
    var operationRaw: String     // "move" | "copy"
    var statusRaw: String        // "pending" | "done" | "skipped" | "error"
    var errorMessage: String?
    var appliedAt: Date?
    /// Non-nil when the source file was extracted from a .zip archive.
    /// On undo, archive-sourced files are deleted rather than moved back,
    /// because the original lives inside the zip which was never touched.
    var archiveSourcePath: String?

    init(sessionID: UUID, mediaFileID: UUID, source: String, destination: String, op: FileOperation) {
        self.id = UUID()
        self.sessionID = sessionID
        self.mediaFileID = mediaFileID
        self.sourceAbsPath = source
        self.destinationAbsPath = destination
        self.operationRaw = op.rawValue
        self.statusRaw = PlanStatus.pending.rawValue
    }

    var operation: FileOperation { FileOperation(rawValue: operationRaw) ?? .move }
    var status: PlanStatus {
        get { PlanStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var sourceURL: URL { URL(fileURLWithPath: sourceAbsPath) }
    var destinationURL: URL { URL(fileURLWithPath: destinationAbsPath) }
    var destinationFolder: String { destinationURL.deletingLastPathComponent().path }
}

enum FileOperation: String, Codable, CaseIterable {
    case move
    case copy
}

enum PlanStatus: String, Codable {
    case pending, done, skipped, error
}

// MARK: ─── UndoManifest & UndoEntry ──────────────────────────────────────────

/// A complete manifest for one "Apply" run. Needed to reverse every move.
@Model
final class UndoManifest {
    var id: UUID
    var sessionID: UUID
    var createdAt: Date
    var rootPath: String
    var operation: String   // "move" | "copy"
    var wasUndone: Bool

    @Relationship(deleteRule: .cascade, inverse: \UndoEntry.manifest)
    var entries: [UndoEntry]

    init(sessionID: UUID, rootPath: String, operation: FileOperation) {
        self.id = UUID()
        self.sessionID = sessionID
        self.createdAt = Date()
        self.rootPath = rootPath
        self.operation = operation.rawValue
        self.wasUndone = false
        self.entries = []
    }
}

/// One file movement record inside a UndoManifest.
@Model
final class UndoEntry {
    var id: UUID
    var originalPath: String
    var newPath: String
    var contentHash: String
    var operationRaw: String   // "move" | "copy"
    var timestamp: Date
    /// True when the file was extracted from a .zip archive.
    /// Undo for these entries deletes the organized copy instead of moving it back,
    /// because the original content is still safely inside the untouched archive.
    var isFromArchive: Bool

    @Relationship(deleteRule: .nullify)
    var manifest: UndoManifest?

    init(originalPath: String, newPath: String, hash: String, operation: FileOperation, isFromArchive: Bool = false) {
        self.id = UUID()
        self.originalPath = originalPath
        self.newPath = newPath
        self.contentHash = hash
        self.operationRaw = operation.rawValue
        self.isFromArchive = isFromArchive
        self.timestamp = Date()
    }

    var operation: FileOperation { FileOperation(rawValue: operationRaw) ?? .move }
}

// MARK: ─── OrganizationConfig ─────────────────────────────────────────────────

/// User preferences for how the organization should work.
/// Lives in AppNavigator (not persisted, reset on restart).
struct OrganizationConfig {
    var mode: OrganizationMode = .smartHybrid
    var fileOperation: FileOperation = .move
    var includeVideos: Bool = true
    var includeArchives: Bool = true
    var separateDuplicates: Bool = true
    var outputFolderName: String = "Organized Media"
    var customOutputParentPath: String?
    var useGPSLocation: Bool = true    // for SmartHybrid / ByLocation modes
}

extension OrganizationConfig {
    /// Standard output root for a selected folder.
    /// If the user already selected the organized output folder itself,
    /// reuse it directly instead of nesting another output folder inside.
    func outputRoot(forSelectedRoot rootURL: URL) -> URL {
        if let customOutputParentPath, !customOutputParentPath.isEmpty {
            return URL(fileURLWithPath: customOutputParentPath)
                .appendingPathComponent(outputFolderName)
        }
        guard rootURL.lastPathComponent != outputFolderName else { return rootURL }
        return rootURL.appendingPathComponent(outputFolderName)
    }

    var hasCustomOutputParent: Bool {
        guard let customOutputParentPath else { return false }
        return !customOutputParentPath.isEmpty
    }

    var reviewFolderName: String { "Needs Review" }
}

enum OrganizationMode: String, CaseIterable {
    case smartHybrid  = "Smart Hybrid (recommended)"
    case byYear       = "By Year"
    case byYearMonth  = "By Year & Month"
    case byExactDate  = "By Exact Date"
    case byLocation   = "By Location"

    var description: String {
        switch self {
        case .smartHybrid: return "Year → Month → Date, with location when available. Best for most libraries."
        case .byYear:      return "One folder per year. Simple and fast."
        case .byYearMonth: return "One folder per month, grouped by year."
        case .byExactDate: return "One folder per day. Most granular."
        case .byLocation:  return "Country → State → City when location is available. Files without location go to Unknown Location grouped by year."
        }
    }

    var exampleTree: String {
        switch self {
        case .smartHybrid: return "2026/\n  2026-05 May/\n    2026-05-18 Herndon VA/"
        case .byYear:      return "2026/\n2025/\n2024/"
        case .byYearMonth: return "2026/\n  2026-05 May/\n  2026-04 April/"
        case .byExactDate: return "2026/\n  2026-05 May/\n    2026-05-18/"
        case .byLocation:  return "United States/\n  Virginia/\n    Herndon/\nUnknown Location/\n  2026/"
        }
    }
}
