// FolderScanner.swift
// Recursively walks the root folder and discovers all media files.
// When a supported desktop archive is encountered it is extracted to a temporary directory
// and the media files found inside are added to the results.
// The original archive is never moved or modified.
// Reports progress via the onProgress callback for live UI updates.

import Foundation
#if os(macOS)
import Photos
#endif

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
    /// ZIP, RAR, and 7z archives are extracted transparently — their contents appear
    /// in results with `archiveSourceURL` set; the original archive is not included.
    /// If `rootURL` is itself an archive file it is extracted directly.
    /// Folders whose `lastPathComponent` appears in `excludedFolderNames` are
    /// skipped entirely — this prevents Foldiq from re-scanning its own output.
    func scan(
        rootURL: URL,
        includeVideos: Bool,
        includeArchives: Bool = true,
        excludedFolderNames: Set<String> = [],
        photosScope: PhotosLibraryScope = PhotosLibraryScope(),
        onProgress: @MainActor @escaping (ScanProgress) -> Void,
        onArchiveError: (@MainActor (URL, String) -> Void)? = nil
    ) async throws -> [DiscoveredFile] {

        guard FileManager.default.isReadableFile(atPath: rootURL.path) else {
            throw ScanError.notReadable(rootURL.path)
        }

        // ── An Apple Photos library: read only the originals inside it ──────
        if PhotosLibrarySupport.isPhotosLibrary(rootURL) {
            return try await scanPhotosLibrary(
                rootURL,
                includeVideos: includeVideos,
                scope: photosScope,
                onProgress: onProgress,
                onArchiveError: onArchiveError
            )
        }

        // ── If rootURL is an archive file, extract it directly ──────────────
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

            // ── Archive extraction ───────────────────────────────────────────
            // Extract supported media; the original archive stays untouched.
            if includeArchives && MediaTypes.archiveExtensions.contains(ext) {
                do {
                    let result = try await archiveExtractor.extract(fileURL)
                    let countBefore = results.count
                    defer {
                        // No media inside: no file points at the folder, so nothing
                        // else would ever delete it.
                        if results.count == countBefore { TempWorkspace.remove(result.tempDirectory) }
                    }
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

    // MARK: - Photos library

    /// Lists the original photos and videos stored inside a Photos library.
    /// The rest of the package (database, thumbnails, previews) is never read,
    /// and Live Photo videos are left out so a library of Live Photos doesn't
    /// turn into thousands of three-second clips.
    private func scanPhotosLibrary(
        _ libraryURL: URL,
        includeVideos: Bool,
        scope: PhotosLibraryScope,
        onProgress: @MainActor @escaping (ScanProgress) -> Void,
        onArchiveError: (@MainActor (URL, String) -> Void)?
    ) async throws -> [DiscoveredFile] {
        let libraryName = libraryURL.lastPathComponent

        #if os(macOS)
        // The Mac's main library goes through Photos, which downloads from
        // iCloud the originals that "Optimize Mac Storage" keeps off the disk.
        if PhotosLibrarySupport.isDefaultSystemLibrary(libraryURL) {
            let staged = try await SystemPhotosStager.stage(
                libraryURL: libraryURL,
                includeVideos: includeVideos,
                scope: scope,
                onProgress: onProgress
            )
            if staged.failedCount > 0, let onArchiveError {
                let noun = staged.failedCount == 1 ? "item" : "items"
                await onArchiveError(
                    libraryURL,
                    "\(staged.failedCount) \(noun) couldn't be copied from Photos, usually because the original couldn't be downloaded from iCloud. Everything else is included."
                )
            }
            return staged.files
        }
        #endif

        // Any other library (an older one, or one on an external drive) is read
        // straight from disk.
        let folders = PhotosLibrarySupport.originalsFolders(in: libraryURL)
        guard !folders.isEmpty,
              folders.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) })
        else {
            throw ScanError.photosLibraryUnreadable(libraryName)
        }

        var results: [DiscoveredFile] = []
        for folder in folders {
            results += try await scan(
                rootURL: folder,
                includeVideos: includeVideos,
                includeArchives: false,
                onProgress: onProgress
            )
        }

        let originals = Self.removingLivePhotoCompanions(results)
        guard !originals.isEmpty else {
            throw ScanError.photosLibraryEmpty(libraryName)
        }
        return originals
    }

    static func removingLivePhotoCompanions(_ files: [DiscoveredFile]) -> [DiscoveredFile] {
        var photoStemsByFolder: [String: Set<String>] = [:]
        for file in files where file.kind == .photo {
            photoStemsByFolder[file.url.deletingLastPathComponent().path, default: []]
                .insert(file.url.deletingPathExtension().lastPathComponent.lowercased())
        }
        return files.filter { file in
            guard file.kind == .video else { return true }
            let stems = photoStemsByFolder[file.url.deletingLastPathComponent().path] ?? []
            return !PhotosLibrarySupport.isLivePhotoCompanion(file.url, photoStemsInFolder: stems)
        }
    }

    // MARK: - Archive-as-root extraction

    /// Called when the user selects an archive file directly (not a folder).
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

        if files.isEmpty {
            // No media inside: no file points at the folder, so nothing else would delete it.
            TempWorkspace.remove(result.tempDirectory)
        }
        await onProgress(ScanProgress(scannedCount: 1, foundCount: files.count, currentPath: url.path))
        return files
    }
}

// MARK: ─── Mac's main Photos library ──────────────────────────────────────────

#if os(macOS)
/// Copies the originals of the Mac's main Photos library into a temporary
/// folder through Photos itself, downloading from iCloud whatever is only kept
/// there. Foldiq then organizes those copies the same way it organizes files
/// extracted from an archive: the library is never changed, the temporary
/// folder is deleted after Apply, and Undo only removes the organized copies.
enum SystemPhotosStager {
    struct Result {
        var files: [DiscoveredFile]
        var failedCount: Int
    }

    /// Foldiq stops copying when the disk gets this close to full.
    static let minimumFreeBytes: Int64 = 2_000_000_000
    private static let simultaneousDownloads = 4

    private enum ItemOutcome {
        case copied(DiscoveredFile)
        case skipped
        case failed
        case outOfSpace
    }

    static func stage(
        libraryURL: URL,
        includeVideos: Bool,
        scope: PhotosLibraryScope,
        onProgress: @MainActor @escaping (FolderScanner.ScanProgress) -> Void
    ) async throws -> Result {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ScanError.photosAccessDenied
        }

        let assets = fetchAssets(includeVideos: includeVideos, scope: scope)
        guard !assets.isEmpty else {
            if scope.kind != .everything { throw ScanError.photosSelectionEmpty }
            throw ScanError.photosLibraryEmpty(libraryURL.lastPathComponent)
        }

        let stagingRoot = try TempWorkspace.create(prefix: TempWorkspace.photosPrefix)

        var files: [DiscoveredFile] = []
        var failedCount = 0
        var ranOutOfSpace = false
        var finished = 0

        await withTaskGroup(of: ItemOutcome.self) { group in
            var nextIndex = 0
            func startNext() {
                guard nextIndex < assets.count, !ranOutOfSpace, !Task.isCancelled else { return }
                let index = nextIndex
                let asset = assets[index]
                nextIndex += 1
                group.addTask {
                    await stageOne(asset, index: index, libraryURL: libraryURL, stagingRoot: stagingRoot)
                }
            }

            for _ in 0..<simultaneousDownloads { startNext() }

            while let outcome = await group.next() {
                finished += 1
                switch outcome {
                case .copied(let file): files.append(file)
                case .skipped:          break
                case .failed:           failedCount += 1
                case .outOfSpace:       ranOutOfSpace = true
                }
                await onProgress(FolderScanner.ScanProgress(
                    scannedCount: finished,
                    foundCount: files.count,
                    currentPath: "Copying from Photos — \(finished) of \(assets.count)"
                ))
                startNext()
            }
        }

        // Cancelled (the person went back): nothing will use these copies.
        // Removed here, after the last in-flight copy has finished writing.
        if Task.isCancelled {
            TempWorkspace.remove(stagingRoot)
            throw CancellationError()
        }
        if ranOutOfSpace {
            TempWorkspace.remove(stagingRoot)
            throw ScanError.notEnoughSpaceForPhotos
        }
        if files.isEmpty {
            TempWorkspace.remove(stagingRoot)
            throw ScanError.photosLibraryEmpty(libraryURL.lastPathComponent)
        }
        return Result(files: files, failedCount: failedCount)
    }

    struct Album: Identifiable, Hashable {
        let id: String
        let title: String
        let count: Int
    }

    private static func fetchOptions(includeVideos: Bool, scope: PhotosLibraryScope) -> PHFetchOptions {
        var predicates = [
            includeVideos
                ? NSPredicate(format: "mediaType == %d || mediaType == %d",
                              PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
                : NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        ]
        if scope.kind == .dateRange {
            predicates.append(NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                scope.rangeStart as NSDate,
                scope.rangeEnd as NSDate
            ))
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return options
    }

    /// The assets the scope selects, oldest first. A photo that sits in two of
    /// the chosen albums is counted once.
    static func fetchAssets(includeVideos: Bool, scope: PhotosLibraryScope) -> [PHAsset] {
        let options = fetchOptions(includeVideos: includeVideos, scope: scope)
        var assets: [PHAsset] = []

        if scope.kind == .albums {
            var seen = Set<String>()
            let albums = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: Array(scope.albumIdentifiers),
                options: nil
            )
            albums.enumerateObjects { album, _, _ in
                PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
                    if seen.insert(asset.localIdentifier).inserted { assets.append(asset) }
                }
            }
            return assets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        }

        let fetched = PHAsset.fetchAssets(with: options)
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    static func count(includeVideos: Bool, scope: PhotosLibraryScope) -> Int {
        if scope.kind == .albums {
            return fetchAssets(includeVideos: includeVideos, scope: scope).count
        }
        return PHAsset.fetchAssets(with: fetchOptions(includeVideos: includeVideos, scope: scope)).count
    }

    /// Favorites plus the person's own albums, skipping empty ones.
    static func albums(includeVideos: Bool) -> [Album] {
        let options = fetchOptions(includeVideos: includeVideos, scope: PhotosLibraryScope())
        func makeAlbum(from collection: PHAssetCollection) -> Album? {
            let count = PHAsset.fetchAssets(in: collection, options: options).count
            guard count > 0 else { return nil }
            return Album(id: collection.localIdentifier,
                         title: collection.localizedTitle ?? "Untitled Album",
                         count: count)
        }

        var favorites: [Album] = []
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
            .enumerateObjects { collection, _, _ in
                if let album = makeAlbum(from: collection) { favorites.append(album) }
            }

        var own: [Album] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in
                if let album = makeAlbum(from: collection) { own.append(album) }
            }
        own.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return favorites + own
    }

    /// Copies one original into its own folder, so two photos that share a
    /// name (IMG_0001.JPG from different years) never collide while staged.
    private static func stageOne(
        _ asset: PHAsset,
        index: Int,
        libraryURL: URL,
        stagingRoot: URL
    ) async -> ItemOutcome {
        guard let resource = preferredResource(for: asset) else { return .skipped }
        if let free = availableCapacity(at: stagingRoot), free < minimumFreeBytes { return .outOfSpace }

        let filename = safeFilename(resource.originalFilename, asset: asset)
        let folder = stagingRoot.appendingPathComponent(String(index), isDirectory: true)
        let destination = folder.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await writeOriginal(of: asset, resource: resource, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return isOutOfSpace(error) ? .outOfSpace : .failed
        }

        if let date = asset.creationDate {
            try? FileManager.default.setAttributes(
                [.creationDate: date, .modificationDate: date],
                ofItemAtPath: destination.path
            )
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? Int64) ?? 0

        var file = DiscoveredFile(
            url: destination,
            kind: asset.mediaType == .video ? .video : .photo,
            fileSize: size,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
                || MediaTypes.isScreenshot(filename: filename),
            archiveSourceURL: libraryURL,
            tempDirectoryURL: stagingRoot
        )
        file.photosCaptureDate = asset.creationDate
        if let coordinate = asset.location?.coordinate,
           coordinate.latitude != 0 || coordinate.longitude != 0 {
            file.photosLatitude = coordinate.latitude
            file.photosLongitude = coordinate.longitude
        }
        return .copied(file)
    }

    /// Photos use PHImageManager, which reliably downloads originals from
    /// iCloud; videos use PHAssetResourceManager. Edits made in Photos are
    /// left out: Foldiq organizes the originals.
    private static func writeOriginal(of asset: PHAsset, resource: PHAssetResource, to destination: URL) async throws {
        if asset.mediaType == .image {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .unadjusted
            options.isSynchronous = false

            let data: Data = try await withCheckedThrowingContinuation { continuation in
                var didResume = false
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                    guard !didResume else { return }
                    didResume = true
                    if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? CocoaError(.fileReadUnknown))
                    }
                }
            }
            try data.write(to: destination)
        } else {
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private static func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            return resources.first { $0.type == .fullSizeVideo }
                ?? resources.first { $0.type == .video }
                ?? resources.first
        }
        return resources.first { $0.type == .fullSizePhoto }
            ?? resources.first { $0.type == .photo }
            ?? resources.first
    }

    private static func safeFilename(_ original: String, asset: PHAsset) -> String {
        let cleaned = original
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty, cleaned != ".", cleaned != ".." { return cleaned }
        return asset.mediaType == .video ? "Video.mov" : "Photo.heic"
    }

    private static func availableCapacity(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
            || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
    }
}
#endif

// MARK: ─── DiscoveredFile ─────────────────────────────────────────────────────

/// Lightweight struct produced during scanning, before metadata extraction.
struct DiscoveredFile {
    let url: URL
    let kind: MediaKind
    let fileSize: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let isScreenshot: Bool
    /// Non-nil when this file was extracted from a supported archive.
    /// The value is the URL of the original archive on disk.
    let archiveSourceURL: URL?
    /// The temporary directory the archive was extracted into.
    /// Must be deleted after the organized files have been moved to their destinations.
    let tempDirectoryURL: URL?
    /// What Photos knows about an item copied out of the Mac's Photos library.
    /// Used only when the file itself has no capture date or location —
    /// images saved from apps or the web often carry neither.
    var photosCaptureDate: Date? = nil
    var photosLatitude: Double? = nil
    var photosLongitude: Double? = nil

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
    case photosLibraryUnreadable(String)
    case photosLibraryEmpty(String)
    case photosAccessDenied
    case notEnoughSpaceForPhotos
    case photosSelectionEmpty

    var errorDescription: String? {
        switch self {
        case .notReadable(let p): return "Cannot read folder: \(p)"
        case .cancelled:          return "Scan was cancelled."
        case .photosLibraryUnreadable(let name):
            return "Foldiq couldn't read the original files inside \"\(name)\". Remove it and choose it again with \"Export from Photos\" so macOS grants access."
        case .photosLibraryEmpty(let name):
            return "No original photos or videos were found inside \"\(name)\". If iCloud Photos is set to Optimize Mac Storage, the originals are kept in iCloud: in Photos, open Settings → iCloud, choose \"Download Originals to this Mac\", wait for the download to finish, then scan again."
        case .photosSelectionEmpty:
            return "Nothing in your Photos library matches the dates or albums you chose. Remove the library from the list, choose \"Export from Photos\" again and pick a different selection."
        case .photosAccessDenied:
            return "Foldiq doesn't have access to your Photos library. Open System Settings → Privacy & Security → Photos, turn on Foldiq, then scan again."
        case .notEnoughSpaceForPhotos:
            return "Your Mac is almost out of space. Foldiq copies each original out of Photos (downloading it from iCloud if needed) before organizing it, and stopped so at least 2 GB stay free. Free up some space, then scan again."
        }
    }
}
