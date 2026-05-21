// SettingsView.swift
// macOS Settings window (Cmd+,).
// Binds directly to the same UserDefaults keys used by OrganizationConfig.load(),
// so any change here is picked up automatically the next time a scan session starts.

import SwiftUI

struct SettingsView: View {

    // ── Organisation defaults ──────────────────────────────────────────────────
    // These @AppStorage bindings write to the exact same UserDefaults keys that
    // OrganizationConfig.load() reads, so they are always in sync.

    @AppStorage(OrganizationConfig.UDKey.mode)
    private var defaultMode: OrganizationMode = .smartHybrid

    @AppStorage(OrganizationConfig.UDKey.fileOperation)
    private var defaultFileOp: FileOperation = .move

    @AppStorage(OrganizationConfig.UDKey.includeVideos)
    private var includeVideos = true

    @AppStorage(OrganizationConfig.UDKey.includeArchives)
    private var includeArchives = true

    @AppStorage(OrganizationConfig.UDKey.separateDuplicates)
    private var separateDuplicates = true

    @AppStorage(OrganizationConfig.UDKey.useGPSLocation)
    private var useGPS = true

    @AppStorage(OrganizationConfig.UDKey.outputFolderName)
    private var outputFolderName = "Organized Media"

    // ── Local state ────────────────────────────────────────────────────────────
    @State private var showingResetConfirmation = false

    var body: some View {
        TabView {
            organizationTab
                .tabItem { Label("Organization", systemImage: "folder.badge.gearshape") }

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 480)
    }

    // MARK: - Organization tab

    private var organizationTab: some View {
        Form {
            Section {
                Text("These are the default settings applied at the start of every new scan session. You can still adjust them in the wizard before previewing changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Folder Structure") {
                Picker("Default structure", selection: $defaultMode) {
                    ForEach(OrganizationMode.allCases, id: \.rawValue) { mode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.rawValue)
                            Text(mode.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("File Handling") {
                Picker("Default operation", selection: $defaultFileOp) {
                    Text("Move originals into new folders").tag(FileOperation.move)
                    Text("Copy — keep originals in place").tag(FileOperation.copy)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Rules") {
                Toggle("Include video files alongside photos", isOn: $includeVideos)
                Toggle("Include compressed archives (ZIP, etc.)", isOn: $includeArchives)
                Toggle("Route duplicates to a Duplicates/ subfolder", isOn: $separateDuplicates)
                Toggle("Use GPS location in folder names (requires internet)", isOn: $useGPS)
            }

            Section("Output Folder") {
                HStack {
                    TextField("Organized Media", text: $outputFolderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Text("(folder name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset All to Defaults", role: .destructive) {
                        showingResetConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .confirmationDialog(
                        "Reset all settings to factory defaults?",
                        isPresented: $showingResetConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Reset to Defaults", role: .destructive) {
                            OrganizationConfig.resetToDefaults()
                            // Reload local @AppStorage state to reflect reset
                            defaultMode       = .smartHybrid
                            defaultFileOp     = .move
                            includeVideos     = true
                            includeArchives   = true
                            separateDuplicates = true
                            useGPS            = true
                            outputFolderName  = "Organized Media"
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will reset the default organization mode, file operation, and all rules to their original values.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About tab

    private var aboutTab: some View {
        Form {
            Section("Foldiq") {
                LabeledContent("Version") {
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Build") {
                    Text(appBuild)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Platform") {
                    Text("macOS \(macOSVersion)")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("100% local processing", systemImage: "icloud.slash")
                        .fontWeight(.medium)
                    Text("Foldiq never uploads your files or metadata to any server. All organization happens entirely on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Data") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Undo manifests are saved locally", systemImage: "clock.arrow.circlepath")
                        .fontWeight(.medium)
                    Text("Every time you apply an organization, Foldiq saves a full undo manifest so you can reverse all file movements at any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
