// WelcomeView.swift
// Step 1: Intro + folder/zip picker (supports selecting multiple folders and .zip files).

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct WelcomeView: View {

    @EnvironmentObject private var nav: AppNavigator
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isHoveringButton = false
    @State private var isDragTargeted = false
    @State private var showingItemImporter = false

    // Undo toast (shown after returning from a successful undo)
    @State private var showUndoToast = false
    @State private var undoRestoredCount: Int?
    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

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
                            Image(systemName: url.isZipFile ? "doc.zipper" : "folder.fill")
                                .foregroundStyle(url.isZipFile ? .orange : .blue)
                                .font(.caption)
                            Text(url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
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
                Text("You can also drag folders or ZIPs directly onto this window")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .opacity(isCompact ? 0 : 1)

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
            allowedContentTypes: [.folder, UTType(filenameExtension: "zip") ?? .zip],
            allowsMultipleSelection: true
        ) { result in
            handleImportedItems(result)
        }
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
                            Text("Drop folders or ZIPs to add them")
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
        .onAppear {
            // ── SwiftData cleanup ────────────────────────────────────────────
            // When we return to WelcomeView (via restart or back navigation),
            // nav.scanSession is nil. All persisted sessions are stale —
            // delete them now to prevent SwiftData conflicts and memory growth.
            purgeStaleSwiftData()

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

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            selectItems()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: nav.selectedFolderURLs.isEmpty ? "folder.badge.plus" : "plus.circle")
                Text(nav.selectedFolderURLs.isEmpty ? "Select Folders or ZIPs" : "Add More")
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
        .help("Choose folders or .zip archives containing your photos and videos")

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

            // Delete all UndoManifests and their cascaded UndoEntries
            let manifests = try context.fetch(FetchDescriptor<UndoManifest>())
            manifests.forEach { context.delete($0) }

            // Delete all ScanSessions (cascades to their MediaFiles)
            let sessions = try context.fetch(FetchDescriptor<ScanSession>())
            sessions.forEach { context.delete($0) }

            try context.save()
        } catch {
            // Non-fatal: log and continue — worst case is a slightly larger store
            print("[WelcomeView] SwiftData purge error: \(error)")
        }
    }

    /// Label for the Scan button, reflecting the mix of folders and ZIPs selected.
    private var scanButtonLabel: String {
        let total = nav.selectedFolderURLs.count
        let zips    = nav.selectedFolderURLs.filter(\.isZipFile).count
        let folders = total - zips

        if folders == 0 {
            return zips == 1 ? "Scan ZIP" : "Scan \(zips) ZIPs"
        } else if zips == 0 {
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
                guard isDir.boolValue || url.isZipFile else { return }
                guard !existing.contains(url.path) else { return }

                DispatchQueue.main.async {
                    nav.addSelectedFolderURLs([url])
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
        panel.message = "Choose folders or .zip archives. The app will scan and organize all supported media inside."
        // Allow any folder or specifically ZIP files
        panel.allowedContentTypes = [.folder, UTType(filenameExtension: "zip") ?? .zip]

        guard panel.runModal() == .OK else { return }

        // Merge new URLs, deduplicating by path; reject unsupported file types
        let existing = Set(nav.selectedFolderURLs.map(\.path))
        let newURLs = panel.urls.filter { url in
            guard !existing.contains(url.path) else { return false }
            // Accept directories and .zip files; reject anything else
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue { return true }
            return url.isZipFile
        }
        nav.addSelectedFolderURLs(newURLs)
        #else
        showingItemImporter = true
        #endif
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
            return url.isZipFile
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
