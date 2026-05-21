// ReportView.swift
// Step 6: Final report — stats, error list, export CSV, undo, open folder.

import SwiftUI
import SwiftData
import AppKit

struct ReportView: View {

    @EnvironmentObject private var nav: AppNavigator
    @Environment(\.modelContext) private var context

    @State private var plans: [OrganizationPlan] = []
    @State private var manifests: [UndoManifest]  = []
    @State private var isUndoing    = false
    @State private var undoComplete = false
    @State private var undoRestoredCount = 0
    @State private var undoProgress = FileMover.ApplyProgress(done: 0, total: 1, currentFile: "", errors: [])
    @State private var showUndoConfirm = false
    @State private var exportFeedback: FeedbackMessage?

    // Empty folder cleanup
    @State private var emptyFolderCount  = 0
    @State private var showCleanupConfirm = false
    @State private var isCleaningFolders = false
    @State private var cleanupRemovedCount = 0

    private let mover = FileMover()

    struct FeedbackMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let revealURL: URL?
    }

    var done:    [OrganizationPlan] { plans.filter { $0.status == .done } }
    var skipped: [OrganizationPlan] { plans.filter { $0.status == .skipped } }
    var errors:  [OrganizationPlan] { plans.filter { $0.status == .error } }

    var body: some View {
        VStack(spacing: 0) {
            if isUndoing {
                undoProgressView
            } else if undoComplete {
                undoCompleteView
            } else {
                reportContent
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isUndoing)
        .animation(.easeInOut(duration: 0.3), value: undoComplete)
        .onAppear { loadData() }
        .alert(item: $exportFeedback) { item in
            if let revealURL = item.revealURL {
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    primaryButton: .default(Text("Reveal in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                    },
                    secondaryButton: .cancel(Text("OK"))
                )
            } else {
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    // MARK: - Report content

    var reportContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                // ── Header ─────────────────────────────────────────────────
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.title)
                            Text("Organization Complete")
                                .font(.largeTitle).fontWeight(.bold)
                        }
                        if let session = nav.scanSession {
                            Text(nav.organizationConfig.outputRoot(forSelectedRoot: URL(fileURLWithPath: session.rootPath)).path)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Label(
                            nav.organizationConfig.fileOperation == .move
                                ? "Originals were moved into the organized library."
                                : "An organized copy was created and originals were left in place.",
                            systemImage: nav.organizationConfig.fileOperation == .move
                                ? "arrow.right.circle.fill"
                                : "doc.on.doc.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(nav.organizationConfig.fileOperation == .move ? .blue : .green)
                    }
                    Spacer()
                    VStack(spacing: 8) {
                        Button {
                            exportCSV()
                        } label: {
                            Label("Export CSV", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            openOrganizedFolder()
                        } label: {
                            Label("Open in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // ── Stats row ──────────────────────────────────────────────
                HStack(spacing: 16) {
                    ReportStatCard(value: done.count,    label: "Organized",  color: .green,  icon: "checkmark.circle.fill")
                    ReportStatCard(value: skipped.count, label: "Skipped",    color: .yellow, icon: "forward.fill")
                    ReportStatCard(value: errors.count,  label: "Errors",     color: .red,    icon: "exclamationmark.triangle.fill")
                }

                // ── Errors list ────────────────────────────────────────────
                if !errors.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Errors", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(.red)

                        HStack(spacing: 10) {
                            Button {
                                retryFailedPlans()
                            } label: {
                                Label("Retry Failed Files", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                copyFailedPaths()
                            } label: {
                                Label("Copy Failed Paths", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                        }

                        ForEach(errors) { plan in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.red).padding(.top, 1)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(URL(fileURLWithPath: plan.sourceAbsPath).lastPathComponent)
                                            .fontWeight(.medium)
                                        Text(plan.errorMessage ?? "Unknown error")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }

                                HStack(spacing: 8) {
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([plan.sourceURL])
                                    } label: {
                                        Label("Reveal", systemImage: "folder")
                                    }
                                    .buttonStyle(.bordered)

                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(plan.sourceAbsPath, forType: .string)
                                    } label: {
                                        Label("Copy Path", systemImage: "doc.on.doc")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                // ── Undo section ───────────────────────────────────────────
                if let manifest = manifests.first, !manifest.wasUndone {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Undo Organization", systemImage: "arrow.uturn.backward.circle")
                            .font(.headline)
                        Text("An undo manifest was created for this session. You can reverse every file movement.")
                            .font(.caption).foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            showUndoConfirm = true
                        } label: {
                            Label("Undo — Move Files Back", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                    .confirmationDialog("Undo Organization?", isPresented: $showUndoConfirm,
                                        titleVisibility: .visible) {
                        Button("Yes, Move Files Back", role: .destructive) {
                            performUndo()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("All \(done.count) organized files will be moved back to their original locations.")
                    }
                }

                // ── Empty folder cleanup ───────────────────────────────────
                // Only relevant after a Move operation — Copy leaves originals intact.
                if nav.organizationConfig.fileOperation == .move, emptyFolderCount > 0 {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Empty Folders", systemImage: "folder.badge.minus")
                            .font(.headline)
                        Text("Found \(emptyFolderCount) empty folder\(emptyFolderCount == 1 ? "" : "s") left behind after moving your files. These are safe to delete.")
                            .font(.caption).foregroundStyle(.secondary)

                        if isCleaningFolders {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Removing empty folders…").font(.caption).foregroundStyle(.secondary)
                            }
                        } else if cleanupRemovedCount > 0 {
                            Label("\(cleanupRemovedCount) empty folder\(cleanupRemovedCount == 1 ? "" : "s") removed.", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        } else {
                            Button {
                                showCleanupConfirm = true
                            } label: {
                                Label("Remove \(emptyFolderCount) Empty Folder\(emptyFolderCount == 1 ? "" : "s")", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .confirmationDialog("Remove Empty Folders?", isPresented: $showCleanupConfirm, titleVisibility: .visible) {
                                Button("Yes, Delete Empty Folders", role: .destructive) { performCleanup() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This will permanently delete \(emptyFolderCount) empty folder\(emptyFolderCount == 1 ? "" : "s") from your original folder structure. This cannot be undone.")
                            }
                        }
                    }
                }

                // ── Start over ─────────────────────────────────────────────
                Divider()
                Button("Organize Another Folder") { nav.restart() }
                    .buttonStyle(.bordered)
            }
            .padding(40)
        }
    }

    // MARK: - Undo in progress

    var undoProgressView: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 56)).foregroundStyle(.orange)
                .symbolEffect(.pulse, isActive: true)
            Text("Undoing Organization…").font(.title2).fontWeight(.semibold)
            ProgressView(value: Double(undoProgress.done), total: Double(max(undoProgress.total, 1)))
                .frame(width: 400).tint(.orange)
            Text("\(undoProgress.done) / \(undoProgress.total)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Undo complete

    var undoCompleteView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72, weight: .thin))
                    .foregroundStyle(.orange)

                VStack(spacing: 8) {
                    Text("Undo Complete")
                        .font(.largeTitle).fontWeight(.bold)
                    Text("\(undoRestoredCount) file\(undoRestoredCount == 1 ? "" : "s") moved back to their original locations.")
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Summary cards
                HStack(spacing: 16) {
                    UndoSummaryCard(
                        icon: "arrow.uturn.backward.circle.fill",
                        label: "Restored",
                        value: undoRestoredCount,
                        color: .orange
                    )
                    if let session = nav.scanSession {
                        UndoSummaryCard(
                            icon: "folder.fill",
                            label: "Folder",
                            value: nil,
                            subtitle: URL(fileURLWithPath: session.rootPath).lastPathComponent,
                            color: .blue
                        )
                    }
                }
                .frame(maxWidth: 460)

                Text("The organized folder has been cleared. Your library is back to its original state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Spacer()

            Button {
                nav.lastUndoRestoredCount = undoRestoredCount
                nav.restart()
            } label: {
                HStack {
                    Text("Organize Another Folder")
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    // MARK: - Helpers

    private func loadData() {
        guard let session = nav.scanSession else { return }
        let sid = session.id

        let planDesc = FetchDescriptor<OrganizationPlan>(
            predicate: #Predicate { $0.sessionID == sid }
        )
        plans = (try? context.fetch(planDesc)) ?? []

        let mDesc = FetchDescriptor<UndoManifest>(
            predicate: #Predicate { $0.sessionID == sid }
        )
        manifests = (try? context.fetch(mDesc)) ?? []

        // Count empty folders left behind (only meaningful for Move operations)
        if nav.organizationConfig.fileOperation == .move {
            let roots = nav.selectedFolderURLs
            let outputName = nav.organizationConfig.outputFolderName
            Task {
                let count = await Task.detached(priority: .utility) {
                    roots.reduce(0) { acc, root in
                        acc + FileMover.countEmptyDirs(root, skip: outputName, isRoot: true)
                    }
                }.value
                emptyFolderCount = count
            }
        }
    }

    private func performCleanup() {
        let roots = nav.selectedFolderURLs
        let outputName = nav.organizationConfig.outputFolderName
        isCleaningFolders = true
        Task {
            let removed = await mover.removeEmptyFolders(under: roots, skipping: outputName)
            isCleaningFolders   = false
            cleanupRemovedCount = removed
            emptyFolderCount    = 0
        }
    }

    private func openOrganizedFolder() {
        guard let session = nav.scanSession else { return }
        let outURL = nav.organizationConfig
            .outputRoot(forSelectedRoot: URL(fileURLWithPath: session.rootPath))
        NSWorkspace.shared.open(outURL)
    }

    private func performUndo() {
        guard let manifest = manifests.first else { return }
        let restoredCount = done.count
        isUndoing = true
        Task {
            await mover.undo(manifest: manifest) { p in
                self.undoProgress = p
            }
            try? context.save()
            isUndoing    = false
            undoRestoredCount = restoredCount
            undoComplete = true
        }
    }

    private func exportCSV() {
        guard let session = nav.scanSession else { return }

        do {
            let url = try ReportExporter.exportCSV(plans: plans, sessionID: session.id)
            exportFeedback = FeedbackMessage(
                title: "CSV Ready",
                message: "The final report was saved to \(url.lastPathComponent). You can review it in Finder or send it to someone else.",
                revealURL: url
            )
        } catch ReportExporter.ExportError.cancelled {
            return
        } catch {
            exportFeedback = FeedbackMessage(
                title: "Export Failed",
                message: error.localizedDescription,
                revealURL: nil
            )
        }
    }

    private func retryFailedPlans() {
        let failed = plans.filter { $0.status == .error }
        guard !failed.isEmpty else { return }

        for plan in failed {
            plan.status = .pending
            plan.errorMessage = nil
            plan.appliedAt = nil
        }

        try? context.save()
        nav.go(to: .apply)
    }

    private func copyFailedPaths() {
        let payload = errors.map(\.sourceAbsPath).joined(separator: "\n")
        guard !payload.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        exportFeedback = FeedbackMessage(
            title: "Paths Copied",
            message: "Copied \(errors.count) failed path(s) to the clipboard.",
            revealURL: nil
        )
    }
}

// MARK: ─── Report Stat Card ───────────────────────────────────────────────────

struct ReportStatCard: View {
    let value: Int
    let label: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text("\(value)").font(.title).fontWeight(.bold).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: ─── Undo Summary Card ──────────────────────────────────────────────────

struct UndoSummaryCard: View {
    let icon: String
    let label: String
    var value: Int?
    var subtitle: String?
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                if let value {
                    Text("\(value)").font(.title3).fontWeight(.bold).monospacedDigit()
                } else if let subtitle {
                    Text(subtitle).font(.subheadline).fontWeight(.medium).lineLimit(1)
                }
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}
