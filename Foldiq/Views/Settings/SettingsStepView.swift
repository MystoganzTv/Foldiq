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

    private var operationHeadline: String {
        nav.organizationConfig.fileOperation == .move
            ? "Move originals into the new structure"
            : "Keep originals where they are and create organized copies"
    }

    private var operationSummary: String {
        nav.organizationConfig.fileOperation == .move
            ? "Best when you are ready to clean up the library now. An undo manifest is still created before changes are made."
            : "Best when you want a lower-risk first pass. It uses more disk space because both the original and organized copy remain."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {

                // ── Page header ────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text("Organization Settings")
                        .font(.largeTitle).fontWeight(.bold)
                    Text("Choose the rule, the destination, and how your original files should be handled. You will preview every change before anything is applied.")
                        .foregroundStyle(.secondary)
                }

                // ── Mode picker ────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 12) {
                    Label("Organization Rule", systemImage: "folder.badge.gearshape")
                        .font(.headline)
                    Text("This decides how folders are named and how files are grouped inside \(selectedRootName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                    Label("How To Handle Originals", systemImage: "arrow.right.doc.on.clipboard")
                        .font(.headline)
                    Text("Pick whether the originals should be reorganized directly or whether a second organized library should be created.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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

                    VStack(alignment: .leading, spacing: 6) {
                        Label(operationHeadline, systemImage: "info.circle")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(operationSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }

                Divider()

                // ── Additional options ─────────────────────────────────────
                VStack(alignment: .leading, spacing: 14) {
                    Label("Rules", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Text("These rules affect what gets organized and how special cases are routed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                        detail: "Move duplicates to a Duplicates/ subfolder instead of organizing normally",
                        isOn: $nav.organizationConfig.separateDuplicates
                    )
                    ToggleRow(
                        label: "Use GPS location in folder names",
                        detail: "Requires internet for reverse-geocoding (Smart Hybrid and By Location modes)",
                        isOn: $nav.organizationConfig.useGPSLocation
                    )
                }

                Divider()

                // ── Output folder name ─────────────────────────────────────
                VStack(alignment: .leading, spacing: 12) {
                    Label("Destination", systemImage: "folder")
                        .font(.headline)
                    Text("Choose whether the organized library should be saved inside the scanned folder or in another folder you pick. Existing files at the destination are never overwritten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        DestinationModeRow(
                            title: "Inside selected folder",
                            detail: "Save the organized library inside \(selectedRootName).",
                            isSelected: !nav.organizationConfig.hasCustomOutputParent
                        ) {
                            nav.organizationConfig.customOutputParentPath = nil
                        }

                        DestinationModeRow(
                            title: "Custom location",
                            detail: "Choose a different parent folder for the organized library.",
                            isSelected: nav.organizationConfig.hasCustomOutputParent
                        ) {
                            chooseCustomDestinationFolder()
                        }
                    }

                    HStack {
                        TextField("Organized Media", text: $nav.organizationConfig.outputFolderName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                        Text("(folder name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Save location")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(destinationBasePath)
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
                                Button("Use Selected Folder Instead") {
                                    nav.organizationConfig.customOutputParentPath = nil
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Final destination")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(destinationPreviewPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }

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

struct DestinationModeRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
