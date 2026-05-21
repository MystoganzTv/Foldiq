// ArchiveExtractor.swift
// Extracts media files from ZIP archives to a temporary directory.
// Uses system libz (always available on macOS, sandbox-safe) via ZipInflate.c.
// Supports ZIP compression methods: 0 = STORE, 8 = DEFLATE.
// The original archive is NEVER modified or moved — it stays exactly where it is.

import Foundation

// MARK: ─── ZIP format constants ───────────────────────────────────────────────

private let kLocalFileSig:   UInt32 = 0x04034b50
private let kCentralDirSig:  UInt32 = 0x02014b50
private let kEndOfCentralSig: UInt32 = 0x06054b50

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

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let r):        return "Invalid ZIP: \(r)"
        case .unsupportedCompression(let m): return "Unsupported ZIP compression method \(m)"
        case .decompressionFailed:         return "DEFLATE decompression failed"
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
                return ".\(ext) archives cannot be extracted — format not supported on macOS without external tools."
            case .extractionFailed(let reason):
                return "Extraction failed: \(reason)"
            }
        }
    }

    // MARK: - Public

    /// Returns true if this file extension can be extracted in the macOS sandbox.
    static func isExtractable(_ ext: String) -> Bool {
        ext.lowercased() == "zip"
    }

    /// Extract the archive at `url` to a new temporary directory.
    /// Returns an `ExtractionResult` on success, or throws on failure.
    /// The caller is responsible for deleting `result.tempDirectory` after use.
    func extract(_ url: URL) throws -> ExtractionResult {
        let ext = url.pathExtension.lowercased()
        guard ext == "zip" else {
            throw ArchiveError.unsupportedFormat(ext)
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("foldiq_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        do {
            let zipData = try Data(contentsOf: url, options: .mappedIfSafe)
            let entries = try parseCentralDirectory(zipData)

            for entry in entries where !entry.isDirectory {
                let destURL = tempDir.appendingPathComponent(entry.filename)
                // Create intermediate directories if needed
                let destDir = destURL.deletingLastPathComponent()
                try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

                let raw = try compressedData(for: entry, in: zipData)
                let fileData: Data

                switch entry.compressionMethod {
                case 0:   // STORE — no compression
                    fileData = raw
                case 8:   // DEFLATE
                    fileData = try deflateDecompress(raw, uncompressedSize: Int(entry.uncompressedSize))
                default:
                    // Skip entries with unsupported compression — don't fail the whole archive
                    continue
                }

                try fileData.write(to: destURL, options: .atomic)
            }
        } catch {
            try? fm.removeItem(at: tempDir)
            throw ArchiveError.extractionFailed(error.localizedDescription)
        }

        let mediaURLs = collectMedia(in: tempDir)
        return ExtractionResult(tempDirectory: tempDir, mediaURLs: mediaURLs)
    }

    // MARK: - ZIP Parsing

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

        var entries: [ZipEntry] = []
        var pos = cdOffset

        for _ in 0 ..< cdCount {
            guard pos + 46 <= data.count else { break }
            guard data.u32LE(at: pos) == kCentralDirSig else { break }

            let compressionMethod = data.u16LE(at: pos + 10)
            let compressedSize    = data.u32LE(at: pos + 20)
            let uncompressedSize  = data.u32LE(at: pos + 24)
            let fileNameLen       = Int(data.u16LE(at: pos + 28))
            let extraLen          = Int(data.u16LE(at: pos + 30))
            let commentLen        = Int(data.u16LE(at: pos + 32))
            let localHeaderOffset = data.u32LE(at: pos + 42)

            guard pos + 46 + fileNameLen <= data.count else { break }
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
