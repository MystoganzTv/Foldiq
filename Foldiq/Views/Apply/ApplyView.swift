// ApplyView.swift
// Step 5: Executes all planned file operations with a live progress bar.

import SwiftUI
import SwiftData

struct ApplyView: View {

    @EnvironmentObject private var nav: AppNavigator
    @Environment(\.modelContext) private var context

    @State private var progress: FileMover.ApplyProgress = .init(done: 0, total: 1, currentFile: "", errors: [])
    @State private var isComplete = false
    @State private var manifest: UndoManifest?
    @State private var cleanedEmptyFolders = 0
    @State private var reviewShelvedFiles = 0

    private let mover = FileMover()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                // Icon
                Group {
                    if #available(macOS 15.0, *) {
                        Image(systemName: isComplete ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle")
                            .symbolEffect(.rotate, isActive: !isComplete)
                    } else {
                        Image(systemName: isComplete ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle")
                            .symbolEffect(.pulse, isActive: !isComplete)
                    }
                }
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(isComplete ? .green : .blue)

                // Title
                Text(isComplete ? "Done!" : (nav.organizationConfig.fileOperation == .move ? "Moving Files…" : "Copying Files…"))
                    .font(.largeTitle).fontWeight(.bold)

                if !isComplete {
                    Text(nav.organizationConfig.fileOperation == .move
                         ? "Files are being moved into the organized library."
                         : "Files are being copied into the organized library.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if isComplete, cleanedEmptyFolders > 0 {
                    Label("\(cleanedEmptyFolders) empty folder\(cleanedEmptyFolders == 1 ? "" : "s") cleaned up automatically.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isComplete, reviewShelvedFiles > 0 {
                    Label("\(reviewShelvedFiles) leftover file\(reviewShelvedFiles == 1 ? "" : "s") moved into Needs Review.", systemImage: "folder.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Progress bar
                VStack(spacing: 8) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 460)
                        .tint(isComplete ? .green : .blue)

                    HStack {
                        Text(progress.currentFile.isEmpty ? "Starting…" : progress.currentFile)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 360)
                        Spacer()
                        Text("\(progress.done) / \(progress.total)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(width: 460)
                }

                // Error summary (live)
                if !progress.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(progress.errors.count) error(s)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(progress.errors.suffix(5), id: \.self) { err in
                                    Text(err).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: 460, height: 60)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            Spacer()

            // Continue (enabled only when done)
            if isComplete {
                Button {
                    nav.go(to: .report)
                } label: {
                    HStack {
                        Text("View Report")
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 40)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: isComplete)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startApply() }
    }

    // MARK: - Apply

    private func startApply() {
        guard let session = nav.scanSession else { return }

        // Fetch all pending plans for this session
        let sessionID = session.id
        let descriptor = FetchDescriptor<OrganizationPlan>(
            predicate: #Predicate { $0.sessionID == sessionID && $0.statusRaw == "pending" }
        )
        guard let plans = try? context.fetch(descriptor), !plans.isEmpty else {
            isComplete = true; return
        }

        // Create undo manifest
        let m = UndoManifest(
            sessionID: sessionID,
            rootPath: session.rootPath,
            operation: nav.organizationConfig.fileOperation
        )
        context.insert(m)
        manifest = m

        let tempDirs = nav.archiveTempDirs
        Task {
            await mover.apply(plans: plans, manifest: m) { p in
                self.progress = p
            }
            try? context.save()
            // Delete temp extraction dirs now that the files have been moved/copied.
            await mover.cleanupTempDirs(tempDirs)
            nav.archiveTempDirs = []
            if nav.organizationConfig.fileOperation == .move {
                reviewShelvedFiles = await mover.shelveResidualFilesForReview(
                    under: nav.selectedFolderURLs,
                    expectedDestinationPaths: Set(plans.map(\.destinationAbsPath)),
                    outputFolderName: nav.organizationConfig.outputFolderName,
                    reviewFolderName: nav.organizationConfig.reviewFolderName
                )
                cleanedEmptyFolders = await mover.removeEmptyFolders(
                    under: nav.selectedFolderURLs,
                    skipping: nav.organizationConfig.outputFolderName
                )
            }
            isComplete = true
        }
    }
}
