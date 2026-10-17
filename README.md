# RagaMentor-iOS

Native iOS app for RagaMentor (SwiftUI). This repo is the native counterpart of the
web prototype at https://github.com/shahz-bot1/RagaMentor — it starts life as a
Hello World app that proves the build and test pipeline end to end.

## Pipeline

Every push to `main` runs GitHub Actions on a macOS runner (free: this repo is public):

- **Unit tests (simulator)** — `bundle exec fastlane test` runs the XCTest suite.
- **Unsigned IPA artifact** — `bundle exec fastlane build_unsigned` archives the app
  with code signing disabled and packages the `.app` into `RagaMentor-iOS-unsigned.ipa`,
  uploaded as a workflow artifact (kept 14 days).

## Installing the unsigned IPA on an iPhone (no paid account)

An unsigned IPA cannot install as-is. A sideloading tool signs it with your own
Apple ID at install time — no jailbreak involved:

1. Download the `RagaMentor-iOS-unsigned-ipa` artifact from the latest Actions run and unzip it.
2. Open the `.ipa` in **SideStore** (or AltStore) and install.
3. Free Apple ID signing lasts 7 days; SideStore re-signs in the background.

Limits of free signing: 3 self-signed apps at a time, no push/iCloud entitlements.

## Later

With a paid Apple Developer account, fastlane gains `match` signing plus ad hoc
and TestFlight lanes, so builds install for a year with no weekly refresh.
