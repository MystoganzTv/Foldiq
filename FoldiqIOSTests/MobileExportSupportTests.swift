import XCTest
@testable import Foldiq

final class MobileExportSupportTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var sampleDate: Date {
        DateComponents(
            calendar: utcCalendar,
            timeZone: utcCalendar.timeZone,
            year: 2026,
            month: 5,
            day: 18,
            hour: 12
        ).date!
    }

    func testSmartHybridMatchesDesktopFolderConvention() {
        let folder = MobileExportPlanner.relativeFolder(
            date: sampleDate,
            mode: .smartHybrid,
            includeLocation: true,
            locationComponents: ["United States", "VA", "Herndon"],
            calendar: utcCalendar
        )

        XCTAssertEqual(folder, "2026/2026-05 May/2026-05-18 Herndon VA")
    }

    func testAllOrganizationModesHaveStablePaths() {
        XCTAssertEqual(
            MobileExportPlanner.relativeFolder(
                date: sampleDate,
                mode: .byYear,
                includeLocation: false,
                locationComponents: [],
                calendar: utcCalendar
            ),
            "2026"
        )
        XCTAssertEqual(
            MobileExportPlanner.relativeFolder(
                date: sampleDate,
                mode: .byYearMonth,
                includeLocation: false,
                locationComponents: [],
                calendar: utcCalendar
            ),
            "2026/2026-05 May"
        )
        XCTAssertEqual(
            MobileExportPlanner.relativeFolder(
                date: sampleDate,
                mode: .byExactDate,
                includeLocation: false,
                locationComponents: [],
                calendar: utcCalendar
            ),
            "2026/2026-05 May/2026-05-18"
        )
        XCTAssertEqual(
            MobileExportPlanner.relativeFolder(
                date: sampleDate,
                mode: .byLocation,
                includeLocation: true,
                locationComponents: ["United States", "VA", "Herndon"],
                calendar: utcCalendar
            ),
            "United States/VA/Herndon"
        )
    }

    func testUnknownMetadataUsesExplicitReviewFolders() {
        XCTAssertEqual(
            MobileExportPlanner.relativeFolder(
                date: nil,
                mode: .smartHybrid,
                includeLocation: true,
                locationComponents: [],
                calendar: utcCalendar
            ),
            "Unknown Date"
        )
        XCTAssertEqual(
            MobileExportPlanner.relativeFolder(
                date: sampleDate,
                mode: .byLocation,
                includeLocation: true,
                locationComponents: [],
                calendar: utcCalendar
            ),
            "Unknown Location/2026"
        )
    }

    func testCollisionPlannerNeverReusesExistingOrReservedPaths() {
        let root = URL(fileURLWithPath: "/exports")
        let intended = root.appendingPathComponent("IMG_0001.HEIC")
        var reserved: Set<String> = [root.appendingPathComponent("IMG_0001_1.HEIC").path]

        let result = MobileExportPlanner.collisionSafeURL(
            for: intended,
            reserved: &reserved,
            exists: { $0 == intended.path }
        )

        XCTAssertEqual(result.lastPathComponent, "IMG_0001_2.HEIC")
        XCTAssertTrue(reserved.contains(result.path))
    }

    func testCSVReportEscapesUserControlledMetadata() {
        let row = MobileExportReportRow(
            filename: "vacation, \"best\".jpg",
            kind: "photo",
            capturedAt: sampleDate,
            relativePath: "2026/vacation, \"best\".jpg",
            status: .failed,
            detail: "Cloud unavailable\nTry again"
        )

        let csv = MobileExportPlanner.buildCSV(rows: [row])

        XCTAssertTrue(csv.hasPrefix("filename,type,captured_at,destination,status,detail\n"))
        XCTAssertTrue(csv.contains("\"vacation, \"\"best\"\".jpg\""))
        XCTAssertTrue(csv.contains("\"Cloud unavailable\nTry again\""))
    }

    func testRelativePathCannotExposeDestinationParent() {
        let root = URL(fileURLWithPath: "/private/export/Foldiq Export")
        let inside = root.appendingPathComponent("2026/IMG.jpg")
        let outside = URL(fileURLWithPath: "/private/other/IMG.jpg")

        XCTAssertEqual(MobileExportPlanner.relativePath(of: inside, from: root), "2026/IMG.jpg")
        XCTAssertEqual(MobileExportPlanner.relativePath(of: outside, from: root), "IMG.jpg")
    }

    func testOutputFolderNameCannotEscapeSelectedDestination() {
        XCTAssertEqual(MobileExportPlanner.safeOutputFolderName("../"), "Foldiq Export")
        XCTAssertEqual(MobileExportPlanner.safeOutputFolderName("  Family: 2026  "), "Family_ 2026")
        XCTAssertFalse(MobileExportPlanner.safeOutputFolderName("\u{0}Photos").contains("\u{0}"))
    }

    func testManifestPathsMustRemainInsideExportRoot() {
        let root = URL(fileURLWithPath: "/private/export/Foldiq Export")

        XCTAssertEqual(
            MobileExportPlanner.containedURL(forRelativePath: "2026/IMG.jpg", within: root)?.path,
            "/private/export/Foldiq Export/2026/IMG.jpg"
        )
        XCTAssertNil(MobileExportPlanner.containedURL(forRelativePath: "../outside.jpg", within: root))
        XCTAssertNil(MobileExportPlanner.containedURL(forRelativePath: "/private/outside.jpg", within: root))
        XCTAssertNil(MobileExportPlanner.containedURL(forRelativePath: "", within: root))
    }
}
