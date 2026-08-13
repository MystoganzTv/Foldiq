# Foldiq — Session handoff

Updated: 2026-08-13 00:05 America/New_York

## Read this first

The repository is `/Users/enrique/Developer/Foldiq`. The active branch is `main`.
`main` and `origin/main` contain the complete Windows 1.0.17 work. It supersedes the
older 1.0.15 test build: it fixes the metadata runtime/hang, closes the major
macOS parity gaps, adds real opt-in location organization, retry/cleanup/report
controls, and persists Windows preferences. Do not discard these changes.

Smart Duplicates 1.0.18 is implemented for macOS and Windows in the current
source and has a locally verified Windows installer, but it is not yet a GitHub
Release and has not been uploaded to App Store Connect. Publishing remains a
separate release decision. The currently supported customer release remains
Windows 1.0.17 and macOS 1.0.8 until 1.0.18 is explicitly released.

Windows 1.0.17 is pushed, tagged, and released at
`https://github.com/MystoganzTv/Foldiq/releases/tag/v1.0.17-windows`. The release
asset is named `Foldiq-Setup.exe`, so the website's dynamic download endpoint
will resolve it as the latest Windows installer. A fresh remote download matched
the local/Desktop SHA-256 exactly.

The user installed and tested this published 1.0.17 build on a real Windows PC
and confirmed on 2026-08-12 that it worked well. The real-machine release gate
is therefore complete. Do not replace the existing 1.0.17 bytes; any future app
code correction must use a new version.

The Windows purchase pipeline is ready for customers. On 2026-08-12 the invalid
Vercel `GITHUB_RELEASE_TOKEN` (GitHub returned 401) was replaced with a dedicated
fine-grained token scoped only to `MystoganzTv/Foldiq`, with `Contents: Read-only`
and `Metadata: Read-only`. It has no expiration so paid downloads do not suddenly
stop; rotate it immediately if exposure is suspected. Vercel production was
redeployed and became Ready. A paid/complete Windows checkout simulation through
the real download handler returned HTTP 302 to
`release-assets.githubusercontent.com`, resolving release `v1.0.17-windows` and
asset `Foldiq-Setup.exe`. No token value is stored in this repository.

No credentials or Apple/GitHub secrets are recorded in this checkpoint.

On 2026-08-12 all six external direct purchasers were contacted individually
about the supported releases. Stripe showed five legacy macOS purchases and one
Windows purchase (the owner's own test purchase was excluded). Five one-time
Apple promo codes for macOS 1.0.8 were generated in App Store Connect and sent
one per Mac buyer, with redemption instructions, Apple terms, and the Apple
expiration of 2026-09-09 at 11:59 PM PT. The Windows buyer received their
original purchase-bound private download link for Windows 1.0.17. Gmail Sent
verification found exactly five Mac notices and one Windows notice. No customer
addresses, checkout sessions, or promo-code values are recorded here.

Operational email caveat: the connected Resend account rejected
`receipts@foldiq.app` because `foldiq.app` is not verified there (the only listed
verified domain was `rbtgenius.com`). No Resend attempts were delivered; the six
customer notices were sent successfully from the connected owner Gmail account,
`enrique.padron853@gmail.com`, signed as Foldiq Support. Before relying on future
automatic purchase receipts from `web/api/webhook.js`, confirm whether Vercel's
production `RESEND_API_KEY` belongs to a different account where `foldiq.app` is
verified, or verify the domain and rotate/update that key.

## Published state

- Windows 1.0.17 is the latest GitHub-published Windows release/tag.
- Release: `https://github.com/MystoganzTv/Foldiq/releases/tag/v1.0.17-windows`
- The private website download endpoint dynamically resolves the latest GitHub
  release asset named `Foldiq-Setup.exe`. Production was redeployed after the
  GitHub credential rotation described above. The live website still creates a
  `checkout.stripe.com` live Windows checkout, and all 12 web purchase/download
  tests pass.
- `foldiq.app` is hosted by Vercel from the `web/` root. Public copy and the
  privacy/terms pages now disclose optional Apple and Windows GPS lookups,
  including Windows coordinate rounding and OpenStreetMap. The obsolete GitHub
  Pages workflow was removed because it was generating false deployment
  failures. The updated web suite passes all 12 tests, and a protected Vercel
  preview verified the static pages plus all three serverless functions.
- GitHub Actions cleanup completed after the account reached its included usage:
  41 temporary workflow artifacts totaling 2,422,863,177 bytes (2.42 GB) were
  deleted; active Actions artifact storage verified at zero afterward. Published
  GitHub Releases and `Foldiq-Setup.exe` were not touched. Both remaining build
  workflows are manual-only, cancel duplicate runs, have bounded timeouts, and
  retain any future artifacts for one day.
- Windows code is intentionally unsigned for now; the user accepted that
  SmartScreen may warn. Do not start a Windows certificate purchase/signing
  workflow unless explicitly requested.
- macOS 1.0.8 is publicly listed in the US Mac App Store at
  `https://apps.apple.com/us/app/foldiq/id6772513569` for $4.99 and requires
  macOS 14.0 or later. App Store Connect build 116 was the known good submitted
  build in the prior work.
- Obsolete Netlify references were removed in commit `c7cb0e8`; do not restore
  Netlify without a new explicit reason.
- The repository was made private earlier in the project.

## Windows 1.0.17 — built, verified, pushed, and published

This build includes everything from the superseded 1.0.15 test build plus:

- Real `By Location` organization: Country → State → City, with explicit
  `Unknown Location` fallback.
- Smart Hybrid can add city/state to day folders (`2026-05-18 Herndon VA`).
- GPS naming is opt-in. By Location explicitly enables it; Smart Hybrid leaves
  it off until chosen. Approximate coordinates are reverse-geocoded in one
  serial stream, rounded into roughly 1 km cache buckets, cached locally, and
  displayed with OpenStreetMap/ODbL attribution. The public endpoint is limited
  below one request/second and uses an identifying User-Agent.
- 1.0.17 corrects a final privacy discrepancy found after publishing 1.0.16:
  coordinates are now actually rounded to two decimal places before leaving the
  PC, matching the disclosure. 1.0.16 remains in release history but is
  superseded; do not direct users to it.
- Persistent Windows preferences in app data: organization mode, output,
  copy/move, duplicate policy, videos, archives, date estimates, and GPS choice.
- Retry Failed Files from Report. Retry results get their own safe manifest and
  Undo reverses all successful attempts in reverse order.
- Empty source folders are no longer removed silently. Report counts them and
  offers explicit cleanup while preserving selected roots and the output tree.
- Report totals use successfully completed operations, not merely planned ones.
- Welcome has no scrollbar at either 1100x740 or 1100x650. Direct DOM
  measurements at 1100x650 were body `650/650` and Welcome `578/578`.

Validation completed:

- `npm test`: 44 passed, 0 failed, 1 Windows-only RAR runtime test skipped on
  macOS.
- Vite production build, Electron/Node syntax checks, and `git diff --check`
  passed.
- Real IPC scan of `/Users/enrique/Downloads/IMG_9115.HEIC`: 1 file, 0
  warnings, camera metadata date, valid GPS, and `iPhone 16 Pro`; no metadata
  hang.
- Visual checks at 1100x650 confirmed no Vite overlay, all five organization
  modes, location/GPS disclosure and attribution, Retry Failed File, and Remove
  Empty Folders.
- `npm run build:win` passed, including the mandatory native runtime verifier:
  complete Windows ExifTool and 7-Zip runtimes.

Installer:

`/Users/enrique/Desktop/Foldiq Setup 1.0.17.exe`

- Size: approximately 118 MB
- SHA-256: `0a749f3bbc949d1b38df6227b3ee43fb81e1d7ae9b729adf610998d0ebc376c8`
- Identical source artifact:
  `/Users/enrique/Developer/Foldiq/desktop/dist-electron/Foldiq Setup 1.0.17.exe`
- Published asset: `Foldiq-Setup.exe`. A fresh download from the GitHub release
  matched SHA-256
  `0a749f3bbc949d1b38df6227b3ee43fb81e1d7ae9b729adf610998d0ebc376c8`.

## Windows 1.0.10 release

`desktop/package.json` and `desktop/package-lock.json` are versioned as
`1.0.10`. Commit `4f8afd5` is on `main` and `origin/main`; tag
`v1.0.10-windows` and the GitHub release are published.

## Windows 1.0.15 local test build — superseded by 1.0.17

After real Windows feedback that 1.0.11 still appeared stuck at `Reading
capture dates`, the metadata stage was redesigned again:

- **Confirmed root cause of the repeated real-Windows failure:** builds created
  on macOS contained `exiftool-vendored.pl/bin/exiftool` but no
  `exiftool-vendored.exe`. macOS could run the Perl version, so local tests
  passed; a normal Windows installation could not start it. Inspection of the
  old final `app.asar` explicitly returned `MISSING_WINDOWS_EXIFTOOL`.
- 1.0.13 downloads the official `exiftool-vendored.exe` 13.59.2 package during
  build, verifies the pinned archive SHA-256
  `4c135bfb89f5bf1f1bb7d7cead45dced3d89ffae17dccaf425cad69f62d11029`,
  and stages the complete 510-file native runtime in
  `resources/exiftool`. Windows now explicitly resolves
  `resources/exiftool/exiftool.exe`; it never asks for the macOS Perl package.
- The final package was inspected: `exiftool.exe` and its bundled `perl.exe`
  are both PE32+ x86-64 Windows executables, their auxiliary runtime is present,
  and the app resolves the exact packaged path.
- `npm run build:win` now ends with a mandatory package verifier and fails if
  native ExifTool/7-Zip files are absent, incomplete, or not Windows PE files.

- ExifTool now receives batches of up to 40 files through explicit child
  processes, with two batches running concurrently. It no longer launches a
  separate ExifTool task for every photo.
- Windows paths are streamed to ExifTool over stdin instead of being placed on
  one long process command line. This avoids Windows command-line limits with
  long NAS paths.
- Metadata timeout now scales from 15 to 60 seconds according to batch size for
  slow network storage. If a batch still fails, it is recursively divided until
  Foldiq isolates only the unreadable file; valid photos in the same group no
  longer become `Missing Date`. This was a concrete code-level cause of inflated
  missing-date counts in 1.0.13.
- Duplicate hashing is a separate phase, limited to two concurrent reads, and
  still runs only for same-size candidates.
- Scan and archive extraction are cancellable from the UI.
- UI names each phase. The raw `Open diagnostics` control was removed from the
  normal scan UI. Only after a warning or failure, the user can choose `Send
  diagnostics to developer`, review a privacy/consent dialog, and open a draft
  to `support@foldiq.app`. The summary contains app/Windows versions, stages,
  timings, counts, and error codes; it strips photos, filenames, folder paths,
  and local usernames. Nothing is sent until the user reviews and sends the
  email. Error results now say `Scan Failed`, not `Scan Complete`.

### Smart Duplicates 1.0.18 (implemented locally; release not published yet)

- Exact duplicates still use SHA-256, but Windows now elects the best original
  after metadata extraction instead of keeping whichever path scanned first.
- macOS and Windows calculate an orientation-aware 64-bit visual hash and can
  find renamed, rotated, metadata-modified, and re-encoded photos.
- Smart Matches form connected groups of two or more files instead of consuming
  only one pair and silently dropping a third copy.
- Strong visual matches may follow the user's duplicate-handling choice. Weaker
  similarities and metadata-only matches are explicitly `Review only` and are
  never separated automatically.
- Windows supports JPG, PNG, HEIC/HEIF, and TIFF visual decoding. HEIC/TIFF run
  in a worker thread with concurrency 1, a 60 MP/256 MB safety cap, live
  progress, and cancellation so the scan UI remains responsive.
- macOS uses ImageIO thumbnails and CoreGraphics. RAW formats are attempted by
  ImageIO when the system provides a decoder.
- Windows ships HEIC support outside `app.asar` with third-party license notices
  for LGPL compliance.
- Current validation: Windows 54 tests passed (1 platform-gated RAR test skipped),
  macOS 27 tests passed, the macOS Release build reports 1.0.18 (117), Windows
  installer packaging passed, and a real renamed HEIC with changed metadata was
  detected end-to-end as a 100% visual match in 2.9 seconds. The 1.0.18 installers
  have not been distributed or uploaded yet.

Major macOS/Windows parity work included in the same build:

- Welcome footer displays `v1.0.15 · Windows`, plus a `How it works` dialog.
- Pre-scan options for videos and ZIP/RAR/7z archives.
- Welcome spacing now uses the available 1100x740 window without an unnecessary
  scrollbar. Browser measurements were `clientHeight=667` and
  `scrollHeight=667`; scrolling remains available for genuinely long source
  lists or smaller windows. The video/archive include controls remain enabled.
- Follow-up Windows feedback showed the scrollbar remained because the native
  title/menu bars reduce the web content below 740px. Welcome was reworked and
  verified at 1100x650: empty is `577/577` with no scrollbar; one selected
  source is `577/577` with no scrollbar; 21 sources are `1431/577` and retain
  the necessary scrollbar. Empty Welcome explicitly hides overflow while
  selected-source lists remain scrollable only when their content exceeds the
  available height.
- Clickable scan result cards with the actual matching file lists.
- Probable-duplicate detection, exact/probable duplicate display, and handling
  choices: separate into duplicate folders, leave untouched, or organize.
- Camera/model, dimensions, duration, and GPS metadata extraction/display.
- Report CSV export and clearer copied/moved/untouched totals.
- Scanning now reuses the animated circular-arrows activity indicator that the
  user liked on Applying. It was visually verified at 1100x740.
- Scan Results now shows a date-evidence breakdown: embedded dates, filename
  dates, missing dates, and missing dates with a file-timestamp estimate.
- Organization Settings offers an explicit, default-off option to estimate
  genuinely missing capture dates from file timestamps. Preview labels these as
  estimates and warns that copies/exports may have newer timestamps; Foldiq does
  not silently assume every missing file belongs to 2026.
- Historical note: this 1.0.15 limitation was superseded by 1.0.17. Windows now
  supports opt-in reverse-geocoded location organization with rounded
  coordinates and OpenStreetMap attribution, as documented near the top of this
  handoff.
- The user supplied `/Users/enrique/Downloads/IMG_9115.HEIC`. It is a valid
  6.5 MB iPhone 16 Pro HEIC and ExifTool reads it in about 140 ms, so it does
  not reproduce the metadata hang. It did expose that ExifTool's formatted DMS
  GPS strings were being discarded. Metadata reads now use numeric output;
  this sample returns latitude `38.9497222222222` and longitude
  `-77.4029527777778` correctly.

Local validation:

- Desktop `npm test`: 38 passed, 0 failed, 1 Windows-only RAR test skipped.
- Vite build, Electron syntax checks, `git diff --check`, and the Windows NSIS
  installer build passed.
- The Welcome screen was visually verified in a real browser session, including
  its version footer and `How it works` content.
- The real iCloud ZIP completed 46 files through all phases in about 388 ms on
  this Mac, with no archive warnings.

Test installer:

`/Users/enrique/Desktop/Foldiq Setup 1.0.15.exe`

- Size: approximately 118 MB (larger because it now actually includes the
  complete 34 MB Windows metadata runtime)
- SHA-256: `e681b04415d53a92a7f14086c2e488556788f8d6e44c1098f986f1eb7821d1bc`
- This 1.0.15 build is local only: not committed, pushed, tagged, released, or
  served by the website yet. Wait for the user's real Windows confirmation.

The user later clarified that `IMG_9117.HEIC` and
`EA0D9ADA-B107-45F4-B7A7-66CD0F5CB312.JPG` were captures of the Windows UI, not
examples of library media reported as Missing Date. Do not cite their metadata
as evidence about the user's missing-date files. A real file listed by Foldiq as
Missing Date is still needed to identify why that specific file lacks a trusted
capture date.

Files included in the release commit:

- `desktop/electron/main.js`
- `desktop/electron/preload.js`
- `desktop/electron/services/scanner.js`
- `desktop/electron/services/archive.js`
- `desktop/package.json`
- `desktop/package-lock.json`
- `desktop/src/components/StepBar.jsx`
- `desktop/src/components/StepBar.module.css`
- `desktop/src/screens/ApplyScreen.jsx`
- `desktop/src/screens/PreviewScreen.jsx`
- `desktop/src/screens/ScanScreen.jsx`
- `desktop/src/screens/Screen.module.css`
- `desktop/tests/safety.test.js`
- `desktop/tests/archive.test.js`

## What was implemented in 1.0.10

### Windows Preview/UI parity

- Rich table with current path, planned destination, real operation, and
  per-file organize/leave-untouched checkbox.
- Animated side inspector with secure local thumbnail generation.
- Search, filters, sorting, folder-tree preview, and preflight confirmation.
- Actual copy/move counts. Archive contents say `Copy only`; ZIP/RAR/7z sources
  remain untouched even when the global option is Move.
- Progress screen now shows current filename, percent, elapsed time, completion,
  and errors.
- Step/progress animations were improved.
- Essential content no longer animates from opacity zero. Electron could pause
  background animations and leave the whole Preview washed out, as seen in the
  user's screenshot. Animations now use movement without fading core content.
- Ambiguous `Include shown` / `Exclude shown` controls were removed. There is
  one explicit contextual action such as `Keep 46 files untouched` or
  `Organize 12 matching files`. `Matching files` means files matching the
  current filter and search.
- Filter language is now `Will organize` and `Left untouched`.

### Incorrect Windows dates — serious fix

Root cause: Windows accepted `ModifyDate` and filesystem modification/birth
timestamps as capture dates. ZIP extraction or a recent copy/export could
therefore organize old photos under August 2026.

New policy:

- Never use file modification/birth time as a capture date.
- Never use embedded `ModifyDate` as a capture date.
- Trust capture-oriented EXIF/container fields (`DateTimeOriginal`, digitized,
  media/track creation, creation date) and recognized filename dates.
- If a filename contains a date over 90 days older than recently replaced
  embedded metadata, prefer the filename date (matching macOS behavior for
  WhatsApp/Telegram-style exports).
- If no reliable date exists, route to `Unknown Date`; never invent one.
- Preview shows `Date source` and lets the user correct or clear a date before
  confirming. Rebuilding the plan recalculates destinations safely.

macOS was inspected: photos/videos already organize from `dateTaken` rather
than filesystem modification time, and its Preview already permits assigning
dates to `Unknown Date` items. No macOS date-code change was made in this turn.

### Large archive scan freeze/lag fix

- Windows 7-Zip extraction now emits live percentage updates instead of
  appearing frozen until the whole archive finishes.
- Extraction has a five-minute no-activity watchdog and remains capped by the
  existing hard timeout.
- Scan shows the current indexing/analyzing file, elapsed time, and an
  indeterminate animation while totals are not known.
- Temporary archive cleanup is asynchronous so it no longer blocks Electron's
  main process.
- Exact-duplicate detection first groups by file size and hashes only files
  that could actually be duplicates. This avoids reading every byte of unique
  large videos while preserving exact duplicate detection.

## Validation already completed

From `/Users/enrique/Developer/Foldiq/desktop`:

- `npm test`: 25 passed, 0 failed, 1 skipped. The skipped case is the real
  bundled Windows RAR-engine execution, which is platform-gated on macOS.
- `npx vite build`: passed.
- `node --check` for modified Electron services: passed.
- `git diff --check`: passed.
- `npm run build:win`: passed after the final UI/date corrections.
- The updated 7-Zip path was exercised against the real iCloud ZIP and emitted
  progress while extracting all 46 supported media files.
- Web `npm test`: 10 passed, 0 failed.
- A real `/Users/enrique/Downloads/iCloud Photos.zip` scan was used to verify
  archive handling, thumbnails, destinations, folder-tree preview, and correct
  `46 copied / 0 moved` reporting.

Latest local installer:

`/Users/enrique/Developer/Foldiq/desktop/dist-electron/Foldiq Setup 1.0.10.exe`

- Size: approximately 109 MB
- SHA-256: `49e8a3ecc3cf66da44e8d77c47d3c7f91a24dfa36d0d26f2137be83382bcfb77`
- Desktop copy: `/Users/enrique/Desktop/Foldiq Setup 1.0.10.exe`
- GitHub asset: `Foldiq-Setup.exe` (114,666,978 bytes)
- The GitHub asset was downloaded after publishing and its SHA-256 matched the
  local installer exactly.

## Important product/safety notes

- Existing folders organized incorrectly by an older build are not silently
  repaired. Use Undo if the session still offers it, or retest into a new empty
  output folder. Never delete the user's old output without explicit approval.
- Archive inputs are extracted to internal temporary storage and copied to the
  chosen output. They must never attempt to save inside the archive.
- Internal undo JSON stays in app data, not the user's photo folder, and is
  cleared according to the existing Start Over/session policy.
- Do not overwrite an already published version with different content. Windows
  1.0.17 is the current tested release; any later app correction must use a new
  version.

## Recommended next session sequence

1. Read this file and inspect `git status` before changing anything.
2. Treat Windows 1.0.17 as the current released and real-PC-tested build. Keep
   `/Users/enrique/Desktop/Foldiq Setup 1.0.17.exe` as the known-good installer.
3. Do not overwrite or replace the published 1.0.17 asset with different bytes.
   Any future Windows app correction must receive a new version and fresh test.
4. The next independent product track is iPhone/iPad: inspect the current iOS
   build/submission state in App Store Connect before uploading or submitting.
5. Keep public privacy copy aligned with optional GPS lookup: media stays on the
   device; Apple platforms may use Apple's geocoder, while Windows sends only a
   coordinate rounded to two decimals to OpenStreetMap when the user enables
   location naming.
