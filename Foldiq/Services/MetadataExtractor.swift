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
}

// MARK: ─── MetadataExtractor ──────────────────────────────────────────────────

/// Stateless service; create once and call extract(from:kind:) concurrently.
final class MetadataExtractor: Sendable {

    // MARK: Public

    func extract(from url: URL, kind: MediaKind) -> ExtractedMetadata {
        switch kind {
        case .photo:   return extractPhoto(url)
        case .video:   return extractVideo(url)
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

        // Pixel dimensions
        meta.pixelWidth  = props[kCGImagePropertyPixelWidth  as String] as? Int
        meta.pixelHeight = props[kCGImagePropertyPixelHeight as String] as? Int

        // EXIF
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            meta.dateTaken = parseEXIFDate(
                exif[kCGImagePropertyExifDateTimeOriginal  as String] as? String ??
                exif[kCGImagePropertyExifDateTimeDigitized as String] as? String
            )
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
        meta.dateTaken = resolvedDate(exifDate: meta.dateTaken,
                                      filenameDate: parseDateFromFilename(url.lastPathComponent))

        return meta
    }

    // MARK: ─── Video ──────────────────────────────────────────────────────────

    private func extractVideo(_ url: URL) -> ExtractedMetadata {
        var meta = ExtractedMetadata()

        let asset = AVURLAsset(url: url)

        // Duration (synchronous — OK for background threads)
        let duration = asset.duration
        if duration.isValid && !duration.isIndefinite {
            meta.durationSeconds = CMTimeGetSeconds(duration)
        }

        // Common metadata (creation date, location)
        for item in asset.commonMetadata {
            switch item.commonKey {
            case .commonKeyCreationDate:
                if let str = item.stringValue {
                    meta.dateTaken = ISO8601DateFormatter().date(from: str)
                } else if let date = item.dateValue {
                    meta.dateTaken = date
                }
            case .commonKeyLocation:
                if let str = item.stringValue,
                   let loc = parseISO6709(str) {
                    meta.latitude  = loc.latitude
                    meta.longitude = loc.longitude
                }
            default:
                break
            }
        }

        meta.dateTaken = resolvedDate(exifDate: meta.dateTaken,
                                      filenameDate: parseDateFromFilename(url.lastPathComponent))

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
        // Valid range: 1990-01-02 to 1 day from now (1 day slack for timezone edge cases)
        let earliest = Date(timeIntervalSince1970: 631_238_400) // 1990-01-02
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
        guard let fnDate = filenameDate else { return exifDate }
        guard let exif = exifDate else { return fnDate }
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
        let lowerBound = Date(timeIntervalSince1970: 631152000) // 1990-01-01

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
