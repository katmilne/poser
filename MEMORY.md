# Project Environment

- Native iOS SwiftUI app at `poser.xcodeproj`; target and scheme are `poser`.
- Bundle identifier: `space.concurrent.poser`; development team: `V2P38BF2T2`.
- iPhone-only, portrait, minimum iOS 17.0. SwiftData is the metadata store; image bytes live under Documents.
- Reference implementation: `/Users/kat/Dev/Poser-react` (Expo/React Native). Its `src/app` screens and `src/components` files are the behavioral/pixel source of truth.
- Simulator build: `xcodebuild -project poser.xcodeproj -scheme poser -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- No unit/UI test target currently exists. Real camera validation requires a physical iPhone.
- Argent CLI is installed, but Argent MCP device tools were not exposed in the 2026-07-14 session.

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
