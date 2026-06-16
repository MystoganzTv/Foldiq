import SwiftUI

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
