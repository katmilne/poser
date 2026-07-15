# POSER — Native iOS (SwiftUI) Port

## Your task

Build **POSER** as a native iOS app in Swift/SwiftUI, from scratch, in this
repository (`/Users/kat/Dev/poser`). This is a **rewrite, not a wrapper** — do
not embed React Native or a web view. The existing app is a working Expo/React
Native app at `/Users/kat/Dev/Poser-react`; treat it as the **product
specification and reference implementation**. Read it whenever a behavior is
ambiguous. This document captures everything you need, but the RN source is the
source of truth for exact pixel values, copy, and interaction details.

The Xcode project is already scaffolded here:
- `poser.xcodeproj` — bundle id `space.concurrent.poser`, Swift 5, team
  `V2P38BF2T2`. **The scaffold currently targets iOS 26.5 — lower the
  deployment target to iOS 17.0** (see below).
- `poser/poserApp.swift`, `poser/ContentView.swift` — placeholder SwiftUI hello-world.
- `poser/Assets.xcassets` — empty asset catalog.

**Minimum deployment target: iOS 17.0**, for device reach. This has one major
consequence: **native Liquid Glass (`glassEffect` / `GlassEffectContainer`) is
iOS 26+ only.** So the glass chrome must be written as a **capability-gated
component**: use real Liquid Glass when running on iOS 26+, and fall back to a
tasteful translucent material (`.ultraThinMaterial`/`.regularMaterial` with the
milky glass edge and tint) on iOS 17–25. This mirrors what the RN app already
does — `native-glass.tsx` checks `isLiquidGlassAvailable()` and renders a plain
translucent `View` otherwise. Build one `GlassSurface` component with the
`if #available(iOS 26, *)` split inside it, and every screen just uses that.
The Vision subject-cutout requires iOS 17+, which the floor satisfies.

## Why we are doing this port

The React Native version works but is limited by the framework. The native
rewrite exists to fix exactly these things — treat them as the **priorities**:

1. **Performance** — interaction is not smooth in RN. Gallery open/close
   animations, page turns, gesture-driven drags, and camera transitions must be
   buttery at 120fps on ProMotion. This is the #1 reason for the port.
2. **First-class Liquid Glass** — the app's entire chrome is built on glass. RN
   goes through `expo-glass-effect`, a thin bridge. Native `glassEffect` /
   `GlassEffectContainer` (iOS 26) must be used directly and richly **on iOS
   26+**, with a translucent-material fallback on iOS 17–25 (see the deployment
   note above). Heads-up: this goal is why the minimum-iOS choice matters —
   users below iOS 26 get the fallback, not true Liquid Glass.
3. **First-class camera** — use `AVFoundation` directly for full control over
   the capture pipeline, preview, exposure, and clean full-resolution stills.
4. **Gestures, haptics, animation** — use SwiftUI gestures, `CoreHaptics` /
   `UIFeedbackGenerator`, and native SwiftUI animation/`matchedGeometryEffect`
   so the physical, tactile feel is better than RN could deliver.
This is an **iOS-only** app (iPhone, portrait). There is no Android target and
no map feature — ignore any Android code paths in the RN reference.

When a native API offers a better version of an interaction than the RN code
did, **prefer the native idiom** — do not slavishly reproduce RN workarounds
(e.g. the RN "camera ready" 650ms black-frame guard exists because of RN's
mount timing; solve the underlying problem the native way). Preserve the
*experience*, not the *implementation*.

---

## What POSER is

A **ghost-pose camera app**. The person who wants to be photographed picks a
**pose reference image** (a screenshot, an old photo, saved inspiration). That
image renders **semi-transparent over the live camera viewfinder** as a
"ghost." They hand the phone to whoever is taking the picture, and the
photographer simply lines the real subject up with the translucent ghost, then
taps the shutter.

**Critical rule: the ghost is a framing guide ONLY.** The actual photo is
captured through the real camera capture pipeline (`AVCapturePhotoOutput`),
**never a screenshot of the screen**. Saved photos are always clean,
full-sensor-resolution, and contain no ghost, no UI, no overlay. The ghost
briefly hides at the moment of capture as a flourish, but that only affects the
overlay's on-screen opacity — it must never pause or freeze the camera preview
(a paused preview captures a black frame).

A separate, optional **decorated share copy** (frames + stickers) is a
composited image made on the preview/edit screen — that one *is* a render, kept
entirely distinct from the clean capture.

---

## Design system ("Gelboys" aesthetic)

Bright, airy, candy-sticker aesthetic inspired by the TV show *Gelboys*. Soft
sunlit-cloud palette, translucent Liquid Glass chrome, glossy jelly buttons,
Y2K sticker charms. Port the design tokens from
`Poser-react/src/theme/tokens.ts` into a Swift `Theme`/`Tokens` enum. Key
values:

**Colors** (sRGB hex):
- Backgrounds: `bg #F6FAFE`, `bgDeep #E3EDF9`, `cream #FFFDF9`, `linen #F3EFE6`,
  `cloud #FFFFFF`, `mist #EAF2FB`
- Ink/text: `ink #111318`, `black #090A0D`, `textDim rgba(17,19,24,0.50)`,
  `disabled rgba(17,19,24,0.24)`, `outline rgba(17,19,24,0.12)`
- Candy accents: `hotPink #D9B8CF`, `tangerine #D8BD91`, `lime #E5EAD8`,
  `sky #D7E8F6`, `cyan #DCEEEE`, `lemon #F4EACF`, `grape #DFDDF0`,
  `electricBlue #7C9CB9`, `denim #65798D`, `recRed #DF6B68`
- Glass tints: `glassSelected rgba(219,233,248,0.34)`,
  `glassEdge rgba(255,255,255,0.72)`, fallback `rgba(255,255,255,0.76)`

Note: this palette is deliberately **desaturated/pastel** in the current build
(the "bright bubblegum pink" of the show is toned down to a dusty
`#D9B8CF`). Match what's in `tokens.ts`, not the show literally.

**Spacing:** xs 4, sm 8, md 12, lg 16, xl 24.
**Radius:** sm 14, md 20, lg 30, pill 999. Use **continuous corner curve**
(`RoundedRectangle(cornerRadius:style:.continuous)`) everywhere — every RN
surface sets `borderCurve: 'continuous'`.

**Shadows:**
- `StickerShadow`: `0 8px 24px rgba(44,61,78,0.08)` (diffuse blue-grey depth)
- `CharmShadow`: `0 3px 12px rgba(44,61,78,0.07)` (small floating controls)
- `StickerBorder`: 1px `rgba(255,255,255,0.88)` milky rim on cards/sleeves

**Typography:** the RN app uses the **system font** throughout (`System`).
Reproduce with SF Pro / `.system`. HUD/digicam elements (REC, timestamps) use a
monospaced/terminal feel — use a monospaced system font or SF Mono for those.
Weights and sizes are specified inline in each RN screen's `StyleSheet` — match
them.

**Do NOT** reintroduce vector human-pose silhouettes. The user explicitly
removed those in favor of user-uploaded photos. Poses are always real images.

### Liquid Glass usage

Chrome is built from three reusable glass primitives (see
`Poser-react/src/components/native-glass.tsx`) — build native SwiftUI
equivalents:

- **GlassSurface** — a container with the glass effect (clear style, light
  color scheme, optional tint, optional interactive). All floating panels,
  pills, capsules, and circular buttons are built on it.
- **GlassIconButton** — a circular glass button wrapping an **SF Symbol**
  (default 46pt, symbol ~0.43× the button). A `selected` state applies the
  `glassSelected` tint. Fires a **selection haptic** on press.
- **GlassTextButton** — a glass capsule (48pt tall, pill radius) with a bold
  label; a `compact` variant is 36pt. `selected` tint + selection haptic.

Also build a **GhostOpacityBar** — a long thin (14pt) interactive glass bar
with a fill sweeping in from the left plus a bright meniscus line; dragging
sets ghost opacity 0.15–0.75, and a **selection tick haptic** fires when
crossing the 0.40 default detent.

On **iOS 26+**, use `GlassEffectContainer` to group nearby glass elements and
get correct blending/morphing, and prefer real interactive glass
(`.glassEffect(...)`, `.buttonStyle(.glass)` where appropriate). On **iOS
17–25**, fall back to `.ultraThinMaterial`/`.regularMaterial` inside the same
`GlassSurface` component, keeping the milky `glassEdge` border, continuous
corners, and `glassSelected` tint so the look degrades gracefully rather than
breaking. Put the `if #available(iOS 26, *)` branch **inside** `GlassSurface`
so call sites stay clean.

### SF Symbols used (map these to the icon buttons)

`bolt` / `bolt.slash` (flash), `timer`, `arrow.triangle.2.circlepath` (flip
camera), `photo.on.rectangle` (album), `xmark`, `chevron.up`,
`square.grid.2x2`, `wand.and.sparkles` (edit), `square.and.arrow.up` (share),
`square.and.arrow.down` (save), `trash`, `camera.fill`, `photo`,
`photo.on.rectangle.angled`, `camera.aperture`.

### Background motif

Two backgrounds recur:
- **SkyBackground** (`sky-background.tsx`) — a pale vertical gradient
  (`#FFFFFF → #F6FAFE → #E3EDF9`) with soft white cumulus clouds (built from
  overlapping circles + capsule bodies, each with a faint blue-grey shadow puff
  underneath for volume). A `quiet` variant fades it to 55%. Recreate with
  SwiftUI shapes/gradients (or a single asset — your call, but keep it light
  and airy, never grey/murky).
- **cloud-background.png** — a raster cloud image used full-bleed behind the
  album. Copy `Poser-react/assets/images/cloud-background.png` into the asset
  catalog.

---

## App structure & navigation

Five screens (RN uses expo-router; you'll use SwiftUI navigation +
full-screen covers/sheets). Root gate: if not onboarded → Onboarding.

| Route | Presentation | Purpose |
|-------|-------------|---------|
| `index` | root | **Camera** — the main viewfinder + ghost |
| `onboarding` | replaces root, no swipe-back | 2-slide intro + camera permission |
| `preview` | full-screen cover, no swipe-dismiss | **Edit** — decorate a just-taken or existing shot |
| `gallery` | full-screen cover | **Album** — slip-in photo album of shots |
| `poses` | sheet/modal | **Pose library** — manage & pick pose references |

Global: light status bar on camera, dark elsewhere; portrait only. **Every
photo surface and the viewfinder are locked to 3:4** (`VIEWPORT_ASPECT = 3/4`,
the iPhone portrait sensor shape) so the preview shows exactly what the capture
saves.

---

## Screen specs

### 1. Camera (`src/app/index.tsx`) — the heart of the app

Full-bleed 3:4 camera preview with floating glass chrome over it.

**Top bar:** a "POSER" wordmark in a glass pill (left); flash toggle
(off→auto→on, `bolt.slash`/`bolt`) and self-timer toggle (0→3→10s, `timer`) as
glass icon buttons (right). Selected state tints the glass.

**Bottom bar:** flip-camera button (left), the **shutter** (center), album
button (right). The shutter is a large (92pt) glass circle with a layered
translucent halo/inner-ring/dot; it presses to 0.94 scale and is disabled until
the camera is genuinely ready to produce a non-black frame.

**Pose ref strip** (`ref-strip.tsx`) — a floating glass panel above the bottom
bar showing recently-used pose thumbnails (52pt rounded tiles) in a horizontal
scroll, with a grid button that opens the full pose library. A grabber collapses
it to a single up-chevron. When a pose is selected, the **GhostOpacityBar**
appears inside the panel.
- Tapping a thumb **cycles**: select as ghost → tap again mirrors/flips it →
  tap again removes it from the viewfinder. The active thumb has an ink border;
  flipped thumbs render mirrored.
- Long-press a thumb → confirm-delete (original stays in Photos).

**Ghost overlay** (`ghost-overlay.tsx`) — the selected pose image drawn
**cover-fit** across the viewport (so no empty bands regardless of aspect),
semi-transparent at the user's chosen opacity. It is manipulable directly on
the viewfinder:
- **Pan** (1 finger) — move it, clamped to ±60% of viewport.
- **Pinch** — scale it, clamped 0.4×–2.5× of the base cover-fit size.
- **Double-tap** — snap back to default position/scale, with a **medium impact
  haptic**.
- Horizontal flip via the ref-strip tap-cycle (mirrored state).
- The overlay is **non-interactive to touches itself**; gestures are attached
  to the viewport around it. It ignores capture — hidden at shutter time via
  opacity only.

**Capture flow** (get this exactly right — see AGENTS.md notes):
1. Guard against double-fire (a synchronous busy lock).
2. If a timer is set, count down (3 or 10s), showing a big countdown number in
   a glass circle with "HOLD THAT POSE", firing a **selection haptic** each
   second.
3. Fire a **medium impact haptic**, hide the ghost overlay (opacity only —
   **never pause the preview**).
4. Capture a clean full-resolution still via `AVCapturePhotoOutput`
   (front camera output should be **mirrored** to match the mirrored preview).
5. Save the clean file into app-local storage (`shots/`), index it, and
   navigate to the **preview/edit** screen.
6. **After** the transition (off the critical path), copy the photo to the
   system camera roll (write-only permission — see Permissions). If that's
   denied, keep the app-local copy and tell the user it's safe inside POSER.
7. On any failure, show a friendly alert naming the phase that failed.

**Permission states:** if camera denied, show a glass card ("CAMERA TIME") with
an ALLOW CAMERA / OPEN SETTINGS button. Handle "permanently denied" → deep-link
to Settings.

The RN version has an elaborate "camera ready" gate (`onCameraReady` +
650ms settle) to avoid capturing a black frame right after mount/flip on iOS.
With AVFoundation you control the session directly — solve this properly:
enable the shutter once the capture session is running and the first frame has
been produced, disable it during camera switches.

### 2. Onboarding (`onboarding.tsx`)

Two slides over the SkyBackground, "Poser" wordmark at top. Slide 1:
`photo.on.rectangle.angled` symbol, "Match the pose." — *"Choose a reference
photo. It floats over the camera so anyone can line up the shot."* Slide 2:
`camera.aperture` symbol, "Clean photos, always." — *"The guide disappears
before capture. Your full-resolution photo stays clean and on your phone."*
Page dots (active dot elongates). Button reads "Continue" then "Allow Camera";
the final tap requests camera permission and marks onboarded. Persist the
onboarded flag (see settings).

### 3. Pose library (`poses.tsx`)

A 2-column image-first board of the user's pose references over SkyBackground.
- First tile is always **"Add pose · From Photos"** — opens the system photo
  picker (`PHPickerViewController`, multi-select, ordered). Picked images are
  copied into app-local `overlays/`.
- Each pose tile: tap → select it as the camera ghost and return to camera;
  long-press → action sheet (Edit tags / Delete).
- **Tag filter rail**: two tag groups — "Who is posing?" (Solo/Duo/Group) and
  "What is the vibe?" (Cute/Cool/Silly). An "All" chip clears filters. Filters
  are ANDed. Chips are compact glass text buttons.
- **PoseTaggingFlow** (`pose-tagging-flow.tsx`): after importing new poses, a
  focused full-screen sequential tagging pass — one pose at a time, shows the
  photo, one required choice per group, "Next pose"/"Done". Can be dismissed to
  tag later.

### 4. Album / Gallery (`gallery.tsx`) — the showpiece animation

This is the most animation-heavy screen and a major reason for the native port.
It's a **real slip-in photo album** metaphor:

- Photos are laid out **4 per page** in a 2×2 grid, each slotted into a
  plastic-sleeve **pocket** on a cardstock page. Page aspect ~0.75, centered,
  max width 640.
- **Photo tiles** (`photo-tile.tsx`, `instax-print.tsx`) are clean 3:4 prints
  with a glossy plastic-sleeve finish (milky rim, glare streaks, glints).
- **Header:** an "ALBUM" glass pill with a live count; an `xmark` close button.
  *(TODO from the user: make the album/close buttons clearer than plain white.)*
- **Footer:** a page counter `01 / 03`.

**Interactions (all must be 120fps-smooth):**
- **Tap** a photo → it grows from its pocket into a full-screen lightbox
  (`matchedGeometryEffect` is the natural native tool here; the RN version
  hand-animates a transform-around-a-pinned-rect to avoid re-decodes).
- **Pull up** a photo → it slides up out of its plastic sleeve; the print is
  split across two clipped layers (one behind the pocket plastic, one in the
  open air above it) so it reads as one photo crossing the sleeve opening. Let
  go past ~90px and it pops free into the lightbox; let go early and it drops
  back into the pocket. Threshold crossings fire a **selection tick haptic**;
  settling fires a **rigid impact**.
- **Swipe sideways** (album, not lightbox) → turn the page. The outgoing grid
  stays put; incoming (preloaded) photos **pop into place in a short stagger**
  (each tile inflates like a soft bubble: translateY + scale overshoot to 1.045
  + slight rotate). Fires a settle haptic.
- **In the lightbox:** horizontal paging between all shots; **flick down** to
  toss it closed (fades + flies off, ~640px, past 150px or velocity > 1000);
  or the close button slides it **back into its exact origin pocket** (only if
  it's still the same photo that was opened — otherwise it just shrinks away in
  place).
- **Long-press** a photo → confirm delete (only the in-app copy; the camera
  roll keeps its own). Fires a wiggle animation + medium impact.

**Lightbox chrome:** a footer with close (`xmark`), edit (`wand.and.sparkles`),
save-to-camera-roll (`square.and.arrow.down`), a counter, and delete (`trash`).
If the shot was taken with a ghost, a small **"USE GHOST"** glass button
(top-right) re-selects that pose and returns to the camera.

**Animation curves:** the RN version deliberately uses **ease-out timing, never
springs**, for the pocket slide (a spring overshoots; a photo sliding out of a
sleeve should decelerate under one continuous motion). `GLIDE =
easeOut(cubic)`, `SETTLE = easeInOut(cubic)`. Respect that feel — use springs
only where a bubble-pop overshoot is intended (page-turn tile pop, tap-press
scale).

**Performance note carried from RN:** full-sensor captures are huge (tens of
MP). The RN app generates a **downscaled ~1600px display copy** per shot and
renders that everywhere on-screen, reserving the full-res original only for
save/share. Preserve this: display/thumbnail surfaces use a downscaled copy;
export uses the original (or the flattened decorated version). On iOS you can
lean on `PhotosPicker`/`ImageRenderer`/thumbnail generation, but keep the
principle — never decode full-res files into the grid.

### 5. Preview / Edit (`preview.tsx`)

Opened right after capture and from the album's edit button. Non-destructive
sticker/frame decoration over the 3:4 photo, on a SkyBackground (quiet).

**Composite target:** photo (cover-fit) + optional frame + sticker layer. This
exact view is what gets rendered to an image for share/save (use `ImageRenderer`
at a fixed export size, e.g. 1536×2048 for 3:4). Keep the composite's bounds
square-cornered so every corner pixel of the 3:4 photo survives the render.
*(User TODO: adding stickers must NOT crop the photo's corners — verify the
render preserves them.)*

**Tools tray** (toggled by `wand.and.sparkles`):
- **Frames** (`frames.tsx`): None, **Hearts**, **Stars**, **Digicam**,
  **Sparkle**. Full-bleed decorative edge ornaments with transparent centers.
  The **Digicam** frame has corner brackets, a pulsing "● REC" indicator, a
  battery glyph, and a live retro **timestamp HUD** (`hud.tsx`, format
  `'YY MM DD  AM H:MM`) in amber.
- **Stickers** (`stickers.tsx`): a Y2K vector set — star, sparkle, heart,
  smiley, butterfly, flame, bolt, CD, "2000", "xoxo", flower charm, marker
  scribble, speech bubble ("NO BAD ANGLES"), safety pin, "STATUS: ICONIC" pixel
  note. Each is an SVG drawn in a 100×100 box with a default scale relative to
  photo width. **Port these to SwiftUI `Path`/`Shape` + `Canvas`** (or bundle
  as vector assets). Each dropped sticker lands slightly offset from the last.
- **Text notes**: an "Aa" button opens a text-entry sheet (max 48 chars) that
  drops an editable cream sticky-note sticker.
- **Custom stickers ("Make a sticker")**: opens the **StickerMaker** →
  see Native Features. Saved cutouts appear in the tray; long-press to delete.

**Placed stickers** (`sticker-canvas.tsx`): each sticker is independently
draggable (pan), resizable (pinch, 0.3×–4×), and rotatable (rotation gesture),
all **simultaneously**. Tap to select → shows a dashed Y2K marquee + a remove
badge, and a bottom toolbar with FLIP and DELETE ("PINCH TO RESIZE · TWIST TO
ROTATE"). Transforms are stored **normalized to the 3:4 canvas** so an edit
reopens identically at any screen size. Selection chrome must be cleared before
rendering the export.

**Actions row:** edit-toggle (`wand.and.sparkles`), **share**
(`square.and.arrow.up`), **save decorated copy** (`square.and.arrow.down`,
enabled only when decorated).
- **Share**: if undecorated, share the clean original file directly
  (full-res). If decorated, render the composite to a temp JPEG and share that.
  Use the native share sheet (`UIActivityViewController`).
- **Save decorated copy**: render composite → save to camera roll (write-only
  permission), with success/warning haptics + alert.
- Closing the editor persists the edit recipe (cheap JSON) **and** a flattened
  "decorated preview" JPEG used by the album (so the album shows the decorated
  version in-place). *(User TODO: also let users download plain album images,
  burning in stickers, asking permission first — this is the save path.)*

Edits are saved to JSON after every meaningful change (crash-safe), and the
flattened preview is regenerated on close.

---

## Data & persistence

**Use SwiftData for the index/metadata** (`@Model` records + `@Query` in
views), while the **images always live as plain files on disk** in the app's
document directory (SwiftData stores only the metadata + filenames, never the
image bytes). The RN app used plain JSON index files instead — treat that as
the schema reference (same fields), but model each record as a SwiftData
`@Model` class so the album/pose/sticker views update reactively and the pose
tag filters become simple `@Query` predicates. Newest-first ordering via sort
descriptors on `takenAt` / `addedAt` / `createdAt`.

Keep the image-file layout below exactly as-is regardless — SwiftData replaces
only the four `*.json` index files.

Directory layout (under `Documents/`):
- `shots/<id>.jpg` — clean full-res captures. `shots/display/<id>.jpg` —
  downscaled display copies. `shots/decorated/<id>-decorated-<ts>.jpg` —
  flattened decorated previews. `shots/ghosts/<id>.<ext>` — preserved pose
  reference for each shot.
- `overlays/<id>.<ext>` — imported pose reference images.
- `stickers/<id>.png` — custom subject-cutout stickers (transparent PNG).
- The four RN index files (`shots.json`, `overlays.json`, `stickers.json`,
  `settings.json`) are **replaced by SwiftData `@Model` types** — one model per
  record kind below. `settings` (just the `onboarded` flag) can be a single
  SwiftData record or `@AppStorage`; your call.

**Models** — model each as a SwiftData `@Model`; the RN files (`lib/shots.ts`,
`lib/overlays.ts`, `lib/custom-stickers.ts`, `lib/settings.ts`) give the exact
fields. `ShotSticker` is a value type serialized inside a shot's edits (store
it as a `Codable` array attribute on the shot's edit model, not its own table):

- **ShotRecord**: `id, fileName, decoratedFileName?, facing (front|back),
  takenAt, width, height, ghost?: {overlayId, fileName, width, height},
  edits?: {frameId, stickers[], updatedAt}`. The **ghost reference is copied
  independently** so album history survives if the pose is later deleted from
  the library.
- **ShotSticker** (serializable, normalized): `key, stickerId, customStickerId?,
  imageAspectRatio?, flipped?, text?, cx, cy, offsetX?, offsetY?, scale?,
  rotation?`.
- **OverlayRecord** (pose): `id, fileName, addedAt, width, height, tags[],
  lastUsedAt?`. Newest-first; `listRecentOverlays` returns those with a
  `lastUsedAt`, most-recent first (drives the camera ref-strip).
- **CustomStickerRecord**: `id, fileName, createdAt, width, height`.
- **Settings**: `{ onboarded?: bool }`.

Handle the small handoffs the RN app does via module caches: "picked a pose in
the library, ghost it back on the camera" and "use ghost from this album photo."
In SwiftUI these become normal state/observable-object bindings — cleaner than
the RN one-shot cache.

---

## Native features (use the platform directly)

### Camera — AVFoundation
- `AVCaptureSession` with a `AVCapturePhotoOutput`, 3:4 still capture, a
  SwiftUI preview layer (`AVCaptureVideoPreviewLayer` via
  `UIViewRepresentable`, or the newer SwiftUI camera preview APIs).
- Front/back switching, flash on/auto/off, mirror the front-camera output to
  match the mirrored preview.
- Full-resolution clean stills — no screenshots, ever.
- Never freeze the preview at capture time.

### Subject cutout — Vision (directly reusable)
The RN app already ships a native Swift module doing exactly what you need:
`Poser-react/modules/subject-cutout/ios/SubjectCutoutModule.swift`. It uses
`VNGenerateForegroundInstanceMaskRequest` + `generateMaskedImage(...,
croppedToInstancesExtent: true)` and writes a cropped transparent PNG via
`CIContext.writePNGRepresentation`. **Lift this logic almost verbatim** into a
Swift helper (drop the Expo `Module` wrapper; keep the Vision/CoreImage core).
Notes carried over:
- Requires iOS 17+ (always true at your deploy target).
- Downscale the source to a **2048px long edge before** running Vision —
  passing a 12–48MP capture straight in exhausts memory. Use `autoreleasepool`,
  `cacheIntermediates: false`, `applyOrientationProperty: true`.
- Throw a clear "no subject found" error the UI can surface.

**StickerMaker UI** (`sticker-maker.tsx`): a full-screen "CUTOUT CAMERA" —
take a photo or pick one, preview it in a 3:4 surface, "CUT IT OUT" runs the
Vision cutout (with a "LIFTING THE SUBJECT…" scrim), saves a reusable
transparent sticker, and drops it onto the current edit. Same clean-capture
rules as the main camera.

### Haptics
Port the RN haptic vocabulary (the RN code has Android haptic variants too —
**ignore those, iOS only**). Map `expo-haptics` → `UIImpactFeedbackGenerator` /
`UISelectionFeedbackGenerator` / `UINotificationFeedbackGenerator`, or
`CoreHaptics` for richer effects:
- **Selection** — button taps, thumb cycling, tag choices, tick when crossing a
  threshold/detent (opacity default, pull threshold, page change).
- **Medium impact** — shutter fire, ghost double-tap reset, destructive-intent
  long-press.
- **Soft impact** — drag start. **Rigid impact** — settle into place.
- **Success/Warning notification** — save-to-roll result, cutout success.

### Gestures
Native SwiftUI gestures throughout: simultaneous pan+pinch (ghost, stickers add
rotation), double-tap, drag-with-threshold (album pull + lightbox dismiss),
horizontal paging, long-press. This is where the "not smooth" RN feel gets
fixed — make these feel physical and immediate.

### Photos & permissions
- **Write-only** photo-library access only (`PHPhotoLibrary` add-only
  authorization → the lightweight "Add Photos Only" prompt). The app **never
  reads the camera roll** and must not request read permission. The in-app
  gallery reads only app-local copies.
- Pose/sticker image picking uses **PHPicker** (out-of-process, needs no
  permission).
- Camera permission via `AVCaptureDevice` authorization.
- Add `Info.plist` usage strings (camera; add-photos). Copy the friendly copy
  from `Poser-react/app.json`.

---

## Assets to carry over
From `Poser-react/assets/images/`: `cloud-background.png` (album backdrop),
`icon.png` / the app icon set, `splash-icon.png`. Build a launch screen /
splash matching the `#F8FAFC` background. The rest of the RN assets (react
logos, tab icons, expo badges) are template cruft — **ignore them**.

---

## What to preserve vs. improve

**Preserve exactly:** the ghost-guide concept and clean-capture guarantee; the
3:4 lock; the pose/ghost cycling interaction; the album metaphor and its
gesture set; the sticker/frame set and non-destructive edit model; the
write-only-photos privacy stance; all user-facing copy and the friendly tone;
the pastel Gelboys palette and glass chrome; the animation *feel* (ease-out
pocket slides, bubble-pop page turns).

**Improve (the point of the port):** raw smoothness/frame rate; use real Liquid
Glass and `matchedGeometryEffect`; a properly managed AVFoundation session
instead of RN's black-frame timing hacks; native gesture/haptic fidelity;
memory behavior around large captures.

**Known TODOs from the user** (`Poser-react/TODO.md`) — fix these in the port:
1. Adding stickers must not crop the photo's corners.
2. Album header/close buttons should be clearer, not plain white.
3. Let users download album images (burning in stickers), asking photo
   permission first.

---

## Suggested build order
1. Theme/tokens, glass primitives (GlassSurface / icon / text buttons), haptics
   helper, SkyBackground.
2. Persistence layer (SwiftData `@Model`s for shots/overlays/stickers + the
   image-file directory helpers; onboarded flag).
3. Camera screen with AVFoundation capture → save → basic album list. Prove the
   clean-capture pipeline first.
4. Ghost overlay + pose ref-strip + opacity bar + gesture manipulation.
5. Pose library + PHPicker import + tagging flow.
6. Preview/Edit: frames, vector stickers, text notes, placed-sticker gestures,
   composite render + share/save.
7. Subject-cutout module + StickerMaker.
8. Album showpiece animations (pocket pull, matched-geometry lightbox, page-turn
   stagger, flick-to-dismiss).
9. Onboarding + permission flows + polish pass on haptics/animation timing.

Refer back to the RN source constantly for exact numbers, copy, and edge-case
handling — every screen file has detailed inline comments explaining *why* each
interaction works the way it does.

---

## Decisions locked in
- **iOS only** (iPhone, portrait). No Android, no map feature — ignore the RN
  app's Android/web code paths.
- **Minimum iOS 17.0.** Liquid Glass is gated to iOS 26+ with a
  translucent-material fallback on 17–25, inside a single `GlassSurface`
  component. (Trade-off acknowledged: users below iOS 26 get the fallback, not
  true Liquid Glass.)
- **Persistence: SwiftData** for index/metadata; images stay as plain files on
  disk. (See Data & persistence.)
