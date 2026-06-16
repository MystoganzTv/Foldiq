// ReportExporter.swift
// Exports a CSV log of every planned/applied file operation.

import Foundation
#if os(macOS)
import AppKit
#endif

struct ReportExporter {
    enum ExportError: LocalizedError {
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "The CSV export was cancelled."
            }
        }
    }

    /// Show a save panel and write the CSV file.
    @discardableResult
    static func exportCSV(plans: [OrganizationPlan], sessionID: UUID) throws -> URL {
        let csv = buildCSV(plans: plans)
        let fileName = "Foldiq-Report-\(sessionID.uuidString.prefix(8)).csv"

        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes  = [.commaSeparatedText]
        panel.message = "Choose where to save the Foldiq organization report"

        guard panel.runModal() == .OK, let url = panel.url else {
            throw ExportError.cancelled
        }

        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
        #endif
    }

    static func buildCSV(plans: [OrganizationPlan]) -> String {
        var lines: [String] = [
            "\"Status\",\"Operation\",\"Source\",\"Destination\",\"Error\",\"Applied At\""
        ]

        let df = ISO8601DateFormatter()
        for p in plans {
            let row = [
                p.status.rawValue,
                p.operation.rawValue,
                p.sourceAbsPath,
                p.destinationAbsPath,
                p.errorMessage ?? "",
                p.appliedAt.map { df.string(from: $0) } ?? "",
            ]
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: ",")
            lines.append(row)
        }

        return lines.joined(separator: "\n")
    }
}
