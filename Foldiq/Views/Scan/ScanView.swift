// ScanView.swift
// Step 2: Runs the full scan pipeline and shows aggregate results.
// Stat cards are tappable — clicking one opens a sheet listing the files in that category.

import SwiftUI
import SwiftData
import AppKit
import QuickLookUI

struct ScanView: View {

    @EnvironmentObject private var nav: AppNavigator
    @Environment(\.modelContext) private var context

    @StateObject private var coordinator = ScanCoordinator()
    @State private var taskHandle: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if coordinator.phase == .done, let session = nav.scanSession {
                ScanResultsPanel(session: session)
                    .transition(.opacity)
            } else {
                ScanProgressPanel(
                    coordinator: coordinator,
                    onCancel: cancelScan,
                    onScanOrganized: organizedMediaURLs.isEmpty ? nil : rescanOrganized
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: coordinator.phase)
        .onAppear { startScan() }
        .onDisappear { taskHandle?.cancel() }
    }

    // MARK: - Scan control

    private func startScan() {
        // If a scan already completed (user navigated back from a later step),
        // just surface the existing results — don't re-scan and create duplicates.
        if nav.scanSession != nil {
            coordinator.phase = .done
            return
        }
        guard !nav.selectedFolderURLs.isEmpty else { return }
        taskHandle = Task {
            let session = await coordinator.run(
                rootURLs: nav.selectedFolderURLs,
                config: nav.organizationConfig,
                context: context
            )
            if let session {
                nav.scanSession = session
                // Store archive temp dirs so ApplyView can clean them up after apply.
                nav.archiveTempDirs = coordinator.archiveTempDirs
            }
            // Errors are shown inside ScanProgressPanel via coordinator.errorMessage
        }
    }

    private func cancelScan() {
        taskHandle?.cancel()
        nav.restart()
    }

    // MARK: - Re-scan organized folder

    /// URLs of existing "Organized Media" subfolders inside the selected roots.
    /// Non-empty only when the scan failed because everything was already organized.
    var organizedMediaURLs: [URL] {
        guard coordinator.phase == .failed else { return [] }
        return nav.selectedFolderURLs.compactMap { root in
            let url = root.appendingPathComponent(nav.organizationConfig.outputFolderName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private func rescanOrganized() {
        let urls = organizedMediaURLs
        guard !urls.isEmpty else { return }
        taskHandle?.cancel()
        nav.selectedFolderURLs = urls
        nav.scanSession = nil
        // coordinator.run() resets phase to .scanning at start
        startScan()
    }
}

// MARK: ─── Scan Progress Panel ────────────────────────────────────────────────

struct ScanProgressPanel: View {
    @ObservedObject var coordinator: ScanCoordinator
    @EnvironmentObject private var nav: AppNavigator

    let onCancel: () -> Void
    let onScanOrganized: (() -> Void)?   // non-nil only when organized folder exists

    var progress: Double {
        guard coordinator.foundCount > 0 else { return 0 }
        switch coordinator.phase {
        case .extracting, .hashing:
            let total = max(coordinator.foundCount, 1)
            return min(Double(coordinator.processedCount) / Double(total), 1.0)
        default:
            return 0
        }
    }

    var isFailed: Bool { coordinator.phase == .failed }
    var isActive: Bool {
        coordinator.phase == .scanning ||
        coordinator.phase == .extracting ||
        coordinator.phase == .hashing
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: isFailed ? "exclamationmark.magnifyingglass" : "magnifyingglass.circle")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(isFailed ? .red : .blue)
                .symbolEffect(.pulse, isActive: isActive)

            VStack(spacing: 8) {
                Text(coordinator.phase.rawValue)
                    .font(.title2).fontWeight(.semibold)
                    .foregroundStyle(isFailed ? .red : .primary)

                if isFailed, let msg = coordinator.errorMessage {
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(coordinator.currentFile.isEmpty ? "Starting…" : coordinator.currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 500)
                }
            }

            // Progress bar — shown while active
            if isActive {
                VStack(spacing: 6) {
                    ProgressView(value: progress > 0 ? progress : nil)
                        .frame(width: 400)
                        .tint(.blue)

                    HStack(spacing: 20) {
                        StatLabel(value: coordinator.foundCount, label: "found")
                        StatLabel(value: coordinator.processedCount, label: "processed")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            // Action buttons
            HStack(spacing: 12) {
                if isFailed {
                    Button("Change Folders") { nav.restart() }
                        .buttonStyle(.bordered)

                    // Offer to scan the already-organized subfolder when applicable
                    if let onScanOrganized {
                        Button {
                            onScanOrganized()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Re-organize \"\(nav.organizationConfig.outputFolderName)\"")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if isActive {
                    Button {
                        onCancel()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle")
                            Text("Cancel")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: ─── Scan Results Panel ─────────────────────────────────────────────────

struct ScanResultsPanel: View {
    let session: ScanSession
    @EnvironmentObject private var nav: AppNavigator

    @State private var drillCategory: FileCategory?

    enum FileCategory: String, Identifiable {
        var id: String { rawValue }
        case photos             = "Photos"
        case videos             = "Videos"
        case archives           = "From ZIP Archives"
        case duplicates         = "Exact Duplicates"
        case probableDuplicates = "Probable Duplicates"
        case missingDate        = "Missing Date"
        case noMetadata         = "No Metadata"
        case allFiles           = "All Files"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                Text("Scan Complete")
                    .font(.largeTitle).fontWeight(.bold)
                let folderNames = nav.selectedFolderURLs.map(\.lastPathComponent).joined(separator: ", ")
                Text(folderNames.isEmpty ? session.rootPath : folderNames)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            // Stats grid — each card is tappable (4 columns × 2 rows)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                TappableStatCard(icon: "photo.stack",          label: "Photos",           value: session.photoCount,             color: .blue)   { drillCategory = .photos }
                TappableStatCard(icon: "video.fill",           label: "Videos",           value: session.videoCount,             color: .purple) { drillCategory = .videos }
                TappableStatCard(icon: "doc.zipper",           label: "ZIPs Extracted",   value: session.archivesExtractedCount, color: .teal)   { drillCategory = .archives }
                TappableStatCard(icon: "square.on.square",     label: "Exact Dupes",      value: session.duplicateCount,         color: .orange) { drillCategory = .duplicates }
                TappableStatCard(icon: "equal.circle",         label: "Probable Dupes",   value: session.probableDuplicateCount, color: .yellow) { drillCategory = .probableDuplicates }
                TappableStatCard(icon: "questionmark.circle",  label: "Missing Date",     value: session.missingDateCount,       color: .red)    { drillCategory = .missingDate }
                TappableStatCard(icon: "info.circle",          label: "No Metadata",      value: session.missingMetaCount,       color: .gray)   { drillCategory = .noMetadata }
                TappableStatCard(icon: "doc.on.doc",           label: "Total Files",      value: session.totalFiles,             color: .green)  { drillCategory = .allFiles }
            }
            .padding(.horizontal, 40)

            Spacer()

            // Continue
            HStack {
                Button("Change Folders") { nav.restart() }
                    .buttonStyle(.bordered)

                Spacer()

                Button {
                    nav.go(to: .settings)
                } label: {
                    HStack {
                        Text("Configure Organization")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .sheet(item: $drillCategory) { category in
            FileDrillSheet(session: session, category: category)
        }
    }
}

// MARK: ─── File Drill Sheet ───────────────────────────────────────────────────

struct FileDrillSheet: View {
    let session: ScanSession
    let category: ScanResultsPanel.FileCategory

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var previewURL: URL?          // Quick Look target
    @State private var hoveredFileID: UUID?      // for row highlight

    var files: [MediaFile] {
        let all = session.files
        switch category {
        case .photos:             return all.filter { $0.mediaKind == .photo }
        case .videos:             return all.filter { $0.mediaKind == .video }
        case .archives:           return all.filter { $0.archiveSourcePath != nil }
        case .duplicates:         return all.filter { $0.isDuplicate }
        case .probableDuplicates: return all
                .filter { $0.probableDuplicateGroupID != nil }
                .sorted {
                    // Group pairs together; within a pair, duplicate side first
                    let g = ($0.probableDuplicateGroupID?.uuidString ?? "") <
                            ($1.probableDuplicateGroupID?.uuidString ?? "")
                    return g || ($0.probableDuplicateGroupID == $1.probableDuplicateGroupID
                                 && $0.isProbableDuplicate && !$1.isProbableDuplicate)
                }
        case .missingDate:        return all.filter { !$0.hasDate }
        case .noMetadata:         return all.filter { $0.cameraMake == nil && $0.cameraModel == nil && !$0.hasGPS }
        case .allFiles:           return all
        }
    }

    var filtered: [MediaFile] {
        guard !searchText.isEmpty else { return files }
        let q = searchText.lowercased()
        return files.filter { $0.filename.lowercased().contains(q) || $0.filePath.lowercased().contains(q) }
    }

    var categoryColor: Color {
        switch category {
        case .photos:             return .blue
        case .videos:             return .purple
        case .archives:           return .teal
        case .duplicates:         return .orange
        case .probableDuplicates: return .yellow
        case .missingDate:        return .red
        case .noMetadata:         return .gray
        case .allFiles:           return .green
        }
    }

    var categoryIcon: String {
        switch category {
        case .photos:             return "photo.stack"
        case .videos:             return "video.fill"
        case .archives:           return "doc.zipper"
        case .duplicates:         return "square.on.square"
        case .probableDuplicates: return "equal.circle"
        case .missingDate:        return "questionmark.circle"
        case .noMetadata:         return "info.circle"
        case .allFiles:           return "doc.on.doc"
        }
    }

    var explainerText: String {
        switch category {
        case .archives:
            return "These photos and videos were extracted from ZIP archives. The original .zip files are left untouched in their current location. On undo, these organized copies are removed — the originals remain safely inside the zips."
        case .missingDate:
            return "These files have no EXIF date in their metadata. They could not be reliably dated and will be placed in an \"Unknown Date\" folder. You can assign them a date manually in the Preview step."
        case .noMetadata:
            return "These files have no camera make, model, or GPS data embedded. They may have been exported from messaging apps or cloud services that strip metadata."
        case .duplicates:
            return "These are exact duplicate copies (identical file contents, verified by SHA-256). One copy per group stays organized; the rest go to Duplicates/Exact Duplicates/."
        case .probableDuplicates:
            return "These files share a name and closely match in size, timestamp, or dimensions — but have different bytes, so SHA-256 couldn't confirm them. Each pair is shown together. Review before applying: the flagged copy goes to Duplicates/Probable Duplicates/, the original stays organized."
        default:
            return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: categoryIcon)
                    .font(.title2)
                    .foregroundStyle(categoryColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.rawValue)
                        .font(.title2).fontWeight(.bold)
                    Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            if !explainerText.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(categoryColor)
                        .font(.caption)
                        .padding(.top, 1)
                    Text(explainerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .padding(.top, 0)
            }

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search files…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // File list
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label("No matching files", systemImage: "magnifyingglass")
                } description: {
                    Text(searchText.isEmpty
                         ? "There are no files in this category for the current scan."
                         : "Try a different search term to find files in this category.")
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, id: \.id) { file in
                    let fileURL = URL(fileURLWithPath: file.filePath)
                    let isProbable = category == .probableDuplicates
                    HStack(spacing: 12) {

                        // Role badge for probable-duplicate pairs
                        if isProbable {
                            Image(systemName: file.isProbableDuplicate ? "arrow.right.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(file.isProbableDuplicate ? .yellow : .green)
                                .font(.caption)
                                .frame(width: 16)
                                .help(file.isProbableDuplicate ? "Will move to Probable Duplicates/" : "Original — stays organized")
                        } else {
                            Image(systemName: {
                                switch file.mediaKind {
                                case .video:   return "video.fill"
                                case .archive: return "doc.zipper"
                                default:       return "photo"
                                }
                            }())
                            .foregroundStyle(categoryColor)
                            .frame(width: 20)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(file.filename)
                                    .fontWeight(.medium)
                                    .lineLimit(1)

                                // Confidence badge for probable duplicates
                                if isProbable && file.isProbableDuplicate && file.probableMatchScore > 0 {
                                    Text("\(file.probableMatchScore)%")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(.yellow.opacity(0.2), in: Capsule())
                                        .foregroundStyle(.orange)
                                }
                            }

                            // Standard metadata line
                            HStack(spacing: 8) {
                                Text(file.formattedFileSize)
                                if let date = file.dateTaken {
                                    Text("·")
                                    Text(date, style: .date)
                                } else {
                                    Text("·  No date").foregroundStyle(.orange)
                                }
                                if file.isDuplicate {
                                    Text("·  Exact dup").foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            // Probable duplicate details
                            if isProbable {
                                if file.isProbableDuplicate,
                                   let peer = file.probableMatchPeerFilename,
                                   let reasons = file.probableMatchReasons {
                                    Text("↔ \(peer)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(reasons)
                                        .font(.caption2).foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                } else if !file.isProbableDuplicate {
                                    Text("Original copy — will stay in organized structure")
                                        .font(.caption2).foregroundStyle(.green.opacity(0.8))
                                }
                            } else {
                                Text(file.filePath)
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }

                        Spacer()

                        // Show in Finder
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                    }
                    .padding(.vertical, 4)
                    .background(
                        hoveredFileID == file.id
                            ? categoryColor.opacity(0.07)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                    .onHover { hoveredFileID = $0 ? file.id : nil }
                    .onTapGesture { previewURL = fileURL }
                    .help("Click to preview")
                }
                .listStyle(.plain)
                .sheet(isPresented: previewBinding) {
                    if let previewURL {
                        QuickLookPreviewContainer(
                            url: previewURL,
                            onClose: { self.previewURL = nil }
                        )
                        .frame(minWidth: 720, minHeight: 520)
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("\(filtered.count) of \(files.count) shown")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private var previewBinding: Binding<Bool> {
        Binding(
            get: { previewURL != nil },
            set: { isPresented in
                if !isPresented {
                    previewURL = nil
                }
            }
        )
    }
}

private struct QuickLookPreviewContainer: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QuickLookPreviewSheet(url: url)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary, Color(.windowBackgroundColor))
                    .padding(14)
            }
            .buttonStyle(.plain)
            .help("Close preview")
        }
    }
}

private struct QuickLookPreviewSheet: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        guard let previewView = QLPreviewView(frame: .zero, style: .normal) else {
            preconditionFailure("Failed to create QLPreviewView")
        }
        previewView.autostarts = true
        previewView.previewItem = url as NSURL
        return previewView
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as NSURL
    }
}

// MARK: ─── Tappable Stat Card ─────────────────────────────────────────────────

struct TappableStatCard: View {
    let icon: String
    let label: String
    let value: Int
    let color: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(value)")
                        .font(.title2).fontWeight(.bold).monospacedDigit()
                    Text(label)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()

                if value > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .opacity(isHovering ? 1 : 0)
                }
            }
            .padding(16)
            .background(
                isHovering ? color.opacity(0.08) : Color(.windowBackgroundColor).opacity(0.5),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovering ? color.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(value == 0)
    }
}

// MARK: ─── Shared stat widgets ─────────────────────────────────────────────────

struct StatLabel: View {
    let value: Int
    let label: String
    var body: some View {
        Text("\(value) \(label)")
    }
}
