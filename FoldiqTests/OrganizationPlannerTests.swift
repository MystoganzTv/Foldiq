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

    func testMissingZipRootPlacesOutputBesideArchive() {
        var config = OrganizationConfig()
        config.outputFolderName = "Sorted Library"

        let output = config.outputRoot(
            forSelectedRoot: URL(fileURLWithPath: "/Users/tester/Imports/photos.zip")
        )

        XCTAssertEqual(output.path, "/Users/tester/Imports/Sorted Library")
    }

    func testSelectingNamedOutputFolderDoesNotNestDuplicateFolder() {
        var config = OrganizationConfig()
        config.outputFolderName = "Organized Media"
        config.customOutputParentPath = "/Users/tester/Desktop/Organized Media"

        let output = config.outputRoot(
            forSelectedRoot: URL(fileURLWithPath: "/Users/tester/Imports/photos.zip")
        )

        XCTAssertEqual(output.path, "/Users/tester/Desktop/Organized Media")
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

    func testReviewOnlySimilarPhotoStaysInNormalOrganization() async {
        let similar = makePhoto(
            path: "/Users/tester/Photos/BURST.JPG",
            filename: "BURST.JPG",
            date: isoDate("2026-01-04")
        )
        similar.probableDuplicateGroupID = UUID()
        similar.probableMatchScore = 84
        similar.isProbableDuplicate = false

        let session = makeSession(rootPath: "/Users/tester/Photos", files: [similar])
        var config = OrganizationConfig()
        config.mode = .byYear
        config.separateDuplicates = true

        let plans = await OrganizationPlanner().buildPlan(session: session, config: config) { _ in }

        XCTAssertEqual(plans.count, 1)
        XCTAssertFalse(plans[0].destinationAbsPath.contains("/Duplicates/"))
        XCTAssertTrue(plans[0].destinationAbsPath.contains("/2026/"))
    }

    func testUserSetAsidePhotoAlwaysUsesSafeReviewFolder() async {
        let similar = makePhoto(
            path: "/Users/tester/Photos/BURST_2.JPG",
            filename: "BURST_2.JPG",
            date: isoDate("2026-01-04")
        )
        similar.isUserSetAside = true

        let session = makeSession(rootPath: "/Users/tester/Photos", files: [similar])
        var config = OrganizationConfig()
        config.separateDuplicates = false

        let plans = await OrganizationPlanner().buildPlan(session: session, config: config) { _ in }

        XCTAssertEqual(
            plans[0].destinationAbsPath,
            "/Users/tester/Photos/Organized Media/Duplicates/To Review/BURST_2.JPG"
        )
    }

    func testUserExcludedComparisonGroupStaysUntouched() async {
        let photo = makePhoto(
            path: "/Users/tester/Photos/KEEP_HERE.JPG",
            filename: "KEEP_HERE.JPG",
            date: isoDate("2026-01-04")
        )
        photo.isUserExcluded = true

        let session = makeSession(rootPath: "/Users/tester/Photos", files: [photo])
        let plans = await OrganizationPlanner().buildPlan(
            session: session,
            config: OrganizationConfig()
        ) { _ in }

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].status, .skipped)
    }

    // MARK: - Review prompt policy

    func testReviewPromptIgnoresRunsThatOrganizedNothing() {
        withCleanDefaults { defaults in
            XCTAssertFalse(
                AppReviewPromptPolicy.shouldRequestAfterSuccessfulOrganization(
                    successfulItemCount: 0,
                    defaults: defaults
                )
            )
        }
    }

    func testReviewPromptWaitsForASecondSuccessfulOrganization() {
        withCleanDefaults { defaults in
            let day0 = Date(timeIntervalSince1970: 1_700_000_000)

            // The very first run is the worst possible moment to ask: the person
            // has just moved thousands of files and has not checked them yet.
            XCTAssertFalse(
                AppReviewPromptPolicy.shouldRequestAfterSuccessfulOrganization(
                    successfulItemCount: 400,
                    defaults: defaults,
                    now: day0
                )
            )
            XCTAssertTrue(
                AppReviewPromptPolicy.shouldRequestAfterSuccessfulOrganization(
                    successfulItemCount: 400,
                    defaults: defaults,
                    now: day0.addingTimeInterval(86_400)
                )
            )
        }
    }

    func testReviewPromptIgnoresTinyTrialRuns() {
        withCleanDefaults { defaults in
            let day0 = Date(timeIntervalSince1970: 1_700_000_000)

            // Two runs, but only three files total — nothing was proven yet.
            for offset in 0..<2 {
                XCTAssertFalse(
                    AppReviewPromptPolicy.shouldRequestAfterSuccessfulOrganization(
                        successfulItemCount: 3,
                        defaults: defaults,
                        now: day0.addingTimeInterval(Double(offset) * 86_400)
                    )
                )
            }
        }
    }

    func testReviewPromptSpacesAttemptsAndKeepsThreePerYear() {
        withCleanDefaults { defaults in
            let day0 = Date(timeIntervalSince1970: 1_700_000_000)
            func run(onDay day: Double) -> Bool {
                AppReviewPromptPolicy.shouldRequestAfterSuccessfulOrganization(
                    successfulItemCount: 100,
                    defaults: defaults,
                    now: day0.addingTimeInterval(day * 86_400)
                )
            }

            XCTAssertFalse(run(onDay: 0))    // first success, not eligible yet
            XCTAssertTrue(run(onDay: 1))     // attempt 1
            XCTAssertFalse(run(onDay: 10))   // too soon after attempt 1
            XCTAssertTrue(run(onDay: 50))    // attempt 2
            XCTAssertTrue(run(onDay: 120))   // attempt 3
            XCTAssertFalse(run(onDay: 200))  // yearly budget spent
            XCTAssertTrue(run(onDay: 380))   // attempt 1 has aged out of the year
        }
    }

    /// The bug this policy was written to fix: `requestReview()` can be silently
    /// refused by StoreKit, and the old code treated that as "already asked",
    /// permanently. Anyone carrying the old flag gets their chances back.
    func testLegacySingleRequestFlagBecomesOneSpentAttemptRatherThanASilentBan() {
        withCleanDefaults { defaults in
            defaults.set(true, forKey: "hasRequestedReviewAfterSuccessfulOrganization")
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            XCTAssertTrue(
                AppReviewPromptPolicy.shouldRequestAfterSuccessfulOrganization(
                    successfulItemCount: 300,
                    defaults: defaults,
                    now: now
                )
            )
            XCTAssertNil(defaults.object(forKey: "hasRequestedReviewAfterSuccessfulOrganization"))
        }
    }

    func testManualInviteStaysQuietWhileApplesOwnDialogIsStillFresh() {
        withCleanDefaults { defaults in
            let day0 = Date(timeIntervalSince1970: 1_700_000_000)
            _ = AppReviewPromptPolicy.shouldRequestAfterSuccessfulOrganization(
                successfulItemCount: 300, defaults: defaults, now: day0
            )
            XCTAssertTrue(
                AppReviewPromptPolicy.shouldRequestAfterSuccessfulOrganization(
                    successfulItemCount: 300,
                    defaults: defaults,
                    now: day0.addingTimeInterval(86_400)
                )
            )

            // StoreKit was just asked — do not stack a second ask on top of it.
            XCTAssertFalse(
                ManualRatingInvitePolicy.shouldShowInvite(
                    defaults: defaults,
                    now: day0.addingTimeInterval(2 * 86_400)
                )
            )
            XCTAssertTrue(
                ManualRatingInvitePolicy.shouldShowInvite(
                    defaults: defaults,
                    now: day0.addingTimeInterval(20 * 86_400)
                )
            )
        }
    }

    func testManualInviteTreatsNotNowAsNotNowAndNotNever() {
        withCleanDefaults { defaults in
            let day0 = Date(timeIntervalSince1970: 1_700_000_000)
            _ = AppReviewPromptPolicy.shouldRequestAfterSuccessfulOrganization(
                successfulItemCount: 300, defaults: defaults, now: day0
            )

            let afterTheDialogCoolsOff = day0.addingTimeInterval(30 * 86_400)
            XCTAssertTrue(ManualRatingInvitePolicy.shouldShowInvite(defaults: defaults, now: afterTheDialogCoolsOff))

            ManualRatingInvitePolicy.recordDismissal(defaults: defaults, now: afterTheDialogCoolsOff)
            XCTAssertFalse(
                ManualRatingInvitePolicy.shouldShowInvite(
                    defaults: defaults,
                    now: afterTheDialogCoolsOff.addingTimeInterval(10 * 86_400)
                )
            )
            XCTAssertTrue(
                ManualRatingInvitePolicy.shouldShowInvite(
                    defaults: defaults,
                    now: afterTheDialogCoolsOff.addingTimeInterval(61 * 86_400)
                )
            )
        }
    }

    func testManualInviteStopsOnceSomeoneOpensTheReviewComposer() {
        withCleanDefaults { defaults in
            let day0 = Date(timeIntervalSince1970: 1_700_000_000)
            _ = AppReviewPromptPolicy.shouldRequestAfterSuccessfulOrganization(
                successfulItemCount: 300, defaults: defaults, now: day0
            )

            ManualRatingInvitePolicy.recordReviewComposerOpened(defaults: defaults)
            XCTAssertFalse(
                ManualRatingInvitePolicy.shouldShowInvite(
                    defaults: defaults,
                    now: day0.addingTimeInterval(400 * 86_400)
                )
            )
        }
    }

    func testWriteReviewLinkOpensTheReviewComposerDirectly() {
        XCTAssertEqual(
            AppStoreLinks.writeReview.absoluteString,
            "https://apps.apple.com/app/id6772513569?action=write-review"
        )
    }

    private func withCleanDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "AppReviewPromptPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
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

// These lived inside isoDate() by mistake: as local functions XCTest never ran
// them, and addTeardownBlock had no test case to belong to.
extension OrganizationPlannerTests {
    func testWebUpdateComparesVersionsNumerically() {
        XCTAssertTrue(WebUpdateChecker.isNewer("2.0", than: "1.0.22"))
        XCTAssertTrue(WebUpdateChecker.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertFalse(WebUpdateChecker.isNewer("1.0.22", than: "1.0.22"))
        XCTAssertFalse(WebUpdateChecker.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(WebUpdateChecker.isNewer("1.0.9", than: "1.0.10"))
    }

    // MARK: - Big libraries

    func testThousandsOfSameNamedFilesGetConsecutiveSuffixes() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Foldiq-Collisions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        // A file already on disk takes its name too.
        try Data().write(to: folder.appendingPathComponent("IMG_0001_3.JPG"))

        let name = folder.appendingPathComponent("IMG_0001.JPG")
        var reserved = Set<String>()
        var nextSuffix: [String: Int] = [:]
        var names: [String] = []
        for _ in 0..<2_000 {
            let url = OrganizationPlanner.resolveCollision(name, reserved: &reserved, nextSuffix: &nextSuffix)
            reserved.insert(url.path)
            names.append(url.lastPathComponent)
        }

        XCTAssertEqual(Set(names).count, 2_000)
        XCTAssertEqual(Array(names.prefix(5)), [
            "IMG_0001.JPG", "IMG_0001_1.JPG", "IMG_0001_2.JPG", "IMG_0001_4.JPG", "IMG_0001_5.JPG",
        ])
        XCTAssertEqual(names.last, "IMG_0001_2000.JPG")
    }

    func testDifferentNamesKeepTheirOwnSuffixes() {
        let folder = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        var reserved = Set<String>()
        var nextSuffix: [String: Int] = [:]
        func plan(_ name: String) -> String {
            let url = OrganizationPlanner.resolveCollision(
                folder.appendingPathComponent(name), reserved: &reserved, nextSuffix: &nextSuffix
            )
            reserved.insert(url.path)
            return url.lastPathComponent
        }

        XCTAssertEqual(plan("a.jpg"), "a.jpg")
        XCTAssertEqual(plan("b.jpg"), "b.jpg")
        XCTAssertEqual(plan("a.jpg"), "a_1.jpg")
        XCTAssertEqual(plan("b.jpg"), "b_1.jpg")
        XCTAssertEqual(plan("a.jpg"), "a_2.jpg")
        XCTAssertEqual(plan("video"), "video")
        XCTAssertEqual(plan("video"), "video_1")
    }
}
