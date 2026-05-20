// OrganizationPlanner.swift
// Computes the destination path for every MediaFile according to the chosen
// OrganizationMode, then returns a list of OrganizationPlan records
// that the user can review before anything is touched on disk.

import Foundation

// MARK: ─── Planner ────────────────────────────────────────────────────────────

actor OrganizationPlanner {

    private let geocoder: any LocationGeocoding

    init(geocoder: any LocationGeocoding = ReverseGeocoder()) {
        self.geocoder = geocoder
    }

    // MARK: Public

    struct PlanProgress {
        var planned: Int
        var total: Int
        var currentFile: String
    }

    /// Build the full plan. Calls `onProgress` every 20 files.
    /// Returns a flat list of OrganizationPlan objects ready to insert into SwiftData.
    func buildPlan(
        session: ScanSession,
        config: OrganizationConfig,
        onProgress: @MainActor @escaping (PlanProgress) -> Void
    ) async -> [OrganizationPlan] {

        let files = session.files
        let total = files.count
        var plans: [OrganizationPlan] = []

        let outputRoot = config.outputRoot(forSelectedRoot: session.rootURL)

        // Track reserved destination paths to handle filename collisions.
        var reservedPaths = Set<String>()

        for (idx, file) in files.enumerated() {
            if idx % 20 == 0 {
                let p = PlanProgress(planned: idx, total: total, currentFile: file.filename)
                await onProgress(p)
            }

            // Determine destination folder
            let folder = await destinationFolder(
                for: file,
                config: config,
                outputRoot: outputRoot
            )

            // Resolve collision-safe filename
            var destURL = folder.appendingPathComponent(file.filename)
            destURL = resolveCollision(destURL, reserved: &reservedPaths)
            reservedPaths.insert(destURL.path)

            // NOTE: Do NOT write file.plannedDestinationPath here.
            // OrganizationPlanner is a non-@MainActor actor; writing to a SwiftData
            // @Model from here causes EXC_BAD_ACCESS. The caller applies the update
            // on @MainActor after receiving the plans.

            let plan = OrganizationPlan(
                sessionID: session.id,
                mediaFileID: file.id,
                source: file.filePath,
                destination: destURL.path,
                op: config.fileOperation
            )
            plan.archiveSourcePath = file.archiveSourcePath
            plans.append(plan)
        }

        return plans
    }

    // MARK: ─── Destination Logic ──────────────────────────────────────────────

    private func destinationFolder(
        for file: MediaFile,
        config: OrganizationConfig,
        outputRoot: URL
    ) async -> URL {
        if config.mode == .byLocation {
            return await locationModeFolder(for: file, config: config, outputRoot: outputRoot)
        }

        // Screenshots → Screenshots/
        if file.isScreenshot {
            return outputRoot.appendingPathComponent("Screenshots")
        }

        // Videos → Videos/ (when in a mode that doesn't date-sort videos)
        if file.mediaKind == .video && !config.includeVideos {
            return outputRoot.appendingPathComponent("Videos")
        }

        // Exact duplicates → Duplicates/Exact Duplicates/
        if file.isDuplicate && config.separateDuplicates {
            return outputRoot
                .appendingPathComponent("Duplicates")
                .appendingPathComponent("Exact Duplicates")
        }

        // Probable duplicates → Duplicates/Probable Duplicates/
        // (only the file elected as "duplicate" side has isProbableDuplicate == true)
        if file.isProbableDuplicate && config.separateDuplicates {
            return outputRoot
                .appendingPathComponent("Duplicates")
                .appendingPathComponent("Probable Duplicates")
        }

        // No date → Unknown Date/
        guard file.hasDate else {
            return outputRoot.appendingPathComponent("Unknown Date")
        }

        // Date-based organisation
        switch config.mode {
        case .byYear:
            return outputRoot
                .appendingPathComponent(file.yearString ?? "Unknown")

        case .byYearMonth:
            return outputRoot
                .appendingPathComponent(file.yearString ?? "Unknown")
                .appendingPathComponent(file.monthFolderName ?? "Unknown")

        case .byExactDate:
            return outputRoot
                .appendingPathComponent(file.yearString ?? "Unknown")
                .appendingPathComponent(file.monthFolderName ?? "Unknown")
                .appendingPathComponent(file.dayFolderName ?? "Unknown")

        case .byLocation:
            return outputRoot

        case .smartHybrid:
            return await smartHybridFolder(for: file, config: config, outputRoot: outputRoot)
        }
    }

    private func locationModeFolder(
        for file: MediaFile,
        config: OrganizationConfig,
        outputRoot: URL
    ) async -> URL {
        // Duplicates still stay in dedicated review buckets regardless of mode.
        if file.isDuplicate && config.separateDuplicates {
            return outputRoot
                .appendingPathComponent("Duplicates")
                .appendingPathComponent("Exact Duplicates")
        }

        if file.isProbableDuplicate && config.separateDuplicates {
            return outputRoot
                .appendingPathComponent("Duplicates")
                .appendingPathComponent("Probable Duplicates")
        }

        var base = await locationFolderAllowingUnknownDate(for: file, outputRoot: outputRoot)

        // Keep screenshots grouped, but inside the location bucket instead of at root.
        if file.isScreenshot {
            base.appendPathComponent("Screenshots")
        }

        return base
    }

    private func smartHybridFolder(
        for file: MediaFile,
        config: OrganizationConfig,
        outputRoot: URL
    ) async -> URL {
        var url = outputRoot
        url.appendPathComponent(file.yearString ?? "Unknown")
        url.appendPathComponent(file.monthFolderName ?? "Unknown")

        // Day folder, optionally decorated with city name
        var dayName = file.dayFolderName ?? "Unknown"
        if config.useGPSLocation, file.hasGPS,
           let lat = file.latitude, let lon = file.longitude {
            let geo = await geocoder.geocode(latitude: lat, longitude: lon)
            let parts = [geo.city, geo.state].compactMap { $0 }.prefix(2)
            if !parts.isEmpty {
                dayName += " " + parts.joined(separator: " ")
            }
        }
        url.appendPathComponent(dayName)
        return url
    }

    private func locationFolderAllowingUnknownDate(for file: MediaFile, outputRoot: URL) async -> URL {
        if file.hasGPS, let lat = file.latitude, let lon = file.longitude {
            let geo = await geocoder.geocode(latitude: lat, longitude: lon)
            if !geo.folderComponents.isEmpty {
                var url = outputRoot
                for component in geo.folderComponents {
                    url.appendPathComponent(component)
                }
                return url
            }
        }

        var url = outputRoot.appendingPathComponent("Unknown Location")
        url.appendPathComponent(file.yearString ?? "Unknown Year")
        return url
    }

    // MARK: ─── Collision Resolution ───────────────────────────────────────────

    /// If `url` is already reserved on disk or in our plan, append _1, _2, … until unique.
    private func resolveCollision(_ url: URL, reserved: inout Set<String>) -> URL {
        guard reserved.contains(url.path) || FileManager.default.fileExists(atPath: url.path) else {
            return url
        }
        let dir  = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext  = url.pathExtension
        var counter = 1
        var candidate = url
        repeat {
            let newName = ext.isEmpty ? "\(name)_\(counter)" : "\(name)_\(counter).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            counter += 1
        } while reserved.contains(candidate.path) || FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}
