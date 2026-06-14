import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../fsd/fsd_client.dart';
import '../fsd/models.dart';
import '../fsd/navdata.dart';
import 'messages_panel.dart';

const _globalVerbs = {'SPAWN', 'FIX', 'FIXES'};

/// A selectable map base layer.
class _Basemap {
  final String name;
  final String url;
  final List<String> subdomains;
  final int maxZoom;
  final String? labels; // optional transparent reference/labels overlay

  const _Basemap(this.name, this.url,
      {this.subdomains = const [], this.maxZoom = 19, this.labels});
}

const _basemaps = <_Basemap>[
  _Basemap(
    'Satellite',
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    labels:
        'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
  ),
  _Basemap(
    'Dark',
    'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
    subdomains: ['a', 'b', 'c', 'd'],
    maxZoom: 20,
  ),
  _Basemap('Streets', 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'),
];

/// Colour for an aircraft target by track ownership.
Color trackColor(Aircraft ac, String myCallsign) {
  final owner = ac.trackedBy;
  if (owner == null) return Colors.lightBlueAccent; // untracked
  if (owner == myCallsign) return Colors.greenAccent; // mine
  return Colors.orangeAccent; // another controller
}

class ScopePage extends StatefulWidget {
  final FsdClient client;
  const ScopePage({super.key, required this.client});

  @override
  State<ScopePage> createState() => _ScopePageState();
}

class _ScopePageState extends State<ScopePage> {
  final _mapController = MapController();
  final _cmd = TextEditingController();
  final ValueNotifier<String> _composeTo = ValueNotifier<String>('@49999');

  String? _selected;
  bool _showMessages = true;
  bool _showList = true;
  bool _showNav = true;
  bool _mapReady = false;
  int _basemap = 0;

  NavData _nav = NavData();

  FsdClient get client => widget.client;

  @override
  void dispose() {
    _cmd.dispose();
    _composeTo.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _select(String callsign, {bool center = false}) {
    setState(() => _selected = callsign);
    if (center && _mapReady) {
      final ac = client.aircraft[callsign];
      if (ac != null) {
        _mapController.move(
            ac.extrapolated(DateTime.now()), _mapController.camera.zoom);
      }
    }
  }

  void _onMapTap(TapPosition _, LatLng point) => setState(() => _selected = null);

  // Right-click / long-press: send the selected (owned) aircraft direct to here.
  void _onMapLongPress(TapPosition _, LatLng point) {
    final cs = _selected;
    if (cs == null) return;
    final ac = client.aircraft[cs];
    if (ac == null || ac.trackedBy != client.myCallsign) {
      _toast('Track an aircraft first to vector it');
      return;
    }
    client.sendSimCommand(
        '$cs DCT ${point.latitude.toStringAsFixed(5)} ${point.longitude.toStringAsFixed(5)}');
    _toast('$cs cleared direct to point');
  }

  // ---- Command line (CRC-style dot commands + aircraft control) ----

  void _runCommand(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;

    if (text.startsWith('.')) {
      _runDotCommand(text);
    } else {
      final firstWord = text.split(RegExp(r'\s+')).first.toUpperCase();
      if (_selected != null && !_globalVerbs.contains(firstWord)) {
        client.sendSimCommand('$_selected $text');
      } else {
        client.sendSimCommand(text);
      }
    }
    _cmd.clear();
  }

  void _runDotCommand(String text) {
    final parts = text.split(RegExp(r'\s+'));
    final cmd = parts[0].toLowerCase();

    switch (cmd) {
      case '.msg':
      case '.m':
        if (parts.length < 3) {
          _toast('Usage: .msg <recipient> <message>');
          return;
        }
        client.sendText(_resolveRecipient(parts[1]), parts.sublist(2).join(' '));
        break;
      case '.chat':
      case '.c':
        if (parts.length < 2) {
          _toast('Usage: .chat <recipient>');
          return;
        }
        _composeTo.value = _resolveRecipient(parts[1]);
        setState(() => _showMessages = true);
        break;
      case '.wallop':
      case '.w':
        if (parts.length < 2) {
          _toast('Usage: .wallop <message>');
          return;
        }
        client.sendText('*S', parts.sublist(1).join(' '));
        break;
      case '.atc':
        if (parts.length >= 2) {
          client.sendText('@49999', parts.sublist(1).join(' '));
        }
        break;
      default:
        _toast('Unknown command: $cmd');
    }
  }

  String _resolveRecipient(String to) {
    if (to.startsWith('@') || to.startsWith('*')) return to;
    if (RegExp(r'^\d{2,3}\.\d{1,3}$').hasMatch(to)) {
      return FsdClient.frequencyRecipient(to);
    }
    return to.toUpperCase();
  }

  void _toggleTrack() {
    final cs = _selected;
    if (cs == null) return;
    final ac = client.aircraft[cs];
    if (ac == null) return;
    if (ac.trackedBy == client.myCallsign) {
      client.dropTrack(cs);
    } else {
      client.initiateTrack(cs);
    }
  }

  // Spawn at the controller's vis center (server places it there when no
  // coordinates are given).
  Future<void> _openSpawnDialog() async {
    final callsign = TextEditingController(text: 'HAL1');
    final hdg = TextEditingController(text: '0');
    final alt = TextEditingController(text: '0');
    final spd = TextEditingController(text: '0');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Spawn aircraft at field'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: callsign,
                decoration: const InputDecoration(labelText: 'Callsign')),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: hdg,
                      decoration: const InputDecoration(labelText: 'Heading'))),
              const SizedBox(width: 8),
              Expanded(
                  child: TextField(
                      controller: alt,
                      decoration:
                          const InputDecoration(labelText: 'Altitude'))),
              const SizedBox(width: 8),
              Expanded(
                  child: TextField(
                      controller: spd,
                      decoration: const InputDecoration(labelText: 'Speed'))),
            ]),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Spawn')),
        ],
      ),
    );

    if (ok == true) {
      client.sendSimCommand('SPAWN ${callsign.text.trim().toUpperCase()} '
          '${hdg.text.trim()} ${alt.text.trim()} ${spd.text.trim()}');
    }
  }

  Future<void> _openNavDialog() async {
    final airports = TextEditingController();
    final navaids = TextEditingController();
    final fixes = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Load navdata'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Paste absolute file paths. OurAirports CSVs (public domain) and '
                'X-Plane earth_fix.dat are supported. Leave a field blank to skip.',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 12),
              TextField(
                  controller: airports,
                  decoration:
                      const InputDecoration(labelText: 'airports.csv path')),
              TextField(
                  controller: navaids,
                  decoration:
                      const InputDecoration(labelText: 'navaids.csv path')),
              TextField(
                  controller: fixes,
                  decoration:
                      const InputDecoration(labelText: 'earth_fix.dat path')),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Load')),
        ],
      ),
    );

    if (ok != true) return;

    final nav = NavData();
    var total = 0;
    try {
      if (airports.text.trim().isNotEmpty) {
        total += await nav.loadAirportsCsv(airports.text.trim());
      }
      if (navaids.text.trim().isNotEmpty) {
        total += await nav.loadNavaidsCsv(navaids.text.trim());
      }
      if (fixes.text.trim().isNotEmpty) {
        total += await nav.loadXPlaneFixes(fixes.text.trim());
      }
    } catch (e) {
      _toast('Navdata load failed: $e');
      return;
    }

    setState(() => _nav = nav);
    _toast('Loaded $total navdata points');
  }

  List<Widget> _tileLayers() {
    final bm = _basemaps[_basemap];
    final layers = <Widget>[
      TileLayer(
        urlTemplate: bm.url,
        subdomains: bm.subdomains,
        maxNativeZoom: bm.maxZoom,
        userAgentPackageName: 'com.openvector.client',
      ),
    ];
    if (bm.labels != null) {
      layers.add(TileLayer(
        urlTemplate: bm.labels!,
        maxNativeZoom: bm.maxZoom,
        userAgentPackageName: 'com.openvector.client',
      ));
    }
    return layers;
  }

  List<Marker> _buildAircraftMarkers() {
    final now = DateTime.now();
    return client.aircraft.values.map((ac) {
      return Marker(
        point: ac.extrapolated(now),
        width: 130,
        height: 76,
        child: _AircraftSymbol(
          aircraft: ac,
          selected: ac.callsign == _selected,
          myCallsign: client.myCallsign,
          onTap: () => _select(ac.callsign),
        ),
      );
    }).toList();
  }

  List<Marker> _buildNavMarkers() {
    if (!_mapReady || !_showNav || _nav.isEmpty) return const [];
    final cam = _mapController.camera;
    final bounds = cam.visibleBounds;

    final markers = <Marker>[];
    for (final p in _nav.points) {
      if (!bounds.contains(p.pos)) continue;
      markers.add(Marker(
        point: p.pos,
        width: 90,
        height: 26,
        child: _NavSymbol(point: p, showLabel: cam.zoom >= 12),
      ));
      if (markers.length >= 600) break;
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final s = client.session!;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.circle, color: Colors.greenAccent, size: 12),
            const SizedBox(width: 8),
            Text('OpenVector — ${s.callsign}'),
          ],
        ),
        actions: [
          ListenableBuilder(
            listenable: client,
            builder: (_, __) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text('${client.aircraft.length} tgt',
                    style: const TextStyle(color: Colors.greenAccent)),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Aircraft list',
            icon: Icon(_showList ? Icons.list : Icons.list_alt_outlined),
            onPressed: () => setState(() => _showList = !_showList),
          ),
          IconButton(
            tooltip: 'Basemap: ${_basemaps[_basemap].name}',
            icon: const Icon(Icons.map),
            onPressed: () => setState(
                () => _basemap = (_basemap + 1) % _basemaps.length),
          ),
          IconButton(
            tooltip: 'Toggle navdata (${_nav.length})',
            icon: Icon(_showNav ? Icons.layers : Icons.layers_clear),
            onPressed: () => setState(() => _showNav = !_showNav),
          ),
          IconButton(
            tooltip: 'Load navdata',
            icon: const Icon(Icons.folder_open),
            onPressed: _openNavDialog,
          ),
          IconButton(
            tooltip: 'Messages',
            icon: Icon(_showMessages ? Icons.forum : Icons.forum_outlined),
            onPressed: () => setState(() => _showMessages = !_showMessages),
          ),
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.logout),
            onPressed: client.disconnect,
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: ListenableBuilder(
              listenable: client,
              builder: (_, __) => FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: s.center,
                  initialZoom: 14,
                  minZoom: 11,
                  maxZoom: 19,
                  cameraConstraint: CameraConstraint.contain(
                    bounds: LatLngBounds(
                      LatLng(s.center.latitude - 0.4, s.center.longitude - 0.4),
                      LatLng(s.center.latitude + 0.4, s.center.longitude + 0.4),
                    ),
                  ),
                  onTap: _onMapTap,
                  onLongPress: _onMapLongPress,
                  onSecondaryTap: _onMapLongPress,
                  onMapReady: () => setState(() => _mapReady = true),
                ),
                children: [
                  ..._tileLayers(),
                  MarkerLayer(markers: _buildNavMarkers()),
                  MarkerLayer(markers: _buildAircraftMarkers()),
                ],
              ),
            ),
          ),
          if (_showList)
            Positioned(
              left: 8,
              top: 8,
              bottom: 76,
              width: 260,
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                color: const Color(0xF20E1411),
                child: _aircraftList(),
              ),
            ),
          if (_showMessages)
            Positioned(
              right: 8,
              top: 8,
              bottom: 76,
              width: 340,
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: MessagesPanel(client: client, composeTo: _composeTo),
              ),
            ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _commandBar(),
          ),
        ],
      ),
    );
  }

  Widget _aircraftList() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(8),
          child: Row(children: [
            Icon(Icons.flight, size: 18),
            SizedBox(width: 8),
            Text('Aircraft', style: TextStyle(fontWeight: FontWeight.bold)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListenableBuilder(
            listenable: client,
            builder: (_, __) {
              final list = client.aircraft.values.toList()
                ..sort((a, b) => a.callsign.compareTo(b.callsign));
              if (list.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No aircraft',
                        style: TextStyle(color: Colors.white38)),
                  ),
                );
              }
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final ac = list[i];
                  final fl = (ac.altitude / 100).round().toString().padLeft(3, '0');
                  final owner = ac.trackedBy;
                  final ownerStr = (owner != null && owner != client.myCallsign)
                      ? '  @$owner'
                      : '';
                  return ListTile(
                    dense: true,
                    selected: ac.callsign == _selected,
                    selectedTileColor: Colors.white10,
                    leading: Icon(Icons.circle,
                        size: 12, color: trackColor(ac, client.myCallsign)),
                    title: Text(ac.callsign,
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text('FL$fl · ${ac.groundspeed}kt$ownerStr',
                        style: const TextStyle(fontSize: 11)),
                    onTap: () => _select(ac.callsign, center: true),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _commandBar() {
    return Material(
      elevation: 8,
      color: const Color(0xF20E1411),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Spawn aircraft at field',
              icon: const Icon(Icons.flight_takeoff),
              onPressed: _openSpawnDialog,
            ),
            if (_selected != null)
              ListenableBuilder(
                listenable: client,
                builder: (_, __) {
                  final ac = client.aircraft[_selected];
                  final mine = ac?.trackedBy == client.myCallsign;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InputChip(
                      label: Text(_selected!),
                      avatar:
                          Icon(mine ? Icons.link : Icons.link_off, size: 16),
                      onPressed: _toggleTrack,
                      onDeleted: () => setState(() => _selected = null),
                    ),
                  );
                },
              ),
            Expanded(
              child: TextField(
                controller: _cmd,
                textInputAction: TextInputAction.send,
                onSubmitted: _runCommand,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: _selected == null
                      ? 'Command   ·   .msg <cs> hi   ·   SPAWN AAL123 …'
                      : '$_selected: FH 270 / C 5000 / DCT TWY   ·   .msg …',
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: () => _runCommand(_cmd.text),
            ),
          ],
        ),
      ),
    );
  }
}

class _AircraftSymbol extends StatelessWidget {
  final Aircraft aircraft;
  final bool selected;
  final String myCallsign;
  final VoidCallback onTap;

  const _AircraftSymbol({
    required this.aircraft,
    required this.selected,
    required this.myCallsign,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        selected ? Colors.amber : trackColor(aircraft, myCallsign);
    final fl = (aircraft.altitude / 100).round().toString().padLeft(3, '0');
    final owner = aircraft.trackedBy;

    final tag =
        StringBuffer('${aircraft.callsign}\n$fl ${aircraft.groundspeed}');
    if (owner != null && owner != myCallsign) {
      tag.write('\n@$owner');
    }

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.rotate(
            angle: aircraft.heading * pi / 180.0,
            child: Icon(Icons.navigation, color: color, size: 22),
          ),
          const SizedBox(height: 2),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              child: Text(
                tag.toString(),
                textAlign: TextAlign.center,
                style: TextStyle(color: color, fontSize: 10, height: 1.1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavSymbol extends StatelessWidget {
  final NavPoint point;
  final bool showLabel;

  const _NavSymbol({required this.point, required this.showLabel});

  @override
  Widget build(BuildContext context) {
    late final IconData icon;
    late final Color color;
    switch (point.kind) {
      case NavKind.airport:
        icon = Icons.local_airport;
        color = Colors.white70;
        break;
      case NavKind.vor:
        icon = Icons.hexagon_outlined;
        color = Colors.cyanAccent;
        break;
      case NavKind.ndb:
        icon = Icons.circle_outlined;
        color = Colors.cyanAccent;
        break;
      case NavKind.fix:
        icon = Icons.change_history; // triangle
        color = Colors.tealAccent;
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 12),
        if (showLabel)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(point.ident,
                style: TextStyle(color: color, fontSize: 9)),
          ),
      ],
    );
  }
}
