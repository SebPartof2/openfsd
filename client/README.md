# OpenVector Client

A cross-platform air traffic control client for [OpenVector](../README.md), built
with Flutter. It connects to an OpenVector/FSD server and lets controllers
**create and vector simulated aircraft** from a list-driven, command-line
interface designed for clearance/ground/local positions.

## Features

- Connects as a real FSD controller (no special API needed).
- **Aircraft list** — the main view. Every target shows a track-state colour,
  flight level, groundspeed, heading, squawk, and owning controller. Tap to
  select; the track button acquires/drops its FSD track.
- **Spawn** — one click, asks only for a callsign. The aircraft is created at
  your position and you automatically hold its track.
- **Message window** — a dockable FSD chat panel showing all text traffic
  (ATC chat, frequency, private, SIM, server) with an addressable send bar.
- **CRC-style command line** handling both messaging and aircraft control:
  - `.msg <recipient> <text>` — send a message. Recipient can be a callsign,
    a frequency (`121.9`), `@49999` (ATC chat), or `*S` (wallop).
  - `.chat <recipient>` — open the message panel addressed to that recipient.
  - `.wallop <text>` — message supervisors.
  - `.atc <text>` — broadcast on the ATC chat channel.
  - Anything without a leading dot is an aircraft command (`FH`, `C`, `S`,
    `DCT`, `ROUTE`, `SQ`, `VS`, `DEL`, or global `SPAWN`/`FIX`). With a target
    selected, per-aircraft commands are auto-prefixed with its callsign.

## Track-state colours

- **Blue** — untracked
- **Green** — tracked by you
- **Orange** — tracked by another controller (their callsign is shown on the row)

## Project layout

```
lib/
  main.dart              app entry + connection swap
  fsd/
    fsd_client.dart      TCP connection + FSD protocol + world model
    models.dart          Aircraft + message models
  ui/
    connect_page.dart    login form (remembers last settings)
    scope_page.dart      aircraft list, message panel, command line
```

## Running

The platform runner folders (android/ios/linux/macos/windows) are not checked in.
Generate them once, then run:

```bash
cd client
flutter create . --platforms=windows,macos,linux,android,ios
flutter pub get
flutter run            # or: flutter run -d windows / -d macos / -d linux
```

### macOS: allow outbound connections

macOS apps run sandboxed and `flutter create` does not grant outbound network
access, so the client fails with `Operation not permitted (errno = 1)` until you
add the **network client** entitlement. Add the following inside the `<dict>` of
**both** `macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements`, then restart the app:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

(Linux and Windows desktop builds need no entitlement changes.)

## Connecting

Fill in the server host/port, your **CID** and **password** (an OpenVector user —
e.g. the default admin CID `1`), a **callsign**, **rating**, and **position**
(Clearance / Ground / Tower). Defaults target Honolulu Tower (`HNL_TWR` / PHNL).
Your last-used settings — including the password — are remembered locally between
launches.
