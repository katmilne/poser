# Poser — App Overview

**App name:** Poser: Pose Camera
**Bundle ID:** `space.concurrent.poser`
**Platform:** iOS (iPhone, portrait only), minimum iOS 17.0
**Category:** Photo & Video

## What it is

Poser is a **ghost-pose camera app**. The person who wants to be photographed
picks a reference image — a pose they like from a screenshot, an old photo, or
saved inspiration — and Poser renders it **semi-transparent over the live
camera viewfinder** as a "ghost." Whoever is holding the phone lines the real
subject up with the translucent ghost, then taps the shutter.

The ghost is a framing guide only. The actual photo is captured through the
real camera pipeline (`AVCapturePhotoOutput`) — never a screenshot of the
screen. Saved photos are always clean, full-resolution, and contain no ghost
or UI overlay. The ghost's opacity briefly drops at the moment of capture as a
flourish, but the camera preview itself is never paused or frozen.

## Core screens

1. **Camera** — full-screen live viewfinder with the ghost overlay, flash and
   self-timer controls, a pose reference strip (recently-used poses,
   selectable/flippable), and the shutter.
2. **Onboarding** — a two-slide intro explaining the pose-matching concept and
   the clean-capture guarantee, ending in the camera-permission request.
3. **Pose library** — a 2-column board of the user's saved pose references,
   imported from Photos via the system picker. Poses can be tagged (who's
   posing / what's the vibe) and filtered. Reframing and deleting are
   supported.
4. **Album (Gallery)** — an animated "photo album" of the user's captured
   shots, 4 per page in a 2×2 grid styled as plastic-sleeve pockets. Supports
   tap-to-open lightbox, pull-out-of-pocket gesture, page turns, and
   long-press delete.
5. **Preview / Edit** — non-destructive decoration of a captured photo with
   frames (Hearts, Stars, Digicam, Sparkle) and stickers (a Y2K sticker set,
   custom cutout stickers, and text notes). Edits are composited only at
   share/save time; the original clean capture is never altered.
6. **Sticker Maker** — a subject-cutout tool (Apple Vision framework,
   `VNGenerateForegroundInstanceMaskRequest`) that turns a photo of a person
   or object into a transparent-background sticker for reuse in the editor.

## Monetization

Poser is free to use with two capped free-tier limits:

- 3 poses imported from Photos
- 3 custom cutout stickers

The camera, ghost-pose matching, album, and basic editing are free and
unlimited. Records created while under a free or lapsed-premium state are
never deleted — lapsing only removes the ability to create *beyond* the free
limits.

**Premium** ("Poser Premium") removes both caps and is offered via
auto-renewing subscriptions and a one-time purchase, sold through the Apple
App Store and managed with RevenueCat:

| Plan | Product ID | Price | Notes |
|---|---|---|---|
| Monthly | `space.concurrent.poser.monthly` | $1.99/month | Auto-renewing |
| Yearly | `space.concurrent.poser.yearly` | $9.99/year | Auto-renewing; eligible new subscribers get a 7-day free trial |
| Yearly (onboarding intro) | `space.concurrent.poser.yearly_intro30` | $9.99/year | Auto-renewing; eligible new subscribers get $0.99 for the first month, then $9.99/year |
| Lifetime | `space.concurrent.poser.lifetime` | $14.99 once | Non-consumable, permanent unlock |

The three subscription products share one Apple subscription group, so a
customer can redeem at most one introductory offer (trial or discounted
month) across them. A **Restore Purchases** action is available in Settings.
Purchase state is always verified against the RevenueCat `premium`
entitlement, not local flags or product IDs alone.

## Data & storage

- All photos, poses, and stickers are stored as files in the app's local
  Documents directory, indexed with SwiftData.
- The app has **write-only** access to the system Photos library (the
  "Add Photos Only" permission) to save captures out — it never requests or
  uses read access to the camera roll. Pose/sticker imports use `PHPicker`,
  which runs out-of-process and needs no permission grant.
- There is no user account, login, or server-side backend for app content.
  Nothing about a user's photos or poses leaves the device except purchase
  receipts (handled by Apple/RevenueCat), anonymous product-analytics events
  (Aptabase, opt-out in Settings), crash/error reports (Sentry, always on,
  content-free), and an optional decorated image the user explicitly shares
  or saves.

## Design

"Dreamy core: a bright, airy, pastel palette with translucent
Liquid Glass chrome (native `glassEffect` on iOS 26+, a translucent-material
fallback on iOS 17–25), continuous-curve corners, and Y2K sticker-charm
details throughout.

## Tech stack

- SwiftUI, SwiftData, AVFoundation (camera), Vision + Core Image (subject
  cutout), PhotosUI (`PHPicker`), CoreHaptics/UIFeedbackGenerator.
- Third-party SDKs, all wrapped behind `Analytics.swift` / `PremiumStore.swift`
  so feature code never touches them directly:
  - **RevenueCat** (`purchases-ios-spm`) for subscription/entitlement
    management.
  - **Aptabase** (`aptabase-swift`) for opt-out, low-cardinality product
    analytics (e.g. photo captured, pose imported, purchase completed) — no
    photo content or file paths ever leave the device.
  - **Sentry** (`sentry-cocoa`) for always-on crash/error reporting, tagged by
    feature area (e.g. `camera_capture`, `photo_library_save`). Configured
    with `sendDefaultPii = false` and no session replay.
