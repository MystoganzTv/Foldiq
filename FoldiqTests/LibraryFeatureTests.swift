import XCTest
import ImageIO
import CoreGraphics
@testable import Foldiq

/// Google Takeout dates, rename by capture date and duplicate space.
/// Mirrors desktop/tests/takeout.test.js and desktop/tests/rename.test.js.
final class LibraryFeatureTests: XCTestCase {

    // MARK: Google Takeout

    func testCandidateNamesCoverOldNewNumberedAndEditedExports() {
        XCTAssertEqual(Array(GoogleTakeout.candidateNames(for: "IMG_1234.jpg").prefix(3)), [
            "img_1234.jpg.supplemental-metadata.json",
            "img_1234.jpg.json",
            "img_1234.json",
        ])
        XCTAssertTrue(GoogleTakeout.candidateNames(for: "IMG_1234(1).jpg").contains("img_1234.jpg(1).json"))
        XCTAssertTrue(GoogleTakeout.candidateNames(for: "IMG_1234(1).jpg").contains("img_1234.jpg.supplemental-metadata(1).json"))
        XCTAssertTrue(GoogleTakeout.candidateNames(for: "IMG_1234-edited.jpg").contains("img_1234.jpg.json"))
    }

    func testExactNamesWinAndNumberedCopiesKeepTheirOwnJSON() {
        let sidecars = index([
            "IMG_1234.jpg.supplemental-metadata.json",
            "IMG_1234.jpg(1).json",
        ])
        XCTAssertEqual(GoogleTakeout.match(mediaName: "IMG_1234.jpg", in: sidecars)?.url.lastPathComponent,
                       "IMG_1234.jpg.supplemental-metadata.json")
        XCTAssertEqual(GoogleTakeout.match(mediaName: "IMG_1234(1).jpg", in: sidecars)?.url.lastPathComponent,
                       "IMG_1234.jpg(1).json")
        XCTAssertNil(GoogleTakeout.match(mediaName: "IMG_9999.jpg", in: sidecars))
    }

    func testTruncatedNamesMatchOnlyLongNames() {
        let truncated = "PXL_20240814_153210123.NIGHT.PORTRAIT-01.COVER.j.json"
        let match = GoogleTakeout.match(mediaName: "PXL_20240814_153210123.NIGHT.PORTRAIT-01.COVER.jpg", in: index([truncated]))
        XCTAssertEqual(match?.url.lastPathComponent, truncated)
        XCTAssertEqual(match?.truncated, true)

        XCTAssertNil(GoogleTakeout.match(mediaName: "IMG_1234_extra.jpg", in: index(["IMG_1234.json"])))
    }

    func testParseReadsCaptureTimeAndIgnoresPlaceholderCoordinates() throws {
        let parsed = try XCTUnwrap(GoogleTakeout.parse(sidecarData()))
        XCTAssertEqual(parsed.date, Date(timeIntervalSince1970: 1_565_788_330))
        XCTAssertNil(parsed.latitude)

        let located = try XCTUnwrap(GoogleTakeout.parse(sidecarData(latitude: 38.97, longitude: -77.38)))
        XCTAssertEqual(located.latitude, 38.97)
        XCTAssertEqual(located.longitude, -77.38)

        XCTAssertNil(GoogleTakeout.parse(Data(#"{"photoTakenTime":{"timestamp":"0"}}"#.utf8)))
        XCTAssertNil(GoogleTakeout.parse(Data("not json".utf8)))
    }

    func testIndexFindsSidecarsOnDiskAndAcrossArchives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let album = root.appendingPathComponent("Takeout/Google Photos/Photos from 2019")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try sidecarData().write(to: album.appendingPathComponent("IMG_1234.jpg.json"))

        let disk = TakeoutSidecarIndex()
        disk.add(album.appendingPathComponent("IMG_1234.jpg.json"))
        XCTAssertNotNil(disk.lookup(mediaURL: album.appendingPathComponent("IMG_1234.jpg"), tempDirectory: nil))
        XCTAssertNil(disk.lookup(mediaURL: root.appendingPathComponent("IMG_1234.jpg"), tempDirectory: nil))

        // takeout-001.zip holds the photo, takeout-002.zip holds its JSON.
        let archiveA = root.appendingPathComponent("a")
        let archiveB = root.appendingPathComponent("b")
        let inner = "Takeout/Google Photos/Trip"
        try FileManager.default.createDirectory(at: archiveB.appendingPathComponent(inner), withIntermediateDirectories: true)
        let sidecarURL = archiveB.appendingPathComponent(inner).appendingPathComponent("IMG_1234.jpg.supplemental-metadata.json")
        try sidecarData(latitude: 40.4, longitude: -3.7).write(to: sidecarURL)

        let archives = TakeoutSidecarIndex()
        archives.add(sidecarURL, tempDirectory: archiveB)
        let found = archives.lookup(
            mediaURL: archiveA.appendingPathComponent(inner).appendingPathComponent("IMG_1234.jpg"),
            tempDirectory: archiveA
        )
        XCTAssertEqual(found?.latitude, 40.4)
    }

    func testSidecarNeverOverridesAnEmbeddedDate() {
        let sidecar = TakeoutSidecar(date: Date(timeIntervalSince1970: 1_565_788_330), latitude: 1, longitude: 2, title: nil)

        var embedded = ExtractedMetadata()
        embedded.dateTaken = Date(timeIntervalSince1970: 1_000_000_000)
        embedded.hasEmbeddedDate = true
        XCTAssertFalse(embedded.apply(sidecar))
        XCTAssertEqual(embedded.dateTaken, Date(timeIntervalSince1970: 1_000_000_000))
        XCTAssertEqual(embedded.latitude, 1, "GPS still comes from the sidecar when the file has none")

        var fromFilename = ExtractedMetadata()
        fromFilename.dateTaken = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertTrue(fromFilename.apply(sidecar))
        XCTAssertEqual(fromFilename.dateTaken, sidecar.date)
    }

    // MARK: Rename by capture date

    func testDateStemUsesFileSystemSafeCharacters() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(DateFileNaming.stem(for: Date(timeIntervalSince1970: 1_723_649_530), calendar: calendar),
                       "2024-08-14 15.32.10")
    }

    func testRenameIsOffByDefault() async {
        XCTAssertFalse(OrganizationConfig().renameByDate)
        let photo = makeFile("/Photos/IMG_4821.jpg", date: localDate(2024, 8, 14, 15, 32, 10))
        let plans = await OrganizationPlanner().buildPlan(session: session([photo]), config: renameConfig(false)) { _ in }
        XCTAssertEqual(plans.first?.destinationURL.lastPathComponent, "IMG_4821.jpg")
    }

    func testDatedFilesAreRenamedAndPairsKeepMatchingNames() async {
        let files = [
            makeFile("/Photos/IMG_0001.MOV", kind: .video, date: localDate(2024, 8, 14, 15, 32, 11)),
            makeFile("/Photos/IMG_0001.HEIC", date: localDate(2024, 8, 14, 15, 32, 10)),
        ]
        let plans = await OrganizationPlanner().buildPlan(session: session(files), config: renameConfig(true)) { _ in }
        XCTAssertEqual(plans.map(\.destinationURL.lastPathComponent),
                       ["2024-08-14 15.32.10.MOV", "2024-08-14 15.32.10.HEIC"])
    }

    func testSameSecondGetsNumberedAndDuplicatesKeepTheirNames() async {
        let second = localDate(2024, 8, 14, 15, 32, 10)
        let duplicate = makeFile("/Photos/copy.jpg", date: second)
        duplicate.isDuplicate = true
        let files = [
            makeFile("/Photos/IMG_1.jpg", date: second),
            makeFile("/Photos/IMG_2.jpg", date: second),
            duplicate,
            makeFile("/Photos/nodate.jpg", date: nil),
        ]
        let plans = await OrganizationPlanner().buildPlan(session: session(files), config: renameConfig(true)) { _ in }
        XCTAssertEqual(plans.map(\.destinationURL.lastPathComponent),
                       ["2024-08-14 15.32.10.jpg", "2024-08-14 15.32.10_1.jpg", "copy.jpg", "nodate.jpg"])
    }

    // MARK: Photos libraries

    func testFilesFromAPhotosLibraryAreAlwaysCopiedAndNamedByDate() async {
        var config = renameConfig(false)
        config.fileOperation = .move
        let files = [
            makeFile("/Pictures/Photos Library.photoslibrary/originals/7/7F3A1C2E-4B5D-4E6F-8A9B-0C1D2E3F4A5B.heic",
                     date: localDate(2024, 8, 14, 15, 32, 10)),
            makeFile("/Pictures/Loose/IMG_0001.jpg", date: localDate(2024, 8, 15, 9, 0, 0)),
        ]
        let plans = await OrganizationPlanner().buildPlan(session: session(files), config: config) { _ in }

        XCTAssertEqual(plans.map(\.operation), [.copy, .move])
        XCTAssertEqual(plans.map(\.destinationURL.lastPathComponent),
                       ["2024-08-14 15.32.10.heic", "IMG_0001.jpg"])
    }

    func testPathsInsideAPhotosLibraryAreRecognised() {
        XCTAssertTrue(PhotosLibrarySupport.isInsidePhotosLibrary("/Pictures/Photos Library.photoslibrary/originals/A/x.heic"))
        XCTAssertTrue(PhotosLibrarySupport.isInsidePhotosLibrary("/Volumes/Old/Family.PHOTOSLIBRARY/Masters/2012/IMG_1.JPG"))
        XCTAssertFalse(PhotosLibrarySupport.isInsidePhotosLibrary("/Pictures/photoslibrary notes/x.heic"))
        XCTAssertFalse(PhotosLibrarySupport.isInsidePhotosLibrary("/Pictures/Photos Library.photoslibrary"))
    }

    func testLivePhotoVideosAreLeftOut() {
        let folder = "/Lib.photoslibrary/originals/7/"
        let names = ["UUID-1.heic", "UUID-1_3.mov", "UUID-2.mov", "IMG_1.JPG", "IMG_1.mov", "IMG_2.mp4"]
        let discovered = names.map { name -> DiscoveredFile in
            let url = URL(fileURLWithPath: folder + name)
            return DiscoveredFile(
                url: url,
                kind: MediaTypes.kind(for: url.pathExtension) ?? .photo,
                fileSize: 1,
                creationDate: nil,
                modificationDate: nil,
                isScreenshot: false
            )
        }
        XCTAssertEqual(FolderScanner.removingLivePhotoCompanions(discovered).map(\.filename),
                       ["UUID-1.heic", "UUID-2.mov", "IMG_1.JPG", "IMG_2.mp4"])
    }

    func testScannerReadsOnlyTheOriginalsInsideAPhotosLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Foldiq-PhotosLibraryTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Photos Library.photoslibrary", isDirectory: true)
        let fm = FileManager.default
        for (path, contents) in [
            ("originals/7/7F3A.heic", "photo"),
            ("originals/7/7F3A_3.mov", "live"),
            ("originals/9/9B2C.mov", "video"),
            ("resources/derivatives/7/7F3A_1_105_c.jpeg", "thumbnail"),
            ("database/Photos.sqlite", "db"),
        ] {
            let url = library.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }

        let found = try await FolderScanner().scan(rootURL: library, includeVideos: true, onProgress: { _ in })

        XCTAssertEqual(Set(found.map(\.filename)), ["7F3A.heic", "9B2C.mov"])
        XCTAssertEqual(OrganizationConfig().outputRoot(forSelectedRoot: library).path,
                       root.appendingPathComponent("Organized Media").path)
    }

    func testEmptyFoldersInsideAPhotosLibraryAreNeverRemoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Foldiq-PruneTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Photos Library.photoslibrary/private/empty"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Trip/empty"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("Trip/keep.jpg"))

        XCTAssertEqual(FileMover.countEmptyDirs(root, skip: "Organized Media", isRoot: true), 1)
    }

    // MARK: Damaged files

    func testHealthyPhotosPassAndBrokenOnesAreCaught() async throws {
        let folder = try scratchFolder()
        let healthy = folder.appendingPathComponent("healthy.jpg")
        try writeJPEG(to: healthy)
        let healthySize = Int64(try Data(contentsOf: healthy).count)
        let healthyProblem = await MediaValidator.problem(at: healthy, kind: .photo, fileSize: healthySize)
        XCTAssertNil(healthyProblem)

        let empty = folder.appendingPathComponent("empty.jpg")
        try Data().write(to: empty)
        let emptyProblem = await MediaValidator.problem(at: empty, kind: .photo, fileSize: 0)
        XCTAssertNotNil(emptyProblem)

        let notAnImage = folder.appendingPathComponent("notes.png")
        try Data("just some text".utf8).write(to: notAnImage)
        let notAnImageProblem = await MediaValidator.problem(at: notAnImage, kind: .photo, fileSize: 14)
        XCTAssertNotNil(notAnImageProblem)

        // A RAW this Mac can't decode is never called damaged.
        let raw = folder.appendingPathComponent("new-camera.cr3")
        try Data("unknown raw".utf8).write(to: raw)
        let rawProblem = await MediaValidator.problem(at: raw, kind: .photo, fileSize: 11)
        XCTAssertNil(rawProblem)
    }

    func testCutOffJPEGIsCaughtButExtraDataAfterThePictureIsFine() throws {
        let folder = try scratchFolder()
        let original = folder.appendingPathComponent("original.jpg")
        try writeJPEG(to: original)
        let bytes = try Data(contentsOf: original)

        let cutOff = folder.appendingPathComponent("cut-off.jpg")
        try bytes.prefix(bytes.count / 2).write(to: cutOff)
        XCTAssertTrue(MediaValidator.jpegIsCutOff(cutOff))

        // Motion photos append a video after the picture's end marker.
        let motionPhoto = folder.appendingPathComponent("motion.jpg")
        try (bytes + Data(repeating: 0x42, count: 512)).write(to: motionPhoto)
        XCTAssertFalse(MediaValidator.jpegIsCutOff(motionPhoto))
        XCTAssertFalse(MediaValidator.jpegIsCutOff(original))
    }

    func testDamagedFilesGoToTheirOwnReviewFolder() async {
        let damaged = makeFile("/Photos/broken.jpg", date: localDate(2024, 8, 14, 15, 32, 10))
        damaged.damageReason = "The file is empty (0 bytes)."
        let plans = await OrganizationPlanner().buildPlan(session: session([damaged]), config: renameConfig(true)) { _ in }
        XCTAssertEqual(plans.first?.destinationURL.path,
                       "/Library/Organized Media/Needs Review/Damaged Files/broken.jpg")
    }

    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Foldiq-ValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func writeJPEG(to url: URL) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        for row in 0..<8 {
            context.setFillColor(CGColor(red: CGFloat(row) / 8, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: row * 8, width: 64, height: 8))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    // MARK: Location recovery

    func testPlaceComesFromTheClosestItemInTimeWithinTwoHours() {
        let start = Date(timeIntervalSince1970: 1_723_640_000)
        let phone = point("IMG_1.HEIC", start, camera: "iPhone", 40.4168, -3.7038)
        let laterPhone = point("IMG_2.HEIC", start.addingTimeInterval(90 * 60), camera: "iPhone", 40.4200, -3.7000)
        let camera = point("DSC_1.NEF", start.addingTimeInterval(10 * 60), camera: "Nikon Z6")
        let muchLater = point("DSC_2.NEF", start.addingTimeInterval(5 * 3600), camera: "Nikon Z6")

        let suggestions = LocationRecovery.suggestions(missing: [camera, muchLater], known: [phone, laterPhone])

        XCTAssertEqual(suggestions.map(\.fileID), [camera.id])
        XCTAssertEqual(suggestions.first?.sourceFilename, "IMG_1.HEIC")
        XCTAssertEqual(suggestions.first?.minutesApart, 10)
    }

    func testWhileTravellingOnlyVeryCloseMatchesAreTrusted() {
        let start = Date(timeIntervalSince1970: 1_723_640_000)
        let madrid = point("IMG_1.HEIC", start, camera: "iPhone", 40.4168, -3.7038)
        let barcelona = point("IMG_2.HEIC", start.addingTimeInterval(90 * 60), camera: "iPhone", 41.3874, 2.1686)
        let halfway = point("DSC_1.NEF", start.addingTimeInterval(45 * 60), camera: "Nikon Z6")
        let rightAfterMadrid = point("DSC_2.NEF", start.addingTimeInterval(5 * 60), camera: "Nikon Z6")

        let suggestions = LocationRecovery.suggestions(missing: [halfway, rightAfterMadrid], known: [madrid, barcelona])

        XCTAssertEqual(suggestions.map(\.fileID), [rightAfterMadrid.id])
        XCTAssertEqual(suggestions.first?.sourceFilename, "IMG_1.HEIC")
    }

    private func point(_ name: String, _ date: Date, camera: String?, _ latitude: Double? = nil, _ longitude: Double? = nil) -> LocationRecovery.Point {
        LocationRecovery.Point(id: UUID(), date: date, filename: name, camera: camera, latitude: latitude, longitude: longitude)
    }

    // MARK: Duplicate space

    func testReclaimableSpaceCountsExactAndSameImageCopiesOnly() {
        let exact = makeFile("/Photos/a.jpg", date: nil, size: 3_000)
        exact.isDuplicate = true
        let sameImage = makeFile("/Photos/b.jpg", date: nil, size: 2_000)
        sameImage.isProbableDuplicate = true
        let burst = makeFile("/Photos/c.jpg", date: nil, size: 9_000)
        burst.probableMatchKindRaw = "burst"
        XCTAssertEqual(DuplicateSpace.reclaimableBytes(in: [exact, sameImage, burst]), 5_000)
    }

    // MARK: Helpers

    private func index(_ names: [String]) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: names.map {
            ($0.lowercased(), URL(fileURLWithPath: "/takeout").appendingPathComponent($0))
        })
    }

    private func sidecarData(latitude: Double = 0, longitude: Double = 0) -> Data {
        Data("""
        {"title":"IMG_1234.jpg","photoTakenTime":{"timestamp":"1565788330","formatted":"ignored"},
         "geoData":{"latitude":\(latitude),"longitude":\(longitude),"altitude":0}}
        """.utf8)
    }

    private func renameConfig(_ enabled: Bool) -> OrganizationConfig {
        var config = OrganizationConfig()
        config.mode = .byExactDate
        config.customOutputParentPath = "/Library"
        config.renameByDate = enabled
        return config
    }

    private func session(_ files: [MediaFile]) -> ScanSession {
        let session = ScanSession(rootPath: "/Photos")
        session.files = files
        files.forEach { $0.session = session }
        return session
    }

    private func makeFile(_ path: String, kind: MediaKind = .photo, date: Date?, size: Int64 = 1_024) -> MediaFile {
        let url = URL(fileURLWithPath: path)
        let file = MediaFile(filePath: path, filename: url.lastPathComponent, ext: url.pathExtension, kind: kind, fileSize: size)
        file.dateTaken = date
        return file
    }

    private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}
