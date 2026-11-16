// MetadataExtractor.swift
// Pulls EXIF, GPS, camera info from photos (ImageIO) and videos (AVFoundation).

import Foundation
import ImageIO
import AVFoundation
import CoreLocation

// MARK: ─── Extracted Metadata ─────────────────────────────────────────────────

struct ExtractedMetadata {
    var dateTaken: Date?
    var cameraMake: String?
    var cameraModel: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var durationSeconds: Double?   // video only
    var latitude: Double?
    var longitude: Double?
    /// True when `dateTaken` came from the file's own camera or video metadata,
    /// rather than from its filename. Google Takeout sidecars never override it.
    var hasEmbeddedDate: Bool = false
}

// MARK: ─── MetadataExtractor ──────────────────────────────────────────────────

/// Stateless service; create once and call extract(from:kind:) concurrently.
final class MetadataExtractor: Sendable {

    // MARK: Public

    func extract(from url: URL, kind: MediaKind) async -> ExtractedMetadata {
        switch kind {
        case .photo:   return extractPhoto(url)
        case .video:   return await extractVideo(url)
        case .archive: return extractArchive(url)
        }
    }

    // MARK: ─── Photo ──────────────────────────────────────────────────────────

    private func extractPhoto(_ url: URL) -> ExtractedMetadata {
        var meta = ExtractedMetadata()

        let srcOptions: [String: Any] = [kCGImageSourceShouldCache as String: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOptions as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else {
            // Even if ImageIO can't read properties, still try filename date.
            meta.dateTaken = parseDateFromFilename(url.lastPathComponent)
            return meta
        }

        // Pixel dimensions — top-level first.
        // For RAW formats (CR2, NEF, ARW, DNG) the top-level values may reflect
        // the embedded JPEG thumbnail rather than the full-resolution image.
        // Fall back to EXIF PixelXDimension / PixelYDimension when available.
        meta.pixelWidth  = props[kCGImagePropertyPixelWidth  as String] as? Int
        meta.pixelHeight = props[kCGImagePropertyPixelHeight as String] as? Int

        // EXIF — date and actual pixel dimensions for RAW formats.
        // RAW files (CR2, NEF, ARW, DNG) often report thumbnail dimensions at the
        // top level; the real full-resolution size lives in the EXIF subdictionary.
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            meta.dateTaken = parseEXIFDate(
                exif[kCGImagePropertyExifDateTimeOriginal  as String] as? String ??
                exif[kCGImagePropertyExifDateTimeDigitized as String] as? String
            )
            // Override top-level pixel dims with EXIF full-res values when present.
            if let w = exif[kCGImagePropertyExifPixelXDimension as String] as? Int, w > 0 {
                meta.pixelWidth = w
            } else if let w = exif[kCGImagePropertyExifPixelXDimension as String] as? Double, w > 0 {
                meta.pixelWidth = Int(w)
            }
            if let h = exif[kCGImagePropertyExifPixelYDimension as String] as? Int, h > 0 {
                meta.pixelHeight = h
            } else if let h = exif[kCGImagePropertyExifPixelYDimension as String] as? Double, h > 0 {
                meta.pixelHeight = Int(h)
            }
        }

        // TIFF (camera make/model, and TIFF datetime as fallback)
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            meta.cameraMake  = tiff[kCGImagePropertyTIFFMake  as String] as? String
            meta.cameraModel = tiff[kCGImagePropertyTIFFModel as String] as? String
            if meta.dateTaken == nil {
                meta.dateTaken = parseEXIFDate(
                    tiff[kCGImagePropertyTIFFDateTime as String] as? String
                )
            }
        }

        // GPS
        if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            meta.latitude  = coordinate(from: gps, latKey: kCGImagePropertyGPSLatitude  as String,
                                                    refKey: kCGImagePropertyGPSLatitudeRef  as String,
                                                    southOrWest: "S")
            meta.longitude = coordinate(from: gps, latKey: kCGImagePropertyGPSLongitude as String,
                                                    refKey: kCGImagePropertyGPSLongitudeRef as String,
                                                    southOrWest: "W")
        }

        // Use filename date as fallback or as a correction when EXIF date looks wrong.
        // WhatsApp and some messaging apps reset EXIF dates to "now" when forwarding.
        let embeddedPhotoDate = meta.dateTaken.flatMap(sanitize)
        meta.dateTaken = resolvedDate(exifDate: meta.dateTaken,
                                      filenameDate: parseDateFromFilename(url.lastPathComponent))
        meta.hasEmbeddedDate = embeddedPhotoDate != nil && meta.dateTaken == embeddedPhotoDate

        return meta
    }

    // MARK: ─── Video ──────────────────────────────────────────────────────────

    private func extractVideo(_ url: URL) async -> ExtractedMetadata {
        var meta = ExtractedMetadata()

        let asset = AVURLAsset(url: url)

        // Duration
        if let duration = try? await asset.load(.duration),
           duration.isValid && !duration.isIndefinite {
            meta.durationSeconds = CMTimeGetSeconds(duration)
        }

        // Common metadata (creation date, location)
        if let commonMetadata = try? await asset.load(.commonMetadata) {
            for item in commonMetadata {
                switch item.commonKey {
                case .commonKeyCreationDate:
                    if let str = try? await item.load(.stringValue) {
                        meta.dateTaken = ISO8601DateFormatter().date(from: str)
                    } else if let date = try? await item.load(.dateValue) {
                        meta.dateTaken = date
                    }
                case .commonKeyLocation:
                    if let str = try? await item.load(.stringValue),
                       let loc = parseISO6709(str) {
                        meta.latitude  = loc.latitude
                        meta.longitude = loc.longitude
                    }
                default:
                    break
                }
            }
        }

        let embeddedVideoDate = meta.dateTaken.flatMap(sanitize)
        meta.dateTaken = resolvedDate(exifDate: meta.dateTaken,
                                      filenameDate: parseDateFromFilename(url.lastPathComponent))
        meta.hasEmbeddedDate = embeddedVideoDate != nil && meta.dateTaken == embeddedVideoDate

        return meta
    }

    // MARK: ─── Archive ───────────────────────────────────────────────────────

    /// Archives have no embedded EXIF or container metadata.
    /// We rely entirely on filename date patterns (same logic as photos/videos).
    private func extractArchive(_ url: URL) -> ExtractedMetadata {
        var meta = ExtractedMetadata()
        meta.dateTaken = parseDateFromFilename(url.lastPathComponent)
        return meta
    }

    // MARK: ─── Helpers ────────────────────────────────────────────────────────

    private let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func parseEXIFDate(_ string: String?) -> Date? {
        guard let s = string, let date = exifDateFormatter.date(from: s) else { return nil }
        return sanitize(date)
    }

    /// Returns nil for dates that are clearly bogus: camera clock not configured,
    /// factory defaults, well-known epoch values, or impossible timestamps.
    private func sanitize(_ date: Date) -> Date? {
        // Valid range: 1900-01-01 to 1 day from now (1 day slack for timezone edge cases)
        let earliest = Date(timeIntervalSince1970: -2_208_988_800)
        let latest   = Date().addingTimeInterval(86_400)
        guard date >= earliest && date <= latest else { return nil }

        // Common camera "clock never set" default dates
        let cal = Calendar.current
        let y = cal.component(.year,  from: date)
        let m = cal.component(.month, from: date)
        let d = cal.component(.day,   from: date)
        let knownBogus: Set<String> = ["1970-1-1", "2001-1-1", "2000-1-1", "1980-1-1"]
        if knownBogus.contains("\(y)-\(m)-\(d)") { return nil }

        return date
    }

    private func coordinate(
        from gps: [String: Any],
        latKey: String, refKey: String, southOrWest: String
    ) -> Double? {
        guard let value = gps[latKey] as? Double else { return nil }
        let ref = gps[refKey] as? String ?? ""
        return ref.uppercased() == southOrWest ? -value : value
    }

    /// Chooses between an EXIF date and a filename-derived date.
    /// If the filename date is more than 90 days older than the EXIF date, we trust the
    /// filename — this is the common WhatsApp/Telegram scenario where forwarding an old
    /// photo resets the EXIF timestamp to "now".
    private func resolvedDate(exifDate: Date?, filenameDate: Date?) -> Date? {
        let safeEXIF = exifDate.flatMap(sanitize)
        let safeFilename = filenameDate.flatMap(sanitize)
        guard let fnDate = safeFilename else { return safeEXIF }
        guard let exif = safeEXIF else { return fnDate }
        let secondsOlder = exif.timeIntervalSince(fnDate)
        return secondsOlder > 90 * 24 * 3600 ? fnDate : exif
    }

    /// Try to extract a capture date from common filename patterns used by cameras and
    /// messaging apps (WhatsApp, Android, Telegram, iOS screenshots, etc.).
    private func parseDateFromFilename(_ filename: String) -> Date? {
        let name = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent

        // Each entry is (regexPattern, captureGroupIndex, dateFormat)
        let candidates: [(String, Int, String)] = [
            // WhatsApp / Telegram: IMG-20160908-WA0005 or VID-20160908-WA0005
            (#"(?:IMG|VID)-(\d{8})-WA\d+"#, 1, "yyyyMMdd"),
            // Android camera: IMG_20160908_143022 or VID_20160908_143022
            (#"(?:IMG|VID|PANO|BURST|MVIMG|PORTRAIT|SLOW)_(\d{8}_\d{6})"#, 1, "yyyyMMdd_HHmmss"),
            // Generic YYYYMMDD_HHmmss anywhere in the name
            (#"(?<!\d)(\d{8}_\d{6})(?!\d)"#, 1, "yyyyMMdd_HHmmss"),
            // Generic YYYYMMDD-HHmmss
            (#"(?<!\d)(\d{8}-\d{6})(?!\d)"#, 1, "yyyyMMdd-HHmmss"),
            // iOS screenshots: Screenshot 2016-09-08 at 14.30.22
            (#"(\d{4}-\d{2}-\d{2}) at (\d{2}\.\d{2}\.\d{2})"#, 0, "yyyy-MM-dd HH.mm.ss"),
            // Date only as last resort: YYYY-MM-DD
            (#"(?<!\d)(\d{4}-\d{2}-\d{2})(?!\d)"#, 1, "yyyy-MM-dd"),
        ]

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let lowerBound = Date(timeIntervalSince1970: -2_208_988_800) // 1900-01-01

        for (pattern, groupIndex, format) in candidates {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name))
            else { continue }

            let dateStr: String
            if groupIndex == 0 {
                // Special: combine group 1 + group 2
                guard match.numberOfRanges >= 3,
                      let r1 = Range(match.range(at: 1), in: name),
                      let r2 = Range(match.range(at: 2), in: name)
                else { continue }
                dateStr = String(name[r1]) + " " + String(name[r2])
            } else {
                guard match.numberOfRanges > groupIndex,
                      let r = Range(match.range(at: groupIndex), in: name)
                else { continue }
                dateStr = String(name[r])
            }

            f.dateFormat = format
            if let date = f.date(from: dateStr), date >= lowerBound, date <= Date() {
                return date
            }
        }
        return nil
    }

    /// Parse ISO 6709 location strings like "+37.3337-122.0087/"
    private func parseISO6709(_ str: String) -> (latitude: Double, longitude: Double)? {
        let clean = str.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        // Match ±DD.dddd±DDD.dddd
        let pattern = #"([+-]\d{2,3}\.\d+)([+-]\d{2,3}\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
              let r1 = Range(match.range(at: 1), in: clean),
              let r2 = Range(match.range(at: 2), in: clean),
              let lat = Double(clean[r1]),
              let lon = Double(clean[r2])
        else { return nil }
        return (lat, lon)
    }
}

// MARK: ─── MediaValidator ─────────────────────────────────────────────────────

/// Checks that a photo or video can really be opened before it goes into the
/// organized library. A file that can't is never deleted or skipped: Foldiq
/// sets it aside in Needs Review/Damaged Files so the person can look at it.
enum MediaValidator {
    static let folderName = "Damaged Files"

    /// Camera RAW formats change with every new camera, and a Mac that doesn't
    /// know a model yet can't decode it. Those files are only checked for
    /// being empty, so a perfectly good RAW is never called damaged.
    static let rawExtensions: Set<String> = [
        "raw", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
        "dng", "orf", "rw2", "pef", "srw", "raf", "3fr",
    ]

    /// Containers this Mac can't open itself; only checked for being empty.
    static let uncheckableVideoExtensions: Set<String> = [
        "avi", "mkv", "wmv", "flv", "webm", "mts", "m2ts", "ts",
    ]

    /// A short explanation when the file can't be opened, or nil when it's fine.
    static func problem(at url: URL, kind: MediaKind, fileSize: Int64) async -> String? {
        if fileSize == 0 { return "The file is empty (0 bytes)." }
        let ext = url.pathExtension.lowercased()
        switch kind {
        case .photo:
            guard !rawExtensions.contains(ext) else { return nil }
            return photoProblem(at: url)
        case .video:
            guard !uncheckableVideoExtensions.contains(ext) else { return nil }
            return await videoProblem(at: url)
        case .archive:
            return nil
        }
    }

    static func photoProblem(at url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg", jpegIsCutOff(url) {
            return "The photo is incomplete — the file looks cut off."
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0
        else {
            return "The photo can't be opened. It may be damaged, or not really an image."
        }

        // Decode a tiny version of the picture: reading the header alone
        // doesn't prove the image data behind it is intact.
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) != nil else {
            return "The photo's image data can't be read. It may be damaged."
        }
        return nil
    }

    static func videoProblem(at url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        do {
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            guard playable else {
                return "The video can't be played. It may be damaged."
            }
            guard duration.isValid, duration.seconds > 0 else {
                return "The video has no length — the file looks cut off."
            }
            return nil
        } catch {
            return "The video can't be opened. It may be damaged."
        }
    }

    /// A JPEG ends with an end-of-image marker (FF D9). A file that never
    /// reaches it was cut off — an interrupted copy or a failing card.
    static func jpegIsCutOff(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        // Not actually a JPEG: leave it to ImageIO.
        guard let head = try? handle.read(upToCount: 2), head == Data([0xFF, 0xD8]) else { return false }

        // The common case: the marker is the last thing in the file.
        guard let size = try? handle.seekToEnd(), size >= 4 else { return true }
        try? handle.seek(toOffset: size - 2)
        if let tail = try? handle.read(upToCount: 2), tail == Data([0xFF, 0xD9]) { return false }

        // Some cameras append data after the picture (motion photos add a video),
        // so look for the marker where the image data ends instead.
        try? handle.seek(toOffset: 0)
        guard let data = try? handle.readToEnd() else { return false }
        return !jpegContainsEndOfImage(data)
    }

    static func jpegContainsEndOfImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }

        // Skip the header segments (EXIF, thumbnail, colour profile…) by their
        // declared lengths: an embedded thumbnail has its own FF D9.
        var index = 2
        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF else { return false }
            let marker = bytes[index + 1]
            if marker == 0xFF { index += 1; continue }
            if marker == 0xD9 { return true }
            if marker == 0xDA { break }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { index += 2; continue }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2 else { return false }
            index += 2 + length
        }

        // Inside the image data FF is always followed by 00 or a restart
        // marker, so the first FF D9 is the real end of the picture.
        while index + 1 < bytes.count {
            if bytes[index] == 0xFF && bytes[index + 1] == 0xD9 { return true }
            index += 1
        }
        return false
    }
}
