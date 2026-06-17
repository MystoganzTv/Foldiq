// IOSPhotosExportView.swift
// iPhone/iPad flow: export organized copies from Photos Library to Files.

import SwiftUI
import Photos
import PhotosUI
import UniformTypeIdentifiers

#if !os(macOS)
struct IOSPhotosExportView: View {
    @StateObject private var exporter = PhotoLibraryExporter()
    @State private var showingDestinationPicker = false
    @State private var destinationFolder: URL?
    @State private var organizationMode: OrganizationMode = .smartHybrid
    @State private var includeLocation = true
    @State private var showingItemChooser = false
    @State private var searchText = ""
    @State private var activeTask: Task<Void, Never>?
    @State private var showingSystemPicker = false
    @State private var pickedPhotoItems: [PhotosPickerItem] = []

    // What's New / update news
    @State private var showingWhatsNew = false
    /// Stores the last app version for which the user has seen the What's New screen.
    @AppStorage("lastSeenWhatsNewVersion") private var lastSeenWhatsNewVersion = ""

    private var filteredItems: [PhotoLibraryItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return exporter.items }

        return exporter.items.filter { item in
            item.filename.localizedCaseInsensitiveContains(trimmed) ||
            item.kind.rawValue.localizedCaseInsensitiveContains(trimmed) ||
            item.formattedDate.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var visibleItems: [PhotoLibraryItem] {
        Array(filteredItems.prefix(250))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    statusCard
                    configurationPanel
                    selectionPanel
                    actionArea
                    safetyNotes
                    privacyNote
                    versionFooter
                }
                .padding(24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Foldiq")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingWhatsNew = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .accessibilityLabel("What's New")
                }
            }
            .sheet(isPresented: $showingWhatsNew, onDismiss: markWhatsNewSeen) {
                WhatsNewView()
            }
            .onAppear {
                if lastSeenWhatsNewVersion != AppInfo.version {
                    showingWhatsNew = true
                }
            }
            .fileImporter(
                isPresented: $showingDestinationPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        exporter.fail("No export folder was selected.")
                        return
                    }
                    destinationFolder = url
                case .failure(let error):
                    let nsError = error as NSError
                    guard nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError else {
                        return
                    }
                    exporter.fail("Could not open the export folder. \(error.localizedDescription)")
                }
            }
            .photosPicker(
                isPresented: $showingSystemPicker,
                selection: $pickedPhotoItems,
                maxSelectionCount: nil,
                selectionBehavior: .default,
                matching: .any(of: [.images, .videos]),
                preferredItemEncoding: .automatic,
                photoLibrary: .shared()
            )
            .photosPickerDisabledCapabilities(.stagingArea)
            .photosPickerAccessoryVisibility(.hidden, edges: .bottom)
            .onChange(of: pickedPhotoItems) { _, newItems in
                handlePickerSelection(newItems.compactMap(\.itemIdentifier))
            }
            .onDisappear {
                activeTask?.cancel()
                activeTask = nil
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
            case .idle:
                idleState
            case .requestingAccess:
                ProgressView("Requesting Photos access…")
            case .scanning:
                ProgressView("Scanning Photos Library…")
                Text("Reading your library so you can review items before exporting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .ready:
                summary
            case .exporting:
                exportProgress
            case .completed(let folder, let count, let skipped, let failures):
                completionSummary(folder: folder, exportedCount: count, skippedCount: skipped, failures: failures)
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

    private var idleState: some View {
        VStack(spacing: 12) {
            Label("Choose only what you want", systemImage: "hand.tap")
                .font(.title3.bold())
            Text("Pick specific photos and videos, or scan the full Photos Library and choose what to export in Foldiq before saving.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var summary: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                stat("\(exporter.photoCount)", "Photos", "photo")
                stat("\(exporter.videoCount)", "Videos", "video")
                stat(exporter.dateRangeText, "Date Range", "calendar")
            }

            Text("\(exporter.selectedCount) of \(exporter.items.count) items selected for export.")
                .font(.headline)

            Text("Change the selection any time with the system picker, or use the quick filters below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var configurationPanel: some View {
        if case .ready = exporter.phase {
            VStack(alignment: .leading, spacing: 14) {
                Label("Organization", systemImage: "slider.horizontal.3")
                    .font(.headline)

                Picker("Folder structure", selection: $organizationMode) {
                    ForEach(OrganizationMode.allCases, id: \.rawValue) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text(organizationMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if organizationMode == .smartHybrid {
                    Toggle("Use location when available", isOn: $includeLocation)
                        .toggleStyle(.switch)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var selectionPanel: some View {
        if case .ready = exporter.phase {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Choose Items", systemImage: "checklist")
                        .font(.headline)
                    Spacer()
                    Text("\(exporter.selectedCount) selected")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.blue)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { selectionButtons }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .buttonBorderShape(.capsule)
                        .padding(.vertical, 2)
                }

                TextField("Search by filename, type, or date", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                if filteredItems.count > visibleItems.count {
                    Text("Showing the first \(visibleItems.count) of \(filteredItems.count) matching items to keep scrolling usable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(filteredItems.count) matching items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup(isExpanded: $showingItemChooser) {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleItems) { item in
                            Button {
                                exporter.toggleSelection(for: item)
                            } label: {
                                PhotoSelectionRow(
                                    item: item,
                                    isSelected: exporter.selectedItemIDs.contains(item.id)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Review photos and videos with previews")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var selectionButtons: some View {
        Button { exporter.selectAll() } label: {
            Label("Select All", systemImage: "checkmark.circle.fill")
        }
        .tint(.blue)
        Button { exporter.selectPhotosOnly() } label: {
            Label("Photos", systemImage: "photo")
        }
        .tint(.blue)
        Button { exporter.selectVideosOnly() } label: {
            Label("Videos", systemImage: "video")
        }
        .tint(.purple)
        Button { exporter.clearSelection() } label: {
            Label("Clear", systemImage: "xmark.circle")
        }
        .tint(.gray)
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
    private func completionSummary(
        folder: URL,
        exportedCount: Int,
        skippedCount: Int,
        failures: [PhotoLibraryExporter.FailedExport]
    ) -> some View {
        let hasFailures = !failures.isEmpty
        let exportedLabel: String = {
            if exportedCount == 0 && skippedCount > 0 && !hasFailures {
                return "Already up to date — \(skippedCount) already exported"
            }
            var parts = ["Exported \(exportedCount)"]
            if skippedCount > 0 { parts.append("\(skippedCount) already there") }
            if hasFailures { parts.append("\(failures.count) failed") }
            return parts.joined(separator: " · ")
        }()
        let exportedColor: Color = hasFailures ? .orange : .green
        let exportedIcon = hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"

        VStack(spacing: 12) {
            Label(exportedLabel, systemImage: exportedIcon)
                .font(.title3.bold())
                .foregroundStyle(exportedColor)

            Text(folder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)

            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(failures.prefix(3)) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.filename)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(failure.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if failures.count > 3 {
                        Text("+\(failures.count - 3) more skipped files")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch exporter.phase {
        case .idle:
            VStack(spacing: 12) {
                Button {
                    openSystemPicker()
                } label: {
                    Label("Choose Photos and Videos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    startScan()
                } label: {
                    Label("Select Entire Library", systemImage: "photo.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        case .requestingAccess, .scanning:
            VStack(spacing: 12) {
                Button {
                    cancelActiveOperation(resetToStart: true)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        case .ready:
            VStack(spacing: 12) {
                if let destinationFolder {
                    VStack(spacing: 4) {
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
                    }

                    Button {
                        startExport(to: destinationFolder)
                    } label: {
                        Label("Export \(exporter.selectedCount) Organized Copies", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(exporter.selectedCount == 0)

                    HStack(spacing: 20) {
                        Button {
                            showingDestinationPicker = true
                        } label: {
                            Text("Change folder")
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)

                        Button {
                            returnToStart()
                        } label: {
                            Text("Back to start")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                } else {
                    Button {
                        showingDestinationPicker = true
                    } label: {
                        Label("Choose Export Folder", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        returnToStart()
                    } label: {
                        Text("Back to start")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        case .completed:
            VStack(spacing: 12) {
                Button {
                    returnToStart()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        case .exporting:
            VStack(spacing: 12) {
                Button {
                    cancelActiveOperation(resetToStart: false)
                } label: {
                    Label("Cancel Export", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        case .failed:
            VStack(spacing: 12) {
                if exporter.hasLoadedItems {
                    // Keep the user's existing selection — retry the SAME items,
                    // don't silently rescan the whole library.
                    Button {
                        exporter.returnToReview()
                    } label: {
                        Label("Back to Review", systemImage: "arrow.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        returnToStart()
                    } label: {
                        Label("Start Over", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button {
                        startScan()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    private func startScan() {
        activeTask?.cancel()
        activeTask = Task {
            await exporter.requestAccessAndScan()
            activeTask = nil
        }
    }

    private func startLoadSelectedItems(_ identifiers: [String]) {
        activeTask?.cancel()
        activeTask = Task {
            await exporter.loadSelectedItems(localIdentifiers: identifiers)
            activeTask = nil
        }
    }

    private func startExport(to destinationFolder: URL) {
        activeTask?.cancel()
        activeTask = Task {
            await exporter.export(
                to: destinationFolder,
                mode: organizationMode,
                includeLocation: includeLocation
            )
            activeTask = nil
        }
    }

    private func cancelActiveOperation(resetToStart: Bool) {
        activeTask?.cancel()
        activeTask = nil

        if resetToStart {
            returnToStart()
        } else {
            exporter.returnToReview()
        }
    }

    private func returnToStart() {
        exporter.resetToStart()
        destinationFolder = nil
        searchText = ""
        pickedPhotoItems = []
        showingItemChooser = false
    }

    private func handlePickerSelection(_ identifiers: [String]) {
        let uniqueIdentifiers = Array(NSOrderedSet(array: identifiers)) as? [String] ?? identifiers

        guard !uniqueIdentifiers.isEmpty else {
            if !exporter.hasLoadedItems {
                exporter.resetToStart()
            }
            return
        }

        startLoadSelectedItems(uniqueIdentifiers)
    }

    private func openSystemPicker() {
        pickedPhotoItems = exporter.items.map { PhotosPickerItem(itemIdentifier: $0.id) }
        showingSystemPicker = true
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

    // Privacy disclosure — same copy already approved for the Mac app (Settings → About),
    // shown in-app rather than as a web page. "device" replaces "Mac" for iOS.
    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("100% local processing", systemImage: "icloud.slash")
                .font(.caption.weight(.medium))
            Text("Foldiq never uploads your files or metadata to any server. All organization happens entirely on your device.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                if let privacy = URL(string: "https://foldiq.app/privacy") {
                    Link("Privacy Policy", destination: privacy)
                }
                if let terms = URL(string: "https://foldiq.app/terms") {
                    Link("Terms", destination: terms)
                }
            }
            .font(.caption2.weight(.medium))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var versionFooter: some View {
        Button {
            showingWhatsNew = true
        } label: {
            VStack(spacing: 2) {
                Text("Foldiq \(AppInfo.versionString)")
                    .font(.caption2)
                Text("What's New")
                    .font(.caption2.weight(.medium))
                    .underline()
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func markWhatsNewSeen() {
        lastSeenWhatsNewVersion = AppInfo.version
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
            Text(value)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 4)
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

private struct PhotoSelectionRow: View {
    let item: PhotoLibraryItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            AssetThumbnailView(asset: item.asset)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.filename)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: item.kind == .video ? "video.fill" : "photo.fill")
                        .font(.caption)
                        .foregroundStyle(item.kind == .video ? .purple : .blue)
                }

                Text(item.formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(10)
        .background(isSelected ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var subtitle: String {
        let kind = item.kind == .video ? "Video" : "Photo"
        return item.location == nil ? "\(kind) · No saved location" : "\(kind) · Has location"
    }
}

private struct AssetThumbnailView: View {
    let asset: PHAsset

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    private static let manager = PHCachingImageManager()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.14))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: asset.mediaType == .video ? "video" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear(perform: loadThumbnail)
        .onDisappear(perform: cancelRequest)
    }

    private func loadThumbnail() {
        guard image == nil else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        requestID = Self.manager.requestImage(
            for: asset,
            targetSize: CGSize(width: 180, height: 180),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            image = result
        }
    }

    private func cancelRequest() {
        guard let requestID else { return }
        Self.manager.cancelImageRequest(requestID)
        self.requestID = nil
    }
}

private extension PhotoLibraryItem {
    var formattedDate: String {
        guard let date else { return "Unknown date" }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: ─── What's New ──────────────────────────────────────────────────────────

/// A single release entry shown in the What's New / update news screen.
struct FoldiqRelease: Identifiable {
    let id = UUID()
    /// Marketing version this entry describes, e.g. "1.0.4".
    let version: String
    /// Human-readable date label, e.g. "June 2026".
    let date: String
    /// Bullet points: (SF Symbol name, text).
    let highlights: [(symbol: String, text: String)]
}

extension FoldiqRelease {
    /// ⬇️ EDIT ME — paste your real update notes here. Newest version first.
    /// The top entry is what auto-shows when users update to a new version.
    static let all: [FoldiqRelease] = [
        FoldiqRelease(
            version: AppInfo.version,   // tracks the real bundle version, always matches the footer
            date: "June 2026",
            highlights: [
                ("livephoto", "Live Photos stay whole — they export as a matching pair, the still and its motion video together, so nothing is lost."),
                ("arrow.triangle.2.circlepath", "Smarter re-exports — Foldiq remembers what it already saved and skips it, so running an export again is fast and never re-downloads from iCloud."),
                ("icloud.and.arrow.down", "Reliable iCloud downloads — full-resolution photos stored in iCloud now download correctly during export, with clearer messages if iCloud isn't ready."),
                ("checkmark.shield", "Your selection is kept — if an export fails, Foldiq keeps your chosen photos so you can retry without scanning your whole library again."),
                ("sparkles", "Refreshed look — cleaner selection chips, a tidier review screen, and a simpler one-tap finish.")
            ]
        )
    ]
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    ForEach(FoldiqRelease.all) { release in
                        releaseSection(release)
                    }
                }
                .padding(24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text("Updates to Foldiq")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("News about what's new and improved in the app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func releaseSection(_ release: FoldiqRelease) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Version \(release.version)")
                    .font(.title3.bold())
                Spacer()
                Text(release.date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(release.highlights.enumerated()), id: \.offset) { _, item in
                    Label {
                        Text(item.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: item.symbol)
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}
#endif
