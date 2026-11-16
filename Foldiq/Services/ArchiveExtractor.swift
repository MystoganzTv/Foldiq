// ArchiveExtractor.swift
// Extracts media files from ZIP, RAR/RAR5, and 7z archives to a temporary directory.
// ZIP uses system libz; RAR/7z use the sandbox-safe embedded libarchive package.
// The original archive is NEVER modified or moved — it stays exactly where it is.

import Foundation
#if os(macOS)
import CArchive
import SevenZip
#endif

// MARK: ─── ZIP format constants ───────────────────────────────────────────────

private let kLocalFileSig:   UInt32 = 0x04034b50
private let kCentralDirSig:  UInt32 = 0x02014b50
private let kEndOfCentralSig: UInt32 = 0x06054b50
private let kMaxArchiveEntries = 100_000
private let kMaxArchiveMediaBytes: UInt64 = 500 * 1024 * 1024 * 1024
private let kDiskReserveBytes: Int64 = 1024 * 1024 * 1024

// MARK: ─── Data helpers ───────────────────────────────────────────────────────

private extension Data {
    /// Read a little-endian UInt16 at byte offset `off`.
    func u16LE(at off: Int) -> UInt16 {
        guard off + 2 <= count else { return 0 }
        return withUnsafeBytes { ptr in
            var v: UInt16 = 0
            memcpy(&v, ptr.baseAddress!.advanced(by: off), 2)
            return CFSwapInt16LittleToHost(v)
        }
    }

    /// Read a little-endian UInt32 at byte offset `off`.
    func u32LE(at off: Int) -> UInt32 {
        guard off + 4 <= count else { return 0 }
        return withUnsafeBytes { ptr in
            var v: UInt32 = 0
            memcpy(&v, ptr.baseAddress!.advanced(by: off), 4)
            return CFSwapInt32LittleToHost(v)
        }
    }
}

// MARK: ─── ZipEntry ───────────────────────────────────────────────────────────

private struct ZipEntry {
    let filename: String
    let isDirectory: Bool
    let compressionMethod: UInt16   // 0 = STORE, 8 = DEFLATE
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localHeaderOffset: UInt32
}

// MARK: ─── ZipError ───────────────────────────────────────────────────────────

enum ZipError: LocalizedError {
    case invalidFormat(String)
    case unsupportedCompression(UInt16)
    case decompressionFailed
    case encrypted   // bit 0 of general purpose bit flag is set

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let r):          return "Invalid archive: \(r)"
        case .unsupportedCompression(let m): return "Unsupported ZIP compression method \(m)"
        case .decompressionFailed:           return "DEFLATE decompression failed"
        case .encrypted:                     return "This archive is password-protected and cannot be extracted automatically. Open it manually and place the files in a regular folder."
        }
    }
}

// MARK: ─── ArchiveExtractor ───────────────────────────────────────────────────

actor ArchiveExtractor {

    // MARK: - Types

    struct ExtractionResult {
        /// Temporary directory holding the extracted files.
        /// The caller MUST delete this directory after the files have been
        /// moved/copied to their final destinations.
        let tempDirectory: URL
        /// Photos and videos found directly inside the archive.
        let mediaURLs: [URL]
    }

    enum ArchiveError: LocalizedError {
        case unsupportedFormat(String)
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return ".\(ext) archives are not supported. Foldiq accepts ZIP, RAR, and 7z on desktop."
            case .extractionFailed(let reason):
                return "Extraction failed: \(reason)"
            }
        }
    }

    // MARK: - Public

    /// Returns true if this file extension can be extracted in the macOS sandbox.
    static func isExtractable(_ ext: String) -> Bool {
        MediaTypes.archiveExtensions.contains(ext.lowercased())
    }

    /// Extract the archive at `url` to a new temporary directory.
    /// Returns an `ExtractionResult` on success, or throws on failure.
    /// The caller is responsible for deleting `result.tempDirectory` after use.
    func extract(_ url: URL) throws -> ExtractionResult {
        let ext = url.pathExtension.lowercased()
        guard Self.isExtractable(ext) else {
            throw ArchiveError.unsupportedFormat(ext)
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("foldiq_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        do {
            if ext == "zip" {
                try extractZIP(url, to: tempDir)
            } else if ext == "7z" {
                #if os(macOS)
                try extractSevenZip(url, to: tempDir)
                #else
                throw ArchiveError.unsupportedFormat(ext)
                #endif
            } else {
                #if os(macOS)
                try extractRAR(url, to: tempDir)
                #else
                throw ArchiveError.unsupportedFormat(ext)
                #endif
            }
        } catch {
            try? fm.removeItem(at: tempDir)
            if let archiveError = error as? ArchiveError { throw archiveError }
            throw ArchiveError.extractionFailed(error.localizedDescription)
        }

        let mediaURLs = collectMedia(in: tempDir)
        return ExtractionResult(tempDirectory: tempDir, mediaURLs: mediaURLs)
    }

    private func extractZIP(_ url: URL, to tempDir: URL) throws {
        let zipData = try Data(contentsOf: url, options: .mappedIfSafe)
        let entries = try parseCentralDirectory(zipData)

        // Validate every entry before writing anything. This prevents a
        // crafted filename such as ../photo.jpg from escaping the temp dir.
        for entry in entries {
            _ = try safeDestinationURL(for: entry.filename, inside: tempDir)
        }

        // Google Takeout sidecars (.json) are extracted too so their capture dates
        // can be read; collectMedia(in:) still returns photos and videos only.
        let supported = MediaTypes.photoExtensions.union(MediaTypes.videoExtensions).union(["json"])
        let mediaEntries = entries.filter { entry in
            guard !entry.isDirectory else { return false }
            let normalized = entry.filename.replacingOccurrences(of: "\\", with: "/")
            let ext = URL(fileURLWithPath: normalized).pathExtension.lowercased()
            return supported.contains(ext)
        }

        var zipDestinations: Set<String> = []
        for entry in mediaEntries {
            let destination = try safeDestinationURL(for: entry.filename, inside: tempDir)
            guard zipDestinations.insert(destination.path).inserted else {
                throw ZipError.invalidFormat("duplicate archive path: \(entry.filename)")
            }
        }

        var declaredBytes: UInt64 = 0
        for entry in mediaEntries {
            let (next, overflow) = declaredBytes.addingReportingOverflow(UInt64(entry.uncompressedSize))
            guard !overflow, next <= kMaxArchiveMediaBytes else {
                throw ZipError.invalidFormat("media expands beyond the safe extraction limit")
            }
            declaredBytes = next
        }

        if let freeBytes = try? tempDir.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           declaredBytes > UInt64(max(0, freeBytes - kDiskReserveBytes)) {
            throw ZipError.invalidFormat("not enough free disk space to extract safely")
        }

        // Only media is extracted. Unrelated files stay inside the untouched ZIP.
        for entry in mediaEntries {
            let destURL = try safeDestinationURL(for: entry.filename, inside: tempDir)
            let destDir = destURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            let raw = try compressedData(for: entry, in: zipData)
            let fileData: Data

            switch entry.compressionMethod {
            case 0:   // STORE — no compression
                fileData = raw
            case 8:   // DEFLATE
                fileData = try deflateDecompress(raw, uncompressedSize: Int(entry.uncompressedSize))
            default:
                throw ZipError.unsupportedCompression(entry.compressionMethod)
            }

            try fileData.write(to: destURL, options: .atomic)
        }
    }

    #if os(macOS)
    /// Extracts standard LZMA/LZMA2 7z entries using the embedded 7-Zip SDK.
    /// The SDK expands one solid block in memory, so an entry is bounded relative
    /// to the device's physical memory before extraction starts.
    private func extractSevenZip(_ url: URL, to tempDir: URL) throws {
        let sevenZip: SevenZip.Archive
        do {
            sevenZip = try SevenZip.Archive(fileURL: url)
        } catch {
            throw ArchiveError.extractionFailed("Could not read this 7z archive. It may be corrupt or password-protected.")
        }

        guard sevenZip.entries.count <= kMaxArchiveEntries else {
            throw ZipError.invalidFormat("too many archive entries")
        }

        // Google Takeout sidecars (.json) are extracted too so their capture dates
        // can be read; collectMedia(in:) still returns photos and videos only.
        let supported = MediaTypes.photoExtensions.union(MediaTypes.videoExtensions).union(["json"])
        let maximumEntryBytes = min(
            UInt64(8 * 1024 * 1024 * 1024),
            max(UInt64(256 * 1024 * 1024), ProcessInfo.processInfo.physicalMemory / 3)
        )
        var declaredBytes: UInt64 = 0
        var selected: [(entry: SevenZip.Entry, destination: URL)] = []
        var destinations: Set<String> = []

        for entry in sevenZip.entries {
            let destination = try safeDestinationURL(for: entry.path, inside: tempDir)
            guard !entry.directory, supported.contains(destination.pathExtension.lowercased()) else { continue }
            guard destinations.insert(destination.path).inserted else {
                throw ZipError.invalidFormat("duplicate archive path: \(entry.path)")
            }
            guard entry.uncompressedSize <= maximumEntryBytes else {
                throw ZipError.invalidFormat("a 7z entry is too large to extract safely in memory")
            }
            let (next, overflow) = declaredBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, next <= kMaxArchiveMediaBytes else {
                throw ZipError.invalidFormat("media expands beyond the safe extraction limit")
            }
            declaredBytes = next
            selected.append((entry, destination))
        }

        if let freeBytes = try? tempDir.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           declaredBytes > UInt64(max(0, freeBytes - kDiskReserveBytes)) {
            throw ZipError.invalidFormat("not enough free disk space to extract safely")
        }

        for item in selected {
            do {
                let data = try sevenZip.extract(entry: item.entry)
                guard UInt64(data.count) == item.entry.uncompressedSize else {
                    throw ZipError.invalidFormat("7z entry size did not match its contents")
                }
                try FileManager.default.createDirectory(
                    at: item.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard !FileManager.default.fileExists(atPath: item.destination.path) else {
                    throw ZipError.invalidFormat("duplicate archive path: \(item.entry.path)")
                }
                try data.write(to: item.destination, options: .atomic)
            } catch let error as ZipError {
                throw error
            } catch {
                throw ArchiveError.extractionFailed("Could not extract this 7z archive. Password-protected 7z files are not supported.")
            }
        }
    }

    /// Streams RAR/RAR5 entries through libarchive. Only supported media
    /// is written, and every archive path is checked before touching disk.
    private func extractRAR(_ url: URL, to tempDir: URL) throws {
        guard let archive = archive_read_new() else {
            throw ArchiveError.extractionFailed("Could not initialize the archive reader")
        }
        defer { archive_read_free(archive) }

        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)
        guard archive_read_open_filename(archive, url.path, 10_240) == ARCHIVE_OK else {
            throw ArchiveError.extractionFailed(libArchiveMessage(archive))
        }

        // Google Takeout sidecars (.json) are extracted too so their capture dates
        // can be read; collectMedia(in:) still returns photos and videos only.
        let supported = MediaTypes.photoExtensions.union(MediaTypes.videoExtensions).union(["json"])
        let fm = FileManager.default
        var entryPointer: OpaquePointer?
        var entryCount = 0
        var extractedBytes: UInt64 = 0
        var writtenDestinations: Set<String> = []

        while true {
            let status = archive_read_next_header(archive, &entryPointer)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry = entryPointer else {
                throw ArchiveError.extractionFailed(libArchiveMessage(archive))
            }

            entryCount += 1
            guard entryCount <= kMaxArchiveEntries else {
                throw ZipError.invalidFormat("too many archive entries")
            }
            guard let rawPath = archive_entry_pathname(entry) else {
                throw ZipError.invalidFormat("archive entry has no filename")
            }
            let filename = String(cString: rawPath)
            let destination = try safeDestinationURL(for: filename, inside: tempDir)

            if archive_entry_is_encrypted(entry) > 0 {
                throw ZipError.encrypted
            }
            if archive_entry_symlink(entry) != nil || archive_entry_hardlink(entry) != nil {
                throw ZipError.invalidFormat("symbolic and hard links are not supported")
            }

            let ext = destination.pathExtension.lowercased()
            // POSIX S_IFREG (0o100000). The macro is not imported into Swift.
            guard archive_entry_filetype(entry) == 0o100000, supported.contains(ext) else {
                archive_read_data_skip(archive)
                continue
            }
            guard writtenDestinations.insert(destination.path).inserted else {
                throw ZipError.invalidFormat("duplicate archive path: \(filename)")
            }

            let declaredSize = archive_entry_size(entry)
            guard declaredSize >= 0 else {
                throw ZipError.invalidFormat("invalid file size: \(filename)")
            }
            let (nextTotal, overflow) = extractedBytes.addingReportingOverflow(UInt64(declaredSize))
            guard !overflow, nextTotal <= kMaxArchiveMediaBytes else {
                throw ZipError.invalidFormat("media expands beyond the safe extraction limit")
            }
            if let freeBytes = try? tempDir.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage,
               nextTotal > UInt64(max(0, freeBytes - kDiskReserveBytes)) {
                throw ZipError.invalidFormat("not enough free disk space to extract safely")
            }

            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: destination.path),
                  fm.createFile(atPath: destination.path, contents: nil) else {
                throw ZipError.invalidFormat("duplicate archive path: \(filename)")
            }

            do {
                let handle = try FileHandle(forWritingTo: destination)
                defer { try? handle.close() }
                var buffer: UnsafeRawPointer?
                var blockSize = 0
                var offset: Int64 = 0
                var written: UInt64 = 0

                while true {
                    let readStatus = archive_read_data_block(archive, &buffer, &blockSize, &offset)
                    if readStatus == ARCHIVE_EOF { break }
                    guard readStatus == ARCHIVE_OK, let buffer, blockSize >= 0, offset >= 0 else {
                        throw ArchiveError.extractionFailed(libArchiveMessage(archive))
                    }
                    let blockEnd = UInt64(offset) + UInt64(blockSize)
                    guard blockEnd <= UInt64(declaredSize), nextTotal <= kMaxArchiveMediaBytes else {
                        throw ZipError.invalidFormat("archive entry expanded beyond its declared size")
                    }
                    try handle.seek(toOffset: UInt64(offset))
                    try handle.write(contentsOf: Data(bytes: buffer, count: blockSize))
                    written = max(written, blockEnd)
                }
                guard written == UInt64(declaredSize) else {
                    throw ZipError.invalidFormat("archive entry size did not match its contents")
                }
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
            extractedBytes = nextTotal
        }

        if archive_read_has_encrypted_entries(archive) > 0 { throw ZipError.encrypted }
    }

    private func libArchiveMessage(_ archive: OpaquePointer) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? "Unknown archive error"
    }
    #endif

    // MARK: - ZIP Parsing

    private func safeDestinationURL(for filename: String, inside root: URL) throws -> URL {
        guard !filename.isEmpty, !filename.contains("\0") else {
            throw ZipError.invalidFormat("empty or invalid filename")
        }

        let normalized = filename.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"),
              normalized.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil else {
            throw ZipError.invalidFormat("unsafe absolute path: \(filename)")
        }

        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !components.contains(where: { $0 == ".." }) else {
            throw ZipError.invalidFormat("unsafe path: \(filename)")
        }

        let destination = components.reduce(root) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard destination.path.hasPrefix(rootPath + "/") else {
            throw ZipError.invalidFormat("unsafe path: \(filename)")
        }
        return destination
    }

    /// Find the End of Central Directory record and parse all central directory entries.
    private func parseCentralDirectory(_ data: Data) throws -> [ZipEntry] {
        guard data.count >= 22 else {
            throw ZipError.invalidFormat("file too small")
        }

        // Search backwards for EOCD signature (0x06054b50)
        // EOCD is at least 22 bytes; the comment can add up to 65535 bytes after it.
        let maxSearch = min(data.count, 22 + 65535)
        var eocdOffset: Int? = nil

        for i in stride(from: data.count - 22, through: data.count - maxSearch, by: -1) {
            if data.u32LE(at: i) == kEndOfCentralSig {
                eocdOffset = i
                break
            }
        }

        guard let eocd = eocdOffset else {
            throw ZipError.invalidFormat("EOCD signature not found")
        }

        let cdCount  = Int(data.u16LE(at: eocd + 10))   // total entries in central dir
        let cdOffset = Int(data.u32LE(at: eocd + 16))   // offset of central dir
        guard cdCount <= kMaxArchiveEntries else {
            throw ZipError.invalidFormat("too many archive entries")
        }

        var entries: [ZipEntry] = []
        var pos = cdOffset

        for _ in 0 ..< cdCount {
            guard pos + 46 <= data.count else {
                throw ZipError.invalidFormat("truncated central directory")
            }
            guard data.u32LE(at: pos) == kCentralDirSig else {
                throw ZipError.invalidFormat("central directory signature missing")
            }

            // Bit 0 of the general purpose bit flag (pos + 8) = encryption.
            // Throw immediately — a password-protected file cannot be extracted.
            let generalPurposeBitFlag = data.u16LE(at: pos + 8)
            if generalPurposeBitFlag & 0x0001 != 0 {
                throw ZipError.encrypted
            }

            let compressionMethod = data.u16LE(at: pos + 10)
            let compressedSize    = data.u32LE(at: pos + 20)
            let uncompressedSize  = data.u32LE(at: pos + 24)
            let fileNameLen       = Int(data.u16LE(at: pos + 28))
            let extraLen          = Int(data.u16LE(at: pos + 30))
            let commentLen        = Int(data.u16LE(at: pos + 32))
            let localHeaderOffset = data.u32LE(at: pos + 42)

            guard pos + 46 + fileNameLen + extraLen + commentLen <= data.count else {
                throw ZipError.invalidFormat("central directory entry out of bounds")
            }
            let nameRange = (pos + 46) ..< (pos + 46 + fileNameLen)
            let filename = String(data: data[nameRange], encoding: .utf8)
                        ?? String(data: data[nameRange], encoding: .isoLatin1)
                        ?? ""

            let isDirectory = filename.hasSuffix("/") || uncompressedSize == 0 && compressionMethod == 0 && filename.contains("/")

            entries.append(ZipEntry(
                filename: filename,
                isDirectory: isDirectory,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))

            pos += 46 + fileNameLen + extraLen + commentLen
        }

        return entries
    }

    /// Read the compressed data for `entry` from the ZIP file bytes.
    private func compressedData(for entry: ZipEntry, in data: Data) throws -> Data {
        let lhOffset = Int(entry.localHeaderOffset)
        guard lhOffset + 30 <= data.count else {
            throw ZipError.invalidFormat("local header out of bounds")
        }
        guard data.u32LE(at: lhOffset) == kLocalFileSig else {
            throw ZipError.invalidFormat("local file header signature missing")
        }

        let fileNameLen = Int(data.u16LE(at: lhOffset + 26))
        let extraLen    = Int(data.u16LE(at: lhOffset + 28))
        let dataStart   = lhOffset + 30 + fileNameLen + extraLen
        let dataEnd     = dataStart + Int(entry.compressedSize)

        guard dataEnd <= data.count else {
            throw ZipError.invalidFormat("compressed data out of bounds")
        }

        return data[dataStart ..< dataEnd]
    }

    /// Decompress raw DEFLATE data using system libz via the C bridge.
    private func deflateDecompress(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }

        return try compressed.withUnsafeBytes { rawPtr -> Data in
            guard let ptr = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw ZipError.decompressionFailed
            }

            var outPtr: UnsafeMutablePointer<UInt8>? = nil
            let written = foldiq_inflate(ptr, compressed.count, uncompressedSize, &outPtr)

            guard written > 0, let out = outPtr else {
                throw ZipError.decompressionFailed
            }

            // Take ownership of the malloc'd buffer into a Data object that frees it.
            return Data(bytesNoCopy: out, count: written, deallocator: .free)
        }
    }

    // MARK: - Media Collection

    /// Walk `dir` recursively and return URLs of recognised photo/video files.
    /// Nested archives are skipped — we don't recurse into zip-within-zip.
    private func collectMedia(in dir: URL) -> [URL] {
        let supported = MediaTypes.photoExtensions.union(MediaTypes.videoExtensions)
        var found: [URL] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            let fileExt = fileURL.pathExtension.lowercased()
            // Skip nested archives — we don't recursively extract
            if MediaTypes.archiveExtensions.contains(fileExt) { continue }
            if supported.contains(fileExt) {
                found.append(fileURL)
            }
        }
        return found
    }
}
