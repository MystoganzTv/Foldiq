// WelcomeView.swift
// Step 1: Intro + folder/zip picker (supports selecting multiple folders and .zip files).

import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {

    @EnvironmentObject private var nav: AppNavigator
    @State private var isHoveringButton = false

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

            Spacer().frame(height: 48)

            // ── Feature bullets ─────────────────────────────────────────────
            HStack(spacing: 40) {
                FeaturePill(icon: "shield.checkered",       label: "Safe — preview before\nanything moves")
                FeaturePill(icon: "clock.arrow.circlepath", label: "Undo any operation\ncompletely")
                FeaturePill(icon: "icloud.slash",           label: "100% local — no\ncloud or account")
                FeaturePill(icon: "folder.fill.badge.plus", label: "Physical folders\non your Mac")
            }

            Spacer().frame(height: 48)

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
    }

    // MARK: - Helpers

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
