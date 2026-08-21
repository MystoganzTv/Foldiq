// MobileExportSupport.swift
// Pure, testable planning and reporting helpers for the native iPhone/iPad flow.

import Foundation

#if !os(macOS)
struct MobileExportPreviewItem: Identifiable, Equatable {
    let id: String
    let filename: String
    let relativePath: String
    let hasUnknownDate: Bool
    let isAlreadyExported: Bool
}

struct MobileExportReportRow: Codable, Equatable {
    enum Status: String, Codable {
        case exported
        case alreadyExported = "already_exported"
        case failed
    }

    let filename: String
    let kind: String
    let capturedAt: Date?
    let relativePath: String
    let status: Status
    let detail: String
}

struct MobileExportUndoEntry: Codable, Equatable {
    let assetID: String
    let relativePaths: [String]
}

struct MobileExportUndoManifest: Codable, Equatable {
    let createdAt: Date
    var completed: Bool
    var entries: [MobileExportUndoEntry]
}

enum MobileExportPlanner {
    static let englishMonthSymbols = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    static func safeOutputFolderName(_ proposed: String) -> String {
        let withoutControls = proposed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(withoutControls))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "." || trimmed == ".." || trimmed.contains("../") || trimmed.contains("..\\") {
            return "Foldiq Export"
        }
        let cleaned = trimmed
            .folderSafe
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "Foldiq Export" }
        return String(cleaned.prefix(100))
    }

    static func relativeFolder(
        date: Date?,
        mode: OrganizationMode,
        includeLocation: Bool,
        locationComponents: [String],
        calendar: Calendar = .current
    ) -> String {
        guard let date else { return "Unknown Date" }

        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let monthName = englishMonthSymbols[max(0, min(month - 1, englishMonthSymbols.count - 1))]
        let monthFolder = String(format: "%04d-%02d %@", year, month, monthName)
        let dayFolder = String(format: "%04d-%02d-%02d", year, month, day)
        let safeLocation = locationComponents.map(\.folderSafe).filter { !$0.isEmpty }

        switch mode {
        case .byYear:
            return String(year)
        case .byYearMonth:
            return [String(year), monthFolder].joined(separator: "/")
        case .byExactDate:
            return [String(year), monthFolder, dayFolder].joined(separator: "/")
        case .byLocation:
            return safeLocation.isEmpty
                ? ["Unknown Location", String(year)].joined(separator: "/")
                : safeLocation.joined(separator: "/")
        case .smartHybrid:
            let cityAndState = [safeLocation.last, safeLocation.dropLast().last].compactMap { $0 }
            let finalDay = includeLocation && !cityAndState.isEmpty
                ? ([dayFolder] + cityAndState).joined(separator: " ").folderSafe
                : dayFolder
            return [String(year), monthFolder, finalDay].joined(separator: "/")
        }
    }

    static func collisionSafeURL(
        for intended: URL,
        reserved: inout Set<String>,
        exists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL {
        guard reserved.contains(intended.path) || exists(intended.path) else {
            reserved.insert(intended.path)
            return intended
        }

        let directory = intended.deletingLastPathComponent()
        let base = intended.deletingPathExtension().lastPathComponent
        let ext = intended.pathExtension
        var counter = 1
        var candidate: URL

        repeat {
            let filename = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            candidate = directory.appendingPathComponent(filename)
            counter += 1
        } while reserved.contains(candidate.path) || exists(candidate.path)

        reserved.insert(candidate.path)
        return candidate
    }

    static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count))
    }

    /// Resolves a manifest path only when it remains strictly inside `root`.
    /// Manifests live beside user files and can be edited outside Foldiq, so callers
    /// must not trust a stored relative path before reading or deleting a file.
    static func containedURL(forRelativePath relativePath: String, within root: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.hasPrefix("\\") else {
            return nil
        }

        let standardizedRoot = root.standardizedFileURL
        let rootPrefix = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"
        let candidate = standardizedRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(rootPrefix), candidate.path != standardizedRoot.path else {
            return nil
        }
        return candidate
    }

    static func buildCSV(rows: [MobileExportReportRow]) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["filename,type,captured_at,destination,status,detail"]
        lines.reserveCapacity(rows.count + 1)
        for row in rows {
            let values = [
                row.filename,
                row.kind,
                row.capturedAt.map(formatter.string(from:)) ?? "",
                row.relativePath,
                row.status.rawValue,
                row.detail,
            ]
            lines.append(values.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
#endif
