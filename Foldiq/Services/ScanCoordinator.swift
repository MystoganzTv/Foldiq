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

        // Several files are read at once: on 100,000 photos, reading them one
        // after another left the disk idle most of the time. Results are
        // recorded strictly in discovery order, so the outcome is identical.
        let workers = Self.inspectionWorkerCount
        // Finished results waiting for a slower file ahead of them. The window
        // keeps that buffer small even when one file takes long (a huge video).
        let window = workers * 16
        var stopped = false

        await withTaskGroup(of: (Int, InspectedFile).self) { group in
            var nextToStart = 0
            var nextToRecord = 0
            var finished: [Int: InspectedFile] = [:]

            func startMore() {
                while nextToStart < discovered.count,
                      nextToStart - nextToRecord < window,
                      nextToStart - nextToRecord - finished.count < workers {
                    let index = nextToStart
                    let disc = discovered[index]
                    nextToStart += 1
                    group.addTask { (index, await Self.inspect(disc)) }
                }
            }

            startMore()
            while let (index, result) = await group.next() {
                // Honour cancellation on every file. Cancelling (or leaving the
                // scan screen) sends the user back to Welcome, which purges scan
                // data; a late write to that deleted session traps inside SwiftData.
                if Task.isCancelled || !session.isUsable {
                    stopped = true
                    group.cancelAll()
                    break
                }
                finished[index] = result
                while let ready = finished.removeValue(forKey: nextToRecord) {
                    let disc = discovered[nextToRecord]
                    nextToRecord += 1
                    processedCount = nextToRecord
                    currentFile    = disc.filename
                    record(disc, ready, session: session, sidecars: takeoutSidecars, context: context)
                    if nextToRecord % 200 == 0 { try? context.save() }
                }
                startMore()
            }
        }
        if stopped || Task.isCancelled || !session.isUsable {
            return abandon(session, in: context)
        }
        try? context.save()

        // Cancelled during metadata extraction?
        guard !Task.isCancelled, session.isUsable else {
            return abandon(session, in: context)
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

        guard !Task.isCancelled, session.isUsable else {
            return abandon(session, in: context)
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

        guard !Task.isCancelled, session.isUsable else {
            return abandon(session, in: context)
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

    // MARK: - Reading each file

    /// What reading one file produced. Plain values, so it can be made off the
    /// main actor and handed back.
    struct InspectedFile {
        let meta: ExtractedMetadata
        let problem: String?
    }

    /// Files read at the same time. Reading is mostly waiting for the disk (or
    /// a NAS), so a few readers keep it busy without crowding the machine.
    nonisolated static var inspectionWorkerCount: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 6)
    }

    /// Reads metadata and checks that the file opens. Runs off the main actor.
    nonisolated private static func inspect(_ disc: DiscoveredFile) async -> InspectedFile {
        let meta = await MetadataExtractor().extract(from: disc.url, kind: disc.kind)
        let problem = await MediaValidator.problem(at: disc.url, kind: disc.kind, fileSize: disc.fileSize)
        return InspectedFile(meta: meta, problem: problem)
    }

    /// Turns one read file into a MediaFile of the session (main actor only).
    private func record(
        _ disc: DiscoveredFile,
        _ inspected: InspectedFile,
        session: ScanSession,
        sidecars takeoutSidecars: TakeoutSidecarIndex,
        context: ModelContext
    ) {
        var meta = inspected.meta

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
        file.archiveSourcePath = disc.archiveSourceURL?.path
        file.damageReason     = inspected.problem
        file.session          = session

        context.insert(file)
    }

    /// Stops a cancelled scan: removes its partial session unless the Welcome
    /// screen already purged it (deleting it twice would trap as well).
    private func abandon(_ session: ScanSession, in context: ModelContext) -> ScanSession? {
        if session.isUsable {
            context.delete(session)
            try? context.save()
        }
        phase = .failed
        return nil
    }
}
