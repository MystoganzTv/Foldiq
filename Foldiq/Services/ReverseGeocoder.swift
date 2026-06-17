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
