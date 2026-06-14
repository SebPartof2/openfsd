import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'models.dart';

/// Derives the ATC facility type from a callsign suffix (VATSIM convention).
int facilityForCallsign(String callsign) {
  final up = callsign.toUpperCase();
  if (up.endsWith('_DEL')) return 2;
  if (up.endsWith('_GND')) return 3;
  if (up.endsWith('_TWR')) return 4;
  if (up.endsWith('_APP') || up.endsWith('_DEP')) return 5;
  if (up.endsWith('_CTR')) return 6;
  if (up.endsWith('_FSS')) return 1;
  return 0; // OBS / SUP / ADM
}

/// Supervisor mode is triggered by a _SUP or _ADM callsign suffix.
bool isSupervisorCallsign(String callsign) {
  final up = callsign.toUpperCase();
  return up.endsWith('_SUP') || up.endsWith('_ADM');
}

/// Formats a raw FSD frequency field ("19900") as MHz ("119.900").
String frequencyMhz(String raw) {
  if (raw.isEmpty) return '';
  final full = '1$raw';
  return full.length >= 4
      ? '${full.substring(0, 3)}.${full.substring(3)}'
      : raw;
}

String facilityLabel(int facility) {
  switch (facility) {
    case 1:
      return 'FSS';
    case 2:
      return 'Clearance';
    case 3:
      return 'Ground';
    case 4:
      return 'Tower';
    case 5:
      return 'Approach';
    case 6:
      return 'Center';
    default:
      return 'Observer';
  }
}

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
  final String datafeedUrl; // network datafeed (supervisor view)

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
    this.datafeedUrl = '',
  });

  /// True when connected with a supervisor callsign (_SUP / _ADM).
  bool get isSupervisor => isSupervisorCallsign(callsign);
}

/// FsdClient owns the TCP connection to an OpenVector server, speaks the FSD
/// protocol, and exposes the live world model. It is a [ChangeNotifier] so the
/// UI can rebuild as targets move.
class FsdClient extends ChangeNotifier {
  Socket? _socket;
  StreamSubscription<List<int>>? _sub;
  String _buffer = '';

  final Map<String, Aircraft> aircraft = {};
  final Map<String, Controller> controllers = {};
  final Map<String, FlightPlan> flightPlans = {};
  final List<PendingHandoff> pendingHandoffs = [];

  // Active (unacknowledged) wallops received as a supervisor.
  final List<FsdMessage> activeWallops = [];

  // Network-wide roster from the datafeed (supervisor view).
  final List<NetController> networkControllers = [];
  final List<NetPilot> networkPilots = [];
  Timer? _datafeedTimer;

  // Message threads keyed by the other party (callsign / channel recipient).
  final Map<String, List<FsdMessage>> conversations = {};
  final List<String> conversationOrder = [];

  // Callsigns we just spawned: mark them tracked by us once they appear.
  final Set<String> _pendingOwn = {};

  bool connected = false;
  String? error;
  FsdSession? session;

  String get myCallsign => session?.callsign ?? '';

  Timer? _posTimer;
  Timer? _renderTimer;

  // Login is only considered successful once the server accepts it (MOTD).
  // A rejection ($ER) or a dropped connection during this phase fails the login.
  bool _awaitingLogin = false;
  Completer<String?> _login = Completer<String?>();

  Future<void> connect(FsdSession s) async {
    session = s;
    error = null;
    // Start from a clean world so a previous session's state doesn't linger.
    aircraft.clear();
    controllers.clear();
    flightPlans.clear();
    pendingHandoffs.clear();
    activeWallops.clear();
    networkControllers.clear();
    networkPilots.clear();
    conversations.clear();
    conversationOrder.clear();
    _pendingOwn.clear();
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
    // Periodic redraw; also drop targets that have stopped updating.
    _renderTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());

    // Supervisors get a network-wide roster by polling the datafeed.
    if (s.isSupervisor && s.datafeedUrl.isNotEmpty) {
      _pollDatafeed();
      _datafeedTimer =
          Timer.periodic(const Duration(seconds: 15), (_) => _pollDatafeed());
    }

    notifyListeners();
  }

  void _completeLogin(String? loginError) {
    _awaitingLogin = false;
    if (!_login.isCompleted) _login.complete(loginError);
  }

  /// Targets that stop updating for this long are dropped (covers a missed
  /// delete packet). Simulated aircraft broadcast ~1 Hz.
  static const _staleAfter = Duration(seconds: 30);

  static const _controllerStaleAfter = Duration(seconds: 60);

  void _tick() {
    final now = DateTime.now();
    aircraft.removeWhere((_, ac) => now.difference(ac.lastUpdate) > _staleAfter);
    controllers.removeWhere(
        (_, c) => now.difference(c.lastUpdate) > _controllerStaleAfter);
    notifyListeners();
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
    _datafeedTimer?.cancel();
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

  /// Spawns an aircraft at this controller's position. The server gives the
  /// creator the track; we reflect that locally once the aircraft appears.
  void spawnAtField(String callsign) {
    final cs = callsign.trim().toUpperCase();
    if (cs.isEmpty) return;
    sendSimCommand('SPAWN $cs');
    _pendingOwn.add(cs);
  }

  /// Sends a text message to an arbitrary recipient (callsign, "@49999" for ATC
  /// chat, "@18700" for a frequency, "SIM", etc.) and records it locally.
  void sendText(String to, String text) {
    final s = session;
    if (s == null || to.isEmpty || text.isEmpty) return;
    _send('#TM${s.callsign}:$to:$text');
    _record(FsdMessage(s.callsign, to, text));
  }

  /// Ensures a conversation thread exists (e.g. when opening a direct tab).
  void openConversation(String id) {
    conversations.putIfAbsent(id, () {
      conversationOrder.add(id);
      return <FsdMessage>[];
    });
    notifyListeners();
  }

  /// Converts a frequency like "118.700" to its FSD message recipient "@18700".
  static String frequencyRecipient(String mhz) {
    final digits = mhz.replaceAll('.', '');
    return digits.length > 1 ? '@${digits.substring(1)}' : '@$digits';
  }

  // The server is authoritative for sim-aircraft tracks and echoes the change
  // back, so these just send the request.
  void initiateTrack(String target) {
    final s = session;
    if (s == null) return;
    _send('\$CQ${s.callsign}:@94835:IT:$target');
  }

  void dropTrack(String target) {
    final s = session;
    if (s == null) return;
    _send('\$CQ${s.callsign}:@94835:DR:$target');
  }

  /// Offers a handoff of [target] to controller [to] (you must hold the track).
  void initiateHandoff(String target, String to) {
    final s = session;
    if (s == null) return;
    _send('\$HO${s.callsign}:${to.toUpperCase()}:$target');
  }

  /// Accepts an offered handoff: notify the offerer and take the track (HT).
  void acceptHandoff(PendingHandoff ph) {
    final s = session;
    if (s == null) return;
    _send('\$HA${s.callsign}:${ph.from}:${ph.aircraft}');
    _send('\$CQ${s.callsign}:@94835:HT:${ph.aircraft}');
    pendingHandoffs.remove(ph);
    notifyListeners();
  }

  void rejectHandoff(PendingHandoff ph) {
    pendingHandoffs.remove(ph);
    notifyListeners();
  }

  /// Kicks a connection (supervisor only; the server enforces the rating).
  void kick(String callsign) {
    final s = session;
    if (s == null) return;
    _send('\$!!${s.callsign}:${callsign.toUpperCase()}:Kicked by supervisor');
  }

  /// Asks the server for an aircraft's filed flight plan (reply arrives as $FP).
  void requestFlightPlan(String callsign) {
    final s = session;
    if (s == null) return;
    _send('\$CQ${s.callsign}:SERVER:FP:$callsign');
  }

  /// Files/amends a flight plan for an aircraft and reflects it locally.
  void amendFlightPlan(String callsign, FlightPlan fp) {
    final s = session;
    if (s == null) return;
    _send('\$AM${s.callsign}:SERVER:$callsign:${fp.toInfo()}');
    flightPlans[callsign] = fp;
    notifyListeners();
  }

  // --- Conversation recording ---

  void _record(FsdMessage m) {
    final id = _conversationId(m);
    final list = conversations.putIfAbsent(id, () {
      conversationOrder.add(id);
      return <FsdMessage>[];
    });
    list.add(m);
    if (list.length > 500) list.removeAt(0);

    // Surface incoming wallops as a prominent alert.
    if (m.to == '*S' && m.from != myCallsign) {
      activeWallops.add(m);
    }
    notifyListeners();
  }

  void dismissWallop(FsdMessage w) {
    activeWallops.remove(w);
    notifyListeners();
  }

  // --- Supervisor network datafeed polling ---

  Future<void> _pollDatafeed() async {
    final url = session?.datafeedUrl ?? '';
    if (url.isEmpty) return;
    final me = myCallsign;
    try {
      final httpClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      final req = await httpClient.getUrl(Uri.parse(url));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      httpClient.close();
      if (resp.statusCode != 200) return;

      final data = jsonDecode(body) as Map<String, dynamic>;
      networkControllers
        ..clear()
        ..addAll(((data['controllers'] as List?) ?? []).map((c) {
          final m = c as Map<String, dynamic>;
          return NetController(
            callsign: '${m['callsign'] ?? ''}',
            name: '${m['name'] ?? ''}',
            facility: (m['facility'] as num?)?.toInt() ?? 0,
            frequency: '${m['frequency'] ?? ''}',
          );
        }).where((c) => c.callsign != me));
      networkPilots
        ..clear()
        ..addAll(((data['pilots'] as List?) ?? []).map((p) {
          final m = p as Map<String, dynamic>;
          final fp = m['flight_plan'] as Map<String, dynamic>?;
          return NetPilot(
            callsign: '${m['callsign'] ?? ''}',
            name: '${m['name'] ?? ''}',
            altitude: (m['altitude'] as num?)?.toInt() ?? 0,
            groundspeed: (m['groundspeed'] as num?)?.toInt() ?? 0,
            dep: '${fp?['departure'] ?? ''}',
            dest: '${fp?['arrival'] ?? ''}',
            controller: '${m['controller'] ?? ''}',
          );
        }));
      notifyListeners();
    } catch (_) {
      // Ignore transient polling failures.
    }
  }

  String _conversationId(FsdMessage m) {
    if (m.from == myCallsign) return m.to; // outbound -> the recipient
    if (m.to == myCallsign) return m.from; // direct -> the sender
    return m.to; // channel (@49999, @freq, *S)
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
    } else if (head.startsWith('%')) {
      _handleAtcPosition(f);
    } else if (head.startsWith('#AP')) {
      // Aircraft add. We plot it once its first position arrives.
    } else if (head.startsWith('#DP')) {
      aircraft.remove(head.substring(3));
      notifyListeners();
    } else if (head.startsWith('#AA')) {
      final cs = head.substring(3);
      if (cs != myCallsign) {
        controllers.putIfAbsent(cs, () => Controller(callsign: cs)).lastUpdate =
            DateTime.now();
        notifyListeners();
      }
    } else if (head.startsWith('#DA')) {
      controllers.remove(head.substring(3));
      notifyListeners();
    } else if (head.startsWith('#TM')) {
      _handleText(f);
    } else if (head.startsWith('\$CQ')) {
      _handleClientQuery(f);
    } else if (head.startsWith('\$HO')) {
      _handleHandoffRequest(f);
    } else if (head.startsWith('\$FP')) {
      // $FP<callsign>:<to>:<info...>
      if (f.length >= 3) {
        flightPlans[f[0].substring(3)] = FlightPlan.fromInfo(f.sublist(2));
        notifyListeners();
      }
    } else if (head.startsWith('\$AM')) {
      // $AM<from>:<to>:<callsign>:<info...>
      if (f.length >= 4) {
        flightPlans[f[2]] = FlightPlan.fromInfo(f.sublist(3));
        notifyListeners();
      }
    } else if (head.startsWith('\$ER')) {
      final msg = f.length >= 5 ? f.sublist(4).join(':') : line;
      _record(FsdMessage('server', myCallsign, 'ERROR: $msg'));
    }
  }

  // %CALLSIGN:FREQ:FACILITY:VISRANGE:RATING:LAT:LON:ALT
  void _handleAtcPosition(List<String> f) {
    final cs = f[0].substring(1);
    if (cs.isEmpty || cs == myCallsign) return;
    final c = controllers.putIfAbsent(cs, () => Controller(callsign: cs));
    if (f.length > 1) c.frequency = f[1];
    if (f.length > 2) c.facility = int.tryParse(f[2]) ?? c.facility;
    c.lastUpdate = DateTime.now();
    notifyListeners();
  }

  // $HO<FROM>:<TO>:<TARGET>
  void _handleHandoffRequest(List<String> f) {
    if (f.length < 3) return;
    final from = f[0].substring(3);
    final to = f[1];
    final target = f[2];
    if (to != myCallsign) return;
    if (pendingHandoffs.any((h) => h.aircraft == target && h.from == from)) {
      return;
    }
    pendingHandoffs.add(PendingHandoff(from, target));
    notifyListeners();
  }

  // $CQ<FROM>:<RECIPIENT>:<TYPE>:<TARGET>
  // Snoop track changes broadcast by other controllers so the scope shows who
  // currently owns each target.
  void _handleClientQuery(List<String> f) {
    if (f.length < 4) return;
    final from = f[0].substring(3);
    final type = f[2];
    final ac = aircraft[f[3]];
    if (ac == null) return;

    switch (type) {
      case 'IT': // initiate track
      case 'HT': // acquired via handoff
        ac.trackedBy = from;
        notifyListeners();
        break;
      case 'DR': // drop track
        if (ac.trackedBy == from) {
          ac.trackedBy = null;
          notifyListeners();
        }
        break;
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

    // Reflect ownership of aircraft we just spawned.
    if (_pendingOwn.remove(cs)) {
      ac.trackedBy = myCallsign;
    }
  }

  // #TM<FROM>:<TO>:<MESSAGE>
  void _handleText(List<String> f) {
    if (f.length < 3) return;
    final from = f[0].substring(3);
    final to = f[1];
    final msg = f.sublist(2).join(':');
    _record(FsdMessage(from, to, msg));
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}
