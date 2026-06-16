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
    enum Phase: Equatable {
        case idle
        case requestingAccess
        case scanning
        case ready
        case exporting
        case completed(URL, Int)
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
    var selectedItems: [PhotoLibraryItem] { items.filter { selectedItemIDs.contains($0.id) } }
    var selectedCount: Int { selectedItemIDs.count }

    func requestAccessAndScan() async {
        phase = .requestingAccess

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let finalStatus: PHAuthorizationStatus
        if status == .notDetermined {
            finalStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
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

        var exported = 0
        var reservedPaths = Set<String>()

        for (index, item) in exportItems.enumerated() {
            if Task.isCancelled {
                phase = .failed("Export cancelled.")
                return
            }

            progress = ExportProgress(done: index + 1, total: items.count, currentFile: item.filename)

            do {
                let folder = await organizedDestinationFolder(
                    for: item,
                    outputRoot: outputRoot,
                    mode: mode,
                    includeLocation: includeLocation
                )
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

                let destination = Self.resolveCollision(
                    folder.appendingPathComponent(item.filename),
                    reserved: &reservedPaths
                )
                reservedPaths.insert(destination.path)

                try await Self.writeOriginalResource(for: item.asset, to: destination)
                try preserveCreationDate(item.date, at: destination)
                exported += 1
            } catch {
                phase = .failed("Could not export \(item.filename): \(Self.humanize(error))")
                return
            }
        }

        phase = .completed(outputRoot, exported)
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
        let monthName = DateFormatter().monthSymbols[month - 1]

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

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
                .appendingPathComponent(dayFormatter.string(from: date), isDirectory: true)
        case .byLocation:
            return await locationFolder(for: item, outputRoot: outputRoot, fallbackYear: year)
        case .smartHybrid:
            var dayName = dayFormatter.string(from: date)
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
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
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
            items.append(PhotoLibraryItem(
                id: asset.localIdentifier,
                asset: asset,
                filename: filename,
                kind: kind,
                date: asset.creationDate,
                location: asset.location
            ))
        }

        return items
    }

    private nonisolated static func writeOriginalResource(for asset: PHAsset, to destination: URL) async throws {
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

    var folderSafe: String {
        let illegal = CharacterSet(charactersIn: ":/\\?*|\"<>")
        return components(separatedBy: illegal).joined(separator: "_")
    }

    var filenameSafe: String {
        let illegal = CharacterSet(charactersIn: ":/\\?*|\"<>")
        let cleaned = components(separatedBy: illegal).joined(separator: "_")
        return cleaned.isEmpty ? "Foldiq_Asset" : cleaned
    }
}
#endif
