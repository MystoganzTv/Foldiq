// IOSPhotosExportView.swift
// iPhone/iPad flow: export organized copies from Photos Library to Files.

import SwiftUI
import UniformTypeIdentifiers

#if !os(macOS)
struct IOSPhotosExportView: View {
    @StateObject private var exporter = PhotoLibraryExporter()
    @State private var showingDestinationPicker = false
    @State private var destinationFolder: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    statusCard
                    actionArea
                    safetyNotes
                }
                .padding(24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Foldiq")
            .fileImporter(
                isPresented: $showingDestinationPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                destinationFolder = url
            }
            .task {
                if case .idle = exporter.phase {
                    await exporter.requestAccessAndScan()
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 60, weight: .thin))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text("Organize Photos Library")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text("Foldiq exports organized copies from Photos into iCloud Drive, On My iPhone/iPad, or a USB drive shown in Files. Your Photos Library originals stay untouched.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 18) {
            switch exporter.phase {
            case .idle, .requestingAccess:
                ProgressView("Requesting Photos access…")
            case .scanning:
                ProgressView("Scanning Photos Library…")
            case .ready:
                summary
            case .exporting:
                exportProgress
            case .completed(let folder, let count):
                Label("Exported \(count) items", systemImage: "checkmark.circle.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.green)
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var summary: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                stat("\(exporter.photoCount)", "Photos", "photo")
                stat("\(exporter.videoCount)", "Videos", "video")
                stat("\(exporter.missingDateCount)", "No Date", "calendar.badge.exclamationmark")
            }

            Text("Destination structure: Foldiq Export → Year → Month → Day, with location added when available.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var exportProgress: some View {
        VStack(spacing: 10) {
            ProgressView(value: Double(exporter.progress.done), total: Double(max(exporter.progress.total, 1)))
                .tint(.blue)
            Text(exporter.progress.currentFile.isEmpty ? "Preparing export…" : exporter.progress.currentFile)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(exporter.progress.done) / \(exporter.progress.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch exporter.phase {
        case .ready, .completed:
            VStack(spacing: 12) {
                Button {
                    showingDestinationPicker = true
                } label: {
                    Label(destinationFolder == nil ? "Choose Export Folder" : "Change Export Folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if let destinationFolder {
                    Text(destinationFolder.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    if let capacity = availableCapacityText(for: destinationFolder) {
                        Label(capacity, systemImage: "internaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await exporter.export(to: destinationFolder) }
                    } label: {
                        Label("Export Organized Copies", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        case .failed:
            Button {
                Task { await exporter.requestAccessAndScan() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        default:
            EmptyView()
        }
    }

    private var safetyNotes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Export only: originals are never deleted from Photos.", systemImage: "checkmark.shield")
            Label("Use iCloud Drive, On My iPhone/iPad, or USB storage from Files.", systemImage: "externaldrive")
            Label("Large libraries need enough free destination space.", systemImage: "internaldrive")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
            Text(value)
                .font(.title2.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private func availableCapacityText(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }

        let formatted = ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
        return "\(formatted) available at destination"
    }
}
#endif
