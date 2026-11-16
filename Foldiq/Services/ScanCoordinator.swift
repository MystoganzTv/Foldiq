// ScanCoordinator.swift
// High-level coordinator that ties together FolderScanner, MetadataExtractor,
// and DuplicateDetector to produce a complete ScanSession.
// Supports scanning multiple source folders in a single session.

import SwiftUI
import SwiftData

@MainActor
final class ScanCoordinator: ObservableObject {

    // MARK: - Published progress state
    @Published var phase: Phase = .idle
    @Published var scannedCount   = 0
    @Published var foundCount     = 0
    @Published var processedCount = 0
    @Published var phaseItemCount = 0
    @Published var currentFile    = ""
    @Published var errorMessage: String?
    /// Capture dates recovered from Google Takeout .json files in the last scan.
    @Published var takeoutDatesRecovered = 0

    enum Phase: String {
        case idle        = "Ready"
        case scanning    = "Scanning…"
        case extracting  = "Reading metadata…"
        case hashing     = "Detecting duplicates…"
        case matching    = "Finding Smart Matches…"
        case done        = "Scan complete"
        case failed      = "Scan failed"
    }

    // MARK: - Services
    private let scanner          = FolderScanner()
    private let detector         = DuplicateDetector()
    private let probableDetector = ProbableDuplicateDetector()

    /// Temporary directories created when extracting archives during scan.
    /// Must be cleaned up after FileMover.apply() completes (or on restart).
    private(set) var archiveTempDirs: [URL] = []

    // MARK: - Run

    /// Full pipeline across one or more source folders.
    /// Returns the completed ScanSession, or nil on error.
    func run(rootURLs: [URL], config: OrganizationConfig, context: ModelContext) async -> ScanSession? {
        guard !rootURLs.isEmpty else { return nil }

        phase = .scanning
        errorMessage = nil
        archiveTempDirs = []
        phaseItemCount = 0

        // 1. Discover files across all selected folders
        var discovered: [DiscoveredFile] = []
        // Track seen paths so overlapping folder selections don't double-count files.
        var seenPaths = Set<String>()

        for rootURL in rootURLs {
            do {
                let partial = try await scanner.scan(
                    rootURL: rootURL,
                    includeVideos: config.includeVideos,
                    includeArchives: config.includeArchives,
                    excludedFolderNames: [config.outputFolderName],
                    photosScope: config.photosScope,
                    onProgress: { [weak self] p in
                        self?.currentFile = p.currentPath
                    },
                    onArchiveError: { [weak self] archiveURL, message in
                        // Surface the first archive error; more errors are noted in the app log.
                        self?.errorMessage = "⚠️ \"\(archiveURL.lastPathComponent)\": \(message)"
                    }
                )
                // Deduplicate by absolute path across all roots
                for file in partial {
                    if seenPaths.insert(file.filePath).inserted {
                        discovered.append(file)
                    }
                }
                foundCount = discovered.count
            } catch {
                // Non-fatal: skip unreadable folders, continue with others
                let folderName = rootURL.lastPathComponent
                errorMessage = "Could not scan \"\(folderName)\": \(error.localizedDescription)"
            }
        }

        // Collect unique temp dirs from archive extraction
        archiveTempDirs = Array(Set(discovered.compactMap { $0.tempDirectoryURL }))

        guard !discovered.isEmpty else {
            phase = .failed

            // Give a clearer message when the output folder exists — the user likely
            // already ran Foldiq with "Move" and all files ended up in Organized Media.
            let outputExists = rootURLs.contains { rootURL in
                FileManager.default.fileExists(
                    atPath: rootURL.appendingPathComponent(config.outputFolderName).path
                )
            }
            if outputExists {
                errorMessage = "No unorganized media files found. It looks like your photos were already moved into \"\(config.outputFolderName)\". To re-organize them, select that subfolder directly. If you still have the original organization session open, you may also be able to use Undo from the Report screen."
            } else {
                errorMessage = errorMessage ?? "No supported media files were found in the selected folders."
            }
            return nil
        }

        // Cancelled during discovery?
        guard !Task.isCancelled else { phase = .failed; return nil }

        // 2. Create session — rootPath is the primary (first) folder
        let primaryPath = rootURLs[0].path
        let session = ScanSession(rootPath: primaryPath)
        session.totalFiles = discovered.count
        context.insert(session)

        // 3. Extract metadata for each file
        phase = .extracting
        processedCount = 0
        phaseItemCount = discovered.count
        takeoutDatesRecovered = 0
        let takeoutSidecars = TakeoutSidecarIndex.build(for: discovered)

        for (idx, disc) in discovered.enumerated() {
            // Honour cancellation every 25 files
            if idx % 25 == 0, Task.isCancelled {
                // Clean up the partial session from SwiftData before bailing
                context.delete(session)
                try? context.save()
                phase = .failed
                return nil
            }

            processedCount = idx + 1
            currentFile    = disc.filename

            let checked = await Task.detached(priority: .utility) {
                let meta = await MetadataExtractor().extract(from: disc.url, kind: disc.kind)
                let problem = await MediaValidator.problem(at: disc.url, kind: disc.kind, fileSize: disc.fileSize)
                return (meta: meta, problem: problem)
            }.value
            var meta = checked.meta

            // Google Photos exports keep the real capture time in a .json file
            // next to the photo. Use it when the file itself has no embedded date.
            if disc.kind != .archive, !takeoutSidecars.isEmpty,
               !meta.hasEmbeddedDate || meta.latitude == nil,
               let sidecar = takeoutSidecars.lookup(mediaURL: disc.url, tempDirectory: disc.tempDirectoryURL),
               meta.apply(sidecar) {
                takeoutDatesRecovered += 1
            }

            // Photos knows when and where every item was taken, even when the
            // file carries no date of its own. Embedded camera dates still win.
            if disc.photosCaptureDate != nil || disc.photosLatitude != nil {
                meta.apply(TakeoutSidecar(
                    date: disc.photosCaptureDate,
                    latitude: disc.photosLatitude,
                    longitude: disc.photosLongitude
                ))
            }

            let file = MediaFile(
                filePath:  disc.filePath,
                filename:  disc.filename,
                ext:       disc.fileExtension,
                kind:      disc.kind,
                fileSize:  disc.fileSize
            )

            file.dateTaken        = meta.dateTaken
            file.dateCreated      = disc.creationDate
            file.dateModified     = disc.modificationDate
            file.cameraMake       = meta.cameraMake
            file.cameraModel      = meta.cameraModel
            file.pixelWidth       = meta.pixelWidth
            file.pixelHeight      = meta.pixelHeight
            file.durationSeconds  = meta.durationSeconds
            file.latitude         = meta.latitude
            file.longitude        = meta.longitude
            file.isScreenshot     = disc.isScreenshot
            file.archiveSourcePath = disc.archiveSourceURL?.path   // NEW
            file.damageReason     = checked.problem
            file.session          = session

            context.insert(file)

            if (idx + 1) % 200 == 0 { try? context.save() }
        }
        try? context.save()

        // Cancelled during metadata extraction?
        guard !Task.isCancelled else {
            context.delete(session)
            try? context.save()
            phase = .failed
            return nil
        }

        // 4. Duplicate detection
        phase = .hashing
        processedCount = 0
        let allFiles = session.files
        phaseItemCount = allFiles.count

        let groupCount = await detector.detect(files: allFiles) { [weak self] p in
            self?.processedCount = p.processed
            self?.phaseItemCount = p.total
            self?.currentFile    = p.currentFile
        }

        // 5. Probable duplicate detection (second pass, non-exact matches)
        phase = .matching
        processedCount = 0
        phaseItemCount = 0
        await probableDetector.detect(files: allFiles) { [weak self] p in
            self?.processedCount = p.processed
            self?.phaseItemCount = p.total
            self?.currentFile    = p.currentFile
        }

        // 6. Update session stats
        let archiveSourcePaths = Set(discovered.compactMap { $0.archiveSourceURL }
            .filter { !PhotosLibrarySupport.isPhotosLibrary($0) }
            .map(\.path))
        session.photoCount             = allFiles.filter { $0.mediaKind == .photo }.count
        session.videoCount             = allFiles.filter { $0.mediaKind == .video }.count
        session.duplicateCount         = allFiles.filter { $0.isDuplicate }.count
        session.probableDuplicateCount = allFiles.filter { $0.probableMatchKindRaw == "same" }.count
        session.missingDateCount       = allFiles.filter { !$0.hasDate }.count
        session.missingMetaCount       = allFiles.filter {
            $0.cameraMake == nil && $0.cameraModel == nil && !$0.hasGPS
        }.count
        session.archivesExtractedCount = archiveSourcePaths.count
        session.finishedAt             = Date()

        try? context.save()

        _ = groupCount
        phase = .done
        return session
    }
}
