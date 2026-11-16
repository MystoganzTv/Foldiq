// WelcomeView.swift
// Step 1: Intro + folder/archive picker (supports ZIP, RAR, and 7z on macOS).

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import Photos
#endif

struct WelcomeView: View {

    @EnvironmentObject private var nav: AppNavigator
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isHoveringButton = false
    @State private var isDragTargeted = false
    @State private var showingItemImporter = false
    /// The Mac's main Photos library, waiting for the person to choose what to take from it.
    @State private var pendingSystemLibrary: URL?
    #if os(macOS)
    @StateObject private var webUpdates = WebUpdateChecker()
    #endif
    @State private var interruptedManifests: [UndoManifest] = []
    @State private var isRecovering = false
    @State private var recoveryMessage: String?
    @State private var recoveryProgress = FileMover.ApplyProgress(done: 0, total: 1, currentFile: "", errors: [])
    private let recoveryMover = FileMover()

    // Undo toast (shown after returning from a successful undo)
    @State private var showUndoToast = false
    @State private var undoRestoredCount: Int?
    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var archiveContentTypes: [UTType] {
        MediaTypes.archiveExtensions.compactMap { UTType(filenameExtension: $0) }
    }
    /// Apple Photos libraries ("Photos Library.photoslibrary"). macOS only.
    private var photosLibraryContentTypes: [UTType] {
        #if os(macOS)
        [
            UTType("com.apple.photos.library"),
            UTType(filenameExtension: PhotosLibrarySupport.packageExtension, conformingTo: .package),
        ].compactMap { $0 }
        #else
        []
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if !interruptedManifests.isEmpty || recoveryMessage != nil {
                recoveryCard
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }

            #if os(macOS)
            if let version = webUpdates.availableVersion {
                updateBanner(version: version)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
            #endif

            // ── Logo & headline ─────────────────────────────────────────────
            VStack(spacing: 16) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: isCompact ? 56 : 72, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.pulse)

                Text("Organize Your Library")
                    .font(.system(size: isCompact ? 32 : 42, weight: .bold, design: .rounded))

                Text("Clean up and organize thousands of messy photos and videos safely, right on your device.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            .padding(.horizontal, 24)

            Spacer().frame(height: isCompact ? 28 : 48)

            // ── Selected items list ──────────────────────────────────────────
            if !nav.selectedFolderURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(nav.selectedFolderURLs, id: \.path) { url in
                        HStack(spacing: 8) {
                            Image(systemName: Self.iconName(for: url))
                                .foregroundStyle(Self.iconColor(for: url))
                                .font(.caption)
                            Text(url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if PhotosLibrarySupport.isDefaultSystemLibrary(url) {
                                Text(nav.organizationConfig.photosScope.summary)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.pink)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                nav.removeSelectedFolderURL(url)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            // ── CTA ─────────────────────────────────────────────────────────
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actionButtons }
                VStack(spacing: 12) { actionButtons }
            }
            .padding(.horizontal, 20)
            .animation(.spring(response: 0.3), value: nav.selectedFolderURLs.isEmpty)

            Spacer().frame(height: 16)

            // ── Hints ────────────────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("You can also drag folders, Photos libraries, or ZIP, RAR, and 7z archives onto this window")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .opacity(isCompact ? 0 : 1)

            #if os(macOS)
            Button {
                selectPhotosLibrary()
            } label: {
                Label("Export from Photos…", systemImage: "photo.on.rectangle.angled")
                    .font(.callout)
            }
            .buttonStyle(.link)
            .padding(.top, 10)
            .help("Save organized copies of your Photos library to a folder. Your photos stay in Photos.")
            #endif

            Spacer()

            // ── Disclaimer + How it works link ───────────────────────────────
            HStack(spacing: 16) {
                Text("Nothing is deleted without your permission.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button {
                    UserDefaults.standard.removeObject(forKey: "hasSeenOnboarding")
                    withAnimation(.easeInOut(duration: 0.35)) { nav.showOnboarding = true }
                } label: {
                    Text("How it works")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .underline()
                }
                .buttonStyle(.plain)

                Text(AppInfo.versionString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("App version (build number)")
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .openRootFolder)) { _ in
            selectItems()
        }
        .fileImporter(
            isPresented: $showingItemImporter,
            allowedContentTypes: [.folder] + archiveContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImportedItems(result)
        }
        #if os(macOS)
        .sheet(isPresented: isChoosingPhotosScope) {
            PhotosScopeSheet(
                includeVideos: nav.organizationConfig.includeVideos,
                onCancel: { pendingSystemLibrary = nil },
                onConfirm: { scope in
                    if let library = pendingSystemLibrary {
                        nav.organizationConfig.photosScope = scope
                        nav.addSelectedFolderURLs([library])
                    }
                    pendingSystemLibrary = nil
                }
            )
        }
        #endif
        // ── Drag & drop ──────────────────────────────────────────────────────
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay {
            if isDragTargeted {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.blue, lineWidth: 3)
                    .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.blue)
                            Text("Drop folders, Photos libraries, or archives to add them")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        // ── Undo toast ───────────────────────────────────────────────────────
        .overlay(alignment: .bottom) {
            if showUndoToast, let count = undoRestoredCount {
                UndoCompletedToast(restoredCount: count)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        #if os(macOS)
        .task { await webUpdates.check() }
        #endif
        .onAppear {
            // ── SwiftData cleanup ────────────────────────────────────────────
            // When we return to WelcomeView (via restart or back navigation),
            // nav.scanSession is nil. All persisted sessions are stale —
            // delete them now to prevent SwiftData conflicts and memory growth.
            purgeStaleSwiftData()
            loadInterruptedManifests()

            // ── Undo toast ───────────────────────────────────────────────────
            if let count = nav.lastUndoRestoredCount {
                undoRestoredCount = count
                nav.lastUndoRestoredCount = nil
                withAnimation(.spring(response: 0.4)) { showUndoToast = true }
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation(.easeOut) { showUndoToast = false }
                }
            }
        }
    }

    #if os(macOS)
    private func updateBanner(version: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("Foldiq \(version) is available")
                    .font(.headline)
                Text("Download it with the link in your order email — it always gives you the newest version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Later") { webUpdates.dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button("How to Update") { PlatformActions.openURL(webUpdates.downloadPage) }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: 640)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
    #endif

    private var recoveryCard: some View {
        HStack(spacing: 14) {
            Image(systemName: interruptedManifests.isEmpty ? "checkmark.shield.fill" : "exclamationmark.arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(interruptedManifests.isEmpty ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(interruptedManifests.isEmpty ? "Recovery Complete" : "An interrupted organization needs attention")
                    .font(.headline)
                Text(recoveryMessage ?? "Foldiq preserved a safety record. Restore completed files before starting another organization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isRecovering {
                    ProgressView(value: Double(recoveryProgress.done), total: Double(max(recoveryProgress.total, 1)))
                    Text(recoveryProgress.currentFile)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !interruptedManifests.isEmpty {
                Button(isRecovering ? "Restoring…" : "Restore Files Safely") {
                    recoverInterruptedManifests()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isRecovering)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func loadInterruptedManifests() {
        let states = ["applying", "undoing", "needsAttention"]
        interruptedManifests = ((try? context.fetch(FetchDescriptor<UndoManifest>())) ?? [])
            .filter { states.contains($0.stateRaw) && !$0.wasUndone }
    }

    private func recoverInterruptedManifests() {
        isRecovering = true
        recoveryMessage = nil
        Task {
            var restored = 0
            var errors: [String] = []
            for manifest in interruptedManifests.reversed() {
                let accessURLs = Self.restoreSecurityScope(from: manifest.securityBookmarksJSON)
                guard let outputPath = manifest.outputRootPath else {
                    errors.append("The recovery destination is missing from the safety record.")
                    accessURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                    continue
                }
                manifest.stateRaw = "undoing"
                try? context.save()
                let result = await recoveryMover.undo(
                    manifest: manifest,
                    outputRoot: URL(fileURLWithPath: outputPath),
                    checkpoint: { try context.save() }
                ) { recoveryProgress = $0 }
                restored += result.restored
                errors.append(contentsOf: result.errors)
                manifest.stateRaw = result.errors.isEmpty ? "undone" : "needsAttention"
                try? context.save()
                accessURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            }
            isRecovering = false
            loadInterruptedManifests()
            recoveryMessage = errors.isEmpty
                ? "Safe recovery complete — \(restored) file\(restored == 1 ? "" : "s") restored."
                : "Foldiq restored \(restored) files. \(errors[0])"
        }
    }

    private static func restoreSecurityScope(from json: String) -> [URL] {
        #if os(macOS)
        guard let data = json.data(using: .utf8),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return records.compactMap { record in
            guard let encoded = record["bookmark"], let bookmark = Data(base64Encoded: encoded) else { return nil }
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), url.startAccessingSecurityScopedResource() else { return nil }
            return url
        }
        #else
        return []
        #endif
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            selectItems()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: nav.selectedFolderURLs.isEmpty ? "folder.badge.plus" : "plus.circle")
                Text(nav.selectedFolderURLs.isEmpty ? "Select Folders or Archives" : "Add More")
                    .fontWeight(.semibold)
            }
            .font(.title3)
            .frame(maxWidth: isCompact ? .infinity : nil)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(nav.selectedFolderURLs.isEmpty ? Color.blue : Color.secondary.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(nav.selectedFolderURLs.isEmpty ? .white : .primary)
            .scaleEffect(isHoveringButton ? 1.03 : 1.0)
            .animation(.spring(response: 0.25), value: isHoveringButton)
        }
        .buttonStyle(.plain)
        .onHover { isHoveringButton = $0 }
        .help("Choose folders or ZIP, RAR, and 7z archives containing your photos and videos")

        if !nav.selectedFolderURLs.isEmpty {
            Button {
                nav.go(to: .scan)
            } label: {
                HStack(spacing: 10) {
                    Text(scanButtonLabel)
                        .fontWeight(.semibold)
                    Image(systemName: "arrow.right")
                }
                .font(.title3)
                .frame(maxWidth: isCompact ? .infinity : nil)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(.blue, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!interruptedManifests.isEmpty || isRecovering)
            .opacity(interruptedManifests.isEmpty && !isRecovering ? 1 : 0.45)
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    /// Deletes all persisted SwiftData objects that belong to previous scan sessions.
    /// Called every time WelcomeView appears so stale data never accumulates.
    private func purgeStaleSwiftData() {
        do {
            // Delete all OrganizationPlans (not keyed to a live session)
            let plans = try context.fetch(FetchDescriptor<OrganizationPlan>())
            plans.forEach { context.delete($0) }

            // Keep interrupted Apply/Undo journals across relaunches. Completed
            // sessions can be discarded here; an in-progress safety record may
            // be the only reliable way to recover moved files after a crash.
            let manifests = try context.fetch(FetchDescriptor<UndoManifest>())
            manifests
                .filter { !["applying", "undoing", "needsAttention"].contains($0.stateRaw) }
                .forEach { context.delete($0) }

            // Delete all ScanSessions (cascades to their MediaFiles)
            let sessions = try context.fetch(FetchDescriptor<ScanSession>())
            sessions.forEach { context.delete($0) }

            try context.save()
        } catch {
            // Non-fatal: log and continue — worst case is a slightly larger store
            print("[WelcomeView] SwiftData purge error: \(error)")
        }
    }

    /// Label for the Scan button, reflecting the mix of folders and archives selected.
    private var scanButtonLabel: String {
        let total = nav.selectedFolderURLs.count
        let archives = nav.selectedFolderURLs.filter(\.isArchiveFile).count
        let folders = total - archives

        if folders == 0 {
            return archives == 1 ? "Scan Archive" : "Scan \(archives) Archives"
        } else if archives == 0 {
            return folders == 1 ? "Scan Folder" : "Scan \(folders) Folders"
        } else {
            return "Scan \(total) Items"
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let existing = Set(nav.selectedFolderURLs.map(\.path))
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let urlString = String(data: data, encoding: .utf8)?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: urlString)
                else { return }

                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                guard isDir.boolValue || url.isArchiveFile else { return }
                guard !existing.contains(url.path) else { return }

                DispatchQueue.main.async {
                    addItems([url])
                }
            }
        }
    }

    private func selectItems() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Select"
        panel.message = "Choose folders, Photos libraries, or ZIP, RAR, or 7z archives. Foldiq will organize the supported media inside."
        panel.allowedContentTypes = [.folder] + photosLibraryContentTypes + archiveContentTypes

        guard panel.runModal() == .OK else { return }

        // Merge new URLs, deduplicating by path; reject unsupported file types
        let existing = Set(nav.selectedFolderURLs.map(\.path))
        let newURLs = panel.urls.filter { url in
            guard !existing.contains(url.path) else { return false }
            // Accept directories and supported archive files; reject anything else.
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue { return true }
            return url.isArchiveFile
        }
        addItems(newURLs)
        #else
        showingItemImporter = true
        #endif
    }

    #if os(macOS)
    /// Opens the file picker in ~/Pictures, where Photos keeps its library.
    private func selectPhotosLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = photosLibraryContentTypes
        panel.prompt = "Choose"
        panel.message = "Choose your Photos library. Your photos stay in Photos — Foldiq saves organized copies to a folder you pick."
        panel.directoryURL = PhotosLibrarySupport.realHomeDirectory?
            .appendingPathComponent("Pictures", isDirectory: true)

        guard panel.runModal() == .OK else { return }

        let existing = Set(nav.selectedFolderURLs.map(\.path))
        let libraries = panel.urls.filter {
            PhotosLibrarySupport.isPhotosLibrary($0) && !existing.contains($0.path)
        }
        addItems(libraries)
    }
    #endif

    private var isChoosingPhotosScope: Binding<Bool> {
        Binding(
            get: { pendingSystemLibrary != nil },
            set: { if !$0 { pendingSystemLibrary = nil } }
        )
    }

    /// Adds the chosen items. The Mac's main Photos library first asks what to
    /// take from it; it is added once the person confirms.
    private func addItems(_ urls: [URL]) {
        #if os(macOS)
        if let library = urls.first(where: { PhotosLibrarySupport.isDefaultSystemLibrary($0) }) {
            nav.addSelectedFolderURLs(urls.filter { $0 != library })
            pendingSystemLibrary = library
            return
        }
        #endif
        nav.addSelectedFolderURLs(urls)
    }

    private static func iconName(for url: URL) -> String {
        if url.isArchiveFile { return "doc.zipper" }
        if PhotosLibrarySupport.isPhotosLibrary(url) { return "photo.on.rectangle.angled" }
        return "folder.fill"
    }

    private static func iconColor(for url: URL) -> Color {
        if url.isArchiveFile { return .orange }
        if PhotosLibrarySupport.isPhotosLibrary(url) { return .pink }
        return .blue
    }

    private func handleImportedItems(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }

        nav.preserveAccess(to: urls)

        let existing = Set(nav.selectedFolderURLs.map(\.path))
        let newURLs = urls.filter { url in
            guard !existing.contains(url.path) else { return false }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue { return true }
            return url.isArchiveFile
        }
        nav.addSelectedFolderURLs(newURLs)
    }
}

// MARK: ─── Undo Toast ─────────────────────────────────────────────────────────

struct UndoCompletedToast: View {
    let restoredCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Undo complete — \(restoredCount) file\(restoredCount == 1 ? "" : "s") restored to their original locations.")
                .font(.callout)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: ─── App Version ────────────────────────────────────────────────────────

/// Reads the app version and build number from the bundle's Info.plist.
/// These values are stamped automatically on every build by Scripts/bump_version.sh.
enum AppInfo {
    /// Marketing version, e.g. "1.0.3".
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// Build number, e.g. "23".
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// Combined string for display, e.g. "v1.0.3 (23)".
    static var versionString: String { "v\(version) (\(build))" }
}

// MARK: ─── Photos scope sheet ─────────────────────────────────────────────────

#if os(macOS)
/// Asks what to take from the Mac's main Photos library before Foldiq starts
/// copying originals out of it, and shows how many items that is.
struct PhotosScopeSheet: View {
    let includeVideos: Bool
    let onCancel: () -> Void
    let onConfirm: (PhotosLibraryScope) -> Void

    private enum Access { case checking, granted, denied }

    @State private var scope = PhotosLibraryScope()
    @State private var access: Access = .checking
    @State private var albums: [SystemPhotosStager.Album] = []
    @State private var matchingCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What should Foldiq export from Photos?")
                .font(.title2.weight(.bold))
            Text("Your photos stay in Photos. Foldiq saves organized copies to a folder you choose, downloading originals from iCloud when needed. A smaller selection finishes sooner and needs less free space.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch access {
            case .checking:
                ProgressView("Opening your Photos library…")
            case .denied:
                Text("Foldiq doesn't have access to Photos. Turn it on in System Settings → Privacy & Security → Photos, then try again.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .granted:
                scopeControls
            }

            HStack {
                Text(countLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { onConfirm(confirmedScope) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(24)
        .frame(width: 500)
        .task { await openLibrary() }
        .onChange(of: scope) { recount() }
    }

    @ViewBuilder
    private var scopeControls: some View {
        Picker("Organize", selection: $scope.kind) {
            Text("Everything").tag(PhotosLibraryScope.Kind.everything)
            Text("Date Range").tag(PhotosLibraryScope.Kind.dateRange)
            Text("Albums").tag(PhotosLibraryScope.Kind.albums)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        switch scope.kind {
        case .everything:
            Text(includeVideos ? "Every photo and video in the library." : "Every photo in the library.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .dateRange:
            HStack(spacing: 20) {
                DatePicker("From", selection: $scope.startDate, displayedComponents: .date)
                DatePicker("To", selection: $scope.endDate, in: scope.startDate..., displayedComponents: .date)
            }
        case .albums:
            if albums.isEmpty {
                Text("No albums found in this library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                List(albums) { album in
                    Toggle(isOn: isSelected(album)) {
                        HStack {
                            Text(album.title)
                            Spacer()
                            Text("\(album.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .frame(height: 220)
            }
        }
    }

    private var countLabel: String {
        guard access == .granted else { return "" }
        guard let matchingCount else { return "Counting…" }
        return matchingCount == 1 ? "1 item" : "\(matchingCount.formatted()) items"
    }

    private var canConfirm: Bool {
        guard access == .granted, let matchingCount, matchingCount > 0 else { return false }
        return scope.kind != .albums || !scope.albumIdentifiers.isEmpty
    }

    private var confirmedScope: PhotosLibraryScope {
        var confirmed = scope
        confirmed.albumNames = albums.filter { scope.albumIdentifiers.contains($0.id) }.map(\.title)
        return confirmed
    }

    private func isSelected(_ album: SystemPhotosStager.Album) -> Binding<Bool> {
        Binding(
            get: { scope.albumIdentifiers.contains(album.id) },
            set: { selected in
                if selected {
                    scope.albumIdentifiers.insert(album.id)
                } else {
                    scope.albumIdentifiers.remove(album.id)
                }
            }
        )
    }

    private func openLibrary() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            access = .denied
            return
        }
        let videos = includeVideos
        albums = await Task.detached { SystemPhotosStager.albums(includeVideos: videos) }.value
        access = .granted
        recount()
    }

    private func recount() {
        guard access == .granted else { return }
        let current = scope
        let videos = includeVideos
        matchingCount = nil
        Task {
            let count = await Task.detached {
                SystemPhotosStager.count(includeVideos: videos, scope: current)
            }.value
            if current == scope { matchingCount = count }
        }
    }
}
#endif
