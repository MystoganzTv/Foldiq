// WelcomeView.swift
// Step 1: Intro + folder/zip picker (supports selecting multiple folders and .zip files).

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct WelcomeView: View {

    @EnvironmentObject private var nav: AppNavigator
    @Environment(\.modelContext) private var context
    @State private var isHoveringButton = false
    @State private var isDragTargeted = false

    // Undo toast (shown after returning from a successful undo)
    @State private var showUndoToast = false
    @State private var undoRestoredCount: Int?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // ── Logo & headline ─────────────────────────────────────────────
            VStack(spacing: 16) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 72, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.pulse)

                Text("Organize Your Library")
                    .font(.system(size: 42, weight: .bold, design: .rounded))

                Text("Clean up and organize thousands of messy\nphotos and videos safely, right on your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer().frame(height: 40)

            // ── How it works ─────────────────────────────────────────────────
            VStack(spacing: 12) {
                Text("How it works")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 0) {
                    WorkflowStep(number: 1, icon: "folder.badge.plus",
                                 title: "Select",
                                 detail: "Pick a folder or .zip archive containing your media")
                    WorkflowConnector()
                    WorkflowStep(number: 2, icon: "magnifyingglass.circle",
                                 title: "Scan",
                                 detail: "Foldiq reads dates, location, and spots duplicates")
                    WorkflowConnector()
                    WorkflowStep(number: 3, icon: "eye",
                                 title: "Review",
                                 detail: "See every planned file movement before anything changes")
                    WorkflowConnector()
                    WorkflowStep(number: 4, icon: "checkmark.circle.fill",
                                 title: "Apply",
                                 detail: "Foldiq organizes your library — with a full undo log")
                }
                .frame(maxWidth: 680)
            }

            Spacer().frame(height: 32)

            // ── Feature bullets ─────────────────────────────────────────────
            HStack(spacing: 32) {
                FeaturePill(icon: "shield.checkered",       label: "Preview before\nanything moves")
                FeaturePill(icon: "clock.arrow.circlepath", label: "Full undo\nat any time")
                FeaturePill(icon: "icloud.slash",           label: "100% local,\nno cloud")
                FeaturePill(icon: "folder.fill.badge.plus", label: "Real folders\non your Mac")
            }

            Spacer().frame(height: 32)

            // ── Import from Library ──────────────────────────────────────────
            VStack(spacing: 8) {
                Text("Or import directly from")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    LibrarySourceCard(
                        icon: "photo.on.rectangle.angled",
                        iconColor: .indigo,
                        title: "Apple Photos",
                        detail: "Originals from your\nPhotos library"
                    ) { addApplePhotosLibrary() }

                    LibrarySourceCard(
                        icon: "arrow.down.circle.fill",
                        iconColor: .green,
                        title: "Google Takeout",
                        detail: "Select a Google\nPhotos .zip export"
                    ) { selectItems() }    // opens the file picker — ZIPs allowed

                    LibrarySourceCard(
                        icon: "icloud.fill",
                        iconColor: .cyan,
                        title: "iCloud Drive",
                        detail: "Browse your iCloud\nDrive folder"
                    ) { addiCloudDrive() }
                }
                .frame(maxWidth: 520)
            }

            Spacer().frame(height: 24)

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
                                nav.selectedFolderURLs.removeAll { $0 == url }
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
                .padding(.bottom, 12)
            }

            // ── CTA ─────────────────────────────────────────────────────────
            HStack(spacing: 12) {
                // Add folders / ZIPs button
                Button {
                    selectItems()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: nav.selectedFolderURLs.isEmpty ? "folder.badge.plus" : "plus.circle")
                        Text(nav.selectedFolderURLs.isEmpty ? "Select Folders or ZIPs" : "Add More")
                            .fontWeight(.semibold)
                    }
                    .font(.title3)
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

                // Scan button — only shown when items are selected
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
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(.blue, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3), value: nav.selectedFolderURLs.isEmpty)

            Spacer()

            // ── Disclaimer ───────────────────────────────────────────────────
            Text("Nothing is deleted without your permission.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .openRootFolder)) { _ in
            selectItems()
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
                    nav.selectedFolderURLs.append(url)
                }
            }
        }
    }

    /// Adds the Apple Photos Library originals folder if it exists.
    private func addApplePhotosLibrary() {
        let libraryURL = URL(fileURLWithPath: NSString("~/Pictures/Photos Library.photoslibrary/originals").expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: libraryURL.path) else {
            // Library not found — fall back to folder picker
            selectItems()
            return
        }
        let existing = Set(nav.selectedFolderURLs.map(\.path))
        guard !existing.contains(libraryURL.path) else { return }
        nav.selectedFolderURLs.append(libraryURL)
    }

    /// Adds the iCloud Drive folder if it exists.
    private func addiCloudDrive() {
        let iCloudURL = URL(fileURLWithPath: NSString("~/Library/Mobile Documents/com~apple~CloudDocs").expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: iCloudURL.path) else {
            selectItems()
            return
        }
        let existing = Set(nav.selectedFolderURLs.map(\.path))
        guard !existing.contains(iCloudURL.path) else { return }
        nav.selectedFolderURLs.append(iCloudURL)
    }

    private func selectItems() {
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
        nav.selectedFolderURLs.append(contentsOf: newURLs)
    }
}

// MARK: ─── Workflow Step ─────────────────────────────────────────────────────

struct WorkflowStep: View {
    let number: Int
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.blue)
            }
            .overlay(alignment: .topTrailing) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(.blue, in: Circle())
                    .offset(x: 4, y: -4)
            }

            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }
}

struct WorkflowConnector: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 26)   // vertically aligns with center of the icon circle
    }
}

// MARK: ─── Feature Pill ───────────────────────────────────────────────────────

struct FeaturePill: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.blue)
                .frame(height: 32)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 130)
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: ─── Library Source Card ───────────────────────────────────────────────

struct LibrarySourceCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let detail: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(height: 32)

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(
                isHovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovering ? iconColor.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .animation(.spring(response: 0.2), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
