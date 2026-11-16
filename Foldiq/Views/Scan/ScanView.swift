// ScanView.swift
// Step 2: Runs the full scan pipeline and shows aggregate results.
// Stat cards are tappable — clicking one opens a sheet listing the files in that category.

import SwiftUI
import SwiftData
import ImageIO
#if os(macOS)
import AppKit
import QuickLookUI
#else
import QuickLook
#endif

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
        let startedAt = Date()
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
            if !Task.isCancelled {
                AnonymousTelemetry.send(
                    .scanCompleted,
                    success: session != nil,
                    elapsed: Date().timeIntervalSince(startedAt),
                    itemCount: session?.files.count ?? 0
                )
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
        case .extracting, .hashing, .matching:
            let total = max(coordinator.phaseItemCount, 1)
            return min(Double(coordinator.processedCount) / Double(total), 1.0)
        default:
            return 0
        }
    }

    var isFailed: Bool { coordinator.phase == .failed }
    var isActive: Bool {
        coordinator.phase == .scanning ||
        coordinator.phase == .extracting ||
        coordinator.phase == .hashing ||
        coordinator.phase == .matching
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
                        .frame(maxWidth: 400)
                        .tint(.blue)

                    HStack(spacing: 20) {
                        StatLabel(value: coordinator.foundCount, label: "found")
                        StatLabel(value: coordinator.processedCount, label: "processed")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
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
        case archives           = "From Archives"
        case duplicates         = "Exact Duplicates"
        case probableDuplicates = "Same Image"
        case similarPhotos      = "Similar Photos"
        case missingDate        = "Missing Date"
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
                TappableStatCard(icon: "doc.zipper",           label: "Archives Extracted", value: session.archivesExtractedCount, color: .teal) { drillCategory = .archives }
                TappableStatCard(icon: "square.on.square",     label: "Exact Dupes",      value: session.duplicateCount,         color: .orange) { drillCategory = .duplicates }
                TappableStatCard(icon: "square.stack.3d.up",    label: "Same Image", value: session.probableDuplicateCount, color: .yellow) { drillCategory = .probableDuplicates }
                TappableStatCard(icon: "photo.on.rectangle.angled", label: "Similar Photos", value: session.files.filter { $0.probableDuplicateGroupID != nil && $0.probableMatchKindRaw != "same" }.count, color: .indigo) { drillCategory = .similarPhotos }
                TappableStatCard(icon: "questionmark.circle",  label: "Missing Date",     value: session.missingDateCount,       color: .red)    { drillCategory = .missingDate }
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
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var previewURL: URL?          // Quick Look target
    @State private var hoveredFileID: UUID?      // for row highlight
    @State private var selectedComparisonGroupID: UUID?
    @State private var selectedComparisonFileID: UUID?
    @State private var comparisonZoom = 1.0

    struct ComparisonGroup: Identifiable {
        let id: UUID
        let files: [MediaFile]
    }

    var files: [MediaFile] {
        let all = session.files
        switch category {
        case .photos:             return all.filter { $0.mediaKind == .photo }
        case .videos:             return all.filter { $0.mediaKind == .video }
        case .archives:           return all.filter { $0.archiveSourcePath != nil }
        case .duplicates:         return all
                .filter { $0.duplicateGroupID != nil }
                .sorted {
                    let g = ($0.duplicateGroupID?.uuidString ?? "") <
                            ($1.duplicateGroupID?.uuidString ?? "")
                    return g || ($0.duplicateGroupID == $1.duplicateGroupID
                                 && $0.isDuplicate && !$1.isDuplicate)
                }
        case .probableDuplicates: return all
                .filter { $0.probableMatchKindRaw == "same" }
                .sorted {
                    let g = ($0.probableDuplicateGroupID?.uuidString ?? "") <
                            ($1.probableDuplicateGroupID?.uuidString ?? "")
                    return g || ($0.probableDuplicateGroupID == $1.probableDuplicateGroupID
                                 && $0.isProbableDuplicate && !$1.isProbableDuplicate)
                }
        case .similarPhotos: return all
                .filter { $0.probableDuplicateGroupID != nil && $0.probableMatchKindRaw != "same" }
                .sorted {
                    let g = ($0.probableDuplicateGroupID?.uuidString ?? "") <
                            ($1.probableDuplicateGroupID?.uuidString ?? "")
                    return g || ($0.probableDuplicateGroupID == $1.probableDuplicateGroupID
                                 && $0.filename < $1.filename)
                }
        case .missingDate:        return all.filter { !$0.hasDate }
        case .allFiles:           return all
        }
    }

    var filtered: [MediaFile] {
        guard !searchText.isEmpty else { return files }
        let q = searchText.lowercased()
        return files.filter { $0.filename.lowercased().contains(q) || $0.filePath.lowercased().contains(q) }
    }

    var isComparisonCategory: Bool {
        category == .duplicates || category == .probableDuplicates || category == .similarPhotos
    }

    var comparisonGroups: [ComparisonGroup] {
        let eligible = filtered.filter { comparisonGroupID(for: $0) != nil }
        return Dictionary(grouping: eligible, by: { comparisonGroupID(for: $0)! })
            .map { id, files in
                ComparisonGroup(id: id, files: files.sorted { $0.filename < $1.filename })
            }
            .filter { $0.files.count > 1 }
            .sorted { ($0.files.first?.filename ?? "") < ($1.files.first?.filename ?? "") }
    }

    var selectedComparisonGroup: ComparisonGroup? {
        comparisonGroups.first { $0.id == selectedComparisonGroupID } ?? comparisonGroups.first
    }

    var comparisonBaseFile: MediaFile? {
        guard let group = selectedComparisonGroup else { return nil }
        if category == .duplicates,
           let original = group.files.first(where: { !$0.isDuplicate }) {
            return original
        }
        if category == .probableDuplicates,
           let original = group.files.first(where: { !$0.isProbableDuplicate }) {
            return original
        }
        return group.files.sorted {
            let left = $0.dateTaken ?? $0.dateModified ?? .distantFuture
            let right = $1.dateTaken ?? $1.dateModified ?? .distantFuture
            return left == right ? $0.filename < $1.filename : left < right
        }.first
    }

    var comparisonCandidates: [MediaFile] {
        guard let base = comparisonBaseFile, let group = selectedComparisonGroup else { return [] }
        return group.files.filter { $0.id != base.id }
    }

    var selectedComparisonFile: MediaFile? {
        comparisonCandidates.first { $0.id == selectedComparisonFileID } ?? comparisonCandidates.first
    }

    var categoryColor: Color {
        switch category {
        case .photos:             return .blue
        case .videos:             return .purple
        case .archives:           return .teal
        case .duplicates:         return .orange
        case .probableDuplicates: return .yellow
        case .similarPhotos:      return .indigo
        case .missingDate:        return .red
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
        case .similarPhotos:      return "photo.on.rectangle.angled"
        case .missingDate:        return "questionmark.circle"
        case .allFiles:           return "doc.on.doc"
        }
    }

    var explainerText: String {
        switch category {
        case .archives:
            return "These photos and videos were extracted from compressed archives. The original ZIP, RAR, or 7z files remain untouched. On undo, Foldiq removes only the organized copies."
        case .missingDate:
            return "Foldiq could not determine when these photos were taken. They will stay in Unknown Date unless you assign the real date in Preview."
        case .duplicates:
            return "These photos are exactly identical. Choose the copy to keep; the others go to a safe review folder and can be restored with Undo."
        case .probableDuplicates:
            return "These are the same photo after renaming, rotation, metadata changes, or re-encoding. Choose the copy to keep; the others go to Duplicates/To Review."
        case .similarPhotos:
            return "Compare the photos, then keep one, keep all, or leave this group completely untouched."
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
                    Text(isComparisonCategory
                         ? "\(comparisonGroups.count) group\(comparisonGroups.count == 1 ? "" : "s") · \(files.count) photos"
                         : "\(files.count) file\(files.count == 1 ? "" : "s")")
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

            // File list or visual comparison workspace
            if isComparisonCategory {
                comparisonWorkspace
            } else if filtered.isEmpty {
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
                    let isSmartMatch = category == .probableDuplicates || category == .similarPhotos
                    HStack(spacing: 12) {

                        // Role badge for probable-duplicate pairs
                        if isSmartMatch {
                            Image(systemName: category == .similarPhotos ? "eye.circle.fill" : (file.isProbableDuplicate ? "arrow.right.circle.fill" : "checkmark.circle.fill"))
                                .foregroundStyle(category == .similarPhotos ? .indigo : .yellow)
                                .font(.caption)
                                .frame(width: 16)
                                .help(category == .similarPhotos ? "Compare and choose the photo to keep" : (file.isProbableDuplicate ? "Other copy" : "Recommended copy"))
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
                                if isSmartMatch && file.probableMatchScore > 0 {
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
                                    Text("·  Date unknown").foregroundStyle(.orange)
                                }
                                if file.isDuplicate {
                                    Text("·  Exact dup").foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            // Probable duplicate details
                            if isSmartMatch {
                                if let peer = file.probableMatchPeerFilename,
                                   let reasons = file.probableMatchReasons {
                                    Text("↔ \(peer)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(reasons)
                                        .font(.caption2).foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                if category == .similarPhotos {
                                    Text("\(similarKindLabel(file)) — you decide")
                                        .font(.caption2).foregroundStyle(.indigo.opacity(0.8))
                                } else if !file.isProbableDuplicate {
                                    Text("Best copy — stays in organized structure")
                                        .font(.caption2).foregroundStyle(.blue.opacity(0.8))
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
                            PlatformActions.revealInFileManager(fileURL)
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
                Text(isComparisonCategory
                     ? "\(comparisonGroups.count) comparison group\(comparisonGroups.count == 1 ? "" : "s")"
                     : "\(filtered.count) of \(files.count) shown")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: isComparisonCategory ? 900 : 560,
               idealWidth: isComparisonCategory ? 1060 : 620,
               minHeight: isComparisonCategory ? 600 : 480,
               idealHeight: isComparisonCategory ? 700 : 540)
        .onAppear { selectInitialComparisonIfNeeded() }
        .onChange(of: comparisonGroups.map(\.id)) { _, _ in selectInitialComparisonIfNeeded() }
    }

    @ViewBuilder
    private var comparisonWorkspace: some View {
        if comparisonGroups.isEmpty {
            ContentUnavailableView {
                Label("No comparison groups", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Try clearing the search to see every matching group.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        Button("Use all recommendations") {
                            keepRecommendedInAllGroups()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.bottom, 4)

                        ForEach(comparisonGroups) { group in
                            let selected = selectedComparisonGroup?.id == group.id
                            Button {
                                selectedComparisonGroupID = group.id
                                selectedComparisonFileID = comparisonCandidate(in: group)?.id
                                comparisonZoom = 1
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: category == .similarPhotos
                                          ? "photo.on.rectangle.angled" : "square.stack.3d.up")
                                        .foregroundStyle(selected ? .white : categoryColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.files.first?.filename ?? "Photo group")
                                            .lineLimit(1)
                                            .font(.caption.weight(.semibold))
                                        Text("\(group.files.count) photos")
                                            .font(.caption2)
                                            .opacity(0.75)
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .foregroundStyle(selected ? .white : .primary)
                                .background(selected ? categoryColor : categoryColor.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
                .frame(width: 230)

                Divider()

                VStack(spacing: 12) {
                    HStack {
                        Label(category == .duplicates ? "Exact copies" : (category == .similarPhotos ? "You decide" : "Same image"),
                              systemImage: category == .similarPhotos ? "hand.tap.fill" : "checkmark.shield.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(category == .similarPhotos ? .orange : .green)
                        Spacer()
                        Text(comparisonZoom > 1 ? "Drag photos to inspect" : "Synchronized zoom")
                            .font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $comparisonZoom, in: 1...3, step: 0.25)
                            .frame(width: 130)
                        Text(String(format: "%.2gx", comparisonZoom))
                            .font(.caption.monospacedDigit())
                            .frame(width: 38, alignment: .trailing)
                    }

                    if let base = comparisonBaseFile, let candidate = selectedComparisonFile {
                        HStack(spacing: 12) {
                            ComparisonPhotoCard(
                                file: base,
                                title: "Recommended",
                                tint: .green,
                                zoom: comparisonZoom,
                                isKept: keptPhotoID(in: selectedComparisonGroup) == base.id,
                                onKeep: { keep(base, in: selectedComparisonGroup) },
                                onOpen: { previewURL = base.url }
                            )
                            ComparisonPhotoCard(
                                file: candidate,
                                title: category == .similarPhotos ? similarKindLabel(candidate) : "Other copy",
                                tint: category == .similarPhotos ? .orange : .yellow,
                                zoom: comparisonZoom,
                                isKept: keptPhotoID(in: selectedComparisonGroup) == candidate.id,
                                onKeep: { keep(candidate, in: selectedComparisonGroup) },
                                onOpen: { previewURL = candidate.url }
                            )
                        }

                        if comparisonCandidates.count > 1 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Compare another photo in this group")
                                    .font(.caption2).foregroundStyle(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(comparisonCandidates, id: \.id) { file in
                                            Button {
                                                selectedComparisonFileID = file.id
                                                comparisonZoom = 1
                                            } label: {
                                                ComparisonFilmstripItem(
                                                    file: file,
                                                    selected: selectedComparisonFile?.id == file.id
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            Button(selectedComparisonGroup?.files.count == 2 ? "Keep both" : "Keep all") {
                                keepAll(in: selectedComparisonGroup)
                            }
                            .buttonStyle(.bordered)
                            .tint(allPhotosKept(in: selectedComparisonGroup) ? Color.green : Color.accentColor)

                            Button("Leave group untouched") {
                                leaveUntouched(selectedComparisonGroup)
                            }
                            .buttonStyle(.bordered)
                            .tint(groupIsUntouched(selectedComparisonGroup) ? Color.orange : Color.secondary)
                        }
                    }

                    Text(groupDecisionSummary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(groupIsUntouched(selectedComparisonGroup) ? Color.secondary : Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
            .sheet(isPresented: previewBinding) {
                if let previewURL {
                    QuickLookPreviewContainer(url: previewURL, onClose: { self.previewURL = nil })
                        .frame(minWidth: 720, minHeight: 520)
                }
            }
        }
    }

    private func comparisonCandidate(in group: ComparisonGroup) -> MediaFile? {
        let base: MediaFile?
        if category == .duplicates {
            base = group.files.first(where: { !$0.isDuplicate }) ?? group.files.first
        } else if category == .probableDuplicates {
            base = group.files.first(where: { !$0.isProbableDuplicate }) ?? group.files.first
        } else {
            base = group.files.first
        }
        return group.files.first { $0.id != base?.id }
    }

    private func comparisonGroupID(for file: MediaFile) -> UUID? {
        category == .duplicates ? file.duplicateGroupID : file.probableDuplicateGroupID
    }

    private func keptPhotoID(in group: ComparisonGroup?) -> UUID? {
        guard let group else { return nil }
        if group.files.allSatisfy(\.isUserExcluded) { return nil }
        if group.files.contains(where: { $0.isUserSetAside }) {
            return group.files.first(where: { !$0.isUserSetAside })?.id
        }
        if category == .duplicates {
            return group.files.first(where: { !$0.isDuplicate })?.id
        }
        if category == .probableDuplicates {
            return group.files.first(where: { !$0.isProbableDuplicate })?.id
        }
        return nil
    }

    private func keep(_ chosen: MediaFile, in group: ComparisonGroup?) {
        guard let group else { return }
        for file in group.files {
            let setAside = file.id != chosen.id
            file.isUserExcluded = false
            file.isUserSetAside = setAside
            if category == .duplicates {
                file.isDuplicate = setAside
            } else {
                file.isProbableDuplicate = setAside
            }
        }
        try? modelContext.save()
    }

    private func keepAll(in group: ComparisonGroup?) {
        guard let group else { return }
        for file in group.files {
            file.isUserExcluded = false
            file.isUserSetAside = false
            if category == .duplicates {
                file.isDuplicate = false
            } else {
                file.isProbableDuplicate = false
            }
        }
        try? modelContext.save()
    }

    private func leaveUntouched(_ group: ComparisonGroup?) {
        guard let group else { return }
        for file in group.files {
            file.isUserExcluded = true
            file.isUserSetAside = false
        }
        try? modelContext.save()
    }

    private func allPhotosKept(in group: ComparisonGroup?) -> Bool {
        guard let group else { return false }
        return group.files.allSatisfy { file in
            !file.isUserExcluded && !file.isUserSetAside &&
            (category == .duplicates ? !file.isDuplicate : !file.isProbableDuplicate)
        }
    }

    private func groupIsUntouched(_ group: ComparisonGroup?) -> Bool {
        guard let group else { return false }
        return group.files.allSatisfy(\.isUserExcluded)
    }

    private var groupDecisionSummary: String {
        if groupIsUntouched(selectedComparisonGroup) {
            return "This group will stay exactly where it is."
        }
        if allPhotosKept(in: selectedComparisonGroup) {
            return "All photos in this group will be organized."
        }
        return "Unwanted copies go to Duplicates/To Review. Nothing is deleted."
    }

    private func keepRecommendedInAllGroups() {
        for group in comparisonGroups {
            let recommended: MediaFile?
            if category == .duplicates {
                recommended = group.files.first(where: { !$0.isDuplicate }) ?? group.files.first
            } else if category == .probableDuplicates {
                recommended = group.files.first(where: { !$0.isProbableDuplicate }) ?? group.files.first
            } else {
                recommended = group.files.max {
                    let lhsPixels = ($0.pixelWidth ?? 0) * ($0.pixelHeight ?? 0)
                    let rhsPixels = ($1.pixelWidth ?? 0) * ($1.pixelHeight ?? 0)
                    return lhsPixels == rhsPixels ? $0.fileSize < $1.fileSize : lhsPixels < rhsPixels
                }
            }
            if let recommended { keep(recommended, in: group) }
        }
    }

    private func selectInitialComparisonIfNeeded() {
        guard let group = selectedComparisonGroup else { return }
        if selectedComparisonGroupID == nil { selectedComparisonGroupID = group.id }
        if selectedComparisonFileID == nil { selectedComparisonFileID = comparisonCandidates.first?.id }
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

    private func similarKindLabel(_ file: MediaFile) -> String {
        switch file.probableMatchKindRaw {
        case "burst": return "Burst"
        case "edited": return "Edited version"
        default: return "Visually similar"
        }
    }
}

private struct ComparisonPhotoCard: View {
    let file: MediaFile
    let title: String
    let tint: Color
    let zoom: Double
    let isKept: Bool
    let onKeep: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Spacer()
                if file.probableMatchScore > 0 {
                    Text("\(file.probableMatchScore)%")
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(tint.opacity(0.14), in: Capsule())
                }
            }

            LocalPhotoThumbnail(file: file, zoom: zoom)
                .frame(maxWidth: .infinity, minHeight: 220, idealHeight: 260, maxHeight: 300)
                .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .help(zoom > 1 ? "Drag to move around the zoomed photo" : "Click for full preview")

            Text(file.filename)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Text(file.formattedFileSize)
                if let width = file.pixelWidth, let height = file.pixelHeight {
                    Text("· \(width)×\(height)")
                }
                if let date = file.dateTaken {
                    Text("·")
                    Text(date, style: .date)
                } else {
                    Text("· No embedded date").foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Button(isKept ? "Keeping this photo" : "Keep this photo", action: onKeep)
                .buttonStyle(.borderedProminent)
                .tint(isKept ? .green : .accentColor)
                .frame(maxWidth: .infinity)
        }
        .padding(11)
        .background(PlatformColors.windowBackground.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.25)))
        .frame(maxWidth: .infinity)
    }
}

private struct ComparisonFilmstripItem: View {
    let file: MediaFile
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            LocalPhotoThumbnail(file: file, zoom: 1)
                .frame(width: 72, height: 52)
                .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(file.filename)
                .font(.system(size: 8))
                .lineLimit(1)
                .frame(width: 72)
        }
        .padding(5)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: selected ? 2 : 1))
    }
}

private struct LocalPhotoThumbnail: View {
    let file: MediaFile
    let zoom: Double
    @State private var image: PlatformImage?
    @State private var panOffset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let visibleOffset = limitedOffset(
                CGSize(
                    width: panOffset.width + dragOffset.width,
                    height: panOffset.height + dragOffset.height
                ),
                in: geometry.size
            )

            ZStack {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom)
                        .offset(visibleOffset)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($dragOffset) { value, state, _ in
                        guard zoom > 1 else { return }
                        state = value.translation
                    }
                    .onChanged { _ in
                        #if os(macOS)
                        if zoom > 1 { NSCursor.closedHand.set() }
                        #endif
                    }
                    .onEnded { value in
                        guard zoom > 1 else { return }
                        panOffset = limitedOffset(
                            CGSize(
                                width: panOffset.width + value.translation.width,
                                height: panOffset.height + value.translation.height
                            ),
                            in: geometry.size
                        )
                        #if os(macOS)
                        NSCursor.openHand.set()
                        #endif
                    }
            )
            .onChange(of: zoom) { _, newZoom in
                panOffset = newZoom <= 1 ? .zero : limitedOffset(panOffset, in: geometry.size)
                #if os(macOS)
                if newZoom <= 1 { NSCursor.arrow.set() }
                #endif
            }
        }
        .clipped()
        .modifier(PanCursorModifier(active: zoom > 1))
        .task(id: file.id) {
            panOffset = .zero
            image = await Self.loadThumbnail(url: file.url)
        }
    }

    private func limitedOffset(_ proposed: CGSize, in container: CGSize) -> CGSize {
        let extraScale = CGFloat(max(zoom - 1, 0))
        let maxX = container.width * extraScale / 2
        let maxY = container.height * extraScale / 2
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private static func loadThumbnail(url: URL) async -> PlatformImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [String: Any] = [
                kCGImageSourceThumbnailMaxPixelSize as String: 1200,
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceShouldCacheImmediately as String: true,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return PlatformImageFactory.make(cgImage: cgImage)
        }.value
    }
}

private struct PanCursorModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onHover { hovering in
            if hovering && active {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        #else
        content
        #endif
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
                    .foregroundStyle(.secondary, PlatformColors.windowBackground)
                    .padding(14)
            }
            .buttonStyle(.plain)
            .help("Close preview")
        }
    }
}

private struct QuickLookPreviewSheet: PlatformQuickLookRepresentable {
    let url: URL

    #if os(macOS)
    func makeNSView(context: Context) -> NSView {
        QuickLookPreviewFactory.makeView(for: url)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        QuickLookPreviewFactory.update(nsView, for: url)
    }
    #else
    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
    #endif
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
                isHovering ? color.opacity(0.08) : PlatformColors.windowBackground.opacity(0.5),
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
