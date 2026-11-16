# Foldiq on the Microsoft Store

## Why the MSIX route

The Store takes the Windows app two ways:

- **MSIX package** — Microsoft signs it for free and pushes updates itself. This is the route Foldiq uses.
- **EXE/MSI installer** — the installer must already be signed with a paid certificate from a trusted CA. Foldiq's NSIS installer is unsigned, so this route is closed.

The app is already MSIX-safe: everything it writes goes to `app.getPath('userData')`, the bundled ExifTool and 7-Zip run from `process.resourcesPath`, and there is no self-updater to switch off.

The Stripe/NSIS build and its GitHub release are untouched. The Store package is a separate build.

## What is in the repo

- `desktop/package.json` → `build.appx` (display name **Foldiq Photo & Video Organizer**, which must match the reserved Store name exactly, application ID, language) and `build.directories.buildResources = store-resources`.
- `desktop/store-resources/appx/` → Start menu, taskbar and Store tile images generated from `assets/icon.png`, at 100/200/400 % scale plus taskbar target sizes.
- `.github/workflows/windows-store.yml` → manual workflow on `windows-latest` (input: the version in `desktop/package.json`). It runs the tests, builds the `.appx`, checks the bundled runtimes with `verify-win-package.js`, and uploads the package as a build artifact (kept 14 days).
- `desktop/electron/services/rating.js` → Store installs (`process.windowsStore`) open the Store review page; the Stripe build keeps the contact form.

### Partner Center identity (already in `build.appx`)

| Field | Value |
|---|---|
| Store name | Foldiq Photo & Video Organizer |
| Store ID | 9N7XKX8G0M2P |
| Package/Identity/Name | Mystodev.FoldiqPhotoVideoOrganizer |
| Package/Identity/Publisher | CN=40266193-F765-424C-8E74-B50758ADB2D2 |
| PublisherDisplayName | Mystodev |
| Store link | https://apps.microsoft.com/detail/9N7XKX8G0M2P |

## Steps for the owner

1. ~~Create the developer account~~ — done 2026-11-15 (individual, publisher "Mystodev").
2. ~~Reserve the name~~ — done 2026-11-15 as **Foldiq Photo & Video Organizer**. Plain "Foldiq" is held by another account; to claim it, write to reportapp@microsoft.com. The reservation lapses if nothing is submitted within three months (by mid-February 2027).
3. On GitHub → Actions → **Windows Store Package** → Run workflow, with the version in `desktop/package.json`.
4. Download the `foldiq-store-<version>` artifact and unzip it to get the `.appx`.
5. In Partner Center, start the submission and fill in each section using the copy below. Upload the `.appx` under **Packages**.
6. Submit. Certification usually takes a few business days.

## Submission settings

| Section | Value |
|---|---|
| Pricing | Paid, **$19.99** (base price, all markets), the same as the Stripe installer and the App Store. Microsoft commerce, 15 % fee. No free trial: the app has no Store license check, so a trial would be the full product. |
| Markets | All |
| Category | Photo & video |
| Privacy policy URL | https://foldiq.app/privacy-policy.html |
| Website | https://foldiq.app |
| Support contact | https://foldiq.app/contact |
| System requirements | Windows 10/11, x64 |
| Age rating (IARC questionnaire) | Utility app. No violence, sexual content, gambling or user-to-user communication. No in-app purchases. Optional internet use: location lookup (OpenStreetMap) and anonymous product metrics, both off by default. |

### Notes for certification testers

> Foldiq organizes photos and videos already on the PC. To test it: choose any folder that contains a few JPG or MP4 files, pick an organization mode, review the planned moves on the Preview screen, then apply. The report screen offers Undo, which moves every file back. No account or sign-in is needed. Network access is optional (location names and anonymous metrics, both off by default).

## Store listing (English)

The description field must not contain links. Put URLs only in their own fields.

### Short description

Organize years of photos and videos into dated folders using the real capture date. Preview every move before it happens and undo it all with one click. Everything runs on your PC.

### Description

Your photo library deserves better than a folder called "Misc 2019 backup copy (2)".

Foldiq scans any folder of photos and videos on your PC, including ZIP, RAR and 7z archives, and builds a clean, dated folder structure from the date each photo was actually taken. No manual sorting, no cloud, no subscription.

HOW IT WORKS
1. Choose one or more folders, or a ZIP, RAR or 7z archive.
2. Foldiq reads EXIF data, GPS metadata and filenames to find every file's real capture date.
3. Review every planned move in a full preview. Nothing moves until you approve it.
4. Foldiq reorganizes the library and writes an undo log, so every change can be reversed.

THE REAL DATE, NOT THE FILE DATE
Copying, restoring, unzipping or exporting from Google Takeout rewrites a file's modified date. The real date is still inside the photo's EXIF data, and that is the date Foldiq uses. Your library stays in true chronological order even after files were copied, backed up or sent through WhatsApp or Telegram.

ORGANIZE YOUR WAY
Smart Hybrid (recommended), By Year, By Year & Month, By Year, Month & Day, or By Location.

SMART DUPLICATES
Exact copies are confirmed with SHA-256. Foldiq also compares image content on your PC to find the same photo after renaming or re-export, groups related copies and suggests the best original. Similar photos are suggestions to review and are never moved automatically.

UNDO THAT IS VERIFIED
Every run creates an undo manifest. One click moves every file back to its original location, even days later. Foldiq refuses to remove an organized copy unless the original is confirmed in place.

WHAT IT ORGANIZES
Photos: JPG, JPEG, PNG, HEIC, TIFF and RAW (CR2, CR3, NEF, ARW, DNG, RAF, ORF, RW2).
Videos: MOV, MP4, M4V and AVI.
Archives: unencrypted ZIP, RAR and 7z. The original archive is left untouched.

PRIVATE BY DESIGN
Photos, videos, filenames and metadata are processed on your PC and are never uploaded. No account required. Location-based folder names are optional: when enabled, only an approximate coordinate (rounded to about 1 km) is sent to OpenStreetMap. Anonymous usage metrics are off by default.

One-time purchase. No subscription.

### Product features (one per line in Partner Center)

- Organizes photos and videos by their real EXIF capture date
- Full preview of every move before anything changes
- One-click undo for every organization run
- Finds exact and visually identical duplicates
- Opens ZIP, RAR and 7z archives without touching the original
- Supports HEIC, RAW, JPG, PNG, TIFF, MOV, MP4 and more
- Optional folder names by location
- Runs entirely on your PC, no account needed

### Search terms

photo organizer · organize photos by date · exif date · duplicate photos · google takeout photos · photo sorter · video organizer

(Partner Center limits the number and length of terms; trim if its counter complains.)

## Still missing before submitting

- **Windows screenshots.** Every image in `web/screenshots/` is from the Mac app, and the Store needs at least one desktop screenshot (1366×768 or larger). Take 4–5 from Windows: welcome, scan results, the Preview screen with a realistic library (thousands of files), the report with Undo, and settings. Use a folder path that does not show the user name.

## After the first approval

- Add the Store badge to the Windows download on foldiq.app.
- Decide whether the site keeps selling the Stripe installer or points Windows buyers to the Store.
