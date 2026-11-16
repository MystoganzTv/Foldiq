// DuplicateSpace.swift
// How much disk space the duplicate copies found in a scan take up.
// Foldiq never deletes anything; this is the space the user gets back once they
// review Duplicates/ and delete it themselves.

import Foundation

enum DuplicateSpace {

    /// Exact copies plus files classified as the same image. Review-only matches
    /// (bursts, edited versions, similar shots) are left out on purpose.
    static func reclaimableBytes(in files: [MediaFile]) -> Int64 {
        files.reduce(Int64(0)) { total, file in
            (file.isDuplicate || file.isProbableDuplicate) ? total + max(file.fileSize, 0) : total
        }
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
