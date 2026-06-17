// PhotoLibraryExporter.swift
// iOS/iPadOS-only pipeline: read Photos Library assets and export organized copies.

import Foundation

#if !os(macOS)
import Photos
import CoreLocation
import UniformTypeIdentifiers

struct PhotoLibraryItem: Identifiable, Hashable {
    enum Kind: String {
        case photo
        case video
    }

    let id: String
    let asset: PHAsset
    let filename: String
    let kind: Kind
    let date: Date?
    let location: CLLocation?

    var dateOrFallback: Date {
        date ?? Date.distantPast
    }
}

@MainActor
final class PhotoLibraryExporter: ObservableObject {
    struct FailedExport: Equatable, Identifiable {
        let id: String
        let filename: String
        let reason: String
    }

    enum Phase: Equatable {
        case idle
        case requestingAccess
        case scanning
        case ready
        case exporting
        case completed(URL, Int, Int, [FailedExport])
        case failed(String)
    }

    struct ExportProgress: Equatable {
        var done: Int = 0
        var total: Int = 0
        var currentFile: String = ""
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [PhotoLibraryItem] = []
    @Published private(set) var progress = ExportProgress()
    @Published var selectedItemIDs = Set<String>()

    private let geocoder = ReverseGeocoder()

    var photoCount: Int { items.filter { $0.kind == .photo }.count }
    var videoCount: Int { items.filter { $0.kind == .video }.count }
    var missingDateCount: Int { items.filter { $0.date == nil }.count }

    /// Year span of the loaded items, e.g. "2019–2025" (or a single year, or "—" if unknown).
    var dateRangeText: String {
        let years = items.compactMap { $0.date }.map { Calendar.current.component(.year, from: $0) }
        guard let minYear = years.min(), let maxYear = years.max() else { return "—" }
        return minYear == maxYear ? "\(minYear)" : "\(minYear)–\(maxYear)"
    }
    var selectedItems: [PhotoLibraryItem] { items.filter { selectedItemIDs.contains($0.id) } }
    var selectedCount: Int { selectedItemIDs.count }

    var hasLoadedItems: Bool { !items.isEmpty }

    func loadSelectedItems(localIdentifiers: [String]) async {
        let identifiers = Array(Set(localIdentifiers))
        guard !identifiers.isEmpty else {
            resetToStart()
            return
        }

        phase = .scanning
        items = await Task.detached(priority: .userInitiated) {
            Self.fetchSelectedItems(localIdentifiers: identifiers)
        }.value

        if Task.isCancelled {
            phase = .idle
            return
        }

        if items.isEmpty {
            phase = .failed("No photos or videos were loaded from the selection.")
        } else {
            selectedItemIDs = Set(items.map(\.id))
            progress = ExportProgress(done: 0, total: items.count, currentFile: "")
            phase = .ready
        }
    }

    func requestAccessAndScan() async {
        phase = .requestingAccess

        // Foldiq only reads originals and writes copies to Files — it never modifies
        // the Photos Library — so it requests read-only access (a less invasive prompt).
        let status = PHPhotoLibrary.authorizationStatus(for: .read)
        let finalStatus: PHAuthorizationStatus
        if status == .notDetermined {
            finalStatus = await PHPhotoLibrary.requestAuthorization(for: .read)
        } else {
            finalStatus = status
        }

        guard finalStatus == .authorized || finalStatus == .limited else {
            phase = .failed("Photos access was not granted. Enable Photos access in Settings to export your library.")
            return
        }

        phase = .scanning
        items = await Task.detached(priority: .userInitiated) {
            Self.fetchLibraryItems()
        }.value

        if Task.isCancelled {
            phase = .idle
            return
        }

        if items.isEmpty {
            phase = .failed("No photos or videos were found in the Photos Library selection.")
        } else {
            selectedItemIDs = Set(items.map(\.id))
            progress = ExportProgress(done: 0, total: items.count, currentFile: "")
            phase = .ready
        }
    }

    func selectAll() {
        selectedItemIDs = Set(items.map(\.id))
    }

    func selectPhotosOnly() {
        selectedItemIDs = Set(items.filter { $0.kind == .photo }.map(\.id))
    }

    func selectVideosOnly() {
        selectedItemIDs = Set(items.filter { $0.kind == .video }.map(\.id))
    }

    func clearSelection() {
        selectedItemIDs.removeAll()
    }

    func toggleSelection(for item: PhotoLibraryItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func export(
        to destinationFolder: URL,
        mode: OrganizationMode,
        includeLocation: Bool,
        outputFolderName: String = "Foldiq Export"
    ) async {
        let exportItems = selectedItems
        guard !exportItems.isEmpty else {
            phase = .failed("Choose at least one photo or video to export.")
            return
        }

        let didAccess = destinationFolder.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                destinationFolder.stopAccessingSecurityScopedResource()
            }
        }

        let outputRoot = destinationFolder.appendingPathComponent(outputFolderName, isDirectory: true)
        phase = .exporting
        progress = ExportProgress(done: 0, total: exportItems.count, currentFile: "")

        // Pre-flight: if we can read the destination's free space and it's critically
        // low, stop before downloading anything instead of failing item by item.
        if let free = Self.availableCapacity(at: destinationFolder), free < Self.minimumFreeSpace {
            phase = .failed("The destination is out of free space. Free up some space and try again.")
            return
        }

        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Could not create the export folder. \(Self.humanize(error))")
            return
        }

        var exported = 0
        var skipped = 0
        var failures: [FailedExport] = []
        var reservedPaths = Set<String>()

        // Incremental re-export: a manifest mapping each exported asset ID to its file
        // path lets repeat runs skip what's done — without re-downloading from iCloud.
        // Storing the path (not just the ID) means a file the user deleted from the
        // destination is detected as missing and re-exported, instead of being skipped.
        var manifest = Self.loadManifest(at: outputRoot)

        for (index, item) in exportItems.enumerated() {
            if Task.isCancelled {
                phase = .failed("Export cancelled.")
                return
            }

            // `done` reflects items already finished; the current item is shown by
            // name but not counted until it actually completes (iCloud downloads can
            // take a while, so we don't want the bar to jump ahead of real progress).
            progress = ExportProgress(done: index, total: exportItems.count, currentFile: item.filename)

            // Already exported here in a previous run AND the file is still on disk →
            // skip, no download. If the recorded file was deleted (or the legacy
            // manifest stored no path), fall through and re-verify/re-export below.
            if let recordedPath = manifest[item.id], !recordedPath.isEmpty,
               FileManager.default.fileExists(atPath: outputRoot.appendingPathComponent(recordedPath).path) {
                skipped += 1
                continue
            }

            do {
                let folder = await organizedDestinationFolder(
                    for: item,
                    outputRoot: outputRoot,
                    mode: mode,
                    includeLocation: includeLocation
                )
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

                let intended = folder.appendingPathComponent(item.filename)

                // A matching file is already on disk from an earlier export (manifest
                // missing/legacy). Record its path and treat it as done — no re-download.
                if !reservedPaths.contains(intended.path),
                   FileManager.default.fileExists(atPath: intended.path) {
                    manifest[item.id] = Self.relativePath(of: intended, from: outputRoot)
                    skipped += 1
                    continue
                }

                let destination = Self.resolveCollision(intended, reserved: &reservedPaths)
                reservedPaths.insert(destination.path)

                try await Self.writeOriginalResource(for: item.asset, to: destination)
                try preserveCreationDate(item.date, at: destination)
                manifest[item.id] = Self.relativePath(of: destination, from: outputRoot)
                exported += 1
            } catch {
                // Out of space: stop the whole export rather than failing every
                // remaining item. The manifest is saved so a later run resumes.
                if Self.isOutOfSpace(error) {
                    progress = ExportProgress(done: index, total: exportItems.count, currentFile: "")
                    Self.saveManifest(manifest, at: outputRoot)
                    phase = .failed("Ran out of space at the destination after exporting \(exported). Free up space and run the export again — Foldiq picks up where it left off.")
                    return
                }

                failures.append(FailedExport(
                    id: item.id,
                    filename: item.filename,
                    reason: Self.humanize(error)
                ))
            }
        }

        progress = ExportProgress(done: exportItems.count, total: exportItems.count, currentFile: "")
        Self.saveManifest(manifest, at: outputRoot)
        phase = .completed(outputRoot, exported, skipped, failures)
    }

    func fail(_ message: String) {
        phase = .failed(message)
    }

    func returnToReview() {
        guard hasLoadedItems else {
            phase = .idle
            return
        }

        progress = ExportProgress(done: 0, total: items.count, currentFile: "")
        phase = .ready
    }

    func resetToStart() {
        progress = ExportProgress()
        items = []
        selectedItemIDs.removeAll()
        phase = .idle
    }

    private func organizedDestinationFolder(
        for item: PhotoLibraryItem,
        outputRoot: URL,
        mode: OrganizationMode,
        includeLocation: Bool
    ) async -> URL {
        guard let date = item.date else {
            return outputRoot.appendingPathComponent("Unknown Date", isDirectory: true)
        }

        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        // Use fixed English month names and a manual day string so folder names are
        // stable regardless of the device's language/region.
        let monthName = Self.englishMonthSymbols[month - 1]
        let dayString = String(format: "%04d-%02d-%02d", year, month, day)

        switch mode {
        case .byYear:
            return outputRoot.appendingPathComponent(String(year), isDirectory: true)
        case .byYearMonth:
            return outputRoot
                .appendingPathComponent(String(year), isDirectory: true)
                .appendingPathComponent(String(format: "%04d-%02d %@", year, month, monthName), isDirectory: true)
        case .byExactDate:
            return outputRoot
                .appendingPathComponent(String(year), isDirectory: true)
                .appendingPathComponent(String(format: "%04d-%02d %@", year, month, monthName), isDirectory: true)
                .appendingPathComponent(dayString, isDirectory: true)
        case .byLocation:
            return await locationFolder(for: item, outputRoot: outputRoot, fallbackYear: year)
        case .smartHybrid:
            var dayName = dayString
            if includeLocation, let location = item.location {
                let geo = await geocoder.geocode(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
                let parts = [geo.city, geo.state].compactMap { $0?.folderSafe }.prefix(2)
                if !parts.isEmpty {
                    dayName += " " + parts.joined(separator: " ")
                }
            }

            return outputRoot
                .appendingPathComponent(String(year), isDirectory: true)
                .appendingPathComponent(String(format: "%04d-%02d %@", year, month, monthName), isDirectory: true)
                .appendingPathComponent(dayName.folderSafe, isDirectory: true)
        }
    }

    private func locationFolder(for item: PhotoLibraryItem, outputRoot: URL, fallbackYear: Int) async -> URL {
        guard let location = item.location else {
            return outputRoot
                .appendingPathComponent("Unknown Location", isDirectory: true)
                .appendingPathComponent(String(fallbackYear), isDirectory: true)
        }

        let geo = await geocoder.geocode(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        if !geo.folderComponents.isEmpty {
            var url = outputRoot
            for component in geo.folderComponents {
                url.appendPathComponent(component, isDirectory: true)
            }
            return url
        }

        return outputRoot
            .appendingPathComponent("Unknown Location", isDirectory: true)
            .appendingPathComponent(String(fallbackYear), isDirectory: true)
    }

    private func preserveCreationDate(_ date: Date?, at url: URL) throws {
        guard let date else { return }
        try FileManager.default.setAttributes([
            .creationDate: date,
            .modificationDate: date
        ], ofItemAtPath: url.path)
    }

    private nonisolated static func fetchLibraryItems() -> [PhotoLibraryItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )

        let fetched = PHAsset.fetchAssets(with: options)
        var items: [PhotoLibraryItem] = []
        items.reserveCapacity(fetched.count)

        fetched.enumerateObjects { asset, _, _ in
            guard let resource = preferredResource(for: asset) else { return }
            let filename = (resource.originalFilename.nonEmpty ?? fallbackFilename(for: asset, resource: resource)).filenameSafe
            let kind: PhotoLibraryItem.Kind = asset.mediaType == .video ? .video : .photo
            let resolvedDate = resolvedLibraryDate(for: asset, filename: filename)
            items.append(PhotoLibraryItem(
                id: asset.localIdentifier,
                asset: asset,
                filename: filename,
                kind: kind,
                date: resolvedDate,
                location: asset.location
            ))
        }

        return items
    }

    private nonisolated static func fetchSelectedItems(localIdentifiers: [String]) -> [PhotoLibraryItem] {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var items: [PhotoLibraryItem] = []
        items.reserveCapacity(fetched.count)

        fetched.enumerateObjects { asset, _, _ in
            guard let resource = preferredResource(for: asset) else { return }
            let filename = (resource.originalFilename.nonEmpty ?? fallbackFilename(for: asset, resource: resource)).filenameSafe
            let kind: PhotoLibraryItem.Kind = asset.mediaType == .video ? .video : .photo
            let resolvedDate = resolvedLibraryDate(for: asset, filename: filename)
            items.append(PhotoLibraryItem(
                id: asset.localIdentifier,
                asset: asset,
                filename: filename,
                kind: kind,
                date: resolvedDate,
                location: asset.location
            ))
        }

        return items.sorted { lhs, rhs in
            lhs.dateOrFallback > rhs.dateOrFallback
        }
    }

    private nonisolated static func writeOriginalResource(for asset: PHAsset, to destination: URL) async throws {
        // Photos and videos use different APIs. PHImageManager reliably downloads
        // photo originals from iCloud (Optimize Storage); PHAssetResourceManager
        // handles videos. Both allow network access so iCloud originals stream down.
        if asset.mediaType == .image {
            try await writePhotoData(for: asset, to: destination)
        } else {
            try await writeResourceData(for: asset, to: destination)
        }
    }

    private nonisolated static func writePhotoData(for asset: PHAsset, to destination: URL) async throws {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true            // download from iCloud if needed
        options.deliveryMode = .highQualityFormat
        // Export the true original capture, ignoring in-app edits/crops. This matches
        // the video path (fullSizeVideo) and the app's "originals" promise, and keeps
        // the exported data in its original format so the filename extension is correct.
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
                    let underlying = (info?[PHImageErrorKey] as? Error) ?? ExportError.noOriginalResource
                    continuation.resume(throwing: underlying)
                }
            }
        }

        try data.write(to: destination)
    }

    private nonisolated static func writeResourceData(for asset: PHAsset, to destination: URL) async throws {
        guard let resource = preferredResource(for: asset) else {
            throw ExportError.noOriginalResource
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private nonisolated static func preferredResource(for asset: PHAsset) -> PHAssetResource? {
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

    private nonisolated static func fallbackFilename(for asset: PHAsset, resource: PHAssetResource) -> String {
        let ext = preferredFilenameExtension(for: resource, mediaType: asset.mediaType)
        let prefix = asset.mediaType == .video ? "VID" : "IMG"
        return "\(prefix)_\(asset.localIdentifier.stableFilenameComponent).\(ext)"
    }

    private nonisolated static func resolvedLibraryDate(for asset: PHAsset, filename: String) -> Date? {
        asset.creationDate
            ?? filenameDate(from: filename)
            ?? asset.modificationDate
    }

    private nonisolated static func filenameDate(from filename: String) -> Date? {
        let name = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent

        let candidates: [(String, Int, String)] = [
            (#"(?:IMG|VID)-(\d{8})-WA\d+"#, 1, "yyyyMMdd"),
            (#"(?:IMG|VID|PANO|BURST|MVIMG|PORTRAIT|SLOW)_(\d{8}_\d{6})"#, 1, "yyyyMMdd_HHmmss"),
            (#"(?<!\d)(\d{8}_\d{6})(?!\d)"#, 1, "yyyyMMdd_HHmmss"),
            (#"(?<!\d)(\d{8}-\d{6})(?!\d)"#, 1, "yyyyMMdd-HHmmss"),
            (#"(\d{4}-\d{2}-\d{2}) at (\d{2}\.\d{2}\.\d{2})"#, 0, "yyyy-MM-dd HH.mm.ss"),
            (#"(?<!\d)(\d{4}-\d{2}-\d{2})(?!\d)"#, 1, "yyyy-MM-dd"),
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let lowerBound = Date(timeIntervalSince1970: 631152000) // 1990-01-01

        for (pattern, groupIndex, format) in candidates {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name))
            else { continue }

            let dateString: String
            if groupIndex == 0 {
                guard match.numberOfRanges >= 3,
                      let r1 = Range(match.range(at: 1), in: name),
                      let r2 = Range(match.range(at: 2), in: name) else { continue }
                dateString = String(name[r1]) + " " + String(name[r2])
            } else {
                guard match.numberOfRanges > groupIndex,
                      let range = Range(match.range(at: groupIndex), in: name) else { continue }
                dateString = String(name[range])
            }

            formatter.dateFormat = format
            if let date = formatter.date(from: dateString), date >= lowerBound, date <= Date() {
                return date
            }
        }

        return nil
    }

    private nonisolated static func preferredFilenameExtension(
        for resource: PHAssetResource,
        mediaType: PHAssetMediaType
    ) -> String {
        if let type = UTType(resource.uniformTypeIdentifier),
           let ext = type.preferredFilenameExtension {
            return ext
        }
        return mediaType == .video ? "mov" : "heic"
    }

    // MARK: - Incremental export manifest

    private nonisolated static let manifestFilename = ".foldiq-export-manifest.json"

    /// Map of asset ID → path (relative to the output folder) of its exported file.
    /// Empty if none/first run.
    private nonisolated static func loadManifest(at outputRoot: URL) -> [String: String] {
        let url = outputRoot.appendingPathComponent(manifestFilename)
        guard let data = try? Data(contentsOf: url) else { return [:] }

        // Current format: { assetID: relativePath }.
        if let map = try? JSONDecoder().decode([String: String].self, from: data) {
            return map
        }
        // Legacy format: [ assetID ] with no paths — keep the IDs, paths unknown ("").
        // These get their path back (or are re-exported) on the next run.
        if let ids = try? JSONDecoder().decode([String].self, from: data) {
            return Dictionary(ids.map { ($0, "") }, uniquingKeysWith: { first, _ in first })
        }
        return [:]
    }

    private nonisolated static func saveManifest(_ manifest: [String: String], at outputRoot: URL) {
        let url = outputRoot.appendingPathComponent(manifestFilename)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Path of `url` relative to `root` (the output folder), used as the manifest value
    /// so deleted files can be detected regardless of where the folder later lives.
    private nonisolated static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if url.path.hasPrefix(rootPath) {
            return String(url.path.dropFirst(rootPath.count))
        }
        return url.lastPathComponent
    }

    private nonisolated static func resolveCollision(_ url: URL, reserved: inout Set<String>) -> URL {
        guard reserved.contains(url.path) || FileManager.default.fileExists(atPath: url.path) else {
            return url
        }

        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1
        var candidate = url

        repeat {
            let filename = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            candidate = dir.appendingPathComponent(filename)
            counter += 1
        } while reserved.contains(candidate.path) || FileManager.default.fileExists(atPath: candidate.path)

        return candidate
    }

    /// English month names ("January"…"December"), computed once, so folder names are
    /// independent of the device locale. `[String]` is Sendable, unlike DateFormatter.
    private nonisolated static let englishMonthSymbols: [String] = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.monthSymbols
    }()

    // MARK: - Free-space checks

    /// Minimum free space (bytes) required before an export starts. Below this we stop
    /// up front instead of downloading items that can't be written.
    private nonisolated static let minimumFreeSpace: Int64 = 50 * 1024 * 1024  // 50 MB

    /// Free space available at `url`'s volume, or nil if it can't be read (e.g. some
    /// external/USB or cloud destinations) — in which case we skip the pre-flight guard.
    private nonisolated static func availableCapacity(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// True when an error means the destination volume is full.
    private nonisolated static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
            || (ns.domain == NSCocoaErrorDomain && ns.code == 640)
    }

    private nonisolated static func humanize(_ error: Error) -> String {
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSPOSIXErrorDomain, Int(ENOSPC)),
             (NSCocoaErrorDomain, 640):
            return "Not enough free space at the destination."
        case (NSPOSIXErrorDomain, Int(EACCES)),
             (NSPOSIXErrorDomain, Int(EPERM)),
             (NSCocoaErrorDomain, 513),
             (NSCocoaErrorDomain, 642):
            return "Foldiq does not have permission to write there."
        case ("CloudPhotoLibraryErrorDomain", _),
             (PHPhotosErrorDomain, _):
            return "Couldn't download this item from iCloud. Connect to Wi-Fi and keep Foldiq open so originals can download, then try again."
        default:
            return error.localizedDescription
        }
    }

    private enum ExportError: LocalizedError {
        case noOriginalResource

        var errorDescription: String? {
            "The original photo or video resource could not be found."
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var stableFilenameComponent: String {
        components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    // `folderSafe` is defined once in ReverseGeocoder.swift and shared module-wide.
    var filenameSafe: String {
        let cleaned = folderSafe
        return cleaned.isEmpty ? "Foldiq_Asset" : cleaned
    }
}
#endif
