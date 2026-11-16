// FoldiqCommands.swift
import SwiftUI

#if os(macOS)
struct FoldiqCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") {
                NotificationCenter.default.post(name: .openRootFolder, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        // Until now there was no way at all to leave a review on purpose — the
        // only ask was one automatic dialog that most people never saw.
        // Only App Store copies can be reviewed there.
        CommandGroup(after: .help) {
            if AppDistribution.isAppStore {
                Button("Rate Foldiq on the App Store") {
                    ManualRatingInvitePolicy.recordReviewComposerOpened()
                    PlatformActions.openURL(AppStoreLinks.writeReview)
                }
            }
        }
    }
}
#endif

extension Notification.Name {
    static let openRootFolder = Notification.Name("foldiq.openRootFolder")
}
