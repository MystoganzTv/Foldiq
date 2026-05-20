// SettingsView.swift
// macOS Settings window (Cmd+,). Minimal — most config is in the wizard.

import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultMode") private var defaultMode = OrganizationMode.smartHybrid.rawValue
    @AppStorage("defaultOperation") private var defaultOperation = FileOperation.move.rawValue

    var body: some View {
        Form {
            Section {
                Text("These defaults are used when you start a new organization session. You can still change the rule and destination before previewing any file changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Defaults") {
                Picker("Default folder structure", selection: $defaultMode) {
                    ForEach(OrganizationMode.allCases, id: \.rawValue) {
                        Text($0.rawValue).tag($0.rawValue)
                    }
                }
                Picker("Default file operation", selection: $defaultOperation) {
                    Text("Move originals").tag(FileOperation.move.rawValue)
                    Text("Copy and keep originals").tag(FileOperation.copy.rawValue)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 240)
    }
}
