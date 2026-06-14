# OpenVector Client

A cross-platform air traffic control client for [OpenVector](../README.md), built
with Flutter. It connects to an OpenVector/FSD server and lets controllers
**create and vector simulated aircraft** from a list-driven, command-line
interface designed for clearance/ground/local positions.

## Features

- Connects as a real FSD controller (no special API needed).
- **Aircraft / ATC tabs** — *Aircraft* shows every target (track-state colour,
  FL, speed, heading, squawk, owner) with a track button. *ATC* lists other
  online controllers (facility + frequency); tap one to open a direct chat, or
  use the ⇄ button to hand off your selected aircraft to them.
- **Track ownership** — the Track button only works on an untracked aircraft;
  you can't steal another controller's track. Transfers go through handoff.
- **Handoff** — `.ho <controller>` (or the ⇄ button) offers your selected
  aircraft; the receiver gets an Accept/Reject banner and accepting takes the
  track.
- **Spawn** — one click, asks only for a callsign. The aircraft is created at
  your position and you automatically hold its track.
- **Tabbed messages** — one thread per conversation (direct controller, ATC
  chat, frequency, SIM, server). `.msg`/`.chat` or tapping a controller opens a
  direct tab; the active tab is your reply target.
- **One unified command line** for both commands and messages. Routing on send:
  - `.cmd …` always runs a CRC-style command:
    - `.msg <recipient> <text>` — send a message (recipient: callsign, frequency
      like `121.9`, `@49999` for ATC chat, or `*S` for wallop).
    - `.chat <recipient>` — enter chat mode with that recipient (a chip appears).
    - `.wallop <text>` / `.atc <text>`.
  - `SPAWN`/`FIX …` always run as server commands.
  - In **chat mode** (after `.chat`), plain text is sent as a message to that
    recipient.
  - With an **aircraft selected**, plain text is a command for it (`FH 270`,
    `C 5000`, `S 210`, `DCT …`, `DEL`).
  The chip next to the input shows the current context; clear it with the ✕.

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
