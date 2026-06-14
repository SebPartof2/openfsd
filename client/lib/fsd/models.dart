import 'dart:math';

import 'package:latlong2/latlong.dart';

/// A network target (aircraft) as tracked by the client.
class Aircraft {
  final String callsign;
  LatLng position;
  int altitude; // feet
  int groundspeed; // knots
  double heading; // degrees
  String squawk;
  DateTime lastUpdate;

  /// Callsign of the controller currently holding this aircraft's track,
  /// or null when the aircraft is untracked.
  String? trackedBy;

  Aircraft({
    required this.callsign,
    required this.position,
    this.altitude = 0,
    this.groundspeed = 0,
    this.heading = 0,
    this.squawk = '',
    DateTime? lastUpdate,
    this.trackedBy,
  }) : lastUpdate = lastUpdate ?? DateTime.now();

  /// Whether this aircraft is tracked by the controller with [callsign].
  bool isTrackedBy(String controllerCallsign) =>
      trackedBy != null && trackedBy == controllerCallsign;

  /// Dead-reckons the position forward to [now] using the last known
  /// groundspeed and heading, mirroring how a radar scope extrapolates
  /// between position updates so targets glide smoothly.
  LatLng extrapolated(DateTime now) {
    final dt = now.difference(lastUpdate).inMilliseconds / 1000.0;
    if (groundspeed <= 0 || dt <= 0) return position;

    final distNm = groundspeed * dt / 3600.0;
    final distDeg = distNm / 60.0;
    final hdgRad = heading * pi / 180.0;

    final lat = position.latitude + distDeg * cos(hdgRad);
    final cosLat = cos(position.latitude * pi / 180.0);
    final lon = cosLat != 0
        ? position.longitude + distDeg * sin(hdgRad) / cosLat
        : position.longitude;

    return LatLng(lat, lon);
  }
}

/// Decodes the heading (degrees) from an FSD pitch/bank/heading uint32.
double headingFromPbh(int pbh) {
  final headingBits = (pbh >> 2) & 1023;
  return headingBits * 359.0 / 1023.0;
}

/// Another controller online on the network.
class Controller {
  final String callsign;
  String frequency; // raw FSD frequency field, e.g. "19900"
  int facility;
  DateTime lastUpdate;

  Controller({
    required this.callsign,
    this.frequency = '',
    this.facility = 0,
    DateTime? lastUpdate,
  }) : lastUpdate = lastUpdate ?? DateTime.now();

  /// Frequency formatted as MHz, e.g. "19900" -> "119.900".
  String get frequencyMhz {
    if (frequency.isEmpty) return '';
    final full = '1$frequency';
    if (full.length < 4) return frequency;
    return '${full.substring(0, 3)}.${full.substring(3)}';
  }

  String get facilityName {
    switch (facility) {
      case 1:
        return 'FSS';
      case 2:
        return 'DEL';
      case 3:
        return 'GND';
      case 4:
        return 'TWR';
      case 5:
        return 'APP';
      case 6:
        return 'CTR';
      default:
        return 'OBS';
    }
  }
}

/// A handoff offered to us by another controller.
class PendingHandoff {
  final String from;
  final String aircraft;
  PendingHandoff(this.from, this.aircraft);
}

/// A received or sent text message.
class FsdMessage {
  final String from;
  final String to;
  final String text;
  final DateTime time;

  FsdMessage(this.from, this.to, this.text) : time = DateTime.now();

  /// Short category label for display.
  String get channel {
    if (from.toLowerCase() == 'server') return 'SERVER';
    if (from == 'SIM') return 'SIM';
    if (to == '@49999') return 'ATC';
    if (to.startsWith('@')) return 'FREQ';
    if (to == '*S') return 'WALLOP';
    return 'MSG';
  }
}
