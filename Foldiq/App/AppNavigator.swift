// AppNavigator.swift
// Single source of truth for which screen is shown.
// Foldiq is a linear wizard: Welcome → Scan → Settings → Preview → Apply → Report

import SwiftUI

/// The ordered steps of the Foldiq wizard
enum AppScreen: Int, CaseIterable {
    case welcome        = 0
    case scan           = 1
    case settings       = 2
    case preview        = 3
    case apply          = 4
    case report         = 5

    var title: String {
        switch self {
        case .welcome:  return "Welcome"
        case .scan:     return "Scan Results"
        case .settings: return "Organization Settings"
        case .preview:  return "Preview Changes"
        case .apply:    return "Applying"
        case .report:   return "Report"
        }
    }

    var icon: String {
        switch self {
        case .welcome:  return "house"
        case .scan:     return "magnifyingglass.circle"
        case .settings: return "slider.horizontal.3"
        case .preview:  return "eye"
        case .apply:    return "arrow.triangle.2.circlepath"
        case .report:   return "checkmark.circle"
        }
    }
}

@MainActor
final class AppNavigator: ObservableObject {
    @Published var screen: AppScreen = .welcome
    /// True the very first time the app launches — shows OnboardingView overlay.
    @Published var showOnboarding: Bool = !UserDefaults.standard.bool(forKey: "hasSeenOnboarding")
    /// All folders the user selected for this scan session (multi-select supported).
    @Published var selectedFolderURLs: [URL] = []
    @Published var scanSession: ScanSession?
    // Config is loaded from UserDefaults on first launch and auto-saved whenever it changes.
    @Published var organizationConfig: OrganizationConfig = .load() {
        didSet { organizationConfig.save() }
    }
    /// Temp directories created when extracting .zip archives during scan.
    /// Cleaned up by FileMover after apply, or discarded on restart.
    var archiveTempDirs: [URL] = []

    /// Set by ReportView before calling restart() after a successful undo.
    /// WelcomeView reads this to show a confirmation toast, then clears it.
    @Published var lastUndoRestoredCount: Int?

    // Error toast
    @Published var errorMessage: String?
    @Published var showingError = false

    /// Primary folder (first selected) — output is placed here.
    var rootFolderURL: URL? { selectedFolderURLs.first }

    func go(to screen: AppScreen) {
        withAnimation(.easeInOut(duration: 0.25)) {
            self.screen = screen
        }
    }

    func goNext() {
        let next = AppScreen(rawValue: screen.rawValue + 1) ?? screen
        go(to: next)
    }

    func restart() {
        // Clean up any leftover archive extraction temp dirs
        let dirs = archiveTempDirs
        archiveTempDirs = []
        if !dirs.isEmpty {
            Task.detached(priority: .background) {
                for dir in dirs {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
        }
        selectedFolderURLs = []
        scanSession = nil
        // Intentionally keep organizationConfig — user's settings survive between sessions.
        // customOutputParentPath is session-specific, so clear it for the new session.
        organizationConfig.customOutputParentPath = nil
        go(to: .welcome)
    }

    func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}
