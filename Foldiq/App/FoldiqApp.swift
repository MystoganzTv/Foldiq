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
    // Load-failure strategy:
    //   If the store can't be opened (usually a schema change SwiftData can't
    //   migrate on its own), the old files are MOVED aside into
    //   "Foldiq/Recovered Stores/<date>/" instead of being deleted, so pending undo
    //   journals are never destroyed. If even a fresh store can't be created, the
    //   app runs on an in-memory store for this session instead of crashing.
    //   Either way the user is told once, on launch.
    //   Long term, switch to VersionedSchema + SchemaMigrationPlan.
    let container: ModelContainer = FoldiqStore.makeContainer()

    @StateObject private var nav = AppNavigator()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .modelContainer(container)
                .environmentObject(nav)
                .frame(minWidth: 960, minHeight: 640)
                .storeRecoveryAlert()
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
                .storeRecoveryAlert()
        }
        #endif
    }
}

// MARK: - Store loading

enum FoldiqStore {
    enum Recovery {
        /// The old store couldn't be opened; it was moved to `backupFolder`.
        case movedAside(backupFolder: URL)
        /// No on-disk store could be opened at all; this session runs in memory.
        case inMemoryOnly
    }

    /// Set once while the container is built, read by the launch alert.
    static private(set) var recovery: Recovery?

    static let schema = Schema([
        MediaFile.self,
        OrganizationPlan.self,
        UndoManifest.self,
        UndoEntry.self,
        ScanSession.self,
    ])

    static func makeContainer() -> ModelContainer {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let storeDir = appSupport.appendingPathComponent("Foldiq", isDirectory: true)
        try? fileManager.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let storeURL = storeDir.appendingPathComponent("Foldiq.store")
        let onDisk = ModelConfiguration(schema: schema, url: storeURL)

        do {
            return try ModelContainer(for: schema, configurations: [onDisk])
        } catch {
            print("⚠️ SwiftData store could not be opened — moving it aside. Error: \(error)")
        }

        if let backupFolder = moveStoreAside(storeDir: storeDir) {
            do {
                let container = try ModelContainer(for: schema, configurations: [onDisk])
                recovery = .movedAside(backupFolder: backupFolder)
                return container
            } catch {
                print("⚠️ SwiftData failed to create a fresh store: \(error)")
            }
        }

        // Last resort: keep the app usable for this session rather than crashing.
        do {
            let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: schema, configurations: [inMemory])
            recovery = .inMemoryOnly
            return container
        } catch {
            // An in-memory store of a valid schema can't realistically fail; if it
            // does, the model definitions themselves are broken.
            fatalError("SwiftData could not create even an in-memory store: \(error)")
        }
    }

    /// Moves Foldiq.store and its -shm/-wal sidecars into a dated backup folder.
    /// Returns nil if the files could not be moved (nothing is ever deleted).
    private static func moveStoreAside(storeDir: URL) -> URL? {
        let fileManager = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let backupFolder = storeDir
            .appendingPathComponent("Recovered Stores", isDirectory: true)
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)

        do {
            try fileManager.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            for ext in ["store", "store-shm", "store-wal"] {
                let source = storeDir.appendingPathComponent("Foldiq.\(ext)")
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.moveItem(at: source, to: backupFolder.appendingPathComponent(source.lastPathComponent))
            }
            return backupFolder
        } catch {
            print("⚠️ Could not move the SwiftData store aside: \(error)")
            return nil
        }
    }
}

private struct StoreRecoveryAlertModifier: ViewModifier {
    @State private var isPresented = FoldiqStore.recovery != nil

    func body(content: Content) -> some View {
        content.alert("Foldiq had to start fresh", isPresented: $isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    private var message: String {
        switch FoldiqStore.recovery {
        case .movedAside(let folder):
            return "Foldiq couldn't open its saved session data, so it started with a clean slate. "
                + "Nothing in your photo folders was touched. The previous data was kept in "
                + "\"\(folder.path)\" in case you need help recovering a pending Undo."
        case .inMemoryOnly:
            return "Foldiq couldn't open its saved session data. You can keep working, but this "
                + "session won't be saved when you quit. Nothing in your photo folders was touched."
        case nil:
            return ""
        }
    }
}

extension View {
    func storeRecoveryAlert() -> some View {
        modifier(StoreRecoveryAlertModifier())
    }
}

// MARK: - Model liveness

extension PersistentModel {
    /// False once the model was deleted from its context (or the context let go of
    /// it). Long-running work that awaits — scans, duplicate detection, Apply,
    /// Undo — must check this after every suspension point before touching the
    /// model again: going back to the Welcome screen purges scan data, and writing
    /// to a deleted model traps inside SwiftData.
    var isUsable: Bool { !isDeleted && modelContext != nil }
}
