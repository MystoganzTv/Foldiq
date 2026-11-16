// GoogleTakeoutSidecar.swift
// Reads capture dates and GPS from Google Takeout sidecar files.
//
// Google Photos exports put the real capture time in a JSON file next to each
// photo. Its name has changed over the years and is truncated for long names:
//
//   IMG_1234.jpg.json                          (older exports)
//   IMG_1234.jpg.supplemental-metadata.json    (2024 and later)
//   IMG_1234.jpg.supplemental-metad.json       (truncated to ~51 characters)
//   IMG_1234.jpg(1).json                       (for IMG_1234(1).jpg)
//   IMG_1234.jpg.json                          (also used by IMG_1234-edited.jpg)
//
// Mirrors desktop/electron/services/takeout.js so both apps read the same exports
// the same way. Sidecars inside archives are indexed by their path inside the
// archive, so a photo and its JSON match even when Takeout split them across
// two ZIP files.

import Foundation

struct TakeoutSidecar: Equatable, Sendable {
    var date: Date?
    var latitude: Double?
    var longitude: Double?
    var title: String?
}

enum GoogleTakeout {

    static let maxSidecarBytes = 1_048_576
    /// Google truncates the JSON filename to 51 characters (46 before ".json").
    /// A truncated key is only trusted when it is long enough to have been cut.
    static let truncatedKeyMinimumLength = 40

    private static let numberSuffix = try! NSRegularExpression(pattern: #"^(.*?)(\(\d+\))$"#)
    private static let editedSuffix = try! NSRegularExpression(
        pattern: "-(?:edited|bearbeitet|modifié|modifie|editado|modificato|bewerkt)$",
        options: [.caseInsensitive]
    )

    static func isSidecar(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "json"
    }

    static func splitNumberSuffix(_ stem: String) -> (base: String, number: String) {
        let range = NSRange(stem.startIndex..., in: stem)
        guard let match = numberSuffix.firstMatch(in: stem, range: range),
              let baseRange = Range(match.range(at: 1), in: stem),
              let numberRange = Range(match.range(at: 2), in: stem)
        else { return (stem, "") }
        return (String(stem[baseRange]), String(stem[numberRange]))
    }

    static func removingEditedSuffix(_ stem: String) -> String {
        let range = NSRange(stem.startIndex..., in: stem)
        return editedSuffix.stringByReplacingMatches(in: stem, range: range, withTemplate: "")
    }

    /// Splits "IMG_1234-edited(1).jpg" into extension ".jpg", base "IMG_1234-edited",
    /// number "(1)" and original "IMG_1234".
    private static func nameParts(_ mediaName: String) -> (ext: String, base: String, number: String, original: String) {
        let name = mediaName as NSString
        let rawExtension = name.pathExtension
        let ext = rawExtension.isEmpty ? "" : "." + rawExtension
        let stem = rawExtension.isEmpty ? mediaName : name.deletingPathExtension
        let split = splitNumberSuffix(stem)
        return (ext, split.base, split.number, removingEditedSuffix(split.base))
    }

    /// Exact JSON filenames to try for a media file, most specific first (lowercase).
    static func candidateNames(for mediaName: String) -> [String] {
        let parts = nameParts(mediaName)
        var names: [String] = []
        func add(_ name: String) {
            let lower = name.lowercased()
            if !names.contains(lower) { names.append(lower) }
        }
        let stems = parts.original == parts.base ? [parts.base] : [parts.base, parts.original]
        for stem in stems {
            if !parts.number.isEmpty {
                add("\(stem)\(parts.ext).supplemental-metadata\(parts.number).json")
                add("\(stem)\(parts.ext)\(parts.number).json")
                add("\(stem)\(parts.number)\(parts.ext).json")
            }
            add("\(stem)\(parts.ext).supplemental-metadata.json")
            add("\(stem)\(parts.ext).json")
            add("\(stem).json")
        }
        return names
    }

    static func normalizedTitle(_ name: String) -> String {
        let parts = nameParts(name)
        return (parts.original + parts.ext).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Finds the sidecar for `mediaName` among `sidecars` (lowercase filename → URL).
    /// Truncated matches must be confirmed against the JSON title before use.
    static func match(mediaName: String, in sidecars: [String: URL]) -> (url: URL, truncated: Bool)? {
        for candidate in candidateNames(for: mediaName) {
            if let url = sidecars[candidate] { return (url, false) }
        }

        let parts = nameParts(mediaName)
        let targets = Set([parts.base, parts.original]).map {
            "\($0)\(parts.ext).supplemental-metadata".lowercased()
        }

        var best: (url: URL, keyLength: Int)?
        for (lowerName, url) in sidecars {
            guard lowerName.hasSuffix(".json") else { continue }
            let withoutJSON = String(lowerName.dropLast(".json".count))
            let split = splitNumberSuffix(withoutJSON)
            guard split.number.lowercased() == parts.number.lowercased() else { continue }
            let key = split.base
            guard key.count >= truncatedKeyMinimumLength,
                  targets.contains(where: { $0.hasPrefix(key) })
            else { continue }
            if best == nil || key.count > best!.keyLength {
                best = (url, key.count)
            }
        }
        guard let best else { return nil }
        return (best.url, true)
    }

    /// Parses the fields Foldiq uses from a Takeout JSON document.
    static func parse(_ data: Data, now: Date = Date()) -> TakeoutSidecar? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var sidecar = TakeoutSidecar()
        if let taken = object["photoTakenTime"] as? [String: Any] {
            sidecar.date = plausibleDate(taken["timestamp"], now: now)
        }
        if let location = coordinates(object["geoData"]) ?? coordinates(object["geoDataExif"]) {
            sidecar.latitude = location.latitude
            sidecar.longitude = location.longitude
        }
        sidecar.title = object["title"] as? String
        guard sidecar.date != nil || sidecar.latitude != nil else { return nil }
        return sidecar
    }

    static func read(_ url: URL) -> TakeoutSidecar? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= maxSidecarBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return parse(data)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let string as String: return Double(string)
        case let number as NSNumber: return number.doubleValue
        default: return nil
        }
    }

    private static func plausibleDate(_ value: Any?, now: Date) -> Date? {
        guard let seconds = number(value), seconds.isFinite, seconds > 0 else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        let earliest = Date(timeIntervalSince1970: -2_208_988_800)   // 1900-01-01
        guard date >= earliest, date <= now.addingTimeInterval(86_400) else { return nil }
        return date
    }

    private static func coordinates(_ value: Any?) -> (latitude: Double, longitude: Double)? {
        guard let geo = value as? [String: Any],
              let latitude = number(geo["latitude"]),
              let longitude = number(geo["longitude"]),
              latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180
        else { return nil }
        // Takeout writes 0.0 / 0.0 when a photo has no location.
        if latitude == 0 && longitude == 0 { return nil }
        return (latitude, longitude)
    }
}

// MARK: ─── Index ─────────────────────────────────────────────────────────────

/// Sidecars grouped by folder. Built once per scan; not thread-safe.
final class TakeoutSidecarIndex {

    private var directories: [String: [String: URL]] = [:]
    private var parsed: [URL: TakeoutSidecar] = [:]
    private var unreadable: Set<URL> = []

    var isEmpty: Bool { directories.isEmpty }
    var count: Int { directories.values.reduce(0) { $0 + $1.count } }

    static func directoryKey(for fileURL: URL, tempDirectory: URL?) -> String {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL.path
        if let tempDirectory {
            let root = tempDirectory.standardizedFileURL.path
            var relative = directory.hasPrefix(root) ? String(directory.dropFirst(root.count)) : directory
            while relative.hasPrefix("/") { relative.removeFirst() }
            return "archive:" + relative.precomposedStringWithCanonicalMapping.lowercased()
        }
        return "disk:" + directory.precomposedStringWithCanonicalMapping.lowercased()
    }

    func add(_ sidecarURL: URL, tempDirectory: URL? = nil) {
        let key = Self.directoryKey(for: sidecarURL, tempDirectory: tempDirectory)
        let name = sidecarURL.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        // Keep the first copy when the same relative path appears in two archives.
        if directories[key]?[name] == nil {
            directories[key, default: [:]][name] = sidecarURL
        }
    }

    func lookup(mediaURL: URL, tempDirectory: URL?) -> TakeoutSidecar? {
        let key = Self.directoryKey(for: mediaURL, tempDirectory: tempDirectory)
        guard let sidecars = directories[key], !sidecars.isEmpty else { return nil }
        let mediaName = mediaURL.lastPathComponent.precomposedStringWithCanonicalMapping
        guard let match = GoogleTakeout.match(mediaName: mediaName, in: sidecars) else { return nil }

        let sidecar: TakeoutSidecar
        if let cached = parsed[match.url] {
            sidecar = cached
        } else if unreadable.contains(match.url) {
            return nil
        } else if let read = GoogleTakeout.read(match.url) {
            parsed[match.url] = read
            sidecar = read
        } else {
            unreadable.insert(match.url)
            return nil
        }

        if match.truncated {
            guard let title = sidecar.title,
                  GoogleTakeout.normalizedTitle(title) == GoogleTakeout.normalizedTitle(mediaName)
            else { return nil }
        }
        return sidecar
    }

    /// Indexes every JSON file in the folders that hold the scanned media, plus
    /// every JSON file extracted from an archive.
    static func build(for discovered: [DiscoveredFile]) -> TakeoutSidecarIndex {
        let index = TakeoutSidecarIndex()
        let fm = FileManager.default

        let folders = Set(discovered.filter { $0.tempDirectoryURL == nil }
            .map { $0.url.deletingLastPathComponent().standardizedFileURL })
        for folder in folders {
            guard let contents = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents where GoogleTakeout.isSidecar(url) {
                index.add(url)
            }
        }

        let tempDirectories = Set(discovered.compactMap { $0.tempDirectoryURL?.standardizedFileURL })
        for tempDirectory in tempDirectories {
            guard let enumerator = fm.enumerator(
                at: tempDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where GoogleTakeout.isSidecar(url) {
                index.add(url, tempDirectory: tempDirectory)
            }
        }
        return index
    }
}

// MARK: ─── Applying a sidecar ────────────────────────────────────────────────

extension ExtractedMetadata {
    /// Fills in what the file itself does not provide. Embedded camera or video
    /// dates always win; the sidecar beats a date guessed from the filename.
    /// Returns true when the sidecar supplied the capture date.
    @discardableResult
    mutating func apply(_ sidecar: TakeoutSidecar) -> Bool {
        var usedDate = false
        if !hasEmbeddedDate, let date = sidecar.date {
            dateTaken = date
            usedDate = true
        }
        if latitude == nil || longitude == nil,
           let sidecarLatitude = sidecar.latitude,
           let sidecarLongitude = sidecar.longitude {
            latitude = sidecarLatitude
            longitude = sidecarLongitude
        }
        return usedDate
    }
}
