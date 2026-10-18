# RagaMentor for iOS

A Carnatic music practice app for iPhone (iOS 17+), at full feature parity
with the RagaMentor web suite as of **v1.0.0**. Five studios in one app:

- **LoopLab** — import songs (MP3/M4A/WAV/AIFF/CAF), slow them down
  (0.25x–1x presets plus a fine slider, pitch preserved), set named A–B
  loops and nested loop groups, pinch-zoom waveform, per-loop swara
  phrases, and a platform-independent loops JSON backup that matches the
  web format byte-for-byte (v3).
- **Compose Studio** — build swara compositions with the shared phrase
  editor, import/export the web composition JSON format.
- **Ragas** — the 87-raga browser: search by name or swara class,
  favourites, the 72 melakartas by chakra, Hindustani thaats, scale
  playback on sampled harmonium, and the display piano with live
  note highlighting.
- **Varisai** — all 7 lessons and 50 patterns (sarali, janta, dhattu,
  alankaram, sthayi) with grouped notation, dheergam holds and legato
  playback at 1x–8x speeds. Lesson data is generated from the mock
  repo, the notation source of truth.
- **Tala** — the tala wheel for the suladi sapta talas × 5 jatis plus
  the chapu talas, a three-tier lookahead click engine, tap tempo and
  nadai subdivisions.

Native advantages kept: the AVAudioEngine playback core, background
audio with lock-screen remote controls, Files integration, and one
shared phrase editor + raga library across every studio. Starting
playback in any studio stops the others (audio focus).

## Architecture

Protocol-oriented, one Swift package per module under `Packages/`.
Features depend on shared modules and protocols, never on each other
(the one sanctioned exception: LoopLab and Composer compose the
RagaBrowser picker view into the phrase editor, which itself only
knows a builder closure).

- `RagaCore` — pure logic: swara/phrase model and sanitizer, the
  87-raga catalog, scale walks and search, composition format,
  TalaSpec, the ordered JSJSON writer.
- `AudioKit` — file playback engine, harmonium tone engine, peaks,
  the sine click engine, cross-studio audio focus.
- `PersistenceKit` — SwiftData store, raga library store,
  composition store.
- `DesignSystem` — the web studio design language as native tokens
  and components, one theme setting (dark default).
- `SwaraEditor`, `RagaBrowser`, `LoopLab`, `Composer`, `Varisai`,
  `Tala` — the features. `RagaMentor-iOS` (AppShell) composes them.

## Pipeline

Every push to `main` runs GitHub Actions on a macOS runner (free: this
repo is public):

- **Unit tests (simulator)** — `bundle exec fastlane test` runs the
  XCTest suite (90 tests).
- **Unsigned IPA artifact** — `bundle exec fastlane build_unsigned`
  archives the app with code signing disabled and packages
  `RagaMentor-iOS-unsigned.ipa`, republished to the permanent `latest`
  release on every green build.

## Installing on an iPhone (no paid account)

Free signing lasts 7 days; reinstalling refreshes it and keeps app
data. The working route (Apple changed its sign-in rules on
13 Oct 2026, which broke SideStore's in-app sign-in):

1. One-time: sideload SideStore itself via AltServer from a computer,
   enable Developer Mode, and place the pairing file with iloader.
2. For RagaMentor and every update: in iloader, use **Install IPA**
   with the permanent `latest` release:
   https://github.com/shahz-bot1/RagaMentor-iOS/releases/download/latest/RagaMentor-iOS-unsigned.ipa
3. Repeat before each 7-day expiry.

With a paid Apple Developer account, fastlane could gain `match`
signing plus TestFlight lanes, so builds install for a year with no
weekly refresh.
