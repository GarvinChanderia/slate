# Slate logo

| File | Use |
|---|---|
| `slate-wordmark.svg` | "slate." wordmark, white on transparent |
| `slate-icon-ios.svg` | iOS app icon master: full-bleed black, the system applies the mask |
| `slate-icon-macos.svg` | macOS app icon master: black rounded tile on a transparent 1024 canvas |

The type is **Figtree Black (weight 900)**, converted to outlines, so the SVGs render identically
without the font installed.

## The shipped app icon: `SlideshowApp/AppIcon.icon`

The app icon is an Icon Composer document: a solid black fill plus one vector layer, the white
wordmark (`Assets/slate-wordmark-1024.svg`, i.e. `slate-icon-ios.svg` without its background).
Xcode compiles it into every rendition (iOS light/dark/tinted, the macOS icon, and an
`AppIcon.icns` for older macOS). Glass, translucency, and shadow are off for the layer, so the
wordmark stays flat white.

Recent macOS versions fit every icon into the system's rounded-square shape. The earlier PNG icon,
a black rounded tile inside a transparent margin, was shrunk onto a light grey plate in the Dock.
Icon Composer icons are drawn in the system shape, so they don't get that plate. The
`slate-icon-macos.svg` master is kept for reference only. The wordmark is optically centred in the icons: halfway between
its outline centre and its x-height centre, so the lowercase body reads as centred.

Figtree © 2022 The Figtree Project Authors, licensed under the SIL Open Font License 1.1
(see `Figtree-OFL.txt`).
