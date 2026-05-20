## Imported Claude Cowork project instructions

Foldiq is a macOS desktop app designed to clean and organize large messy photo and video libraries.

The app scans a user-selected root folder, analyzes media metadata (dates, locations, filenames, duplicates), and automatically reorganizes files into a structured folder system.

Core goals:
- Organize thousands of photos/videos safely
- Create real folders on disk
- Detect duplicates
- Preserve metadata
- Preview all changes before applying
- Never overwrite files
- Support undo/restore through manifest logs

Main workflow:
1. User selects a root folder
2. Foldiq scans all subfolders
3. App analyzes metadata and duplicates
4. User selects organization method
5. App previews all file movements
6. User confirms
7. Foldiq reorganizes the library safely

Recommended folder structure:
Year → Month → Date → Optional Location

Example:
Photos/
  2026/
    2026-05 May/
      2026-05-18 Herndon VA/

Supported media:
- JPG
- JPEG
- PNG
- HEIC
- TIFF
- RAW formats
- MOV
- MP4
- M4V

Key features:
- Smart folder organization
- Duplicate detection
- Safe file moving/copying
- Preview before apply
- Undo manifest system
- CSV/JSON logs
- Local-only processing
- No cloud required

Technical stack:
- SwiftUI
- FileManager
- ImageIO
- AVFoundation
- CryptoKit
- SwiftData only for lightweight app state

The app is NOT focused on gallery viewing.
The priority is safe and intelligent media organization.
