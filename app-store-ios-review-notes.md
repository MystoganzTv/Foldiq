# Foldiq iOS — App Store Review Notes

Paste the block below into **App Store Connect → your iOS version → App Review Information → Notes**.
No demo account is needed (the app has no sign-up or login). The only thing a reviewer must do is grant Photos access.

---

## App Review Notes (paste this)

Foldiq is a local photo & video organizer. It exports organized COPIES of items from
the Photos Library into Files (iCloud Drive, On My iPhone/iPad, or a connected USB drive).
It never modifies or deletes anything in the Photos Library — originals always stay in place.

NO ACCOUNT / NO LOGIN: The app has no sign-up, no login, and no paywall. Every feature is
available immediately. The only permission required is Photos access.

HOW TO TEST (about 60 seconds):
1. Launch the app and tap "Choose Photos and Videos" (or "Select Entire Library").
2. Approve the Photos permission prompt when it appears.
3. Pick a few photos/videos and tap Continue/Export.
4. In the system folder picker, choose a destination — e.g. "On My iPhone → (any folder)"
   or iCloud Drive. Tap "Export N Organized Copies".
5. Open the Files app at that destination to see the organized "Foldiq Export" folder,
   sorted into dated subfolders.

PROCESSING TIME / SPINNERS: If a selected photo or video is stored in iCloud (Optimize
iPhone Storage), Foldiq downloads the original from the user's own iCloud before copying it.
This can take several seconds per item on a slow connection, so the progress bar may pause
on a single file — this is expected, not a hang. For the fastest review, test with items
that are already downloaded on the device (or disable Optimize Storage beforehand).

PRIVACY / NETWORK: Foldiq sends nothing to Foldiq servers and has no analytics or tracking.
The only network use is Apple's own system services: (a) downloading the user's originals
from their iCloud, and (b) optional reverse geocoding via Apple's CLGeocoder when the user
chooses location-based organization. All organization runs on-device.

DEMO VIDEO: An unlisted screen recording of a successful export is linked below.
[paste your unlisted YouTube/Vimeo/Drive link here]

---

## Demo video — how to record it (point 18)

Record a quick, unedited ~30s clip on your iPhone and upload it unlisted (YouTube unlisted,
Vimeo private, or a Drive "anyone with the link" file), then paste the link in the notes above.

Suggested flow to capture:
1. Open Foldiq → tap "Choose Photos and Videos".
2. Approve the Photos prompt.
3. Select 3–4 items already downloaded on the device (so it's fast on camera).
4. Pick a destination in the Files picker (On My iPhone is quickest).
5. Show the progress bar finishing and the "Done" summary.
6. Open the Files app to reveal the organized dated folders.

Tip: use items already on the device so there's no long iCloud download mid-recording.

---

## Quick reference

- Bundle ID: com.MystoganzTv.Foldiq.iOS
- No account required (leave the demo username/password fields blank)
- Required permission: Photos (NSPhotoLibraryUsageDescription is set)
- Privacy Policy: https://foldiq.app/privacy  ·  Terms: https://foldiq.app/terms
  (also linked inside the app on the main screen)
