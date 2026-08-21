// ApplyView.swift
// Step 5: Executes all planned file operations with a live progress bar.

import SwiftUI
import SwiftData
import StoreKit

struct ApplyView: View {

    @EnvironmentObject private var nav: AppNavigator
    @Environment(\.modelContext) private var context
    @Environment(\.requestReview) private var requestReview

    @State private var progress: FileMover.ApplyProgress = .init(done: 0, total: 1, currentFile: "", errors: [])
    @State private var isComplete = false
    @State private var manifest: UndoManifest?
    @State private var cleanedEmptyFolders = 0
    @State private var reviewShelvedFiles = 0

    // Elapsed time counter
    @State private var elapsedSeconds = 0
    private let elapsedTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let mover = FileMover()

    private var hasErrors: Bool { !progress.errors.isEmpty }

    private var completionTitle: String {
        guard isComplete else {
            return nav.organizationConfig.fileOperation == .move ? "Moving Files…" : "Copying Files…"
        }
        guard hasErrors else { return "Done!" }
        return (manifest?.entries.isEmpty ?? true) ? "Nothing Was Organized" : "Finished with Errors"
    }

    private var statusIcon: String {
        if !isComplete { return "arrow.triangle.2.circlepath.circle" }
        return hasErrors ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if !isComplete { return .blue }
        return hasErrors ? .orange : .green
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                // Icon
                Group {
                    if #available(macOS 15.0, iOS 18.0, *) {
                        Image(systemName: statusIcon)
                            .symbolEffect(.rotate, isActive: !isComplete)
                    } else {
                        Image(systemName: statusIcon)
                            .symbolEffect(.pulse, isActive: !isComplete)
                    }
                }
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(statusColor)

                // Title
                Text(completionTitle)
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
                        .frame(maxWidth: 460)
                        .tint(statusColor)

                    HStack {
                        Text(progress.currentFile.isEmpty ? "Starting…" : progress.currentFile)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 300)
                        Spacer()
                        Text(elapsedFormatted)
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        Text("\(progress.done) / \(progress.total)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 460)
                }
                .padding(.horizontal, 24)

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
                        .frame(maxWidth: 460, minHeight: 60)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.horizontal, 24)
                }
            }

            Spacer()

            // Continue (enabled only when done)
            if isComplete {
                Button {
                    nav.go(to: manifest == nil && hasErrors ? .settings : .report)
                } label: {
                    HStack {
                        Text(manifest == nil && hasErrors ? "Back to Settings" : "View Report")
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
        .onReceive(elapsedTimer) { _ in
            if !isComplete { elapsedSeconds += 1 }
        }
    }

    // MARK: - Helpers

    private var elapsedFormatted: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Apply

    private func startApply() {
        guard let session = nav.scanSession else { return }

        // A system-picker destination is required. Selecting an archive grants
        // read access to that file, not permission to create a sibling folder.
        guard nav.organizationConfig.hasCustomOutputParent else {
            progress = .init(
                done: 0,
                total: max(session.files.count, 1),
                currentFile: "",
                errors: ["Choose a destination folder before organizing files."]
            )
            isComplete = true
            return
        }

        // Fetch all pending plans for this session
        let sessionID = session.id
        let descriptor = FetchDescriptor<OrganizationPlan>(
            predicate: #Predicate { $0.sessionID == sessionID && $0.statusRaw == "pending" }
        )
        guard let plans = try? context.fetch(descriptor), !plans.isEmpty else {
            isComplete = true; return
        }

        // Verify write access once before processing the plan. This prevents one
        // sandbox permission failure from being repeated for every source file.
        let outputRoot = nav.organizationConfig.outputRoot(forSelectedRoot: session.rootURL)
        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        } catch {
            progress = .init(
                done: 0,
                total: plans.count,
                currentFile: "",
                errors: ["Foldiq cannot write to the selected destination. Choose it again and grant access."]
            )
            isComplete = true
            return
        }

        // Create undo manifest
        let m = UndoManifest(
            sessionID: sessionID,
            rootPath: session.rootPath,
            operation: nav.organizationConfig.fileOperation,
            outputRootPath: outputRoot.path
        )
        m.securityBookmarksJSON = Self.securityBookmarksJSON(
            for: nav.selectedFolderURLs + [outputRoot.deletingLastPathComponent()]
        )
        context.insert(m)
        manifest = m

        do {
            // Make the empty journal durable before the first file operation.
            try context.save()
        } catch {
            progress = .init(
                done: 0,
                total: plans.count,
                currentFile: "",
                errors: ["Foldiq could not create its safety record: \(error.localizedDescription)"]
            )
            manifest = nil
            isComplete = true
            return
        }

        let tempDirs = nav.archiveTempDirs
        let startedAt = Date()
        Task {
            await mover.apply(plans: plans, manifest: m, checkpoint: {
                try context.save()
            }) { p in
                self.progress = p
            }
            // Keep an interrupted/ambiguous operation recoverable. Ordinary per-file
            // failures that never reached the filesystem do not leave pending entries.
            m.stateRaw = m.entries.contains(where: { !$0.wasCompleted })
                ? "needsAttention"
                : "complete"
            try? context.save()
            // Delete temp extraction dirs now that the files have been moved/copied.
            if progress.errors.isEmpty {
                await mover.cleanupTempDirs(tempDirs)
                nav.archiveTempDirs = []
            }
            let completedWithoutErrors = progress.errors.isEmpty && m.entries.count == plans.count
            AnonymousTelemetry.send(
                .applyCompleted,
                success: completedWithoutErrors,
                elapsed: Date().timeIntervalSince(startedAt),
                itemCount: plans.count
            )
            if completedWithoutErrors && nav.organizationConfig.fileOperation == .move {
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
            let shouldRequestReview = completedWithoutErrors &&
                AppReviewPromptPolicy.shouldRequestAfterSuccessfulOrganization(
                    successfulItemCount: m.entries.count
                )
            isComplete = true

            if shouldRequestReview {
                // Let the success state settle before showing Apple's standard prompt.
                try? await Task.sleep(for: .seconds(2))
                requestReview()
            }
        }
    }

    private static func securityBookmarksJSON(for urls: [URL]) -> String {
        #if os(macOS)
        let encoded = urls.compactMap { url -> [String: String]? in
            guard let data = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return nil }
            return ["path": url.path, "bookmark": data.base64EncodedString()]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: encoded),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
        #else
        // iOS document-picker URLs are scoped for the active operation. The native
        // Photos export flow keeps its own resumable manifest at the destination and
        // does not use macOS security-scoped bookmarks.
        return "[]"
        #endif
    }
}
