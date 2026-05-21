// PreviewView.swift
// Step 4: Build the organization plan and show every planned file movement
// in a searchable, sortable table. The user confirms before proceeding.
// Selecting a row opens a right-side inspector with a thumbnail and, for
// files with no date, a DatePicker to assign one manually.

import SwiftUI
import SwiftData
import AppKit
import QuickLookUI
import AVFoundation

struct PreviewView: View {

    @EnvironmentObject private var nav: AppNavigator
    @Environment(\.modelContext) private var context

    @State private var plans: [OrganizationPlan] = []
    @State private var isPlanning = true
    @State private var planProgress = 0
    @State private var planTotal = 1
    @State private var planCurrentFile = ""

    @State private var searchQuery = ""
    @State private var filterStatus: FilterStatus = .all
    @State private var sortColumn: SortColumn = .source
    @State private var sortAscending = true

    @State private var showingConfirmation = false
    @State private var planningError: String?
    @State private var exportFeedback: FeedbackMessage?

    // Task handle — stored so the user can cancel planning mid-flight.
    @State private var planTask: Task<Void, Never>?

    // Inspector
    @State private var selectedPlanID: UUID?


    // Folder tree sheet
    @State private var showFolderTree = false
    var selectedPlan: OrganizationPlan? {
        plans.first { $0.id == selectedPlanID }
    }

    struct FeedbackMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let revealURL: URL?
    }

    enum FilterStatus: String, CaseIterable {
        case all = "All"
        case photo = "Photos"
        case video = "Videos"
        case duplicate = "Duplicates"
        case unknownDate = "Unknown Date"
    }

    enum SortColumn: String { case source, destination, status }

    // MARK: - Filtered & sorted plans

    var displayedPlans: [OrganizationPlan] {
        var result = plans

        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter {
                $0.sourceAbsPath.lowercased().contains(q) ||
                $0.destinationAbsPath.lowercased().contains(q)
            }
        }

        switch filterStatus {
        case .all: break
        case .photo:
            result = result.filter { MediaTypes.photoExtensions.contains(
                URL(fileURLWithPath: $0.sourceAbsPath).pathExtension.lowercased()) }
        case .video:
            result = result.filter { MediaTypes.videoExtensions.contains(
                URL(fileURLWithPath: $0.sourceAbsPath).pathExtension.lowercased()) }
        case .duplicate:
            result = result.filter { $0.destinationAbsPath.contains("/Duplicates/") }
        case .unknownDate:
            result = result.filter { $0.destinationAbsPath.contains("/Unknown Date/") }
        }

        result.sort {
            let lhs: String
            let rhs: String
            switch sortColumn {
            case .source:      lhs = $0.sourceAbsPath;      rhs = $1.sourceAbsPath
            case .destination: lhs = $0.destinationAbsPath; rhs = $1.destinationAbsPath
            case .status:      lhs = $0.statusRaw;          rhs = $1.statusRaw
            }
            return sortAscending ? lhs < rhs : lhs > rhs
        }

        return result
    }

    var duplicatePlanCount: Int {
        plans.filter { $0.destinationAbsPath.contains("/Duplicates/") }.count
    }

    var unknownDatePlanCount: Int {
        plans.filter { $0.destinationAbsPath.contains("/Unknown Date/") }.count
    }

    var destinationSummary: String {
        guard
            let session = nav.scanSession
        else { return nav.organizationConfig.outputFolderName }

        return nav.organizationConfig
            .outputRoot(forSelectedRoot: URL(fileURLWithPath: session.rootPath))
            .path
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if isPlanning {
                planningProgress
            } else if let err = planningError {
                ContentUnavailableView("Planning Failed", systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else {
                planTable
            }
        }
        .onAppear { buildPlan() }
        .onDisappear { planTask?.cancel() }
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

    // MARK: - Planning progress

    var planningProgress: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView(value: Double(planProgress), total: Double(max(planTotal, 1)))
                .frame(width: 400)
                .tint(.blue)
            Text("Planning… \(planProgress) / \(planTotal)")
                .font(.headline)
            Text(planCurrentFile)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 500)

            Button("Cancel") {
                planTask?.cancel()
                nav.go(to: .settings)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Plan table

    var planTable: some View {
        VStack(spacing: 0) {
            // ── Toolbar ───────────────────────────────────────────────────
            HStack(spacing: 0) {
                // Stat summary — icon + number + label, no pill backgrounds
                HStack(spacing: 16) {
                    PlanStat(
                        icon: "doc.fill",
                        value: "\(plans.count)",
                        label: "files",
                        color: .blue
                    )
                    PlanStat(
                        icon: nav.organizationConfig.fileOperation == .move
                              ? "arrow.right.circle.fill" : "doc.on.doc.fill",
                        value: nav.organizationConfig.fileOperation == .move ? "Move" : "Copy",
                        label: "originals",
                        color: nav.organizationConfig.fileOperation == .move ? .blue : .green
                    )
                    if duplicatePlanCount > 0 {
                        PlanStat(icon: "square.on.square.fill",
                                 value: "\(duplicatePlanCount)",
                                 label: "duplicates",
                                 color: .orange)
                    }
                    if unknownDatePlanCount > 0 {
                        PlanStat(icon: "calendar.badge.exclamationmark",
                                 value: "\(unknownDatePlanCount)",
                                 label: "no date",
                                 color: Color(red: 0.8, green: 0.65, blue: 0.0))
                    }
                }

                Spacer()

                Picker("Show", selection: $filterStatus) {
                    ForEach(FilterStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)

                TextField("Search paths…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .padding(.leading, 12)

                Button {
                    showFolderTree = true
                } label: {
                    Image(systemName: "folder.fill.badge.questionmark")
                }
                .help("Preview folder structure")
                .padding(.leading, 8)

                Button {
                    exportCSV()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export CSV report")
                .padding(.leading, 6)

            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // ── Table + Inspector ─────────────────────────────────────────
            HStack(spacing: 0) {
                if displayedPlans.isEmpty {
                    ContentUnavailableView {
                        Label("No matching files", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("No files match the current filters or search. Clear the filters or go back to adjust the organization rules.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(displayedPlans, selection: $selectedPlanID) {
                        TableColumn("Current Path") { plan in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: plan.sourceAbsPath).lastPathComponent)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text(plan.sourceURL.deletingLastPathComponent().path)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                        .width(min: 180, ideal: 240)

                        TableColumn("→ Destination") { plan in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: plan.destinationAbsPath).lastPathComponent)
                                    .lineLimit(1)
                                Text(plan.destinationURL.deletingLastPathComponent().path)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                        .width(min: 180, ideal: 260)

                        TableColumn("Operation") { plan in
                            Text(plan.operation == .move ? "Move original" : "Copy only")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    (plan.operation == .move ? Color.blue : Color.green).opacity(0.12),
                                    in: Capsule()
                                )
                                .foregroundStyle(plan.operation == .move ? .blue : .green)
                        }
                        .width(110)

                        TableColumn("") { plan in
                            if plan.destinationAbsPath.contains("/Duplicates/") {
                                Label("Duplicate", systemImage: "square.on.square")
                                    .font(.caption2).foregroundStyle(.orange)
                            } else if plan.destinationAbsPath.contains("/Unknown Date/") {
                                Label("No date", systemImage: "questionmark.circle")
                                    .font(.caption2).foregroundStyle(.yellow)
                            } else if plan.destinationAbsPath.contains("/Screenshots/") {
                                Label("Screenshot", systemImage: "camera.viewfinder")
                                    .font(.caption2).foregroundStyle(.purple)
                            }
                        }
                    }
                }

                // ── Right inspector panel ─────────────────────────────────
                if let plan = selectedPlan {
                    Divider()
                    VStack(spacing: 0) {
                        // Inspector header with close button
                        HStack {
                            Text("File Info")
                                .font(.subheadline).fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedPlanID = nil
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.plain)
                            .help("Close inspector")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.bar)

                        Divider()

                        FileInspectorPanel(
                            plan: plan,
                            session: nav.scanSession,
                            config: nav.organizationConfig,
                            context: context,
                            onDateAssigned: { updatedPlan in
                                if let idx = plans.firstIndex(where: { $0.id == updatedPlan.id }) {
                                    plans[idx] = updatedPlan
                                }
                            }
                        )
                    }
                    .frame(width: 272)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selectedPlanID != nil)

            Divider()

            // ── Footer ────────────────────────────────────────────────────
            HStack {
                Button("Back") { nav.go(to: .settings) }
                    .buttonStyle(.bordered)

                Spacer()

                Text("\(displayedPlans.count) of \(plans.count) shown")
                    .font(.caption).foregroundStyle(.secondary)

                Spacer()

                Button {
                    showingConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: nav.organizationConfig.fileOperation == .move
                              ? "arrow.right.circle.fill" : "doc.on.doc.fill")
                        Text("Apply — \(nav.organizationConfig.fileOperation.rawValue.capitalized) \(plans.count) Files")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(nav.organizationConfig.fileOperation == .move ? .blue : .green)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .sheet(isPresented: $showingConfirmation) {
            ApplyPreflightSheet(
                planCount: plans.count,
                duplicateCount: duplicatePlanCount,
                unknownDateCount: unknownDatePlanCount,
                operation: nav.organizationConfig.fileOperation,
                destinationPath: destinationSummary,
                onCancel: { showingConfirmation = false },
                onConfirm: {
                    showingConfirmation = false
                    nav.go(to: .apply)
                }
            )
        }
        .sheet(isPresented: $showFolderTree) {
            if let session = nav.scanSession {
                let outputRoot = nav.organizationConfig
                    .outputRoot(forSelectedRoot: URL(fileURLWithPath: session.rootPath))
                FolderTreeSheet(plans: plans, outputRoot: outputRoot)
            }
        }
    }

    // MARK: - Build Plan

    private func buildPlan() {
        guard let session = nav.scanSession else { return }
        let config = nav.organizationConfig
        planTotal = session.totalFiles

        // Cancel any in-flight plan before starting a new one.
        planTask?.cancel()

        planTask = Task {
            // Remove any previously generated plans for this session.
            // This handles the case where the user went back from Preview,
            // changed settings, and returned — we always want fresh plans
            // matching the current configuration.
            let sid = session.id
            let oldDesc = FetchDescriptor<OrganizationPlan>(
                predicate: #Predicate { $0.sessionID == sid }
            )
            if let old = try? context.fetch(oldDesc) {
                for p in old { context.delete(p) }
                try? context.save()
            }

            guard !Task.isCancelled else { return }

            let planner = OrganizationPlanner()
            let built = await planner.buildPlan(session: session, config: config) { p in
                self.planProgress    = p.planned
                self.planTotal       = p.total
                self.planCurrentFile = p.currentFile
            }

            // If the user cancelled while the planner was running, bail out.
            guard !Task.isCancelled else { return }

            for plan in built { context.insert(plan) }

            // Apply plannedDestinationPath on @MainActor — safe to write SwiftData here.
            // OrganizationPlanner cannot write @Model properties (wrong actor).
            let destByFileID = Dictionary(
                uniqueKeysWithValues: built.map { ($0.mediaFileID, $0.destinationAbsPath) }
            )
            for file in session.files {
                if let dest = destByFileID[file.id] {
                    file.plannedDestinationPath = dest
                }
            }

            try? context.save()

            plans = built
            isPlanning = false
        }
    }

    private func exportCSV() {
        guard let session = nav.scanSession else { return }

        do {
            let url = try ReportExporter.exportCSV(plans: plans, sessionID: session.id)
            exportFeedback = FeedbackMessage(
                title: "CSV Ready",
                message: "The preview report was saved to \(url.lastPathComponent). You can share it or review it in Finder.",
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
}

struct ApplyPreflightSheet: View {
    let planCount: Int
    let duplicateCount: Int
    let unknownDateCount: Int
    let operation: FileOperation
    let destinationPath: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(operation == .move ? "Review Before Moving" : "Review Before Copying")
                        .font(.title2).fontWeight(.bold)
                    Text(destinationPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    PlanStat(icon: "doc.fill", value: "\(planCount)", label: "files", color: .blue)
                    if duplicateCount > 0 {
                        PlanStat(icon: "square.on.square.fill",
                                 value: "\(duplicateCount)", label: "duplicates", color: .orange)
                    }
                    if unknownDateCount > 0 {
                        PlanStat(icon: "calendar.badge.exclamationmark",
                                 value: "\(unknownDateCount)", label: "no date",
                                 color: Color(red: 0.8, green: 0.65, blue: 0.0))
                    }
                }

                Text(operation == .move
                     ? "Files will be physically moved into the new structure. Foldiq will save an undo manifest so you can reverse the operation later."
                     : "Files will be copied into the new structure. Originals will stay in their current locations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if duplicateCount > 0 || unknownDateCount > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Attention points")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if duplicateCount > 0 {
                            Text("• \(duplicateCount) file(s) are being routed into duplicate folders.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if unknownDateCount > 0 {
                            Text("• \(unknownDateCount) file(s) still have no confirmed date and will remain in Unknown Date.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Spacer()
                Button(action: onConfirm) {
                    Label(
                        operation == .move ? "Move Files Now" : "Copy Files Now",
                        systemImage: operation == .move ? "arrow.right.circle.fill" : "doc.on.doc.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(operation == .move ? .blue : .green)
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 620)
    }
}

// MARK: ─── File Inspector Panel ──────────────────────────────────────────────

struct FileInspectorPanel: View {
    let plan: OrganizationPlan
    let session: ScanSession?
    let config: OrganizationConfig
    let context: ModelContext
    let onDateAssigned: (OrganizationPlan) -> Void

    @State private var thumbnail: NSImage?
    @State private var mediaFile: MediaFile?
    @State private var assignedDate: Date = Calendar.current.date(
        byAdding: .year, value: -3, to: Date()) ?? Date()   // reasonable default
    @State private var dateApplied = false
    @State private var quickLookURL: URL?

    private var isUnknownDate: Bool {
        plan.destinationAbsPath.contains("/Unknown Date/")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Thumbnail ─────────────────────────────────────────────
                ZStack {
                    Rectangle()
                        .fill(Color(.windowBackgroundColor).opacity(0.5))
                        .frame(height: 200)

                    if let img = thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { quickLookURL = plan.sourceURL }
                    } else {
                        Image(systemName: mediaFile?.mediaKind == .video ? "video.fill" : "photo")
                            .font(.system(size: 40, weight: .thin))
                            .foregroundStyle(.tertiary)
                    }

                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                quickLookURL = plan.sourceURL
                            } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption.weight(.semibold))
                                    .padding(8)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Open preview")
                        }
                        Spacer()
                    }
                    .padding(10)
                }

                VStack(alignment: .leading, spacing: 14) {

                    // ── Filename ─────────────────────────────────────────
                    Text(plan.sourceURL.lastPathComponent)
                        .fontWeight(.semibold)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    // ── Metadata rows ────────────────────────────────────
                    if let file = mediaFile {
                        MetaRow(label: "Size",  value: file.formattedFileSize)
                        MetaRow(label: "Type",  value: file.fileExtension.uppercased())
                        if let w = file.pixelWidth, let h = file.pixelHeight {
                            MetaRow(label: "Dimensions", value: "\(w) × \(h)")
                        }
                        if let make = file.cameraMake {
                            let cam = [make, file.cameraModel].compactMap { $0 }.joined(separator: " ")
                            MetaRow(label: "Camera", value: cam)
                        }
                        if file.hasGPS {
                            MetaRow(label: "GPS", value: "Available")
                        }
                        if let dur = file.durationSeconds, dur > 0 {
                            MetaRow(label: "Duration",
                                    value: String(format: "%d:%02d", Int(dur) / 60, Int(dur) % 60))
                        }
                    }

                    // ── Destination ──────────────────────────────────────
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Planned destination")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(plan.destinationURL.deletingLastPathComponent().lastPathComponent
                             + "/" + plan.destinationURL.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(isUnknownDate ? .orange : .secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([plan.sourceURL])
                    } label: {
                        Label("Show Original in Finder", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.bordered)

                    // ── Date assignment (Unknown Date files only) ────────
                    if isUnknownDate {
                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Label(dateApplied ? "Date assigned" : "Assign a date",
                                  systemImage: dateApplied ? "checkmark.circle.fill" : "calendar.badge.plus")
                                .font(.subheadline).fontWeight(.medium)
                                .foregroundStyle(dateApplied ? .green : .primary)

                            Text("Recognize this photo? Pick an approximate date and Foldiq will place it in the most appropriate folder.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            DatePicker(
                                "Date",
                                selection: $assignedDate,
                                in: ...Date(),
                                displayedComponents: [.date]
                            )
                            .labelsHidden()
                            .datePickerStyle(.compact)

                            Button {
                                applyDate(assignedDate)
                            } label: {
                                Label("Apply Date", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .tint(dateApplied ? .green : .blue)
                        }
                        .padding(12)
                        .background(.yellow.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.yellow.opacity(0.3), lineWidth: 1)
                        )
                    }
                }
                .padding(14)
            }
        }
        .background(Color(.windowBackgroundColor).opacity(0.4))
        .task(id: plan.id) { await loadFile() }
        .sheet(isPresented: quickLookBinding) {
            if let quickLookURL {
                PreviewQuickLookContainer(
                    url: quickLookURL,
                    onClose: { self.quickLookURL = nil }
                )
                .frame(minWidth: 720, minHeight: 520)
            }
        }
    }

    // MARK: - Load file info

    private func loadFile() async {
        // Fetch the MediaFile from SwiftData
        let fileID = plan.mediaFileID
        let descriptor = FetchDescriptor<MediaFile>(
            predicate: #Predicate { $0.id == fileID }
        )
        let file = (try? context.fetch(descriptor))?.first
        mediaFile = file

        // Determine kind: prefer SwiftData value, fall back to file extension.
        let url = plan.sourceURL
        let isVideo = file?.mediaKind == .video
                   || MediaTypes.videoExtensions.contains(url.pathExtension.lowercased())

        // Load thumbnail off the main thread.
        let img = await Task.detached(priority: .utility) { () -> NSImage? in
            if isVideo {
                // Use AVAssetImageGenerator for a real video frame thumbnail.
                let asset = AVURLAsset(url: url)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 540, height: 540)
                // Grab a frame ~1 s in; fall back to the very first frame.
                let requestTime = CMTime(seconds: 1.0, preferredTimescale: 600)
                if let cgImg = try? gen.copyCGImage(at: requestTime, actualTime: nil) {
                    return NSImage(cgImage: cgImg, size: .zero)
                }
                // Retry at t=0 for very short clips.
                if let cgImg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                    return NSImage(cgImage: cgImg, size: .zero)
                }
                return nil
            } else {
                // Use ImageIO for photos (including HEIC, RAW formats, etc.).
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let opts: [String: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize as String: 540,
                    kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                    kCGImageSourceCreateThumbnailWithTransform as String: true,
                ]
                guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                else { return nil }
                return NSImage(cgImage: cgThumb, size: .zero)
            }
        }.value
        thumbnail = img
    }

    // MARK: - Apply manual date

    private func applyDate(_ date: Date) {
        guard let file = mediaFile, let session else { return }

        // 1. Write dateTaken on the MediaFile
        file.dateTaken = date
        try? context.save()

        // 2. Recompute destination path using the same logic as OrganizationPlanner
        let cal = Calendar.current
        let year  = cal.component(.year,  from: date)
        let month = cal.component(.month, from: date)
        let day   = cal.component(.day,   from: date)
        let monthName = DateFormatter().monthSymbols[month - 1]
        let yearStr   = "\(year)"
        let monthStr  = String(format: "%d-%02d %@", year, month, monthName)
        let dayStr    = String(format: "%04d-%02d-%02d", year, month, day)

        let outputRoot = config.outputRoot(forSelectedRoot: URL(fileURLWithPath: session.rootPath))

        var folder: URL
        switch config.mode {
        case .byYear:
            folder = outputRoot.appendingPathComponent(yearStr)
        case .byYearMonth:
            folder = outputRoot.appendingPathComponent(yearStr).appendingPathComponent(monthStr)
        case .byExactDate:
            folder = outputRoot.appendingPathComponent(yearStr)
                               .appendingPathComponent(monthStr)
                               .appendingPathComponent(dayStr)
        case .byLocation:
            folder = outputRoot
                .appendingPathComponent("Unknown Location")
                .appendingPathComponent(yearStr)
        case .smartHybrid:
            folder = outputRoot.appendingPathComponent(yearStr)
                               .appendingPathComponent(monthStr)
                               .appendingPathComponent(dayStr)
        }

        // 3. Update the plan destination
        let newDest = folder.appendingPathComponent(plan.sourceURL.lastPathComponent)
        plan.destinationAbsPath = newDest.path
        try? context.save()

        dateApplied = true
        onDateAssigned(plan)
    }

    private var quickLookBinding: Binding<Bool> {
        Binding(
            get: { quickLookURL != nil },
            set: { isPresented in
                if !isPresented {
                    quickLookURL = nil
                }
            }
        )
    }
}

private struct PreviewQuickLookContainer: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PreviewQuickLookSheet(url: url)

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

private struct PreviewQuickLookSheet: NSViewRepresentable {
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

// MARK: ─── Meta Row ───────────────────────────────────────────────────────────

struct MetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
    }
}

// MARK: ─── Plan Stat ─────────────────────────────────────────────────────────
// Compact icon + value + label in one line. No pill background — reads cleanly
// at any window size without text wrapping.

struct PlanStat: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            if !value.isEmpty {
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: ─── Folder Tree Sheet ──────────────────────────────────────────────────

/// Data model for one node in the destination folder tree.
struct FolderNode: Identifiable {
    let id = UUID()
    let name: String
    var fileCount: Int       // files directly inside this folder
    var children: [FolderNode]

    /// Total files reachable from this node (self + all descendants).
    var totalCount: Int { fileCount + children.reduce(0) { $0 + $1.totalCount } }
    /// Returns children or nil so OutlineGroup treats empty folders as leaves.
    var childrenForOutline: [FolderNode]? { children.isEmpty ? nil : children }
}

struct FolderTreeSheet: View {
    let plans: [OrganizationPlan]
    let outputRoot: URL

    @Environment(\.dismiss) private var dismiss

    private var rootNode: FolderNode { buildTree() }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder Structure")
                        .font(.title2).fontWeight(.bold)
                    Text("\(plans.count) files → \(outputRoot.lastPathComponent)/")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary).font(.title2)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            // ── Tree ──────────────────────────────────────────────────────
            List {
                FolderNodeRow(node: rootNode)
            }
            .listStyle(.sidebar)

            Divider()

            // ── Footer ────────────────────────────────────────────────────
            HStack {
                Text("This is a preview — no files have been moved yet.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    // MARK: - Tree builder

    private func buildTree() -> FolderNode {
        // Count files per destination folder
        var counts: [String: Int] = [:]
        for plan in plans {
            let folder = plan.destinationURL.deletingLastPathComponent().path
            counts[folder, default: 0] += 1
        }

        // Root node
        let root = MutableFolderNode(name: outputRoot.lastPathComponent)
        let rootPath = outputRoot.path

        for (folderPath, count) in counts {
            // Strip the output root prefix to get relative path
            let relative: String
            if folderPath == rootPath {
                // Files directly in the output root (unusual but handle it)
                root.fileCount += count
                continue
            } else if folderPath.hasPrefix(rootPath + "/") {
                relative = String(folderPath.dropFirst(rootPath.count + 1))
            } else {
                // Outside output root — shouldn't happen but skip gracefully
                continue
            }
            let components = relative.split(separator: "/").map(String.init)
            root.insert(pathComponents: components, fileCount: count)
        }

        return root.toImmutable()
    }
}

// MARK: - Mutable build helper (private)

private final class MutableFolderNode {
    let name: String
    var fileCount: Int = 0
    var children: [String: MutableFolderNode] = [:]  // keyed by folder name

    init(name: String) { self.name = name }

    func insert(pathComponents: [String], fileCount: Int) {
        guard !pathComponents.isEmpty else {
            self.fileCount += fileCount
            return
        }
        let head = pathComponents[0]
        let tail = Array(pathComponents.dropFirst())
        let child = children[head, default: MutableFolderNode(name: head)]
        children[head] = child
        child.insert(pathComponents: tail, fileCount: fileCount)
    }

    func toImmutable() -> FolderNode {
        let sortedChildren = children.values
            .sorted { $0.name < $1.name }
            .map { $0.toImmutable() }
        return FolderNode(name: name, fileCount: fileCount, children: sortedChildren)
    }
}

// MARK: - Folder node row

struct FolderNodeRow: View {
    let node: FolderNode

    var body: some View {
        if let kids = node.childrenForOutline {
            // Has subfolders — show as disclosure group
            DisclosureGroup(
                content: {
                    ForEach(kids) { child in
                        FolderNodeRow(node: child)
                    }
                    if node.fileCount > 0 {
                        // Files directly in this folder
                        HStack(spacing: 8) {
                            Image(systemName: "doc.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(width: 14)
                            Text("\(node.fileCount) file\(node.fileCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.leading, 4)
                    }
                },
                label: {
                    FolderRowLabel(node: node)
                }
            )
        } else {
            // Leaf folder (no subfolders)
            FolderRowLabel(node: node)
        }
    }
}

struct FolderRowLabel: View {
    let node: FolderNode

    var isSpecial: Bool {
        node.name == "Duplicates" || node.name == "Exact Duplicates"
    }
    var isUnknown: Bool { node.name == "Unknown Date" }
    var isScreenshot: Bool { node.name == "Screenshots" }

    var folderColor: Color {
        if isSpecial  { return .orange }
        if isUnknown  { return .yellow }
        if isScreenshot { return .purple }
        return .blue
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(folderColor)
                .frame(width: 16)

            Text(node.name)
                .lineLimit(1)

            Spacer()

            Text("\(node.totalCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
