# Project Environment

- Native iOS SwiftUI app at `poser.xcodeproj`; target and scheme are `poser`.
- Bundle identifier: `space.concurrent.poser`; development team: `V2P38BF2T2`.
- iPhone-only, portrait, minimum iOS 17.0. SwiftData is the metadata store; image bytes live under Documents.
- Reference implementation: `/Users/kat/Dev/Poser-react` (Expo/React Native). Its `src/app` screens and `src/components` files are the behavioral/pixel source of truth.
- Simulator build: `xcodebuild -project poser.xcodeproj -scheme poser -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- No unit/UI test target currently exists. Real camera validation requires a physical iPhone.
- Environment re-inspected on 2026-07-16: this is a native iOS project (not React Native/Expo),
  with no Metro server, package manager, unit/UI test target, lint task, formatter task, or CI workflow.
- Argent MCP device tools are available; prefer the booted iPhone simulator for UI validation.

# Performance Invariants

- **Nothing touches `AVCaptureSession` on the main actor.** Device discovery, opening an input,
  and `commitConfiguration` cost hundreds of milliseconds on a real phone. `CameraController`
  configures, switches, and starts the session on `sessionQueue` and the main actor only awaits
  the result. Configuring inline on the main actor is why the app used to open frozen — every
  control was dead until AVFoundation finished. `session` is only safe to read on that queue,
  which is why configuration is tracked by `isConfigured`/`configuration` rather than by
  inspecting `session.inputs`. Overlapping starts must keep sharing one `configuration` task:
  two attempts add the same inputs twice and the session refuses them.
- **Camera zoom is expressed in Apple-style display factors.** Back-camera discovery prefers the
  Triple/Dual-Wide/Dual virtual devices so AVFoundation can switch physical lenses continuously.
  On iOS 18+ `displayVideoZoomFactorMultiplier` is the source of truth for labels. Always preserve
  `minAvailableVideoZoomFactor` as the lower bound because `systemRecommendedVideoZoomRange` can
  exclude the 0.5x ultra-wide lens; its upper bound may still cap impractical digital zoom. iOS 17
  derives the 0.5x multiplier from the ultra-wide-to-wide switch point. Raw device zoom and all
  `session.inputs` access stay on `sessionQueue`.
- **Built-in pose sources are read from the app bundle, never copied into Documents.**
  `persistBundledOverlay` copies only the small prepared JPEG; `sourceFileName` gets a
  `bundle:`-prefixed resource name that `resolvedOverlaySourceURL` resolves against `Bundle.main`
  for both display and reframe saves. Never construct a Documents source path directly from a
  bundle-prefixed filename. The sources are read-only and permanent, so duplicating them adds disk
  use and a long first-launch stall for nothing. Legacy sources are PNGs; expanded-catalog sources
  are optimized full-size JPEGs.
  Only read image headers (`imageDimensions(at:)`) from them.
- **Bundled pose catalog v10 contains 78 unique poses.** The 64 additions are tagged by people
  (`solo`, `duo`, `group`), subject (`f`, `m`, `pet`), vibe (`cute`, `cool`, `silly`, `dramatic`),
  and optional framing (`selfie`, `overhead`, `illusion`). The “Who is posing?” filter presents
  Solo, Duo, Group, F, M, and Pet together, but keeps people count, F/M, and Pet as separate logical
  filter groups so combinations such as F + Pet use AND semantics. Poses from the `mixed` intake
  folder carry both `f` and `m`; `puppy-recline-duo` carries `f` and `pet`. Built-in
  poses may provide a non-centred `cropCenter`; `party-photobomb` uses y=0.36 so the default 3:4
  frame includes the foreground subject and the kissing couple behind her, while
  `peekaboo-duo-selfie` uses y=0.64 to include both of the foreground girl's eyes. Catalog v9
  visually audited all 78 source/crop pairs and adds tuned vertical centers to 20 poses where the
  centered crop clipped hands, shoes, or a secondary face; keep each prepared JPEG synchronized
  with its source crop metadata whenever these centers change.
- **`LocalImageLoader` is not an actor, deliberately.** Image decoding is CPU-bound; a single
  actor executor serialized every thumbnail behind every other one, so the pose strip filled in
  one image at a time and one full-size pose guide blocked all the small ones. `NSCache` is
  already thread-safe. Keep decodes concurrent, keep the cache cost-bounded by decoded bitmap
  bytes, and keep `LocalFileImage` seeding its state from `cachedImage` so a cached image does
  not cost a frame of placeholder.

# UI Invariants

- **The camera viewfinder is edge-to-edge.** `CameraView` fills the entire screen with the
  preview (safe areas included) and floats the controls on top. Do not box it into a
  sensor-shaped rect (`width * 4/3` pinned below the top bar, or any similar "match the stock
  Camera app" framing) — that letterboxes the feed into black bars. This has been reintroduced
  and reverted several times; treat black bars around the preview as a bug, never a design.
- **A full-bleed preview does not cost you the 3:4 photo.** Aspect-fill scales the 3:4 sensor to
  cover the screen's *height*, so only its width spills off the sides. Boxing the preview is not
  needed to get 3:4 and never was.
- **`CaptureFrameMetrics` is the single definition of the capture frame** — full width, 3:4 tall,
  anchored 8pt below the top bar (`dropBelowSafeAreaTop` = bar padding + bar height + gap). The
  bar is a constant height on every device but the space around it is not, so this anchor is the
  one that means the same thing on every screen; a fixed offset from centre does not. `cameraTopBar`
  is laid out from the same constants, so the frame follows the bar rather than restating its size.
  The brackets, the pose guide, and the crop (`PreviewView.updatePhotoCrop`) all derive from this
  rect, so the photo is exactly the bracketed area. Never compute the on-screen frame and the crop
  separately: they drift, and the brackets then lie about what is photographed.
  - The overlay is laid out in **safe-area** coordinates and the preview in **full-screen** ones.
    The overlay therefore **measures** the rect it drew and publishes it in window coordinates
    (`CaptureFrameRectKey`); `PreviewView` converts that in, rather than recomputing the frame from
    its own bounds. One definition, measured — do not reintroduce a second computation to "simplify".
  - The crop is **pure geometry** (`CaptureFrameMetrics.photoCrop`), not
    `metadataOutputRectConverted`. The AVFoundation call needs a live preview connection and returns
    nothing before one exists; the old code then left the crop at its `.full` default and silently
    saved the **whole sensor**. `normalizedCaptureCrop` is now `Optional` and capture refuses rather
    than falling back to `.full` — a wrongly-framed photo looks perfectly normal on its own, so it
    must never be the silent default.
  - Crops are stated in **displayed image space** (post-EXIF-transform, as the user saw it) by every
    caller, so `renderCroppedJPEG` does not rotate them. It is x-symmetric and full-width, so
    front-camera mirroring is a no-op.
  - The rect maps to an exactly-3:4 sensor region, so ImageStore's `threeByFourPixelRect` is a
    no-op. If it ever stops being 3:4, that function will silently re-centre the crop: the photo
    would drift from the brackets while both still look plausible on their own.
  - Tight on small screens: space below the frame is ~85pt on an SE and ~102pt on an 8 Plus (vs
    ~207pt on a 15 Pro), so the pose strip and shutter overlap the bottom of the capture area there.
- **Never darken the area outside the capture frame.** `CaptureFrame` marks the 3:4 region with
  corner brackets alone. No scrim, no dim, no tint — the feed is edge-to-edge at full brightness
  everywhere, and a dimmed band top and bottom is exactly the look this screen must not have.
- **The pose guide is fixed to the capture frame and is not user-movable.** Its position is the
  promise about where the crop lands, so drag/pinch on the camera screen would break the only
  crop signal the user has. Poses are stored on a 3:4 canvas, so they fill the frame exactly.
  Changing the capture area is done by re-cropping the pose via "Reframe pose" in the pose library.
- **Collapsing the pose strip also collapses the zoom row.** Both controls share
  `referenceStripCollapsed` and animate out together; the single Show poses chevron restores both.
- **Ghost opacity uses SwiftUI's native `Slider` (0.15...0.75).** Keep the system control instead
  of rebuilding it with geometry and drag gestures: it supplies iOS 26 Liquid Glass styling,
  native accessibility/input behavior, and the correct fallback appearance on earlier iOS versions.
- **Hardware shutter events reuse the on-screen capture path.** On iOS 18+, CameraView registers
  `onCameraCaptureEvent`, captures only for the `.ended` phase, and disables the interaction while
  capture is busy or a modal is presented. This supports Camera Control and the system's other
  capture buttons only while the camera session is active; iOS 17 keeps the on-screen shutter only.
