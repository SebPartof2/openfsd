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

  /// True when this client currently holds the aircraft's track.
  bool trackedByMe;

  Aircraft({
    required this.callsign,
    required this.position,
    this.altitude = 0,
    this.groundspeed = 0,
    this.heading = 0,
    this.squawk = '',
    DateTime? lastUpdate,
    this.trackedByMe = false,
  }) : lastUpdate = lastUpdate ?? DateTime.now();

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
