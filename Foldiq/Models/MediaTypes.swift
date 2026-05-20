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
    // Only ZIP can be extracted on macOS in the sandbox without external tools.
    // Other formats (rar, 7z, tar, etc.) are not recognised — they are ignored by the scanner.
    static let archiveExtensions: Set<String> = ["zip"]

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
