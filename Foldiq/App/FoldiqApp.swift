// FoldiqApp.swift
// Entry point for Foldiq — a safe, local-first photo/video folder organizer.

import SwiftUI
import SwiftData

@main
struct FoldiqApp: App {

    // MARK: - SwiftData container
    // Holds scan results, organization plans, and undo manifests
    // across the session. Stored on disk so a crash doesn't lose progress.
    //
    // Schema changes: SwiftData migrates added properties on its own as long
    //   as they are optional or have a default, so new fields must be added
    //   that way. If the store still can't be opened, it is moved aside — never
    //   deleted — because it may hold the safety record of an interrupted
    //   organization, the only way to put those files back.
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
            print("⚠️ SwiftData store can't be opened with the current schema — moving it aside. Error: \(error)")
            let fm = FileManager.default
            let backupDir = storeDir.appendingPathComponent(
                "Previous Database \(DateFileNaming.stem(for: Date()))",
                isDirectory: true
            )
            try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            for ext in ["store", "store-shm", "store-wal"] {
                let url = storeDir.appendingPathComponent("Foldiq.\(ext)")
                guard fm.fileExists(atPath: url.path) else { continue }
                do {
                    try fm.moveItem(at: url, to: backupDir.appendingPathComponent(url.lastPathComponent))
                } catch {
                    // Last resort only: a store that can't be moved would make
                    // Foldiq fail to start every time.
                    try? fm.removeItem(at: url)
                }
            }
            UserDefaults.standard.set(backupDir.path, forKey: "foldiq.previousDatabasePath")
            do {
                return try ModelContainer(for: schema, configurations: [cfg])
            } catch {
                fatalError("SwiftData failed to initialize even after store reset: \(error)")
            }
        }
    }()

    @StateObject private var nav = AppNavigator()

    var body: some Scene {
        #if os(macOS)
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
        #else
        WindowGroup {
            IOSPhotosExportView()
                .modelContainer(container)
                .environmentObject(nav)
        }
        #endif
    }
}
