# Simulated Aircraft

openfsd supports **controller-spawned simulated aircraft**: a controller can
create an aircraft that lives on the network and is flown by a server-side flight
model. This enables a controller-focused mode where the airspace can be populated
without any connected pilots.

## Concept

- A simulated aircraft is an ordinary network target (it appears on scopes and in
  the data feed exactly like a real pilot). It has no network socket; its position
  is advanced by a flight model running on the server.
- Aircraft **persist** independently of the controller who created them. If that
  controller disconnects, the aircraft keeps flying its last clearance and becomes
  *untracked*, so any other controller may take it over.
- **Maneuver authority follows the FSD track.** Only the controller currently
  holding an aircraft's track may issue commands to it. Taking the track
  (Initiate Track) or accepting a handoff transfers control automatically.

## Commands

Commands are sent as text messages to the reserved station **`SIM`** (active ATC,
above Observer, only). Replies are returned as text messages from `SIM`.

### Create an aircraft

```
SPAWN <callsign> <lat> <lon> <heading> <altitude_ft> <speed_kts>
```

Example:

```
SPAWN AAL123 34.0 -118.0 90 5000 250
```

The creator is automatically given the track.

### Maneuver an aircraft

You must hold the aircraft's track. `<callsign> <command> <value>`:

| Command          | Aliases          | Meaning                                       |
|------------------|------------------|-----------------------------------------------|
| `FH <deg>`       | `H`, `HDG`       | Fly heading (cancels any active route)         |
| `C <ft>`         | `D`, `ALT`       | Climb/descend to altitude                      |
| `S <kts>`        | `SPD`            | Assign groundspeed                             |
| `VS <fpm>`       |                  | Set vertical rate (default 1800 fpm)           |
| `SQ <code>`      | `SQUAWK`         | Assign transponder code                        |
| `DCT <fix>`      | `DIRECT`         | Proceed direct to a named fix                  |
| `DCT <lat> <lon>`| `DIRECT`         | Proceed direct to a coordinate                 |
| `ROUTE <fix> ...`|                  | Follow a sequence of fixes (LNAV)              |
| `DEL`            | `DELETE`, `KILL` | Remove the aircraft from the network           |

Examples:

```
AAL123 FH 270
AAL123 C 12000
AAL123 S 210
AAL123 VS 2500
AAL123 DCT ALPHA
AAL123 ROUTE ALPHA BRAVO/11000 CHARLIE
AAL123 DEL
```

### Navigation fixes

Fixes are named coordinates used by `DCT` and `ROUTE`. Define them with the
global `FIX` command; `FIXES` reports how many are defined.

```
FIX ALPHA 34.5 -117.5
FIX BRAVO 35.1 -116.9
FIXES
```

In a `ROUTE`, a fix may carry an altitude restriction with a `/` suffix
(e.g. `BRAVO/11000`): the aircraft targets that altitude when it sequences the
fix. When the final fix is reached the aircraft reverts to heading hold on its
current heading.

## Flight model

The current model is intentionally simple: standard-rate turns (3°/s),
configurable vertical rate (default ~1800 fpm), and gradual acceleration toward
the assigned speed, with dead-reckoning along the current heading. In LNAV the
aircraft steers along the great-circle bearing to the active waypoint and
sequences fixes within ~1 NM. Position updates are broadcast at ~1 Hz.

## Persistence

When a durable database is configured (file-backed SQLite or PostgreSQL),
simulated aircraft are persisted and **restored on server restart**, resuming
their last clearance (including any active route) as untracked traffic. With the
default in-memory database, aircraft exist only for the life of the process.

## Controller-only networks

Set `CONTROLLER_ONLY=true` to reject pilot (`#AP`) connections entirely, so the
airspace is populated solely by controller-created simulated aircraft.

## Track ownership

Ownership uses the standard FSD track mechanism, so it works from any controller
client:

- **Initiate Track** (`IT`) on an aircraft to acquire control.
- **Drop Track** (`DR`) to release it (the aircraft keeps flying, untracked).
- **Handoff** (`$HO`/`$HA`) transfers control; on acceptance (`HT`) the receiving
  controller becomes the new owner.

## Flight model

The current model is intentionally simple: standard-rate turns (3°/s), ~1800 fpm
climb/descent, and gradual acceleration toward the assigned speed, with
dead-reckoning along the current heading. Position updates are broadcast at ~1 Hz.
