# Slate

A private image library for iPhone, iPad, and Mac, with home-screen, lock-screen, and desktop
widgets that rotate through your images. Personal use; built to run with a **free Apple ID
(Personal Team)**.

- iOS 18+ / macOS 15+, Swift 6, SwiftUI, one shared codebase (platform code only behind `#if os()`)
- Images are **copied** into Slate's App Group container. Slate never reads from or writes to the
  Photos library and never asks for Photos permission (PhotosPicker runs out of process).
- No iCloud, CloudKit, or push notifications. The only capability is **App Groups**.

---

## Architecture

```
Config/                 Slate.xcconfig (IDs + team), entitlements, app Info.plist
Shared/                 compiled into the app, the widget, AND the tests
  LibraryItem.swift       metadata model + ImageVariant (original / thumbnail / widget)
  LibraryStore.swift      the storage protocol + user-facing LibraryError
  FileLibraryStore.swift  actor implementation over plain files + index.json
  ImageProcessing.swift   ImageIO validation, downsampling, JPEG encoding
  RotationSchedule.swift  which image the widget shows when
  AppGroup.swift          resolves the container from Info.plist
SlideshowApp/           the app target (product name "Slate")
  LibraryModel.swift      @Observable app state; import/delete orchestration
  ImageLoader.swift       off-main decoding + NSCache
  Views/                  LibraryView, MasonryGrid, ViewerView, SlideshowView, EmptyLibraryView, …
  SlateApp.swift          scenes + menu commands
SlateWidgets/           the widget extension (iOS + macOS)
  SlideshowIntent.swift   per-widget settings (AppIntentConfiguration)
  SlideshowProvider.swift timeline construction
  SlideshowWidget.swift   layouts for each family
SlateTests/             Swift Testing tests for the store and the rotation schedule
```

### Storage

All storage goes through the `LibraryStore` protocol. The UI and the widget never touch paths
directly, so a different backend can be added later (for example one that mirrors an iCloud
Drive folder) by writing another conforming type. Neither the views nor the widget would change.

`FileLibraryStore` is an `actor` rooted at `<App Group>/Slate/`:

```
index.json            [{id, filename, originalFileExtension, importDate, pixelWidth, pixelHeight, isFavorite}]
Originals/<id>.<ext>  byte-for-byte copy of the imported file (HEIC, JPEG, or PNG)
Thumbnails/<id>.jpg   ≤400 px, for the grid
Widget/<id>.jpg       ≤1200 px, the ONLY files the widget reads
```

Importing works like this:
1. Validate the file with ImageIO (type, readable header, pixel size with EXIF orientation applied).
2. Check free space.
3. Copy the original.
4. Generate the 1200 px JPEG. The 400 px thumbnail is generated *from that JPEG*, which is much
   cheaper than decoding a 48 MP HEIC twice.
5. Append the item to the index (atomic write).

Steps 3–4 run in `@concurrent` functions, so they never block the main thread or the actor. The
app runs up to 3 imports at once. If an import fails, all of its files are removed. Leftovers from
a crash are cleaned up at launch (`removeOrphanedFiles`).

Deleting updates the index first, then removes the original and both derivatives. Widgets are
reloaded (`WidgetCenter.shared.reloadAllTimelines()`) after every import batch and delete.

### Why plain JSON instead of SwiftData

- **One writer, one reader.** Only the app writes. The widget only reads, from a separate process
  with a tight memory limit. An atomically replaced JSON file can never be seen half-written, and
  reading it needs no database stack or schema migration inside the widget.
- **Tiny data.** Seven fields per image; 1,000 images is about 200 KB. There's nothing to query
  beyond "all items, newest first".
- **Sync-friendly.** A folder of files plus a JSON index is exactly what a future file-sync
  backend (such as iCloud Drive) can mirror. SwiftData's store would have to be exported anyway.

### App

- **Library grid:** masonry layout with one `LazyVStack` per column, so only on-screen cells exist.
  Items are placed by their stored aspect ratio, so the layout doesn't jump while thumbnails load.
  Thumbnails are decoded off the main thread and cached in an `NSCache`. A 1,000-image library
  opens straight into the populated grid on the iOS Simulator; scrolling smoothness at that size
  hasn't been profiled on a device yet.
- **Viewer:** horizontal paging `ScrollView`. Swipe, trackpad, or ←/→ to move between images;
  pinch or double-tap to zoom (drag to pan while zoomed); Esc to close. Images are decoded from the
  original at a maximum of 3072 px.
- **Slideshow:** auto-advancing with a cross-fade. Interval (3–60 s) and shuffle are remembered.
  Space pauses; ←/→ step. The screen stays awake while it plays; on Mac it enters full screen.
- **Import:** PhotosPicker (multi-select, original encoding kept), Files (`fileImporter`), and drag
  and drop onto the window (Mac and iPad). Progress appears in a banner; failures are summarised
  per file afterwards (unsupported format, damaged image, out of space).
- **macOS:** a single `Window` (no sidebar) with these commands:

| Command | Shortcut |
|---|---|
| File ▸ Import… | ⌘O |
| File ▸ Import from Photos… | ⇧⌘O |
| Library ▸ Select / Done Selecting | ⌘E |
| Library ▸ Delete | ⌘⌫ (also the Delete key in the grid) |
| Library ▸ Start Slideshow | ⌥⌘P |
| Select All | ⌘A |

  The same commands work from an iPad hardware keyboard.

### Widgets

- Families: `systemSmall`, `systemMedium`, `systemLarge`, `systemExtraLarge` (iPad and Mac), plus
  `accessoryRectangular` on the iOS Lock Screen. Mac desktop / Notification Center widgets use the
  system families.
- **Edit Widget** settings for each widget:
  - **Change Image**: every 15 min, 30 min, 1 hr, 3 hr, or daily
  - **Order**: Shuffle or Newest First
  - **Image Fit**: Fill or Fit
- **Fill** crops the image to the widget's exact aspect ratio: centred horizontally; vertically
  biased upward (to 45% of the height, or 38% on the wide medium widget) so faces and horizons
  survive. **Fit** letterboxes the image over its average colour.
- **Timelines:** each timeline is built 30–48 entries ahead:

| Setting | Entries | Covers |
|---|---|---|
| 15 min | 48 | 12 hours |
| 30 min | 48 | 1 day |
| 1 hr | 48 | 2 days |
| 3 hr | 40 | 5 days |
| Daily | 30 | 30 days |

  Rotation slots align to the clock (on the hour, at midnight) and have absolute numbers, so a
  rebuilt timeline carries on where the old one left off. Shuffle shows every image once per cycle.
- **Memory:** a timeline entry stores only a file URL. The image is decoded when the entry renders,
  from the 1200 px derivative only, downsampled and cropped to the widget's own pixel size. That
  keeps the widget well within its memory limit, and also within WidgetKit's archive size check,
  which rejects images much larger than the widget (`imageTooLarge`). Originals are never opened by
  the widget.
- Tapping a widget opens that image in Slate (`slate://item/<id>`).
- An empty library shows "Add images in Slate". The widget gallery shows a bundled sample image.

**Honest note on timing:** WidgetKit, not Slate, decides exactly when a widget redraws. Entries are
*requests*: iOS and macOS usually honour them within a few minutes but may delay them (Low Power
Mode, a widget that's rarely viewed, system load). This is a periodic **rotation**, not a smooth
animated slideshow. Widgets can't animate between photos. For that, use the in-app slideshow.

---

## Setting your Team and bundle ID (one place)

Everything lives in **`Config/Slate.xcconfig`**:

```
DEVELOPMENT_TEAM = 4UP7AQ5437          // your Personal Team ID
SLATE_BUNDLE_PREFIX = com.yourname.slate
```

1. Set `SLATE_BUNDLE_PREFIX` to something unique to you, e.g. `com.janedoe.slate`. Bundle IDs are
   global across all Apple accounts, so `com.yourname.slate` may already be taken.
2. Check `DEVELOPMENT_TEAM`. In Xcode, open the project ▸ any target ▸ Signing & Capabilities, and
   pick "*Your Name* (Personal Team)". The 10-character ID it shows belongs here. Xcode may write
   the team into the target as well; that's harmless if it's the same value.
3. **Do this once, before the first device build, and then leave it alone.** Free teams can create
   only **10 App IDs per 7 days**. Slate uses 2 (`<prefix>` for the app and `<prefix>.widgets` for
   the widget) plus one App Group. Every prefix change registers new ones.

Everything else is derived from those two values:

| Item | iOS | macOS |
|---|---|---|
| App bundle ID | `<prefix>` | `<prefix>` |
| Widget bundle ID | `<prefix>.widgets` | `<prefix>.widgets` |
| App Group | `group.<prefix>` | `<TEAMID>.<prefix>` |

**Why the App Group differs by platform:** on iOS, app groups must start with `group.` and are
registered in your developer account; Xcode does this automatically because `REGISTER_APP_GROUPS`
is on. On macOS, the native form is prefixed with your Team ID (`$(TeamIdentifierPrefix)`, which is
always `<TEAMID>.`). That form needs no registration, and macOS 15+ grants it without a privacy
prompt when the app is signed by that team.

The xcconfig spells the macOS form as `$(DEVELOPMENT_TEAM).<prefix>` (identical to
`$(TeamIdentifierPrefix)<prefix>`). That lets the *same* build setting, `SLATE_APP_GROUP_ID`, feed
both:
- the entitlements (`Config/*.entitlements`), and
- Info.plist (`SlateAppGroupID`), which `AppGroup.swift` reads at runtime.

As a result, the code and the signature can't disagree. If the group isn't available at runtime
(usually a signing mistake), the app shows "Library Unavailable" with a pointer to the xcconfig,
and the widget shows "Open Slate to set up its library".

---

## Running on your devices with a free Apple ID

**First time on each machine:** Xcode ▸ Settings ▸ Accounts ▸ add your Apple ID.

### iPhone / iPad

1. Connect the device and enable **Developer Mode** (Settings ▸ Privacy & Security ▸ Developer
   Mode; the device restarts).
2. Select the **SlideshowApp** scheme and your device, then Run (⌘R). Xcode registers both App IDs
   and the App Group, and creates the profiles.
3. The first launch fails with "Untrusted Developer". On the device, go to Settings ▸ General ▸
   VPN & Device Management ▸ your Apple ID ▸ **Trust**. Then run again.
4. Add the widget: long-press the Home Screen ▸ Edit ▸ Add Widget ▸ Slate. For the Lock Screen,
   long-press it ▸ Customize ▸ Lock Screen ▸ add the rectangular Slate widget.

### Mac

1. Select the **SlideshowApp** scheme and **My Mac**, then Run.
2. Launch Slate at least once so macOS registers the widget. Then right-click the desktop ▸ Edit
   Widgets ▸ Slate.
3. Optional: to keep the widget registered after you clean the build folder, copy `Slate.app` out
   of the build folder (Product ▸ Show Build Folder in Finder) into `/Applications` and launch it
   from there.

### The weekly re-sign limitation

Free-team provisioning profiles expire after **7 days**. After that, **iOS refuses to launch the
app** (and its widgets go blank) until you plug in the device and Run from Xcode again. Your
library is **not** lost: re-running installs over the existing app, and the App Group container is
kept. Deleting the app from the device *does* delete the container and all imported images.

Free teams can also have only a few apps installed per device at once (currently 3). Slate counts
as one.

On the Mac, a Personal Team build may also stop launching when its profile expires; rebuilding from
Xcode fixes it, and the library (in `~/Library/Group Containers/<TEAMID>.<prefix>/`) is kept.

---

## Tests

The **SlateTests** scheme compiles `Shared/` directly, so it needs no host app and no signing
identity. Run it on "My Mac" or any simulator (⌘U).

- **`LibraryStoreTests`**:
  - import of JPEG/PNG: byte-identical original, 400/1200 px derivatives, no upscaling, EXIF
    rotation
  - persistence and newest-first ordering; concurrent imports
  - corrupt, truncated, and unsupported (GIF) files are rejected and leave no files behind
  - disk-full error mapping
  - delete removes original + both derivatives (single and multi); orphan cleanup; favorites
- **`RotationScheduleTests`**: clock alignment, daily-at-midnight, ordered cycling, shuffle
  coverage, continuing across rebuilds, DST days

---

## Known limits

- **Widget refresh timing** is up to the system (see above). Widgets rotate; they don't animate.
- **Formats:** HEIC/HEIF, JPEG, and PNG only. RAW, GIF, WebP, and others are rejected with a
  message. Animated content and Live Photo motion aren't kept; only the still image is.
- **Truncated files:** a file cut off in its header is rejected. A JPEG/PNG/HEIC cut off *later*
  in its pixel data may still import with a grey area. ImageIO's downsampling decoder fills in
  missing data silently, and a full-resolution check would cost ~200 MB per 48 MP import.
- **Wide colour/HDR:** derivatives are 8-bit JPEGs. The original is preserved exactly, and the
  viewer and slideshow decode from it.
- **The library is per-device.** There's no sync between iPhone and Mac in v1; the `LibraryStore`
  protocol is the seam for adding it.
- **One shared pool:** no albums or tags. `isFavorite` is stored but not used yet.
- **The Lock Screen widget** is rendered by iOS in its vibrant monochrome style, so photos appear as
  tinted silhouettes there. That's system behaviour. It also can't be checked in Xcode Previews,
  which render accessory widgets blank, so verify it on a device.
- **Deleting the app on iOS** deletes its container, and so the whole library. Export anything you
  care about first (Slate never deletes your originals in Photos or Files).
- **Viewer memory:** images display at up to 3072 px on the long edge, so very deep zoom on a large
  original gets soft.
