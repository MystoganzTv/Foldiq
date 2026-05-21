// FolderScanner.swift
// Recursively walks the root folder and discovers all media files.
// When a .zip archive is encountered it is extracted to a temporary directory
// and the media files found inside are added to the results.
// The original .zip is never moved or modified.
// Reports progress via the onProgress callback for live UI updates.

import Foundation

// MARK: ─── Scanner ────────────────────────────────────────────────────────────

actor FolderScanner {

    // MARK: - Public API

    struct ScanProgress {
        var scannedCount: Int
        var foundCount: Int
        var currentPath: String
    }

    private let archiveExtractor = ArchiveExtractor()

    /// Scan `rootURL` and return all discovered media files.
    /// ZIP archives are extracted transparently — their contents appear in results
    /// with `archiveSourceURL` set; the original .zip file is not included.
    /// If `rootURL` is itself a .zip file it is extracted directly.
    /// Folders whose `lastPathComponent` appears in `excludedFolderNames` are
    /// skipped entirely — this prevents Foldiq from re-scanning its own output.
    func scan(
        rootURL: URL,
        includeVideos: Bool,
        includeArchives: Bool = true,
        excludedFolderNames: Set<String> = [],
        onProgress: @MainActor @escaping (ScanProgress) -> Void,
        onArchiveError: (@MainActor (URL, String) -> Void)? = nil
    ) async throws -> [DiscoveredFile] {

        guard FileManager.default.isReadableFile(atPath: rootURL.path) else {
            throw ScanError.notReadable(rootURL.path)
        }

        // ── If rootURL is a .zip file, extract it directly ───────────────────
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
        if !isDirectory.boolValue {
            let ext = rootURL.pathExtension.lowercased()
            guard MediaTypes.archiveExtensions.contains(ext) else {
                return []   // single non-archive file selected — nothing to scan
            }
            return await extractSingleArchive(rootURL, onProgress: onProgress, onArchiveError: onArchiveError)
        }

        var mediaExtensions = MediaTypes.photoExtensions
        if includeVideos { mediaExtensions.formUnion(MediaTypes.videoExtensions) }

        var results: [DiscoveredFile] = []
        var scanned = 0

        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .isDirectoryKey,
                .isHiddenKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            // Check for cancellation every 50 items so the UI stays responsive.
            if scanned % 50 == 0, Task.isCancelled { return results }

            let vals = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

            // If this is a directory with an excluded name, skip it and all contents.
            if vals?.isDirectory == true {
                if excludedFolderNames.contains(fileURL.lastPathComponent) {
                    enumerator?.skipDescendants()
                }
                continue
            }

            guard vals?.isRegularFile == true else { continue }

            scanned += 1

            let ext = fileURL.pathExtension.lowercased()

            // ── ZIP extraction ────────────────────────────────────────────────
            // When a .zip is found, extract it and add the media inside.
            // The .zip itself is NOT added to results — it stays untouched on disk.
            if includeArchives && MediaTypes.archiveExtensions.contains(ext) {
                do {
                    let result = try await archiveExtractor.extract(fileURL)
                    for mediaURL in result.mediaURLs {
                        let mediaExt = mediaURL.pathExtension.lowercased()
                        guard let mediaKind = MediaTypes.kind(for: mediaExt) else { continue }

                        var extractedSize: Int64 = 0
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: mediaURL.path) {
                            extractedSize = (attrs[.size] as? Int64) ?? 0
                        }

                        results.append(DiscoveredFile(
                            url: mediaURL,
                            kind: mediaKind,
                            fileSize: extractedSize,
                            creationDate: nil,
                            modificationDate: nil,
                            isScreenshot: MediaTypes.isScreenshot(filename: mediaURL.lastPathComponent),
                            archiveSourceURL: fileURL,
                            tempDirectoryURL: result.tempDirectory
                        ))
                    }
                } catch {
                    // Surface the error to the UI (corrupt, encrypted, unsupported format, etc.)
                    if let onArchiveError {
                        await onArchiveError(fileURL, error.localizedDescription)
                    }
                }
                if results.count % 25 == 0 {
                    let p = ScanProgress(scannedCount: scanned, foundCount: results.count, currentPath: fileURL.path)
                    await onProgress(p)
                }
                continue   // don't fall through to normal media handling
            }

            // ── Regular photo / video ─────────────────────────────────────────
            guard mediaExtensions.contains(ext),
                  let kind = MediaTypes.kind(for: ext) else { continue }

            var fileSize: Int64 = 0
            var creationDate: Date?
            var modDate: Date?
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
                fileSize     = (attrs[.size] as? Int64) ?? 0
                creationDate = attrs[.creationDate] as? Date
                modDate      = attrs[.modificationDate] as? Date
            }

            results.append(DiscoveredFile(
                url: fileURL,
                kind: kind,
                fileSize: fileSize,
                creationDate: creationDate,
                modificationDate: modDate,
                isScreenshot: MediaTypes.isScreenshot(filename: fileURL.lastPathComponent)
            ))

            // Throttled progress reports (every 25 files)
            if results.count % 25 == 0 {
                let p = ScanProgress(
                    scannedCount: scanned,
                    foundCount: results.count,
                    currentPath: fileURL.path
                )
                await onProgress(p)
            }
        }

        return results
    }

    // MARK: - Archive-as-root extraction

    /// Called when the user selects a .zip file directly (not a folder).
    /// Extracts it and returns the contained media files.
    private func extractSingleArchive(
        _ url: URL,
        onProgress: @MainActor @escaping (ScanProgress) -> Void,
        onArchiveError: (@MainActor (URL, String) -> Void)? = nil
    ) async -> [DiscoveredFile] {
        await onProgress(ScanProgress(scannedCount: 0, foundCount: 0, currentPath: url.path))

        let result: ArchiveExtractor.ExtractionResult
        do {
            result = try await archiveExtractor.extract(url)
        } catch {
            if let onArchiveError {
                await onArchiveError(url, error.localizedDescription)
            }
            return []
        }

        var files: [DiscoveredFile] = []
        for mediaURL in result.mediaURLs {
            let ext = mediaURL.pathExtension.lowercased()
            guard let kind = MediaTypes.kind(for: ext) else { continue }
            var size: Int64 = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: mediaURL.path) {
                size = (attrs[.size] as? Int64) ?? 0
            }
            files.append(DiscoveredFile(
                url: mediaURL,
                kind: kind,
                fileSize: size,
                creationDate: nil,
                modificationDate: nil,
                isScreenshot: MediaTypes.isScreenshot(filename: mediaURL.lastPathComponent),
                archiveSourceURL: url,
                tempDirectoryURL: result.tempDirectory
            ))
        }

        await onProgress(ScanProgress(scannedCount: 1, foundCount: files.count, currentPath: url.path))
        return files
    }
}

// MARK: ─── DiscoveredFile ─────────────────────────────────────────────────────

/// Lightweight struct produced during scanning, before metadata extraction.
struct DiscoveredFile {
    let url: URL
    let kind: MediaKind
    let fileSize: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let isScreenshot: Bool
    /// Non-nil when this file was extracted from a .zip archive.
    /// The value is the URL of the original archive on disk.
    let archiveSourceURL: URL?
    /// The temporary directory the archive was extracted into.
    /// Must be deleted after the organized files have been moved to their destinations.
    let tempDirectoryURL: URL?

    // Convenience init — existing call-sites can omit the new archive parameters.
    init(
        url: URL,
        kind: MediaKind,
        fileSize: Int64,
        creationDate: Date?,
        modificationDate: Date?,
        isScreenshot: Bool,
        archiveSourceURL: URL? = nil,
        tempDirectoryURL: URL? = nil
    ) {
        self.url = url
        self.kind = kind
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.isScreenshot = isScreenshot
        self.archiveSourceURL = archiveSourceURL
        self.tempDirectoryURL = tempDirectoryURL
    }

    var filename: String      { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }
    var filePath: String      { url.path }
}

// MARK: ─── Errors ─────────────────────────────────────────────────────────────

enum ScanError: LocalizedError {
    case notReadable(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notReadable(let p): return "Cannot read folder: \(p)"
        case .cancelled:          return "Scan was cancelled."
        }
    }
}
