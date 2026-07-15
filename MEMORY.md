# Project Environment

- Native iOS SwiftUI app at `poser.xcodeproj`; target and scheme are `poser`.
- Bundle identifier: `space.concurrent.poser`; development team: `V2P38BF2T2`.
- iPhone-only, portrait, minimum iOS 17.0. SwiftData is the metadata store; image bytes live under Documents.
- Reference implementation: `/Users/kat/Dev/Poser-react` (Expo/React Native). Its `src/app` screens and `src/components` files are the behavioral/pixel source of truth.
- Simulator build: `xcodebuild -project poser.xcodeproj -scheme poser -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- No unit/UI test target currently exists. Real camera validation requires a physical iPhone.
- Argent CLI is installed, but Argent MCP device tools were not exposed in the 2026-07-14 session.
