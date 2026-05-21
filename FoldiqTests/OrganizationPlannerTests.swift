import XCTest
@testable import Foldiq

final class OrganizationPlannerTests: XCTestCase {

    func testReverseGeocoderParsesTopLevelThrottleResetInterval() {
        let error = NSError(
            domain: "GEOErrorDomain",
            code: -3,
            userInfo: ["timeUntilReset": 55]
        )

        XCTAssertEqual(ReverseGeocoder.throttleResetInterval(from: error), 55)
    }

    func testReverseGeocoderParsesNestedThrottleResetInterval() {
        let error = NSError(
            domain: "GEOErrorDomain",
            code: -3,
            userInfo: [
                "details": [
                    [
                        "timeUntilReset": 42,
                        "maxRequests": 50
                    ]
                ]
            ]
        )

        XCTAssertEqual(ReverseGeocoder.throttleResetInterval(from: error), 42)
    }

    func testByYearMonthUsesCustomOutputParentPath() async {
        let session = makeSession(
            rootPath: "/Users/tester/Photos",
            files: [
                makePhoto(
                    path: "/Users/tester/Photos/IMG_0001.JPG",
                    filename: "IMG_0001.JPG",
                    date: isoDate("2026-05-18")
                )
            ]
        )

        var config = OrganizationConfig()
        config.mode = .byYearMonth
        config.outputFolderName = "Sorted Library"
        config.customOutputParentPath = "/Volumes/Archive"

        let plans = await OrganizationPlanner().buildPlan(session: session, config: config) { _ in }

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(
            plans[0].destinationAbsPath,
            "/Volumes/Archive/Sorted Library/2026/2026-05 May/IMG_0001.JPG"
        )
    }

    func testByLocationUsesGeocodedHierarchyWhenGPSIsAvailable() async {
        let session = makeSession(
            rootPath: "/Users/tester/Photos",
            files: [
                makePhoto(
                    path: "/Users/tester/Photos/IMG_1000.HEIC",
                    filename: "IMG_1000.HEIC",
                    date: isoDate("2025-08-14"),
                    latitude: 40.0,
                    longitude: -3.7
                )
            ]
        )

        var config = OrganizationConfig()
        config.mode = .byLocation

        let planner = OrganizationPlanner(
            geocoder: StubGeocoder(
                result: .init(country: "Spain", state: "Madrid", city: "Madrid")
            )
        )
        let plans = await planner.buildPlan(session: session, config: config) { _ in }

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(
            plans[0].destinationAbsPath,
            "/Users/tester/Photos/Organized Media/Spain/Madrid/Madrid/IMG_1000.HEIC"
        )
    }

    func testByLocationSendsFilesWithoutGPSIntoUnknownLocation() async {
        let session = makeSession(
            rootPath: "/Users/tester/Photos",
            files: [
                makePhoto(
                    path: "/Users/tester/Photos/IMG_2000.JPG",
                    filename: "IMG_2000.JPG",
                    date: isoDate("2024-02-03")
                )
            ]
        )

        var config = OrganizationConfig()
        config.mode = .byLocation

        let plans = await OrganizationPlanner().buildPlan(session: session, config: config) { _ in }

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(
            plans[0].destinationAbsPath,
            "/Users/tester/Photos/Organized Media/Unknown Location/2024/IMG_2000.JPG"
        )
    }

    func testByLocationPlacesUnknownDateScreenshotsUnderUnknownLocation() async {
        let screenshot = makePhoto(
            path: "/Users/tester/Photos/Screenshot.png",
            filename: "Screenshot.png",
            date: nil
        )
        screenshot.isScreenshot = true

        let session = makeSession(
            rootPath: "/Users/tester/Photos",
            files: [screenshot]
        )

        var config = OrganizationConfig()
        config.mode = .byLocation

        let plans = await OrganizationPlanner().buildPlan(session: session, config: config) { _ in }

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(
            plans[0].destinationAbsPath,
            "/Users/tester/Photos/Organized Media/Unknown Location/Unknown Year/Screenshots/Screenshot.png"
        )
    }

    func testByLocationFallsBackToUnknownLocationWhenGeocoderReturnsNoComponents() async {
        let session = makeSession(
            rootPath: "/Users/tester/Photos",
            files: [
                makePhoto(
                    path: "/Users/tester/Photos/IMG_3000.JPG",
                    filename: "IMG_3000.JPG",
                    date: isoDate("2023-11-08"),
                    latitude: 1.0,
                    longitude: 2.0
                )
            ]
        )

        var config = OrganizationConfig()
        config.mode = .byLocation

        let planner = OrganizationPlanner(
            geocoder: StubGeocoder(result: .init(country: nil, state: nil, city: nil))
        )
        let plans = await planner.buildPlan(session: session, config: config) { _ in }

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(
            plans[0].destinationAbsPath,
            "/Users/tester/Photos/Organized Media/Unknown Location/2023/IMG_3000.JPG"
        )
    }

    func testDuplicatesStayInDedicatedReviewBuckets() async {
        let duplicate = makePhoto(
            path: "/Users/tester/Photos/IMG_DUP.JPG",
            filename: "IMG_DUP.JPG",
            date: isoDate("2026-01-04")
        )
        duplicate.isDuplicate = true

        let session = makeSession(
            rootPath: "/Users/tester/Photos",
            files: [duplicate]
        )

        var config = OrganizationConfig()
        config.mode = .byLocation
        config.separateDuplicates = true

        let plans = await OrganizationPlanner().buildPlan(session: session, config: config) { _ in }

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(
            plans[0].destinationAbsPath,
            "/Users/tester/Photos/Organized Media/Duplicates/Exact Duplicates/IMG_DUP.JPG"
        )
    }
}

private struct StubGeocoder: LocationGeocoding {
    let result: ReverseGeocoder.GeocodedLocation

    func geocode(latitude: Double, longitude: Double) async -> ReverseGeocoder.GeocodedLocation {
        result
    }
}

private func makeSession(rootPath: String, files: [MediaFile]) -> ScanSession {
    let session = ScanSession(rootPath: rootPath)
    session.files = files
    for file in files {
        file.session = session
    }
    return session
}

private func makePhoto(
    path: String,
    filename: String,
    date: Date?,
    latitude: Double? = nil,
    longitude: Double? = nil
) -> MediaFile {
    let file = MediaFile(
        filePath: path,
        filename: filename,
        ext: URL(fileURLWithPath: filename).pathExtension,
        kind: .photo,
        fileSize: 1_024
    )
    file.dateTaken = date
    file.latitude = latitude
    file.longitude = longitude
    return file
}

private func isoDate(_ value: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)!
}
