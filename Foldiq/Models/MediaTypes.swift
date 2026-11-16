// MediaTypes.swift
// Central registry of all file extensions Foldiq recognises.

import Foundation

enum MediaTypes {

    // MARK: Photos
    static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif",
        "tiff", "tif", "gif", "webp", "bmp",
        // RAW formats
        "raw", "cr2", "cr3", "nef", "nrw",
        "arw", "srf", "sr2", "dng", "orf",
        "rw2", "pef", "srw", "raf", "3fr",
    ]

    // MARK: Videos
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv",
        "wmv", "flv", "webm", "3gp", "mts",
        "m2ts", "ts",
    ]

    // MARK: Archives / compressed
    // Desktop archives are handled locally. The iPhone/iPad flow reads the Photos
    // Library directly and intentionally does not accept compressed files.
    #if os(macOS)
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z"]
    #else
    static let archiveExtensions: Set<String> = []
    #endif

    // MARK: All supported
    static let allExtensions: Set<String> = photoExtensions
        .union(videoExtensions)
        .union(archiveExtensions)

    // MARK: Screenshot detection
    /// Filename substrings (lowercased) that strongly indicate a screenshot.
    static let screenshotKeywords: [String] = [
        "screenshot", "screen shot", "screen-shot",
        "bildschirmfoto", "captura", "schermata",
    ]
    /// Prefix patterns used by iOS/macOS screenshot naming.
    static let screenshotPrefixes: [String] = [
        "img_e",      // iOS edited
        "screenshot", // generic
    ]

    // MARK: Helpers

    static func kind(for ext: String) -> MediaKind? {
        let e = ext.lowercased()
        if photoExtensions.contains(e)   { return .photo }
        if videoExtensions.contains(e)   { return .video }
        if archiveExtensions.contains(e) { return .archive }
        return nil
    }

    static func isScreenshot(filename: String) -> Bool {
        let lower = filename.lowercased()
        return screenshotKeywords.contains(where: { lower.contains($0) })
    }
}

// MARK: ─── Photos libraries ───────────────────────────────────────────────────

/// Apple Photos keeps a library as a package ("Photos Library.photoslibrary").
/// Foldiq reads the original files stored inside it and never writes there:
/// every file that comes from a Photos library is copied, never moved, because
/// taking a file out of the package would break the library.
enum PhotosLibrarySupport {
    static let packageExtension = "photoslibrary"

    /// Folders that hold the originals: "originals" since Photos 5
    /// (macOS 10.15), "Masters" in older libraries. Everything else in the
    /// package — the database, thumbnails, previews — is ignored.
    static let originalsFolderNames = ["originals", "Masters"]

    static func isPhotosLibrary(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == packageExtension
    }

    /// The library Photos uses unless the person picked another one. With
    /// iCloud Photos set to "Optimize Mac Storage" most of its originals are
    /// only in iCloud, so Foldiq reads it through Photos instead of from disk.
    static func isDefaultSystemLibrary(_ url: URL) -> Bool {
        guard let home = realHomeDirectory else { return false }
        let expected = home.appendingPathComponent("Pictures/Photos Library.photoslibrary", isDirectory: true)
        return url.resolvingSymlinksInPath().standardizedFileURL.path
            == expected.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The person's real home folder. Inside the App Sandbox,
    /// `NSHomeDirectory()` points at the app's container instead.
    static var realHomeDirectory: URL? {
        guard let directory = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }

    /// True when `path` points at a file stored inside a Photos library.
    static func isInsidePhotosLibrary(_ path: String) -> Bool {
        path.split(separator: "/")
            .dropLast()
            .contains { $0.lowercased().hasSuffix("." + packageExtension) }
    }

    static func originalsFolders(in library: URL) -> [URL] {
        originalsFolderNames
            .map { library.appendingPathComponent($0, isDirectory: true) }
            .filter { folder in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
    }

    /// The short video Photos stores beside a Live Photo. Since Photos 5 it is
    /// "<UUID>_3.mov" next to "<UUID>.heic"; older libraries reuse the photo's
    /// own name ("IMG_1234.JPG" + "IMG_1234.mov"). `photoStemsInFolder` holds
    /// the lowercased names, without extension, of the photos in the same folder.
    static func isLivePhotoCompanion(_ url: URL, photoStemsInFolder: Set<String>) -> Bool {
        guard url.pathExtension.lowercased() == "mov" else { return false }
        var stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if photoStemsInFolder.contains(stem) { return true }
        guard stem.hasSuffix("_3") else { return false }
        stem.removeLast(2)
        return photoStemsInFolder.contains(stem)
    }
}

/// Which part of the Mac's main Photos library to organize. Copying a whole
/// library out of iCloud can take hours and a lot of free space, so the person
/// can narrow it to a date range or to a few albums.
struct PhotosLibraryScope: Equatable {
    enum Kind: String, CaseIterable {
        case everything
        case dateRange
        case albums
    }

    var kind: Kind = .everything
    var startDate: Date = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    var endDate: Date = Date()
    var albumIdentifiers: Set<String> = []
    /// Album titles, kept only to describe the selection.
    var albumNames: [String] = []

    /// Midnight at the start of `startDate`.
    var rangeStart: Date { Calendar.current.startOfDay(for: startDate) }

    /// Midnight after `endDate`, so the last day counts in full.
    var rangeEnd: Date {
        let day = Calendar.current.startOfDay(for: endDate)
        return Calendar.current.date(byAdding: .day, value: 1, to: day) ?? endDate
    }

    var summary: String {
        switch kind {
        case .everything:
            return "Entire library"
        case .dateRange:
            let from = startDate.formatted(date: .abbreviated, time: .omitted)
            let to = endDate.formatted(date: .abbreviated, time: .omitted)
            return "\(from) – \(to)"
        case .albums:
            if albumNames.count == 1 { return albumNames[0] }
            return "\(albumNames.count) albums"
        }
    }
}
