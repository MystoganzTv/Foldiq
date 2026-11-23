import SwiftUI
import Foundation

/// Where Foldiq's App Store record lives. Apple ID 6772513569.
enum AppStoreLinks {
    private static let appID = "6772513569"

    /// Opens the product page.
    static let productPage = URL(string: "https://apps.apple.com/app/id\(appID)")!

    /// Opens the product page with the review composer already presented. Unlike
    /// `requestReview()` this is never throttled, because the person asked for it.
    static let writeReview = URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")!
}

// MARK: ─── App Store copies vs. copies bought on foldiq.app ──────────────────

/// How this copy reached the Mac. App Store copies carry Apple's receipt;
/// copies bought on foldiq.app (Developer ID builds) and Xcode builds don't.
/// Web copies can't leave App Store reviews and get updates from foldiq.app.
enum AppDistribution {
    static let isAppStore: Bool = {
        guard let receipt = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: receipt.path)
    }()
}

#if os(macOS)
/// Tells people who bought Foldiq on foldiq.app when a newer version is out.
/// App Store copies are updated by the App Store and never check.
@MainActor
final class WebUpdateChecker: ObservableObject {
    static let feedURL = URL(string: "https://foldiq.app/mac-version.json")!
    static let fallbackPage = URL(string: "https://foldiq.app/mac-update.html")!
    private static let dismissedKey = "webUpdateDismissedVersion"

    @Published private(set) var availableVersion: String?
    @Published private(set) var downloadPage: URL = WebUpdateChecker.fallbackPage

    private struct Feed: Decodable {
        let version: String
        let downloadPage: URL?
    }

    func check() async {
        guard !AppDistribution.isAppStore else { return }
        let request = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        guard let response = try? await URLSession.shared.data(for: request),
              let feed = try? JSONDecoder().decode(Feed.self, from: response.0),
              Self.isNewer(feed.version, than: AppInfo.version),
              feed.version != UserDefaults.standard.string(forKey: Self.dismissedKey)
        else { return }
        downloadPage = feed.downloadPage ?? Self.fallbackPage
        availableVersion = feed.version
    }

    /// "Later" hides this version; the next one is announced again.
    func dismiss() {
        UserDefaults.standard.set(availableVersion, forKey: Self.dismissedKey)
        availableVersion = nil
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let old = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(new.count, old.count) {
            let lhs = index < new.count ? new[index] : 0
            let rhs = index < old.count ? old[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}
#endif

/// Decides when to spend one of Apple's review requests.
///
/// `requestReview()` is a *request*, not a guarantee: StoreKit draws the dialog
/// only when it feels like it, and stays silent in TestFlight, in enterprise
/// builds, and once its own yearly quota is spent. The first version of this
/// policy treated a single request as proof the person had been asked and never
/// asked again for the life of the install — so everyone whose dialog was
/// silently swallowed was written off permanently.
///
/// This version keeps its own budget instead: at most three attempts per rolling
/// year, spaced well apart, and only once the app has demonstrably worked for
/// this person more than once. Apple enforces its own three-per-year cap on the
/// dialog itself, so matching that number can never result in over-asking.
enum AppReviewPromptPolicy {

    /// One successful run is not evidence the app earned anything — the person
    /// has not yet gone and checked that their library came through intact.
    static let minimumSuccessfulOrganizations = 2

    /// A handful of test files is a trial run, not a win worth celebrating.
    static let minimumOrganizedItems = 25

    /// Apple's own cap on how often the dialog can appear for one person.
    static let maximumAttemptsPerYear = 3

    /// Long enough that a person who ignored the dialog is not asked again the
    /// same week, short enough that the yearly budget actually gets used.
    static let minimumDaysBetweenAttempts = 45

    private enum Key {
        static let successfulOrganizations = "foldiq.review.successfulOrganizationCount"
        static let organizedItems = "foldiq.review.organizedItemTotal"
        static let attemptTimestamps = "foldiq.review.attemptTimestamps"
        /// Written by versions up to 1.0.20. Migrated once, then removed.
        static let legacySingleRequestFlag = "hasRequestedReviewAfterSuccessfulOrganization"
    }

    private static let oneDay: TimeInterval = 24 * 60 * 60

    /// Records the finished run and reports whether this is a good moment to
    /// spend an attempt. Calling this *is* the attempt — only call it when the
    /// caller will follow through with `requestReview()`.
    static func shouldRequestAfterSuccessfulOrganization(
        successfulItemCount: Int,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Bool {
        guard successfulItemCount > 0 else { return false }

        migrateLegacyFlagIfNeeded(defaults: defaults, now: now)
        recordSuccessfulOrganization(itemCount: successfulItemCount, defaults: defaults)

        guard hasEarnedTheAsk(defaults: defaults),
              let attempts = remainingAttempts(defaults: defaults, now: now),
              attempts > 0 else {
            return false
        }

        recordAttempt(defaults: defaults, now: now)
        return true
    }

    /// True when Foldiq already spent a StoreKit attempt recently. The softer
    /// in-app invitation uses this so the two asks never stack on top of
    /// each other.
    static func didAttemptRecently(
        withinDays days: Int = 7,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Bool {
        guard let latest = attemptTimestamps(defaults: defaults).max() else { return false }
        return now.timeIntervalSince1970 - latest < Double(days) * oneDay
    }

    /// How many times the app has finished a run without errors. The manual
    /// invitation uses this to stay quiet until the app has actually delivered.
    static func successfulOrganizationCount(defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: Key.successfulOrganizations)
    }

    // MARK: - Internals

    private static func recordSuccessfulOrganization(itemCount: Int, defaults: UserDefaults) {
        defaults.set(defaults.integer(forKey: Key.successfulOrganizations) + 1, forKey: Key.successfulOrganizations)
        defaults.set(defaults.integer(forKey: Key.organizedItems) + itemCount, forKey: Key.organizedItems)
    }

    private static func hasEarnedTheAsk(defaults: UserDefaults) -> Bool {
        defaults.integer(forKey: Key.successfulOrganizations) >= minimumSuccessfulOrganizations
            && defaults.integer(forKey: Key.organizedItems) >= minimumOrganizedItems
    }

    /// Attempts left in the rolling year, or `nil` when the spacing rule blocks
    /// an attempt regardless of how much budget is left.
    private static func remainingAttempts(defaults: UserDefaults, now: Date) -> Int? {
        let recent = attemptsWithinTheYear(defaults: defaults, now: now)

        if let latest = recent.max() {
            let elapsed = now.timeIntervalSince1970 - latest
            guard elapsed >= Double(minimumDaysBetweenAttempts) * oneDay else { return nil }
        }

        return max(0, maximumAttemptsPerYear - recent.count)
    }

    private static func attemptsWithinTheYear(defaults: UserDefaults, now: Date) -> [Double] {
        let cutoff = now.timeIntervalSince1970 - 365 * oneDay
        return attemptTimestamps(defaults: defaults).filter { $0 >= cutoff }
    }

    private static func attemptTimestamps(defaults: UserDefaults) -> [Double] {
        defaults.array(forKey: Key.attemptTimestamps) as? [Double] ?? []
    }

    private static func recordAttempt(defaults: UserDefaults, now: Date) {
        let kept = attemptsWithinTheYear(defaults: defaults, now: now) + [now.timeIntervalSince1970]
        defaults.set(kept, forKey: Key.attemptTimestamps)
    }

    /// People who already saw — or were silently denied — the single lifetime
    /// prompt start with one attempt spent, dated far enough back that their
    /// next qualifying run can ask again.
    private static func migrateLegacyFlagIfNeeded(defaults: UserDefaults, now: Date) {
        guard defaults.bool(forKey: Key.legacySingleRequestFlag) else { return }
        defaults.removeObject(forKey: Key.legacySingleRequestFlag)

        if attemptTimestamps(defaults: defaults).isEmpty {
            let backdated = now.timeIntervalSince1970 - Double(minimumDaysBetweenAttempts) * oneDay
            defaults.set([backdated], forKey: Key.attemptTimestamps)
        }
        if defaults.integer(forKey: Key.successfulOrganizations) == 0 {
            defaults.set(1, forKey: Key.successfulOrganizations)
        }
    }
}

/// The plain in-app invitation shown on the final report: a link, not a dialog.
///
/// It exists because `requestReview()` can refuse for reasons Foldiq cannot see.
/// Opening the App Store review composer directly is never throttled, so this is
/// the only path that reliably reaches someone who wants to leave a review.
enum ManualRatingInvitePolicy {

    /// A dismissal means "not now", not "never".
    static let daysHiddenAfterDismissal = 60

    private enum Key {
        static let dismissedAt = "foldiq.rating.inviteDismissedAt"
        static let didOpenReview = "foldiq.rating.didOpenReviewComposer"
    }

    private static let oneDay: TimeInterval = 24 * 60 * 60

    static func shouldShowInvite(defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        guard !defaults.bool(forKey: Key.didOpenReview) else { return false }
        guard AppReviewPromptPolicy.successfulOrganizationCount(defaults: defaults) >= 1 else { return false }
        // Never stack on top of Apple's own dialog.
        guard !AppReviewPromptPolicy.didAttemptRecently(defaults: defaults, now: now) else { return false }

        let dismissedAt = defaults.double(forKey: Key.dismissedAt)
        guard dismissedAt > 0 else { return true }
        return now.timeIntervalSince1970 - dismissedAt >= Double(daysHiddenAfterDismissal) * oneDay
    }

    static func recordDismissal(defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Key.dismissedAt)
    }

    /// Once someone has been taken to the review composer, stop asking. Whether
    /// they actually posted is not something the app can or should try to learn.
    static func recordReviewComposerOpened(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: Key.didOpenReview)
    }
}

#if os(macOS)
import AppKit
import QuickLookUI

typealias PlatformImage = NSImage
typealias PlatformQuickLookRepresentable = NSViewRepresentable

enum PlatformColors {
    static let windowBackground = Color(.windowBackgroundColor)
    static let separator = Color(.separatorColor)
}

enum PlatformActions {
    static func revealInFileManager(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

enum PlatformImageFactory {
    static func make(cgImage: CGImage) -> PlatformImage {
        NSImage(cgImage: cgImage, size: .zero)
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

/// Builds the Quick Look view used by the preview sheets.
///
/// `QLPreviewView(frame:style:)` is failable. It used to be force-unwrapped with
/// `preconditionFailure`, which turned a missing preview into a crash of the whole
/// app. Now the user just sees a short message instead of the preview.
enum QuickLookPreviewFactory {
    static func makeView(for url: URL) -> NSView {
        guard let previewView = QLPreviewView(frame: .zero, style: .normal) else {
            return makeUnavailableView()
        }
        previewView.autostarts = true
        previewView.previewItem = url as NSURL
        return previewView
    }

    static func update(_ view: NSView, for url: URL) {
        (view as? QLPreviewView)?.previewItem = url as NSURL
    }

    private static func makeUnavailableView() -> NSView {
        let container = NSView(frame: .zero)
        let label = NSTextField(labelWithString: "Preview isn't available for this file.")
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        return container
    }
}
#else
import UIKit
import QuickLook

typealias PlatformImage = UIImage
typealias PlatformQuickLookRepresentable = UIViewControllerRepresentable

enum PlatformColors {
    static let windowBackground = Color(uiColor: .systemBackground)
    static let separator = Color(uiColor: .separator)
}

enum PlatformActions {
    static func revealInFileManager(_ url: URL) {
        openURL(url)
    }

    static func openURL(_ url: URL) {
        UIApplication.shared.open(url)
    }

    static func copyToClipboard(_ string: String) {
        UIPasteboard.general.string = string
    }
}

enum PlatformImageFactory {
    static func make(cgImage: CGImage) -> PlatformImage {
        UIImage(cgImage: cgImage)
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}
#endif


/// The soft ask: a plain link to the App Store review composer, plus a "no" the
/// app actually remembers. Deliberately not a dialog — `requestReview()` already
/// covers that case, and this needs to work on the runs where StoreKit refuses.
struct RatingInviteCard: View {
    var onResolved: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Did Foldiq get this right?", systemImage: "star.bubble")
                .font(.headline)

            Text("Foldiq is built by one person. A short App Store review is the main way other people find it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    ManualRatingInvitePolicy.recordReviewComposerOpened()
                    PlatformActions.openURL(AppStoreLinks.writeReview)
                    onResolved()
                } label: {
                    Label("Write a Review", systemImage: "star")
                }
                .buttonStyle(.borderedProminent)

                Button("Not now") {
                    ManualRatingInvitePolicy.recordDismissal()
                    onResolved()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: ─── Temporary workspaces ───────────────────────────────────────────────

/// Scratch folders Foldiq creates in its temporary directory: copies of the
/// Photos library staged for organizing, and media extracted from archives.
/// They can be as large as the whole library, so none may outlive its use.
///
/// Each folder holds a lock file that the process which created it keeps
/// locked for as long as it needs the folder. The lock is released when that
/// process quits or crashes, so a later launch can tell a folder left behind
/// from one still in use by another running copy of Foldiq (App Store, web and
/// Xcode copies all share the same sandbox container).
enum TempWorkspace {
    static let photosPrefix = "Foldiq-Photos-"
    static let archivePrefix = "foldiq_"
    static let lockFileName = ".foldiq-workspace-lock"

    /// Folders made by versions without a lock file are only removed once they
    /// have not changed for this long, so an older copy that is still running
    /// keeps its folder.
    static let unlockedGracePeriod: TimeInterval = 24 * 60 * 60

    private static let prefixes = [photosPrefix, archivePrefix]
    private static let registry = Registry()

    /// Creates an empty, locked workspace folder named `<prefix><UUID>`.
    static func create(prefix: String, in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = parent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let lockPath = url.appendingPathComponent(lockFileName).path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if fd >= 0 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                registry.add(key(for: url), fd: fd)
            } else {
                // An unlocked lock file would let another launch delete a folder
                // in use; without one the grace period protects it instead.
                close(fd)
                unlink(lockPath)
            }
        }
        return url
    }

    /// Deletes a workspace and releases its lock. Safe to call more than once
    /// and for folders this process doesn't own.
    static func remove(_ url: URL) {
        let path = key(for: url)   // before deleting, while every component still resolves
        try? FileManager.default.removeItem(at: url)
        if let fd = registry.take(path) {
            close(fd)
        }
    }

    /// Workspaces this process created and hasn't removed yet.
    static func ownedWorkspaces() -> [URL] {
        registry.paths().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Deletes every workspace this process created. Called when the app quits.
    static func removeAllOwned() {
        for url in ownedWorkspaces() {
            remove(url)
        }
    }

    /// Deletes workspaces left behind by a copy of Foldiq that is no longer
    /// running. Called once at launch. Returns the folders it removed.
    @discardableResult
    static func sweepAbandoned(
        in parent: URL = FileManager.default.temporaryDirectory,
        now: Date = Date()
    ) -> [URL] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: keys
        ) else { return [] }

        var removed: [URL] = []
        for url in entries {
            let name = url.lastPathComponent
            guard prefixes.contains(where: { prefix in
                name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            }) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink == false else { continue }
            guard !registry.contains(key(for: url)) else { continue }

            let lockPath = url.appendingPathComponent(lockFileName).path
            if fileManager.fileExists(atPath: lockPath) {
                let fd = open(lockPath, O_RDWR | O_CLOEXEC)
                guard fd >= 0 else { continue }
                defer { close(fd) }
                // Still locked: another running copy of Foldiq is using it.
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
                try? fileManager.removeItem(at: url)
            } else {
                guard let modified = values?.contentModificationDate,
                      now.timeIntervalSince(modified) >= unlockedGracePeriod else { continue }
                try? fileManager.removeItem(at: url)
            }
            if !fileManager.fileExists(atPath: url.path) {
                removed.append(url)
            }
        }
        return removed
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Lock file descriptors of the workspaces this process owns, by path.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptors: [String: Int32] = [:]

        func add(_ path: String, fd: Int32) {
            lock.lock(); defer { lock.unlock() }
            descriptors[path] = fd
        }

        func take(_ path: String) -> Int32? {
            lock.lock(); defer { lock.unlock() }
            return descriptors.removeValue(forKey: path)
        }

        func contains(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return descriptors[path] != nil
        }

        func paths() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(descriptors.keys)
        }
    }
}
