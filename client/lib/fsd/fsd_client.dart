import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'models.dart';

/// Connection parameters for logging in to an OpenVector / FSD server.
class FsdSession {
  final String host;
  final int port;
  final String callsign;
  final int cid;
  final String password; // plaintext password or JWT
  final int rating; // FSD network rating
  final int facility; // ATC facility type (>0 to command aircraft)
  final LatLng center; // scope center / controller position
  final double visRangeNm; // visibility range in nautical miles

  const FsdSession({
    required this.host,
    required this.port,
    required this.callsign,
    required this.cid,
    required this.password,
    this.rating = 12,
    this.facility = 5,
    required this.center,
    this.visRangeNm = 500,
  });
}

/// FsdClient owns the TCP connection to an OpenVector server, speaks the FSD
/// protocol, and exposes the live world model. It is a [ChangeNotifier] so the
/// UI can rebuild as targets move.
class FsdClient extends ChangeNotifier {
  Socket? _socket;
  StreamSubscription<List<int>>? _sub;
  String _buffer = '';

  final Map<String, Aircraft> aircraft = {};
  final List<String> messages = [];

  bool connected = false;
  String? error;
  FsdSession? session;

  Timer? _posTimer;
  Timer? _renderTimer;

  // Login is only considered successful once the server accepts it (MOTD).
  // A rejection ($ER) or a dropped connection during this phase fails the login.
  bool _awaitingLogin = false;
  Completer<String?> _login = Completer<String?>();

  Future<void> connect(FsdSession s) async {
    session = s;
    error = null;
    _login = Completer<String?>();
    _awaitingLogin = true;
    try {
      _socket = await Socket.connect(s.host, s.port,
          timeout: const Duration(seconds: 10));
    } catch (e) {
      error = 'Connection failed: $e';
      _awaitingLogin = false;
      notifyListeners();
      return;
    }

    _sub = _socket!.listen(
      _onData,
      onError: (Object e) {
        error = '$e';
        _cleanup();
      },
      onDone: _cleanup,
    );

    // Login handshake. A short (non-9-field) ID packet skips the vatsim auth
    // challenge, so we authenticate with a plaintext password (or JWT).
    _send('\$ID${s.callsign}:SERVER:openvector:1');
    _send(
        '#AA${s.callsign}:SERVER:OpenVector Controller:${s.cid}:${s.password}:${s.rating}:100');

    // Wait for the server to accept or reject the login before proceeding.
    final loginError = await _login.future
        .timeout(const Duration(seconds: 10), onTimeout: () => 'Login timed out');
    if (loginError != null) {
      error = loginError;
      _cleanup();
      return;
    }

    connected = true;
    _sendPosition();
    _posTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _sendPosition());
    // Periodic redraw so extrapolated positions animate between updates.
    _renderTimer = Timer.periodic(
        const Duration(milliseconds: 250), (_) => notifyListeners());

    notifyListeners();
  }

  void _completeLogin(String? loginError) {
    _awaitingLogin = false;
    if (!_login.isCompleted) _login.complete(loginError);
  }

  void disconnect() {
    final s = session;
    if (s != null && connected) {
      _send('#DA${s.callsign}:${s.cid}');
    }
    _cleanup();
  }

  void _cleanup() {
    if (_awaitingLogin) {
      _completeLogin('Connection closed during login');
    }
    _posTimer?.cancel();
    _renderTimer?.cancel();
    _sub?.cancel();
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
    connected = false;
    notifyListeners();
  }

  void _send(String line) {
    try {
      _socket?.write('$line\r\n');
    } catch (e) {
      error = '$e';
      notifyListeners();
    }
  }

  void _sendPosition() {
    final s = session;
    if (s == null) return;
    _send('%${s.callsign}:19900:${s.facility}:${s.visRangeNm.round()}:'
        '${s.rating}:${s.center.latitude.toStringAsFixed(5)}:'
        '${s.center.longitude.toStringAsFixed(5)}:0');
  }

  // --- Outbound controller actions ---

  /// Sends a raw OpenVector SIM command (e.g. "SPAWN AAL123 ...", "AAL123 FH 270").
  void sendSimCommand(String cmd) {
    final s = session;
    if (s == null) return;
    _send('#TM${s.callsign}:SIM:$cmd');
  }

  void initiateTrack(String target) {
    final s = session;
    if (s == null) return;
    _send('\$CQ${s.callsign}:@94835:IT:$target');
    aircraft[target]?.trackedByMe = true;
    notifyListeners();
  }

  void dropTrack(String target) {
    final s = session;
    if (s == null) return;
    _send('\$CQ${s.callsign}:@94835:DR:$target');
    aircraft[target]?.trackedByMe = false;
    notifyListeners();
  }

  // --- Inbound parsing ---

  void _onData(List<int> data) {
    _buffer += utf8.decode(data, allowMalformed: true);
    while (true) {
      final idx = _buffer.indexOf('\n');
      if (idx < 0) break;
      final line = _buffer.substring(0, idx).replaceAll('\r', '');
      _buffer = _buffer.substring(idx + 1);
      if (line.isNotEmpty) _handleLine(line);
    }
  }

  void _handleLine(String line) {
    final f = line.split(':');
    if (f.isEmpty) return;
    final head = f[0];

    // Resolve the login once the server responds. A MOTD ("#TM" from "server")
    // means success; an error packet means the credentials were rejected.
    if (_awaitingLogin) {
      if (head.startsWith('\$ER')) {
        _completeLogin(_loginErrorMessage(f));
        return;
      } else if (head.startsWith('#TM') && head.substring(3).toLowerCase() == 'server') {
        _completeLogin(null);
        // fall through so the MOTD is also recorded as a message
      }
    }

    if (head.startsWith('@')) {
      _handlePosition(f);
    } else if (head.startsWith('#AP')) {
      // Aircraft add. We plot it once its first position arrives.
    } else if (head.startsWith('#DP')) {
      aircraft.remove(head.substring(3));
      notifyListeners();
    } else if (head.startsWith('#TM')) {
      _handleText(f);
    } else if (head.startsWith('\$ER')) {
      messages.add('ERROR: ${f.length > 3 ? f.sublist(3).join(':') : line}');
      notifyListeners();
    }
  }

  // $ERserver:unknown:<code>::<message>
  String _loginErrorMessage(List<String> f) {
    if (f.length >= 5) {
      final msg = f.sublist(4).join(':').trim();
      if (msg.isNotEmpty) return msg;
    }
    return 'Login rejected';
  }

  // @MODE:CALLSIGN:SQUAWK:RATING:LAT:LON:ALT:GS:PBH:CORRECTION
  void _handlePosition(List<String> f) {
    if (f.length < 9) return;
    final cs = f[1];
    final lat = double.tryParse(f[4]) ?? 0;
    final lon = double.tryParse(f[5]) ?? 0;
    final alt = int.tryParse(f[6]) ?? 0;
    final gs = int.tryParse(f[7]) ?? 0;
    final pbh = int.tryParse(f[8]) ?? 0;

    final ac = aircraft.putIfAbsent(
        cs, () => Aircraft(callsign: cs, position: LatLng(lat, lon)));
    ac.position = LatLng(lat, lon);
    ac.altitude = alt;
    ac.groundspeed = gs;
    ac.heading = headingFromPbh(pbh);
    ac.squawk = f[2];
    ac.lastUpdate = DateTime.now();
  }

  // #TM<FROM>:<TO>:<MESSAGE>
  void _handleText(List<String> f) {
    if (f.length < 3) return;
    final from = f[0].substring(3);
    final msg = f.sublist(2).join(':');
    messages.add('$from: $msg');
    if (messages.length > 200) messages.removeAt(0);
    notifyListeners();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}
