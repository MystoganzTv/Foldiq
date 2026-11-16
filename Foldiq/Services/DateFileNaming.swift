// DateFileNaming.swift
// "Rename files by capture date": IMG_4821.jpg → 2024-08-14 15.32.10.jpg.
// Mirrors plannedFileNames() in desktop/electron/services/planner.js.

import Foundation

enum DateFileNaming {

    /// "2024-08-14 15.32.10" in the given calendar's time zone. No colons, so the
    /// name is valid on every file system Foldiq writes to.
    static func stem(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d %02d.%02d.%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    /// Files in the same source folder with the same name (IMG_1234.HEIC +
    /// IMG_1234.MOV for a Live Photo, or a RAW + JPEG pair) share a group.
    static func groupKey(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent().path
        return (folder + "/" + url.deletingPathExtension().lastPathComponent).lowercased()
    }

    /// Photos stores its originals under random IDs ("7F3A…C2.heic"), so files
    /// that come from a Photos library always get a date-based name.
    static func isEligible(_ file: MediaFile, config: OrganizationConfig) -> Bool {
        guard config.renameByDate || PhotosLibrarySupport.isInsidePhotosLibrary(file.filePath),
              file.mediaKind != .archive,
              !file.isUserSetAside,
              !file.isUserExcluded,
              !file.isScreenshot,
              file.damageReason == nil,
              file.bestDate != nil
        else { return false }
        if config.separateDuplicates && (file.isDuplicate || file.isProbableDuplicate) { return false }
        return true
    }

    /// New filenames keyed by MediaFile.id. Files that are not renamed are absent.
    /// Every member of a pair takes the photo's date so the pair stays together.
    static func plannedNames(
        for files: [MediaFile],
        config: OrganizationConfig,
        calendar: Calendar = .current
    ) -> [UUID: String] {
        let eligible = files.filter { isEligible($0, config: config) }

        var leadDates: [String: Date] = [:]
        let photosFirst = eligible.filter { $0.mediaKind == .photo } + eligible.filter { $0.mediaKind != .photo }
        for file in photosFirst {
            let key = groupKey(forPath: file.filePath)
            if leadDates[key] == nil, let date = file.bestDate {
                leadDates[key] = date
            }
        }

        var names: [UUID: String] = [:]
        for file in eligible {
            guard let date = leadDates[groupKey(forPath: file.filePath)] else { continue }
            let ext = (file.filename as NSString).pathExtension
            names[file.id] = ext.isEmpty ? stem(for: date, calendar: calendar)
                                         : stem(for: date, calendar: calendar) + "." + ext
        }
        return names
    }
}
