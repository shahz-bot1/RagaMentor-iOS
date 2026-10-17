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

## Installing on an iPhone with SideStore (no paid account)

An unsigned IPA cannot install as-is. SideStore signs it with your own Apple ID
on the device — no jailbreak involved. Free signing lasts 7 days and SideStore
re-signs in the background before expiry. Limit: 3 self-signed apps at a time
(SideStore itself counts as one).

**One-time setup (needs a computer once — Windows, Mac or Linux):**

1. On the iPhone: install **WireGuard** from the App Store, add the SideStore
   config (`SideStore.conf` from sidestore.io), and switch the tunnel on.
   (Newer guides use **LocalDevVPN** instead — either works.)
2. On the computer: install **iloader** (or AltServer), connect the iPhone by
   USB, trust the computer, and install SideStore, signing in with your Apple ID.
3. Still on the computer: run the pairing tool (in iloader, or `jitterbugpair`)
   and place the pairing file into SideStore on the phone.
4. On the iPhone: Settings → General → VPN & Device Management → trust your
   Apple ID profile; then Settings → Privacy & Security → Developer Mode on.
5. Open SideStore and sign in with the same Apple ID.

**Then install RagaMentor (and every future build) from the source:**

- In SideStore: Sources → + → add
  `https://raw.githubusercontent.com/shahz-bot1/RagaMentor-iOS/main/apps.json`
- RagaMentor-iOS appears in Browse — tap GET to install. Updates land there too:
  CI republishes the `latest` release IPA on every green build of `main`, and
  the source always points at it.
- Or direct IPA link:
  https://github.com/shahz-bot1/RagaMentor-iOS/releases/download/latest/RagaMentor-iOS-unsigned.ipa

## Later

With a paid Apple Developer account, fastlane gains `match` signing plus ad hoc
and TestFlight lanes, so builds install for a year with no weekly refresh.
