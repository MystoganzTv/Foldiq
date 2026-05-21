# Foldiq — macOS Photo & Video Folder Organizer

> **The goal is simple:** take a messy folder with thousands of photos and videos and turn it into a clean, date-based (or location-based) folder structure — safely, locally, with full undo.

---

## Open in Xcode

1. Open `Foldiq.xcodeproj` in **Xcode 15+**
2. Set your Apple Developer Team in **Signing & Capabilities**
3. Run destination: **My Mac**
4. **⌘R**

**Requirements:** macOS 14 Sonoma · Xcode 15 · Swift 5.9

---

## What Foldiq does

```
Before:                          After (Smart Hybrid mode):
──────────────────────────────   ────────────────────────────────────────
Downloads/Photos/                Downloads/Photos/Organized Media/
  IMG_4821.jpg                     2025/
  IMG_4822.HEIC                      2025-08 August/
  WhatsApp Image 2024...               2025-08-14 Herndon VA/
  DSC_0001.NEF                           IMG_4821.jpg
  VID_20230615.mp4                       IMG_4822.HEIC
  Screenshot 2025-01-09.png            2025-08-20/
  IMG_4821 copy.jpg   ← dup              DSC_0001.NEF
  ...                              Screenshots/
                                     Screenshot 2025-01-09.png
                                   Duplicates/
                                     Exact Duplicates/
                                       IMG_4821 copy.jpg
                                   Videos/
                                     VID_20230615.mp4
```

---

## The 6-Step Wizard

| Step | Screen | What happens |
|---|---|---|
| 1 | **Welcome** | User selects a root folder |
| 2 | **Scan** | Files discovered, metadata extracted, duplicates found |
| 3 | **Settings** | User picks organization mode and move/copy |
| 4 | **Preview** | Full table of every planned file movement (CSV export available) |
| 5 | **Apply** | Files moved/copied with live progress bar |
| 6 | **Report** | Summary of results, undo button, open in Finder |

---

## Architecture

```
Foldiq/
├── App/
│   ├── FoldiqApp.swift           SwiftData container + scene setup
│   ├── AppNavigator.swift       @EnvironmentObject wizard state machine
│   └── FoldiqCommands.swift      Menu bar commands
│
├── Models/
│   ├── Models.swift             All SwiftData @Model types
│   │                              MediaFile, ScanSession, OrganizationPlan
│   │                              UndoManifest, UndoEntry, OrganizationConfig
│   └── MediaTypes.swift         Supported extensions registry
│
├── Services/
│   ├── FolderScanner.swift      Recursive directory traversal (actor)
│   ├── MetadataExtractor.swift  EXIF via ImageIO, video via AVFoundation
│   ├── ReverseGeocoder.swift    GPS → city/state/country (CLGeocoder, cached)
│   ├── DuplicateDetector.swift  SHA-256 content hashing (actor)
│   ├── OrganizationPlanner.swift Destination path calculation (actor)
│   ├── FileMover.swift          Safe move/copy + undo manifest (actor)
│   ├── ReportExporter.swift     CSV export via NSSavePanel
│   └── ScanCoordinator.swift    Orchestrates scanner → extractor → detector
│
└── Views/
    ├── RootView.swift           Outer shell + step progress indicator
    ├── SettingsView.swift       Preferences window (Cmd+,)
    ├── Welcome/WelcomeView.swift
    ├── Scan/ScanView.swift
    ├── Settings/SettingsStepView.swift
    ├── Preview/PreviewView.swift
    ├── Apply/ApplyView.swift
    └── Report/ReportView.swift
```

---

## Organization Modes

| Mode | Example output |
|---|---|
| **Smart Hybrid** *(default)* | `2026/2026-05 May/2026-05-18 Herndon VA/` |
| By Year | `2026/` |
| By Year & Month | `2026/2026-05 May/` |
| By Exact Date | `2026/2026-05 May/2026-05-18/` |
| By Location | `2026/United States/Virginia/Herndon/` |

---

## Safety Features

- **Preview before apply** — a full table of every planned move is shown before any file is touched
- **Confirmation dialog** — explicit "Yes, Move Files" required
- **Never overwrites** — collision resolution appends `_1`, `_2`, etc.
- **Undo manifest** — every operation is recorded with source path, destination path, and SHA-256 hash. One-click undo moves everything back.
- **Copy mode** — optionally copy instead of move; originals are never touched
- **Date preservation** — original file creation/modification timestamps are restored after copying
- **CSV export** — full log of every operation exportable at preview or report stage

---

## Supported File Types

**Photos:** JPG, JPEG, PNG, HEIC/HEIF, TIFF, GIF, WebP, BMP, RAW (CR2, CR3, NEF, ARW, DNG, ORF, RW2…)

**Videos:** MOV, MP4, M4V, AVI, MKV, WMV, 3GP, MTS, M2TS

---

## Frameworks Used

| Framework | Purpose |
|---|---|
| SwiftUI | All UI |
| SwiftData | Persistent scan results, plans, undo logs |
| ImageIO / CoreGraphics | EXIF metadata extraction from photos |
| AVFoundation | Video metadata (duration, creation date, GPS) |
| CryptoKit | SHA-256 file hashing for duplicate detection |
| CoreLocation | Reverse geocoding GPS coordinates |
| FileManager | All file system operations |
| UniformTypeIdentifiers | File type detection |

---

## Entitlements

| Entitlement | Why |
|---|---|
| `app-sandbox` | Mac App Store eligibility |
| `files.user-selected.read-write` | Access to user-chosen root folder |
| `network.client` | CoreLocation reverse geocoding |
| `files.downloads.read-write` | CSV report export |
