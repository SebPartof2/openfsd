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

| Command          | Aliases       | Meaning                              |
|------------------|---------------|--------------------------------------|
| `FH <deg>`       | `H`, `HDG`    | Fly heading                          |
| `C <ft>`         | `D`, `ALT`    | Climb/descend to altitude            |
| `S <kts>`        | `SPD`         | Assign groundspeed                   |
| `SQ <code>`      | `SQUAWK`      | Assign transponder code              |
| `DEL`            | `DELETE`, `KILL` | Remove the aircraft from the network |

Examples:

```
AAL123 FH 270
AAL123 C 12000
AAL123 S 210
AAL123 DEL
```

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
