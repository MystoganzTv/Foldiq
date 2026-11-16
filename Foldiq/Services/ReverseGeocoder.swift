// ReverseGeocoder.swift
// Converts GPS latitude/longitude to human-readable location strings
// using Apple's CLGeocoder. Results are cached to minimise network calls.

import Foundation
import CoreLocation

protocol LocationGeocoding: Sendable {
    func geocode(latitude: Double, longitude: Double) async -> ReverseGeocoder.GeocodedLocation
}

actor ReverseGeocoder: LocationGeocoding {

    // MARK: - Cache
    // Key: "lat,lon" rounded to 2 decimal places (≈ 1 km precision).
    private var cache: [String: GeocodedLocation] = [:]
    private let geocoder = CLGeocoder()
    private var throttledUntil: Date?

    // MARK: - Public

    struct GeocodedLocation {
        var country: String?
        var state: String?
        var city: String?

        /// Folder-safe joined string, e.g. "United States/Virginia/Herndon"
        var folderComponents: [String] {
            [country, state, city].compactMap { $0?.folderSafe }
        }
    }

    func geocode(latitude: Double, longitude: Double) async -> GeocodedLocation {
        let key = cacheKey(latitude, longitude)
        if let cached = cache[key] { return cached }
        if let throttledUntil, throttledUntil > Date() {
            let empty = GeocodedLocation()
            cache[key] = empty
            return empty
        }

        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let pm = placemarks.first else {
                let empty = GeocodedLocation()
                cache[key] = empty
                return empty
            }
            let result = GeocodedLocation(
                country: pm.country,
                state:   pm.administrativeArea,
                city:    pm.locality ?? pm.subLocality
            )
            throttledUntil = nil
            cache[key] = result
            return result
        } catch {
            if let resetInterval = Self.throttleResetInterval(from: error) {
                throttledUntil = Date().addingTimeInterval(resetInterval)
            }

            // Network unavailable, rate-limited, etc. Return empty gracefully.
            let empty = GeocodedLocation()
            cache[key] = empty
            return empty
        }
    }

    // MARK: - Private

    private func cacheKey(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.2f,%.2f", lat, lon)
    }

    nonisolated static func throttleResetInterval(from error: Error) -> TimeInterval? {
        let nsError = error as NSError

        if let reset = nsError.userInfo["timeUntilReset"] as? NSNumber {
            return reset.doubleValue
        }

        if let details = nsError.userInfo["details"] as? [[String: Any]] {
            for detail in details {
                if let reset = detail["timeUntilReset"] as? NSNumber {
                    return reset.doubleValue
                }
                if let reset = detail["timeUntilReset"] as? Double {
                    return reset
                }
                if let reset = detail["timeUntilReset"] as? Int {
                    return TimeInterval(reset)
                }
            }
        }

        return nil
    }
}

// MARK: - String helper

extension String {
    /// Replace characters not safe in folder/file names with underscores.
    /// Canonical definition shared across the app (used here and by the exporter).
    var folderSafe: String {
        let illegal = CharacterSet(charactersIn: ":/\\?*|\"<>")
        return components(separatedBy: illegal).joined(separator: "_")
    }
}

// MARK: ─── Location recovery ──────────────────────────────────────────────────

/// Suggests a place for photos and videos without GPS, taken from the closest
/// item in time that has one — typically a camera without GPS used alongside
/// a phone. Nothing is applied on its own: the person reviews every suggestion,
/// and files are never changed (the place only shapes folder names).
enum LocationRecovery {
    struct Point: Sendable {
        let id: UUID
        let date: Date
        let filename: String
        let camera: String?
        let latitude: Double?
        let longitude: Double?
    }

    struct Suggestion: Identifiable, Sendable, Equatable {
        let fileID: UUID
        let latitude: Double
        let longitude: Double
        let sourceFilename: String
        let minutesApart: Int
        var id: UUID { fileID }
    }

    /// How far apart in time two items can be and still share a place.
    static let window: TimeInterval = 2 * 60 * 60
    /// When the closest items before and after are this far apart, the person
    /// was on the move, and only a very close match in time is trusted.
    static let travellingDistance: CLLocationDistance = 25_000
    static let closeEnoughWhileTravelling: TimeInterval = 20 * 60

    static func suggestions(missing: [Point], known: [Point]) -> [Suggestion] {
        let located = known
            .filter { $0.latitude != nil && $0.longitude != nil }
            .sorted { $0.date < $1.date }
        guard !located.isEmpty else { return [] }
        let dates = located.map(\.date)

        return missing.compactMap { item -> Suggestion? in
            // The first located item taken at or after this one.
            var low = 0
            var high = dates.count
            while low < high {
                let middle = (low + high) / 2
                if dates[middle] < item.date { low = middle + 1 } else { high = middle }
            }
            let before = low > 0 ? located[low - 1] : nil
            let after = low < located.count ? located[low] : nil

            let candidates = [before, after]
                .compactMap { $0 }
                .filter { abs($0.date.timeIntervalSince(item.date)) <= window }
            guard let best = candidates.min(by: { lhs, rhs in
                let lhsGap = abs(lhs.date.timeIntervalSince(item.date))
                let rhsGap = abs(rhs.date.timeIntervalSince(item.date))
                if lhsGap != rhsGap { return lhsGap < rhsGap }
                return lhs.camera == item.camera && rhs.camera != item.camera
            }) else { return nil }

            let gap = abs(best.date.timeIntervalSince(item.date))
            if candidates.count == 2, let before, let after,
               distance(before, after) > travellingDistance,
               gap > closeEnoughWhileTravelling {
                return nil
            }

            return Suggestion(
                fileID: item.id,
                latitude: best.latitude ?? 0,
                longitude: best.longitude ?? 0,
                sourceFilename: best.filename,
                minutesApart: Int((gap / 60).rounded())
            )
        }
    }

    /// Photos and videos with a date and no GPS that are worth a place
    /// (screenshots and damaged files aren't), and the items that have one.
    static func points(from files: [MediaFile]) -> (missing: [Point], known: [Point]) {
        var missing: [Point] = []
        var known: [Point] = []
        for file in files where file.mediaKind != .archive && file.damageReason == nil {
            guard let date = file.bestDate else { continue }
            let point = Point(
                id: file.id,
                date: date,
                filename: file.filename,
                camera: file.cameraModel,
                latitude: file.latitude,
                longitude: file.longitude
            )
            if file.hasGPS {
                known.append(point)
            } else if !file.isScreenshot {
                missing.append(point)
            }
        }
        return (missing, known)
    }

    private static func distance(_ first: Point, _ second: Point) -> CLLocationDistance {
        guard let lat1 = first.latitude, let lon1 = first.longitude,
              let lat2 = second.latitude, let lon2 = second.longitude else { return 0 }
        return CLLocation(latitude: lat1, longitude: lon1)
            .distance(from: CLLocation(latitude: lat2, longitude: lon2))
    }
}
