import 'dart:io';

import 'package:latlong2/latlong.dart';

enum NavKind { airport, vor, ndb, fix }

class NavPoint {
  final String ident;
  final LatLng pos;
  final NavKind kind;
  const NavPoint(this.ident, this.pos, this.kind);
}

/// Aeronautical reference data (airports, navaids, fixes) loaded from standard
/// free datasets and rendered on the scope.
///
/// Supported formats:
///  - OurAirports `airports.csv` and `navaids.csv` (public domain)
///    https://github.com/davidmegginson/ourairports-data
///  - X-Plane `earth_fix.dat` (enroute fixes)
class NavData {
  final List<NavPoint> points = [];

  bool get isEmpty => points.isEmpty;
  int get length => points.length;

  /// OurAirports airports.csv — loads large/medium airports.
  Future<int> loadAirportsCsv(String path) async {
    final lines = await File(path).readAsLines();
    if (lines.isEmpty) return 0;
    final h = _csv(lines.first);
    final iIdent = h.indexOf('ident');
    final iType = h.indexOf('type');
    final iLat = h.indexOf('latitude_deg');
    final iLon = h.indexOf('longitude_deg');
    if (iIdent < 0 || iType < 0 || iLat < 0 || iLon < 0) return 0;

    var n = 0;
    for (final line in lines.skip(1)) {
      final c = _csv(line);
      if (c.length <= iLon) continue;
      final type = c[iType];
      if (type != 'large_airport' && type != 'medium_airport') continue;
      final lat = double.tryParse(c[iLat]);
      final lon = double.tryParse(c[iLon]);
      if (lat == null || lon == null) continue;
      points.add(NavPoint(c[iIdent], LatLng(lat, lon), NavKind.airport));
      n++;
    }
    return n;
  }

  /// OurAirports navaids.csv — loads VOR/NDB-class navaids.
  Future<int> loadNavaidsCsv(String path) async {
    final lines = await File(path).readAsLines();
    if (lines.isEmpty) return 0;
    final h = _csv(lines.first);
    final iIdent = h.indexOf('ident');
    final iType = h.indexOf('type');
    final iLat = h.indexOf('latitude_deg');
    final iLon = h.indexOf('longitude_deg');
    if (iIdent < 0 || iType < 0 || iLat < 0 || iLon < 0) return 0;

    var n = 0;
    for (final line in lines.skip(1)) {
      final c = _csv(line);
      if (c.length <= iLon) continue;
      final lat = double.tryParse(c[iLat]);
      final lon = double.tryParse(c[iLon]);
      if (lat == null || lon == null) continue;
      final kind =
          c[iType].toUpperCase().contains('NDB') ? NavKind.ndb : NavKind.vor;
      points.add(NavPoint(c[iIdent], LatLng(lat, lon), kind));
      n++;
    }
    return n;
  }

  /// X-Plane earth_fix.dat — "lat lon ident ..." per line; header/footer lines
  /// that don't start with a coordinate pair are skipped automatically.
  Future<int> loadXPlaneFixes(String path) async {
    final lines = await File(path).readAsLines();
    var n = 0;
    for (final line in lines) {
      final s = line.trim();
      if (s.isEmpty) continue;
      final parts = s.split(RegExp(r'\s+'));
      if (parts.length < 3) continue;
      final lat = double.tryParse(parts[0]);
      final lon = double.tryParse(parts[1]);
      if (lat == null || lon == null) continue;
      points.add(NavPoint(parts[2], LatLng(lat, lon), NavKind.fix));
      n++;
    }
    return n;
  }

  /// Resolves a fix/navaid/airport by ident (case-insensitive).
  NavPoint? lookup(String ident) {
    final up = ident.toUpperCase();
    for (final p in points) {
      if (p.ident.toUpperCase() == up) return p;
    }
    return null;
  }

  /// Minimal CSV field splitter handling quoted fields and escaped quotes.
  static List<String> _csv(String line) {
    final out = <String>[];
    final sb = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (quoted) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            sb.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          sb.write(ch);
        }
      } else if (ch == '"') {
        quoted = true;
      } else if (ch == ',') {
        out.add(sb.toString());
        sb.clear();
      } else {
        sb.write(ch);
      }
    }
    out.add(sb.toString());
    return out;
  }
}
