# App Store Submission Readiness — Poser

Static audit of the Xcode project, build settings, and Swift source for anything
that could block or trigger rejection at Apple review. Native SwiftUI app, no
simulator run required for this pass.

## 🔴 Likely to block or trigger rejection

### 1. No functional Privacy Policy / Terms of Use links in-app (Guideline 3.1.2)

The app sells auto-renewing subscriptions, which makes working links to a
Privacy Policy and Terms of Use (EULA) mandatory *inside the app*, not just in
the App Store listing. Right now:

- `PRIVACY_POLICY.md` and `TERMS_OF_USE.md` exist only as local markdown files
  — not hosted at a public URL.
- `poser/SettingsSheet.swift:244` just says "...see Privacy Policy" as plain
  text — no `Link`/`openURL`, nothing tappable anywhere in the app.
- `poser/PaywallView.swift` (where Apple looks hardest) has zero policy links.

**Fix:** host both docs at real URLs, add tappable `Link`s in Settings (and
ideally near the paywall's purchase button), and enter the Privacy Policy URL
in App Store Connect's app + subscription-group metadata.

### 2. No `PrivacyInfo.xcprivacy` manifest on the app target

The app directly calls `UserDefaults` in three places
(`poser/Analytics.swift:23-24`, `poser/PremiumStore.swift:105-106`,
`poser/ContentView.swift:293`) — a "required-reason" API — plus it links
RevenueCat, Sentry, and Aptabase, all of which Apple's binary-upload static
analysis inspects. With no manifest declaring a reason, App Store Connect can
generate an `ITMS-91053` warning or hold the build at review. Cheap to fix,
worth doing before archiving for submission.

## 🟡 Worth fixing, not fatal

### 3. No `ITSAppUsesNonExemptEncryption` declared

Without it, every submission stops for a manual export-compliance question in
App Store Connect. Since the app only uses standard TLS (no custom crypto —
confirmed no CryptoKit/CommonCrypto usage), add
`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` to both build configs to
skip that prompt.

### 4. No shared Xcode scheme

`xcshareddata/xcschemes` is empty. Fine for archiving manually from Xcode's
GUI (it self-manages a scheme), but blocks any `xcodebuild`/Fastlane/CI-based
archive-and-upload path.

## ✅ Checked and fine

- Camera (`NSCameraUsageDescription`) and Photos-add
  (`NSPhotoLibraryAddUsageDescription`) strings are present and match actual
  usage — `poser/PhotoLibraryService.swift:18` correctly requests `.addOnly`
  only, no read access ever requested (matches the "ghost camera, write-only
  Photos" design).
- No IDFA/`ASIdentifierManager`/ATT usage — no App Tracking Transparency
  prompt needed.
- `Secrets.swift` is properly gitignored; nothing leaked in git (only the
  example template with placeholder keys is tracked).
- SPM deps (RevenueCat, Sentry, Aptabase) are pinned `upToNextMajorVersion`,
  not branches — safe for reproducible release builds.
- The `#if DEBUG`-gated premium-unlock toggle
  (`poser/PremiumStore.swift:102`, `poser/SettingsSheet.swift:48`) compiles
  out of Release/App Store builds — no free-unlock backdoor ships.
- Paywall already discloses price/duration/auto-renewal per plan and has a
  working Restore Purchases button — the *content* is compliant, it's just
  missing the policy links.
- App icon wired via the new Icon Composer (`POSER_icon.icon`) through
  `ASSETCATALOG_COMPILER_APPICON_NAME` — correctly referenced in both
  Debug/Release.

## Can't verify from code (manual App Store Connect checklist)

Screenshots, app description, age rating, the Privacy "nutrition label"
answers, and subscription-group display name/pricing localization all live in
App Store Connect and weren't checked here.

## Bottom line

The two 🔴 items — missing in-app legal links and the missing privacy
manifest — are the ones most likely to cause an actual rejection or a stalled
review. Fix those before submitting.
