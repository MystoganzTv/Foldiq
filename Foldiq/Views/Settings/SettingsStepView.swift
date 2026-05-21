// SettingsStepView.swift
// Step 3: The user picks an organization mode and file operation options.

import SwiftUI
import AppKit

struct SettingsStepView: View {

    @EnvironmentObject private var nav: AppNavigator

    private var selectedRootName: String {
        nav.rootFolderURL?.lastPathComponent ?? "your selected folder"
    }

    private var destinationPreviewPath: String {
        guard let rootURL = nav.rootFolderURL else {
            return nav.organizationConfig.outputFolderName
        }
        return nav.organizationConfig.outputRoot(forSelectedRoot: rootURL).path
    }

    private var destinationBasePath: String {
        if let custom = nav.organizationConfig.customOutputParentPath, !custom.isEmpty {
            return custom
        }
        return nav.rootFolderURL?.path ?? "No folder selected"
    }

    private var operationSummary: String {
        nav.organizationConfig.fileOperation == .move
            ? "Best when you are ready to clean up the library now. An undo manifest is still created before changes are made."
            : "Best when you want a lower-risk first pass. It uses more disk space because both the original and organized copy remain."
    }

    @State private var showMoreOptions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {

                // ── Page header ────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text("Organization Settings")
                        .font(.largeTitle).fontWeight(.bold)
                    Text("Pick a rule, where to save the result, and how originals should be handled. You'll preview every change before anything moves.")
                        .foregroundStyle(.secondary)
                }

                // ── Mode picker ────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 12) {
                    Label("Organization Rule", systemImage: "folder.badge.gearshape")
                        .font(.headline)

                    ForEach(OrganizationMode.allCases, id: \.self) { mode in
                        ModeOptionRow(
                            mode: mode,
                            isSelected: nav.organizationConfig.mode == mode
                        ) {
                            nav.organizationConfig.mode = mode
                        }
                    }
                }

                Divider()

                // ── File operation ─────────────────────────────────────────
                VStack(alignment: .leading, spacing: 12) {
                    Label("Originals", systemImage: "arrow.right.doc.on.clipboard")
                        .font(.headline)

                    HStack(spacing: 16) {
                        OperationCard(
                            op: .move,
                            selected: nav.organizationConfig.fileOperation == .move
                        ) { nav.organizationConfig.fileOperation = .move }

                        OperationCard(
                            op: .copy,
                            selected: nav.organizationConfig.fileOperation == .copy
                        ) { nav.organizationConfig.fileOperation = .copy }
                    }

                    Text(operationSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                Divider()

                // ── Destination ────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    Label("Destination", systemImage: "folder")
                        .font(.headline)

                    Text(destinationPreviewPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 10) {
                        Button(nav.organizationConfig.hasCustomOutputParent ? "Change Location" : "Choose Location") {
                            chooseCustomDestinationFolder()
                        }
                        .buttonStyle(.bordered)

                        if nav.organizationConfig.hasCustomOutputParent {
                            Button("Use Selected Folder") {
                                nav.organizationConfig.customOutputParentPath = nil
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Divider()

                // ── More options (collapsed by default) ───────────────────
                DisclosureGroup(isExpanded: $showMoreOptions) {
                    VStack(alignment: .leading, spacing: 14) {
                        ToggleRow(
                            label: "Include videos",
                            detail: "Organize video files alongside photos",
                            isOn: $nav.organizationConfig.includeVideos
                        )
                        ToggleRow(
                            label: "Include archives",
                            detail: "Organize compressed files (zip, rar, 7z…) alongside your media",
                            isOn: $nav.organizationConfig.includeArchives
                        )
                        ToggleRow(
                            label: "Separate duplicates",
                            detail: "Route duplicates to a Duplicates/ subfolder instead of organizing normally",
                            isOn: $nav.organizationConfig.separateDuplicates
                        )
                        ToggleRow(
                            label: "Use GPS location in folder names",
                            detail: "Requires internet for reverse-geocoding (Smart Hybrid and By Location modes)",
                            isOn: $nav.organizationConfig.useGPSLocation
                        )

                        Divider().padding(.vertical, 4)

                        HStack {
                            Text("Output folder name")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                            TextField("Organized Media", text: $nav.organizationConfig.outputFolderName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 220)
                        }
                    }
                    .padding(.top, 14)
                } label: {
                    Label("More options", systemImage: "slider.horizontal.3")
                        .font(.headline)
                }
                .animation(.easeInOut(duration: 0.2), value: showMoreOptions)

            }
            .padding(40)
        }
        .safeAreaInset(edge: .bottom) {
            // ── Footer navigation ──────────────────────────────────────────
            HStack {
                Button("Back") { nav.go(to: .scan) }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    nav.go(to: .preview)
                } label: {
                    HStack {
                        Text("Preview Organization")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 16)
            .background(.bar)
        }
    }

    private func chooseCustomDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Destination"
        panel.message = "Choose the folder where the organized library should be created."

        if let currentPath = nav.organizationConfig.customOutputParentPath, !currentPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: currentPath)
        } else {
            panel.directoryURL = nav.rootFolderURL
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        nav.organizationConfig.customOutputParentPath = url.path
    }
}

// MARK: ─── Mode Option Row ────────────────────────────────────────────────────

struct ModeOptionRow: View {
    let mode: OrganizationMode
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 2)
                    .frame(width: 20, height: 20)
                if isSelected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 11, height: 11)
                }
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(mode.rawValue).fontWeight(.medium)
                    if mode == .smartHybrid {
                        Text("Recommended")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.blue, in: Capsule())
                    }
                }
                Text(mode.description)
                    .font(.caption).foregroundStyle(.secondary)

                // Example tree
                Text(mode.exampleTree)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 4)
            }

            Spacer()
        }
        .padding(14)
        .background(isSelected ? Color.accentColor.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color(.separatorColor), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

// MARK: ─── Operation Card ─────────────────────────────────────────────────────

struct OperationCard: View {
    let op: FileOperation
    let selected: Bool
    let onTap: () -> Void

    var icon: String   { op == .move ? "arrow.right.circle" : "doc.on.doc" }
    var label: String  { op == .move ? "Move" : "Copy" }
    var detail: String {
        op == .move
            ? "Files are moved to organized folders. Originals no longer remain in their old location."
            : "Files are copied. Originals stay in place. Safer but uses more disk space."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).font(.title3)
                Text(label).fontWeight(.semibold)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.08) : Color(.windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : Color(.separatorColor), lineWidth: selected ? 1.5 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

// MARK: ─── Toggle Row ─────────────────────────────────────────────────────────

struct ToggleRow: View {
    let label: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}

