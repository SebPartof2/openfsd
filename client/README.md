# OpenVector Client

A cross-platform air traffic control client for [OpenVector](../README.md), built
with Flutter. It connects to an OpenVector/FSD server, renders live traffic on an
OpenStreetMap scope, and lets controllers **create and vector simulated
aircraft**.

## Features (MVP)

- Connects as a real FSD controller (no special API needed).
- Live radar scope on OpenStreetMap tiles (`flutter_map`), with client-side
  extrapolation so targets glide smoothly between updates.
- Tap a target to select it; **Track** acquires its FSD track (required to
  command it).
- **Spawn** mode: tap the map to create an aircraft at that point.
- Command bar speaks the OpenVector `SIM` command set (`FH`, `C`, `S`, `DCT`,
  `ROUTE`, `SQ`, `VS`, `DEL`, plus global `SPAWN`/`FIX`). With a target selected,
  per-aircraft commands are auto-prefixed with its callsign.

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
