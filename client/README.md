# OpenVector Client

A cross-platform air traffic control client for [OpenVector](../README.md), built
with Flutter. It connects to an OpenVector/FSD server, renders live traffic on an
OpenStreetMap scope, and lets controllers **create and vector simulated
aircraft**.

## Features

- Connects as a real FSD controller (no special API needed).
- Live radar scope on OpenStreetMap tiles (`flutter_map`), with client-side
  extrapolation so targets glide smoothly between updates.
- **Navdata layer**: airports, VOR/NDB navaids, and enroute fixes rendered on the
  scope (viewport-culled, labels at higher zoom). Loaded from standard free data.
- **Message window**: a dockable FSD chat panel showing all text traffic
  (ATC chat, frequency, private, SIM, server) and an addressable send bar.
- Tap a target to select it; **Track** acquires its FSD track (required to
  command it). Track ownership of every target is shown (see legend below).
- **Spawn** mode: tap the map to create an aircraft at that point.
- **Right-click / long-press** the map to send the selected aircraft direct to
  that point.
- Command bar speaks the OpenVector `SIM` command set (`FH`, `C`, `S`, `DCT`,
  `ROUTE`, `SQ`, `VS`, `DEL`, plus global `SPAWN`/`FIX`). With a target selected,
  per-aircraft commands are auto-prefixed with its callsign.

## Navdata

The scope ships with no bundled navdata; load free datasets via the **folder**
icon in the toolbar (paste absolute file paths):

- **Airports / navaids** — [OurAirports](https://github.com/davidmegginson/ourairports-data)
  `airports.csv` and `navaids.csv` (public domain).
- **Enroute fixes** — X-Plane `earth_fix.dat` (ships with X-Plane).

Loaded points are rendered with viewport culling (fixes appear as you zoom in).
Toggle the layer with the **layers** icon.

## Reading the scope

Target colour shows track state:

- **Blue** — untracked
- **Green** — tracked by you
- **Orange** — tracked by another controller (their callsign shows as `@CALLSIGN` in the data tag)
- **Amber** — currently selected

The data tag reads `CALLSIGN`, then flight level (altitude/100) and groundspeed.

## Project layout

```
lib/
  main.dart              app entry
  fsd/
    fsd_client.dart      TCP connection + FSD protocol + world model
    models.dart          Aircraft model + heading decode + extrapolation
  ui/
    connect_page.dart    login form
    scope_page.dart      OSM map, targets, command bar, spawn dialog
```

## Running

The platform runner folders (android/ios/linux/macos/windows/web) are not checked
in. Generate them once, then run:

```bash
cd client
flutter create . --platforms=windows,macos,linux,android,ios
flutter pub get
flutter run            # or: flutter run -d windows / -d macos / -d linux / -d chrome
```

> Note: a plain browser cannot open the raw TCP socket FSD requires, so the web
> target won't connect without a bridge. Use a desktop or mobile target.

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
e.g. the default admin CID `1`), a **callsign**, **rating**, and **facility**
(use a facility > 0 such as `5` for Approach so you can command aircraft), plus a
**scope center** and **visibility range**. A large vis range (e.g. 500 NM) lets
you see traffic across a wide area.

## Notes

- OpenStreetMap's public tile server is fine for development but has a
  [usage policy](https://operations.osmfoundation.org/policies/tiles/); use a
  proper tile provider for anything beyond testing.
- This is an MVP: data tags, range rings, flight-plan display, handoff UI, and
  conflict alerts are natural next steps.
