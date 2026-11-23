// ProbableDuplicateDetector.swift
// Smart Duplicates: local-only visual and metadata comparison for photos whose
// bytes differ. Strong visual matches may be separated; weaker similarities are
// review-only and always remain in the normal organization flow.

import Foundation
import SwiftData
import ImageIO
import CoreGraphics

@MainActor
final class ProbableDuplicateDetector {

    struct Progress {
        var processed: Int
        var total: Int
        var currentFile: String
    }

    static let sameImageDistance = 4
    static let similarImageDistance = 10
    static let editedImageDistance = 14
    static let burstImageDistance = 14
    private static let tenMinutes: TimeInterval = 10 * 60
    private static let fifteenSeconds: TimeInterval = 15
    private static let visualCandidateWindow: TimeInterval = 2 * 60
    private static let maxDimensionOnlyGroup = 40

    private struct FileSnapshot: Sendable {
        let id: UUID
        let url: URL
        let filename: String
        let stem: String
        let fileSize: Int64
        let captureDate: Date?
        let hasCaptureDate: Bool
        let hasGPS: Bool
        let pixelWidth: Int?
        let pixelHeight: Int?
        let isExactDuplicate: Bool
        let isFromArchive: Bool
        let pathDepth: Int
    }

    private struct Pair: Hashable, Sendable {
        let left: Int
        let right: Int

        init(_ first: Int, _ second: Int) {
            left = min(first, second)
            right = max(first, second)
        }
    }

    private enum MatchKind: String, Sendable {
        case sameImage = "same"
        case burst
        case edited
        case similar
    }

    private struct MatchEdge: Sendable {
        let left: Int
        let right: Int
        let kind: MatchKind
        let score: Int
        let reasons: String
    }

    private struct UnionFind {
        var parent: [Int]

        init(count: Int) {
            parent = Array(0..<count)
        }

        mutating func find(_ value: Int) -> Int {
            if parent[value] != value {
                parent[value] = find(parent[value])
            }
            return parent[value]
        }

        mutating func union(_ left: Int, _ right: Int) {
            let a = find(left)
            let b = find(right)
            if a != b { parent[b] = a }
        }
    }

    @discardableResult
    func detect(
        files: [MediaFile],
        onProgress: @MainActor @escaping (Progress) -> Void
    ) async -> Int {
        for file in files where !file.isDuplicate {
            file.isProbableDuplicate = false
            file.probableDuplicateGroupID = nil
            file.probableMatchScore = 0
            file.probableMatchReasons = nil
            file.probableMatchPeerFilename = nil
            file.probableMatchKindRaw = nil
        }

        let snapshots = files.map { file in
            FileSnapshot(
                id: file.id,
                url: file.url,
                filename: file.filename,
                stem: Self.normalizedStem(file.filename),
                fileSize: file.fileSize,
                captureDate: file.dateTaken,
                hasCaptureDate: file.dateTaken != nil,
                hasGPS: file.hasGPS,
                pixelWidth: file.pixelWidth,
                pixelHeight: file.pixelHeight,
                isExactDuplicate: file.isDuplicate,
                isFromArchive: file.archiveSourcePath != nil,
                pathDepth: file.filePath.split(separator: "/").count
            )
        }.filter { !$0.isExactDuplicate && Self.isSupportedPhoto($0.url) }

        guard snapshots.count > 1 else { return 0 }
        let pairs = Self.candidatePairs(snapshots)
        let visualIndexes = Set(pairs.flatMap { [$0.left, $0.right] }).sorted()
        var visualHashes: [Int: [UInt64]] = [:]
        visualHashes.reserveCapacity(visualIndexes.count)

        var nextPosition = 0
        var completed = 0
        // Up to four pictures decoded at once on machines with the cores for it.
        let workerCount = min(DuplicateDetector.workerCount, visualIndexes.count)
        await withTaskGroup(of: (Int, [UInt64]?).self) { group in
            func enqueueNext() {
                guard nextPosition < visualIndexes.count else { return }
                let index = visualIndexes[nextPosition]
                nextPosition += 1
                group.addTask {
                    (index, await Self.computeVisualHashes(url: snapshots[index].url))
                }
            }
            for _ in 0..<workerCount { enqueueNext() }
            while let (index, hashes) = await group.next() {
                if Task.isCancelled { group.cancelAll(); return }
                if let hashes { visualHashes[index] = hashes }
                completed += 1
                onProgress(Progress(
                    processed: completed,
                    total: visualIndexes.count,
                    currentFile: snapshots[index].filename
                ))
                enqueueNext()
            }
        }

        // `return` inside the task group only leaves the group; stop here too so a
        // cancelled scan never writes to files the Welcome screen may have purged.
        guard !Task.isCancelled else { return 0 }

        var allGroups = UnionFind(count: snapshots.count)
        var sameGroups = UnionFind(count: snapshots.count)
        var edges: [MatchEdge] = []
        for pair in pairs {
            guard let match = Self.classify(
                snapshots[pair.left],
                snapshots[pair.right],
                leftHashes: visualHashes[pair.left],
                rightHashes: visualHashes[pair.right]
            ) else { continue }
            edges.append(MatchEdge(
                left: pair.left,
                right: pair.right,
                kind: match.kind,
                score: match.score,
                reasons: match.reasons
            ))
            allGroups.union(pair.left, pair.right)
            if match.kind == .sameImage { sameGroups.union(pair.left, pair.right) }
        }

        struct Component {
            var indexes = Set<Int>()
            var edges: [MatchEdge] = []
        }
        var components: [Int: Component] = [:]
        for edge in edges {
            let root = allGroups.find(edge.left)
            components[root, default: Component()].indexes.formUnion([edge.left, edge.right])
            components[root, default: Component()].edges.append(edge)
        }

        let filesByID = Dictionary(uniqueKeysWithValues: files.filter(\.isUsable).map { ($0.id, $0) })
        var groupCount = 0
        for component in components.values {
            groupCount += 1
            let groupID = UUID()
            for index in component.indexes {
                filesByID[snapshots[index].id]?.probableDuplicateGroupID = groupID
            }

            var bestEdgeByIndex: [Int: MatchEdge] = [:]
            for edge in component.edges {
                for index in [edge.left, edge.right] {
                    if bestEdgeByIndex[index]?.score ?? -1 < edge.score {
                        bestEdgeByIndex[index] = edge
                    }
                }
            }
            for (index, edge) in bestEdgeByIndex {
                guard let file = filesByID[snapshots[index].id] else { continue }
                let peer = edge.left == index ? edge.right : edge.left
                file.probableMatchScore = edge.score
                file.probableMatchReasons = edge.reasons
                file.probableMatchPeerFilename = snapshots[peer].filename
                file.probableMatchKindRaw = edge.kind.rawValue
            }

            var highComponents: [Int: [Int]] = [:]
            for index in component.indexes {
                highComponents[sameGroups.find(index), default: []].append(index)
            }
            for indexes in highComponents.values where indexes.count > 1 {
                let original = Self.electOriginal(indexes.map { snapshots[$0] })
                for index in indexes where snapshots[index].id != original.id {
                    guard let duplicate = filesByID[snapshots[index].id] else { continue }
                    duplicate.isProbableDuplicate = true
                    duplicate.probableMatchPeerFilename = original.filename
                }
                for index in indexes {
                    filesByID[snapshots[index].id]?.probableMatchKindRaw = MatchKind.sameImage.rawValue
                }
            }
        }
        return groupCount
    }

    // MARK: Candidate generation

    private static func candidatePairs(_ files: [FileSnapshot]) -> Set<Pair> {
        var result = Set<Pair>()
        var byStem: [String: [Int]] = [:]
        for (index, file) in files.enumerated() where !file.stem.isEmpty {
            byStem[file.stem, default: []].append(index)
        }
        for group in byStem.values {
            for left in group.indices {
                let upper = min(group.count, left + 100)
                guard left + 1 < upper else { continue }
                for right in (left + 1)..<upper { result.insert(Pair(group[left], group[right])) }
            }
        }

        let dated = files.enumerated().compactMap { index, file -> (Int, Date, Double)? in
            guard let date = file.captureDate, let aspect = aspectRatio(file) else { return nil }
            return (index, date, aspect)
        }.sorted { $0.1 < $1.1 }
        for left in dated.indices {
            var right = left + 1
            while right < min(dated.count, left + 100)
                    && dated[right].1.timeIntervalSince(dated[left].1) <= visualCandidateWindow {
                if orientationAwareAspectDifference(dated[left].2, dated[right].2) <= 0.08 {
                    result.insert(Pair(dated[left].0, dated[right].0))
                }
                right += 1
            }
        }

        var byDimensions: [String: [Int]] = [:]
        for (index, file) in files.enumerated() {
            guard let width = file.pixelWidth, let height = file.pixelHeight, width > 0, height > 0 else { continue }
            byDimensions["\(min(width, height))x\(max(width, height))", default: []].append(index)
        }
        for var group in byDimensions.values {
            if group.count > maxDimensionOnlyGroup { continue }
            group.sort { files[$0].fileSize < files[$1].fileSize }
            for left in group.indices {
                let upper = min(group.count, left + 7)
                guard left + 1 < upper else { continue }
                for right in (left + 1)..<upper {
                    if relativeDifference(Double(files[group[left]].fileSize), Double(files[group[right]].fileSize)) <= 0.15 {
                        result.insert(Pair(group[left], group[right]))
                    }
                }
            }
        }
        return result
    }

    // MARK: Pair classification

    private static func classify(
        _ left: FileSnapshot,
        _ right: FileSnapshot,
        leftHashes: [UInt64]?,
        rightHashes: [UInt64]?
    ) -> (kind: MatchKind, score: Int, reasons: String)? {
        let visualDistance = minimumVisualDistance(leftHashes, rightHashes)
        let sameStem = left.stem == right.stem
        let sameDimensions = left.pixelWidth != nil && left.pixelHeight != nil
            && ((left.pixelWidth == right.pixelWidth && left.pixelHeight == right.pixelHeight)
                || (left.pixelWidth == right.pixelHeight && left.pixelHeight == right.pixelWidth))
        let dateDifference = left.captureDate.flatMap { a in right.captureDate.map { abs(a.timeIntervalSince($0)) } }
        let aspectDifference: Double = {
            guard let a = aspectRatio(left), let b = aspectRatio(right) else { return 0 }
            return orientationAwareAspectDifference(a, b)
        }()
        let editedVersion = hasEditMarker(left.filename) || hasEditMarker(right.filename)

        if let distance = visualDistance,
           distance <= editedImageDistance,
           aspectDifference <= 0.18,
           editedVersion,
           sameStem || (dateDifference.map { $0 <= 86_400 } ?? false) {
            return (
                .edited,
                max(78, 94 - distance),
                "Edited version · visual distance \(distance)/64 · review only"
            )
        }
        if let distance = visualDistance,
           isLikelyBurst(left, right, dateDifference: dateDifference, visualDistance: distance),
           aspectDifference <= 0.08 {
            return (
                .burst,
                max(78, 92 - distance),
                "Burst sequence · \(Int((dateDifference ?? 0).rounded()))s apart · review only"
            )
        }

        if let distance = visualDistance,
           distance <= sameImageDistance,
           aspectDifference <= 0.03,
           sameStem || sameDimensions || (dateDifference.map { $0 <= 86_400 } ?? false) {
            return (
                .sameImage,
                max(94, 100 - distance),
                "Visual match · distance \(distance)/64" + (sameDimensions ? " · same dimensions" : "")
            )
        }
        if let distance = visualDistance,
           distance <= similarImageDistance,
           aspectDifference <= 0.05,
           sameStem || (dateDifference.map { $0 <= tenMinutes } ?? false) {
            return (
                sameStem ? .edited : .similar,
                max(80, 92 - distance),
                (sameStem ? "Possible edited version" : "Visually similar")
                    + " · distance \(distance)/64 · review only"
            )
        }

        let metadata = metadataScore(left, right)
        if visualDistance == nil && metadata.score >= 90 {
            return (
                .similar,
                min(89, metadata.score - 5),
                metadata.reasons.joined(separator: " · ") + " · visual check unavailable · review only"
            )
        }
        return nil
    }

    private static func metadataScore(_ left: FileSnapshot, _ right: FileSnapshot) -> (score: Int, reasons: [String]) {
        var score = left.stem == right.stem ? 50 : 0
        var reasons = score > 0 ? ["Related filename"] : []
        let sizeDifference = relativeDifference(Double(left.fileSize), Double(right.fileSize))
        if sizeDifference <= 0.01 { score += 25; reasons.append("Size within 1%") }
        else if sizeDifference <= 0.03 { score += 10; reasons.append("Size within 3%") }
        if let a = left.captureDate, let b = right.captureDate {
            let difference = abs(a.timeIntervalSince(b))
            if difference <= 300 { score += 20; reasons.append("Capture time within 5 min") }
            else if difference <= 3_600 { score += 17; reasons.append("Capture time within 1 hour") }
            else if difference <= 86_400 { score += 10; reasons.append("Capture time within 24 hours") }
        }
        if left.pixelWidth != nil && left.pixelHeight != nil
            && left.pixelWidth == right.pixelWidth && left.pixelHeight == right.pixelHeight {
            score += 10
            reasons.append("Dimensions \(left.pixelWidth!)×\(left.pixelHeight!)")
        }
        return (min(score, 100), reasons)
    }

    private static func hasEditMarker(_ filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        let markers = ["edited", "edit", "exported", "export", "compressed", "optimized",
                       "converted", "enhanced", "filtered", "retouched"]
        let tokens = stem.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
        return tokens.contains { token in
            markers.contains { token == $0 || (token.hasPrefix($0) && token.dropFirst($0.count).allSatisfy(\.isNumber)) }
        }
    }

    private static func sequenceInfo(_ filename: String) -> (prefix: String, number: Int)? {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        guard let digitStart = stem.lastIndex(where: { !$0.isNumber }).map({ stem.index(after: $0) })
                ?? (stem.first?.isNumber == true ? stem.startIndex : nil),
              digitStart < stem.endIndex else { return nil }
        let digits = stem[digitStart...]
        guard digits.count >= 2, let number = Int(digits) else { return nil }
        return (String(stem[..<digitStart]), number)
    }

    private static func isLikelyBurst(
        _ left: FileSnapshot,
        _ right: FileSnapshot,
        dateDifference: TimeInterval?,
        visualDistance: Int
    ) -> Bool {
        guard let dateDifference, dateDifference <= fifteenSeconds,
              visualDistance <= burstImageDistance,
              !hasEditMarker(left.filename), !hasEditMarker(right.filename),
              let a = sequenceInfo(left.filename), let b = sequenceInfo(right.filename),
              a.prefix == b.prefix, a.number != b.number else { return false }
        return abs(a.number - b.number) <= 20
    }

    // MARK: Original election

    private static func electOriginal(_ group: [FileSnapshot]) -> FileSnapshot {
        group.max { rank($0) < rank($1) }!
    }

    private static func rank(_ file: FileSnapshot) -> Double {
        var value = 0.0
        if !file.isFromArchive { value += 10_000 }
        if file.hasCaptureDate { value += 1_000 }
        if file.hasGPS { value += 200 }
        value += min(Double((file.pixelWidth ?? 0) * (file.pixelHeight ?? 0)) / 1_000_000, 100)
        value += min(Double(file.fileSize) / 10_000_000, 10)
        value -= Double(file.pathDepth)
        return value
    }

    // MARK: Visual hashing

    private static func computeVisualHashes(url: URL) async -> [UInt64]? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: 96,
                kCGImageSourceShouldCacheImmediately as String: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let width = image.width, height = image.height
            guard width >= 9, height >= 8 else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            func transformed(_ transform: Int, _ x: Double, _ y: Double) -> (Double, Double) {
                switch transform {
                case 1: return (1 - x, y)
                case 2: return (x, 1 - y)
                case 3: return (1 - x, 1 - y)
                case 4: return (y, x)
                case 5: return (1 - y, x)
                case 6: return (y, 1 - x)
                case 7: return (1 - y, 1 - x)
                default: return (x, y)
                }
            }

            func luminance(_ x: Double, _ y: Double) -> Double {
                let px = max(0, min(width - 1, Int((x * Double(width - 1)).rounded())))
                let py = max(0, min(height - 1, Int((y * Double(height - 1)).rounded())))
                let offset = (py * width + px) * 4
                let alpha = Double(pixels[offset + 3]) / 255
                let red = Double(pixels[offset]) * alpha + 255 * (1 - alpha)
                let green = Double(pixels[offset + 1]) * alpha + 255 * (1 - alpha)
                let blue = Double(pixels[offset + 2]) * alpha + 255 * (1 - alpha)
                return (red * 299 + green * 587 + blue * 114) / 1_000
            }

            return (0..<8).map { transform in
                var hash: UInt64 = 0
                for row in 0..<8 {
                    let values = (0..<9).map { column -> Double in
                        let point = transformed(transform, (Double(column) + 0.5) / 9, (Double(row) + 0.5) / 8)
                        return luminance(point.0, point.1)
                    }
                    for column in 0..<8 {
                        hash = (hash << 1) | (values[column] > values[column + 1] ? 1 : 0)
                    }
                }
                return hash
            }
        }.value
    }

    private static func minimumVisualDistance(_ left: [UInt64]?, _ right: [UInt64]?) -> Int? {
        guard let left, let right, !left.isEmpty, !right.isEmpty else { return nil }
        var best = 64
        for a in left {
            for b in right {
                best = min(best, (a ^ b).nonzeroBitCount)
                if best == 0 { return 0 }
            }
        }
        return best
    }

    // MARK: Helpers

    static func normalizedStem(_ filename: String) -> String {
        var stem = (filename as NSString).deletingPathExtension
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?:[\s._-]+(?:copy|duplicate|duplicated|dup|edited|edit|exported|export|compressed|optimized|converted|backup)(?:[\s._-]*\d+)?|\s*\(\d+\))+$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return stem }
        while true {
            let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
            let replaced = regex.stringByReplacingMatches(in: stem, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if replaced == stem { return stem }
            stem = replaced
        }
    }

    private static func isSupportedPhoto(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2"]
            .contains(url.pathExtension.lowercased())
    }

    private static func aspectRatio(_ file: FileSnapshot) -> Double? {
        guard let width = file.pixelWidth, let height = file.pixelHeight, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    private static func relativeDifference(_ left: Double, _ right: Double) -> Double {
        let larger = max(abs(left), abs(right))
        return larger > 0 ? abs(left - right) / larger : 1
    }

    private static func orientationAwareAspectDifference(_ left: Double, _ right: Double) -> Double {
        guard left > 0, right > 0 else { return 0 }
        return min(relativeDifference(left, right), relativeDifference(1 / left, right))
    }
}
