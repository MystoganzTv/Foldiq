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

    struct FailedUndo: Equatable, Identifiable {
        let id: String
        let relativePath: String
        let reason: String
    }

    enum Phase: Equatable {
        case idle
        case requestingAccess
        case scanning
        case ready
        case exporting
        case completed(URL, Int, Int, [FailedExport])
        case undoing
        case undone(URL, Int, [FailedUndo])
        case failed(String)
    }

    struct ExportProgress: Equatable {
        var done: Int = 0
        var total: Int = 0
        var currentFile: String = ""
    }

    struct PreviewProgress: Equatable {
        var done: Int = 0
        var total: Int = 0
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [PhotoLibraryItem] = []
    @Published private(set) var progress = ExportProgress()
    @Published private(set) var previewProgress = PreviewProgress()
    @Published private(set) var previewItems: [MobileExportPreviewItem] = []
    @Published private(set) var isBuildingPreview = false
    @Published private(set) var reportRows: [MobileExportReportRow] = []
    @Published private(set) var reportURL: URL?
    @Published var selectedItemIDs = Set<String>()

    private let geocoder = ReverseGeocoder()
    private var previewFingerprint: PreviewFingerprint?

    private struct PreviewFingerprint: Equatable {
        let selectedIDs: Set<String>
        let mode: OrganizationMode
        let includeLocation: Bool
        let destinationPath: String
        let outputFolderName: String
    }

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
        let startedAt = Date()
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
            invalidatePreview()
            progress = ExportProgress(done: 0, total: items.count, currentFile: "")
            phase = .ready
        }
        AnonymousTelemetry.send(
            .scanCompleted,
            success: !items.isEmpty,
            elapsed: Date().timeIntervalSince(startedAt),
            itemCount: items.count
        )
    }

    func requestAccessAndScan() async {
        let startedAt = Date()
        phase = .requestingAccess

        // PhotoKit requires `.readWrite` to read asset metadata and resources through
        // `PHAsset`, even though Foldiq never modifies the Photos library itself.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let finalStatus: PHAuthorizationStatus
        if status == .notDetermined {
            finalStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            finalStatus = status
        }

        guard finalStatus == .authorized || finalStatus == .limited else {
            phase = .failed("Photos access was not granted. Enable Photos access in Settings to export your library.")
            AnonymousTelemetry.send(
                .scanCompleted,
                success: false,
                elapsed: Date().timeIntervalSince(startedAt),
                itemCount: 0
            )
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
            invalidatePreview()
            progress = ExportProgress(done: 0, total: items.count, currentFile: "")
            phase = .ready
        }
        AnonymousTelemetry.send(
            .scanCompleted,
            success: !items.isEmpty,
            elapsed: Date().timeIntervalSince(startedAt),
            itemCount: items.count
        )
    }

    func selectAll() {
        selectedItemIDs = Set(items.map(\.id))
        invalidatePreview()
    }

    func selectPhotosOnly() {
        selectedItemIDs = Set(items.filter { $0.kind == .photo }.map(\.id))
        invalidatePreview()
    }

    func selectVideosOnly() {
        selectedItemIDs = Set(items.filter { $0.kind == .video }.map(\.id))
        invalidatePreview()
    }

    func clearSelection() {
        selectedItemIDs.removeAll()
        invalidatePreview()
    }

    func toggleSelection(for item: PhotoLibraryItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
        invalidatePreview()
    }

    func invalidatePreview() {
        previewFingerprint = nil
        previewItems = []
        previewProgress = PreviewProgress()
    }

    func previewIsCurrent(
        destinationFolder: URL,
        mode: OrganizationMode,
        includeLocation: Bool,
        outputFolderName: String
    ) -> Bool {
        let safeName = MobileExportPlanner.safeOutputFolderName(outputFolderName)
        return previewFingerprint == PreviewFingerprint(
            selectedIDs: selectedItemIDs,
            mode: mode,
            includeLocation: includeLocation,
            destinationPath: destinationFolder.standardizedFileURL.path,
            outputFolderName: safeName
        )
    }

    func buildPreview(
        to destinationFolder: URL,
        mode: OrganizationMode,
        includeLocation: Bool,
        outputFolderName: String
    ) async {
        let exportItems = selectedItems
        guard !exportItems.isEmpty else {
            invalidatePreview()
            return
        }

        let didAccess = destinationFolder.startAccessingSecurityScopedResource()
        defer {
            if didAccess { destinationFolder.stopAccessingSecurityScopedResource() }
        }

        let safeName = MobileExportPlanner.safeOutputFolderName(outputFolderName)
        isBuildingPreview = true
        previewItems = []
        previewProgress = PreviewProgress(done: 0, total: exportItems.count)
        defer { isBuildingPreview = false }

        let outputRoot = destinationFolder.appendingPathComponent(safeName, isDirectory: true)
        var reservedPaths = Set<String>()
        let manifest = Self.loadManifest(at: outputRoot)
        var planned: [MobileExportPreviewItem] = []
        planned.reserveCapacity(exportItems.count)

        for (index, item) in exportItems.enumerated() {
            guard !Task.isCancelled else {
                invalidatePreview()
                return
            }

            if let recordedPath = manifest[item.id],
               let recordedURL = MobileExportPlanner.containedURL(
                   forRelativePath: recordedPath,
                   within: outputRoot
               ),
               FileManager.default.fileExists(atPath: recordedURL.path) {
                reservedPaths.insert(recordedURL.path)
                planned.append(MobileExportPreviewItem(
                    id: item.id,
                    filename: item.filename,
                    relativePath: recordedPath,
                    hasUnknownDate: item.date == nil,
                    isAlreadyExported: true
                ))
                previewProgress = PreviewProgress(done: index + 1, total: exportItems.count)
                continue
            }

            let folder = await organizedDestinationFolder(
                for: item,
                outputRoot: outputRoot,
                mode: mode,
                includeLocation: includeLocation
            )
            let intended = folder.appendingPathComponent(item.filename)
            let destination = MobileExportPlanner.collisionSafeURL(for: intended, reserved: &reservedPaths)
            planned.append(MobileExportPreviewItem(
                id: item.id,
                filename: item.filename,
                relativePath: MobileExportPlanner.relativePath(of: destination, from: outputRoot),
                hasUnknownDate: item.date == nil,
                isAlreadyExported: false
            ))
            previewProgress = PreviewProgress(done: index + 1, total: exportItems.count)
        }

        previewItems = planned
        previewFingerprint = PreviewFingerprint(
            selectedIDs: selectedItemIDs,
            mode: mode,
            includeLocation: includeLocation,
            destinationPath: destinationFolder.standardizedFileURL.path,
            outputFolderName: safeName
        )
    }

    func export(
        to destinationFolder: URL,
        mode: OrganizationMode,
        includeLocation: Bool,
        outputFolderName: String = "Foldiq Export"
    ) async {
        let startedAt = Date()
        let exportItems = selectedItems
        guard !exportItems.isEmpty else {
            phase = .failed("Choose at least one photo or video to export.")
            AnonymousTelemetry.send(.applyCompleted, success: false, elapsed: 0, itemCount: 0)
            return
        }

        reportRows = []
        reportURL = nil

        let didAccess = destinationFolder.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                destinationFolder.stopAccessingSecurityScopedResource()
            }
        }

        let safeName = MobileExportPlanner.safeOutputFolderName(outputFolderName)
        let outputRoot = destinationFolder.appendingPathComponent(safeName, isDirectory: true)
        phase = .exporting
        progress = ExportProgress(done: 0, total: exportItems.count, currentFile: "")

        // Pre-flight: if we can read the destination's free space and it's critically
        // low, stop before downloading anything instead of failing item by item.
        if let free = Self.availableCapacity(at: destinationFolder), free < Self.minimumFreeSpace {
            phase = .failed("The destination is out of free space. Free up some space and try again.")
            AnonymousTelemetry.send(
                .applyCompleted,
                success: false,
                elapsed: Date().timeIntervalSince(startedAt),
                itemCount: 0
            )
            return
        }

        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Could not create the export folder. \(Self.humanize(error))")
            AnonymousTelemetry.send(
                .applyCompleted,
                success: false,
                elapsed: Date().timeIntervalSince(startedAt),
                itemCount: 0
            )
            return
        }

        var exported = 0
        var skipped = 0
        var failures: [FailedExport] = []
        var rows: [MobileExportReportRow] = []
        var reservedPaths = Set<String>()

        // Incremental re-export: a manifest mapping each exported asset ID to its file
        // path lets repeat runs skip what's done — without re-downloading from iCloud.
        // Storing the path (not just the ID) means a file the user deleted from the
        // destination is detected as missing and re-exported, instead of being skipped.
        var manifest = Self.loadManifest(at: outputRoot)

        for (index, item) in exportItems.enumerated() {
            if Task.isCancelled {
                Self.saveManifest(manifest, at: outputRoot)
                reportRows = rows
                reportURL = Self.saveReport(rows, at: outputRoot)
                phase = .failed("Export cancelled.")
                AnonymousTelemetry.send(
                    .applyCompleted,
                    success: false,
                    elapsed: Date().timeIntervalSince(startedAt),
                    itemCount: index
                )
                return
            }

            // `done` reflects items already finished; the current item is shown by
            // name but not counted until it actually completes (iCloud downloads can
            // take a while, so we don't want the bar to jump ahead of real progress).
            progress = ExportProgress(done: index, total: exportItems.count, currentFile: item.filename)

            // Already exported here in a previous run AND the file is still on disk →
            // skip, no download. If the recorded file was deleted (or the legacy
            // manifest stored no path), fall through and re-verify/re-export below.
            if let recordedPath = manifest[item.id],
               let recordedURL = MobileExportPlanner.containedURL(
                   forRelativePath: recordedPath,
                   within: outputRoot
               ),
               FileManager.default.fileExists(atPath: recordedURL.path) {
                skipped += 1
                rows.append(Self.reportRow(for: item, relativePath: recordedPath, status: .alreadyExported))
                continue
            }

            var plannedRelativePath = item.filename
            do {
                let folder = await organizedDestinationFolder(
                    for: item,
                    outputRoot: outputRoot,
                    mode: mode,
                    includeLocation: includeLocation
                )
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

                let intended = folder.appendingPathComponent(item.filename)
                plannedRelativePath = MobileExportPlanner.relativePath(of: intended, from: outputRoot)

                let destination = MobileExportPlanner.collisionSafeURL(for: intended, reserved: &reservedPaths)
                plannedRelativePath = MobileExportPlanner.relativePath(of: destination, from: outputRoot)

                try await Self.writeOriginalResource(for: item.asset, to: destination)
                try preserveCreationDate(item.date, at: destination)

                // Live Photo: export the paired video next to the still (IMG_x.HEIC +
                // IMG_x.mov) so the motion isn't lost. Best-effort — a missing/failed
                // video must not discard the still that already exported successfully.
                var createdRelativePaths = [plannedRelativePath]
                if item.asset.mediaSubtypes.contains(.photoLive) {
                    let expectedPairedURL = destination.deletingPathExtension().appendingPathExtension("mov")
                    let pairedExisted = FileManager.default.fileExists(atPath: expectedPairedURL.path)
                    if let pairedURL = try? await Self.writePairedVideo(for: item.asset, besideStill: destination) {
                        try? preserveCreationDate(item.date, at: pairedURL)
                        reservedPaths.insert(pairedURL.path)
                        if !pairedExisted {
                            createdRelativePaths.append(
                                MobileExportPlanner.relativePath(of: pairedURL, from: outputRoot)
                            )
                        }
                    }
                }

                manifest[item.id] = Self.relativePath(of: destination, from: outputRoot)
                exported += 1
                rows.append(Self.reportRow(for: item, relativePath: plannedRelativePath, status: .exported))
                // Checkpoint Undo before marking the asset complete. If the app stops
                // between the two atomic writes, the copy is still known to Undo and
                // cannot become an untracked file in the destination.
                Self.appendUndoEntry(
                    MobileExportUndoEntry(assetID: item.id, relativePaths: createdRelativePaths),
                    at: outputRoot
                )
                // Atomic checkpoint after every completed item makes the export truly
                // resumable after termination, not only after a graceful cancellation.
                Self.saveManifest(manifest, at: outputRoot)
            } catch {
                // Out of space: stop the whole export rather than failing every
                // remaining item. The manifest is saved so a later run resumes.
                if Self.isOutOfSpace(error) {
                    progress = ExportProgress(done: index, total: exportItems.count, currentFile: "")
                    Self.saveManifest(manifest, at: outputRoot)
                    reportRows = rows
                    reportURL = Self.saveReport(rows, at: outputRoot)
                    phase = .failed("Ran out of space at the destination after exporting \(exported). Free up space and run the export again — Foldiq picks up where it left off.")
                    AnonymousTelemetry.send(
                        .applyCompleted,
                        success: false,
                        elapsed: Date().timeIntervalSince(startedAt),
                        itemCount: index
                    )
                    return
                }

                let reason = Self.humanize(error)
                failures.append(FailedExport(
                    id: item.id,
                    filename: item.filename,
                    reason: reason
                ))
                rows.append(Self.reportRow(
                    for: item,
                    relativePath: plannedRelativePath,
                    status: .failed,
                    detail: reason
                ))
            }
        }

        progress = ExportProgress(done: exportItems.count, total: exportItems.count, currentFile: "")
        Self.saveManifest(manifest, at: outputRoot)
        reportRows = rows
        reportURL = Self.saveReport(rows, at: outputRoot)
        Self.markUndoManifestCompleted(at: outputRoot)
        phase = .completed(outputRoot, exported, skipped, failures)
        AnonymousTelemetry.send(
            .applyCompleted,
            success: failures.isEmpty,
            elapsed: Date().timeIntervalSince(startedAt),
            itemCount: exportItems.count
        )
    }

    func undoLastExport(in destinationFolder: URL, outputFolderName: String) {
        let didAccess = destinationFolder.startAccessingSecurityScopedResource()
        defer {
            if didAccess { destinationFolder.stopAccessingSecurityScopedResource() }
        }

        let outputRoot = destinationFolder.appendingPathComponent(
            MobileExportPlanner.safeOutputFolderName(outputFolderName),
            isDirectory: true
        )
        guard var undoManifest = Self.loadUndoManifest(at: outputRoot), !undoManifest.entries.isEmpty else {
            phase = .failed("There is no completed iPhone export available to undo in this folder.")
            return
        }

        phase = .undoing
        var removed = 0
        var failures: [FailedUndo] = []
        var remainingEntries: [MobileExportUndoEntry] = []
        var exportManifest = Self.loadManifest(at: outputRoot)

        for entry in undoManifest.entries.reversed() {
            var failedPaths: [String] = []
            for relativePath in entry.relativePaths.reversed() {
                guard let url = MobileExportPlanner.containedURL(
                    forRelativePath: relativePath,
                    within: outputRoot
                ) else {
                    failedPaths.append(relativePath)
                    failures.append(FailedUndo(
                        id: "\(entry.assetID)-\(relativePath)",
                        relativePath: relativePath,
                        reason: "The undo manifest contains an unsafe path."
                    ))
                    continue
                }

                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                } catch {
                    failedPaths.append(relativePath)
                    failures.append(FailedUndo(
                        id: "\(entry.assetID)-\(relativePath)",
                        relativePath: relativePath,
                        reason: Self.humanize(error)
                    ))
                }
            }

            if failedPaths.isEmpty {
                exportManifest.removeValue(forKey: entry.assetID)
            } else {
                remainingEntries.append(MobileExportUndoEntry(
                    assetID: entry.assetID,
                    relativePaths: failedPaths
                ))
            }
        }

        Self.saveManifest(exportManifest, at: outputRoot)
        if remainingEntries.isEmpty {
            Self.removeUndoManifest(at: outputRoot)
        } else {
            undoManifest.entries = Array(remainingEntries.reversed())
            Self.saveUndoManifest(undoManifest, at: outputRoot)
        }
        Self.removeEmptyExportDirectories(under: outputRoot)
        phase = .undone(outputRoot, removed, failures)
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
        invalidatePreview()
        reportRows = []
        reportURL = nil
        phase = .idle
    }

    private func organizedDestinationFolder(
        for item: PhotoLibraryItem,
        outputRoot: URL,
        mode: OrganizationMode,
        includeLocation: Bool
    ) async -> URL {
        var locationComponents: [String] = []
        let needsLocation = mode == .byLocation || (mode == .smartHybrid && includeLocation)
        if needsLocation, let location = item.location {
            let geo = await geocoder.geocode(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            locationComponents = geo.folderComponents
        }

        let relativeFolder = MobileExportPlanner.relativeFolder(
            date: item.date,
            mode: mode,
            includeLocation: includeLocation,
            locationComponents: locationComponents
        )
        return relativeFolder.split(separator: "/").reduce(outputRoot) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: true)
        }
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
        try await writeData(of: resource, to: destination)
    }

    /// Writes a single asset resource to disk, streaming from iCloud if needed.
    private nonisolated static func writeData(of resource: PHAssetResource, to destination: URL) async throws {
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

    /// For a Live Photo, writes the paired motion video beside the still using the same
    /// base name (e.g. `IMG_1234.HEIC` → `IMG_1234.mov`). Returns the video URL, or nil
    /// if the asset has no paired video resource. The originals keep their Apple asset
    /// identifier, so re-importing the two files re-pairs them into a Live Photo.
    private nonisolated static func writePairedVideo(for asset: PHAsset, besideStill stillURL: URL) async throws -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let paired = resources.first(where: { $0.type == .fullSizePairedVideo })
            ?? resources.first(where: { $0.type == .pairedVideo }) else {
            return nil
        }

        let videoURL = stillURL.deletingPathExtension().appendingPathExtension("mov")
        // Don't clobber an unrelated file that's already there.
        guard !FileManager.default.fileExists(atPath: videoURL.path) else { return videoURL }

        try await writeData(of: paired, to: videoURL)
        return videoURL
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
    private nonisolated static let undoManifestFilename = ".foldiq-last-export.json"

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

    private nonisolated static func loadUndoManifest(at outputRoot: URL) -> MobileExportUndoManifest? {
        let url = outputRoot.appendingPathComponent(undoManifestFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MobileExportUndoManifest.self, from: data)
    }

    private nonisolated static func appendUndoEntry(
        _ entry: MobileExportUndoEntry,
        at outputRoot: URL
    ) {
        var manifest: MobileExportUndoManifest
        if let existing = loadUndoManifest(at: outputRoot), !existing.completed {
            manifest = existing
        } else {
            manifest = MobileExportUndoManifest(createdAt: Date(), completed: false, entries: [])
        }
        manifest.entries.append(entry)
        saveUndoManifest(manifest, at: outputRoot)
    }

    private nonisolated static func markUndoManifestCompleted(at outputRoot: URL) {
        guard var manifest = loadUndoManifest(at: outputRoot), !manifest.entries.isEmpty else { return }
        manifest.completed = true
        saveUndoManifest(manifest, at: outputRoot)
    }

    private nonisolated static func saveUndoManifest(
        _ manifest: MobileExportUndoManifest,
        at outputRoot: URL
    ) {
        let url = outputRoot.appendingPathComponent(undoManifestFilename)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func removeUndoManifest(at outputRoot: URL) {
        let url = outputRoot.appendingPathComponent(undoManifestFilename)
        try? FileManager.default.removeItem(at: url)
    }

    private nonisolated static func removeEmptyExportDirectories(under outputRoot: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: outputRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let directories = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.path.count > $1.path.count }

        for directory in directories where directory != outputRoot {
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private nonisolated static func reportRow(
        for item: PhotoLibraryItem,
        relativePath: String,
        status: MobileExportReportRow.Status,
        detail: String = ""
    ) -> MobileExportReportRow {
        MobileExportReportRow(
            filename: item.filename,
            kind: item.kind.rawValue,
            capturedAt: item.date,
            relativePath: relativePath,
            status: status,
            detail: detail
        )
    }

    private nonisolated static func saveReport(
        _ rows: [MobileExportReportRow],
        at outputRoot: URL
    ) -> URL? {
        guard !rows.isEmpty else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let reportURL = outputRoot.appendingPathComponent("Foldiq Export Report \(stamp).csv")
        guard let data = MobileExportPlanner.buildCSV(rows: rows).data(using: .utf8) else { return nil }
        do {
            try data.write(to: reportURL, options: [.atomic, .withoutOverwriting])
            return reportURL
        } catch {
            return nil
        }
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
