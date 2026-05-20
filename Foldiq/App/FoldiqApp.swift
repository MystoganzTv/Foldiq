// FoldiqApp.swift
// Entry point for Foldiq — a safe, local-first photo/video folder organizer for macOS.

import SwiftUI
import SwiftData

@main
struct FoldiqApp: App {

    // MARK: - SwiftData container
    // Holds scan results, organization plans, and undo manifests
    // across the session. Stored on disk so a crash doesn't lose progress.
    //
    // Schema-change strategy (development builds):
    //   When the @Model schema evolves (new properties added/removed), SwiftData
    //   cannot silently migrate a non-optional column that has no stored default.
    //   For production, switch to VersionedSchema + SchemaMigrationPlan.
    //   For now we destroy and recreate the store on any load failure — scan data
    //   is always regenerated, and undo manifests from a prior schema are invalid anyway.
    let container: ModelContainer = {
        let schema = Schema([
            MediaFile.self,
            OrganizationPlan.self,
            UndoManifest.self,
            UndoEntry.self,
            ScanSession.self,
        ])

        // Explicit store URL so we can nuke it on migration failure.
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeDir = appSupport.appendingPathComponent("Foldiq", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let storeURL = storeDir.appendingPathComponent("Foldiq.store")

        let cfg = ModelConfiguration(schema: schema, url: storeURL)

        do {
            return try ModelContainer(for: schema, configurations: [cfg])
        } catch {
            // Schema changed — destroy the stale store and start fresh.
            print("⚠️ SwiftData store incompatible with current schema — wiping and recreating. Error: \(error)")
            let sidecarExtensions = ["store-shm", "store-wal"]
            for ext in (["store"] + sidecarExtensions) {
                let url = storeDir.appendingPathComponent("Foldiq.\(ext)")
                try? FileManager.default.removeItem(at: url)
            }
            do {
                return try ModelContainer(for: schema, configurations: [cfg])
            } catch {
                fatalError("SwiftData failed to initialize even after store reset: \(error)")
            }
        }
    }()

    @StateObject private var nav = AppNavigator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(container)
                .environmentObject(nav)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands { FoldiqCommands() }

        Settings {
            SettingsView()
        }
    }
}
