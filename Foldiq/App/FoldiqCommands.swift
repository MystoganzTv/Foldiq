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
    }
}
#endif

extension Notification.Name {
    static let openRootFolder = Notification.Name("foldiq.openRootFolder")
}
