import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../fsd/fsd_client.dart';
import '../fsd/models.dart';
import '../fsd/navdata.dart';
import 'messages_panel.dart';

const _globalVerbs = {'SPAWN', 'FIX', 'FIXES'};

class ScopePage extends StatefulWidget {
  final FsdClient client;
  const ScopePage({super.key, required this.client});

  @override
  State<ScopePage> createState() => _ScopePageState();
}

class _ScopePageState extends State<ScopePage> {
  final _mapController = MapController();
  final _cmd = TextEditingController();

  String? _selected;
  bool _spawnMode = false;
  bool _showMessages = true;
  bool _showNav = true;
  bool _mapReady = false;

  NavData _nav = NavData();

  FsdClient get client => widget.client;

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _onMapTap(TapPosition _, LatLng point) {
    if (_spawnMode) {
      _openSpawnDialog(point);
      setState(() => _spawnMode = false);
    } else {
      setState(() => _selected = null);
    }
  }

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

  void _sendCommand(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    final firstWord = text.split(RegExp(r'\s+')).first.toUpperCase();
    if (_selected != null && !_globalVerbs.contains(firstWord)) {
      client.sendSimCommand('$_selected $text');
    } else {
      client.sendSimCommand(text);
    }
    _cmd.clear();
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

  Future<void> _openSpawnDialog(LatLng at) async {
    final callsign = TextEditingController(text: 'AAL123');
    final hdg = TextEditingController(text: '90');
    final alt = TextEditingController(text: '5000');
    final spd = TextEditingController(text: '250');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Spawn aircraft'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
                'At ${at.latitude.toStringAsFixed(4)}, ${at.longitude.toStringAsFixed(4)}'),
            const SizedBox(height: 8),
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
          '${at.latitude.toStringAsFixed(5)} ${at.longitude.toStringAsFixed(5)} '
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
                'X-Plane earth_fix.dat are supported. Leave a field blank to skip it.',
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
                  decoration: const InputDecoration(
                      labelText: 'earth_fix.dat path')),
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
          onTap: () => setState(() => _selected = ac.callsign),
        ),
      );
    }).toList();
  }

  List<Marker> _buildNavMarkers() {
    if (!_mapReady || !_showNav || _nav.isEmpty) return const [];
    final cam = _mapController.camera;
    final bounds = cam.visibleBounds;
    final zoom = cam.zoom;

    final markers = <Marker>[];
    for (final p in _nav.points) {
      if (p.kind == NavKind.fix && zoom < 6.5) continue;
      if ((p.kind == NavKind.vor || p.kind == NavKind.ndb) && zoom < 5) {
        continue;
      }
      if (!bounds.contains(p.pos)) continue;
      markers.add(Marker(
        point: p.pos,
        width: 90,
        height: 26,
        child: _NavSymbol(point: p, showLabel: zoom >= 7),
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
        title: Text('OpenVector — ${s.callsign}'),
        actions: [
          ListenableBuilder(
            listenable: client,
            builder: (_, __) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text(
                  '${client.aircraft.length} tgt'
                  '${client.connected ? '' : '  (disconnected)'}',
                  style: TextStyle(
                      color:
                          client.connected ? Colors.greenAccent : Colors.red),
                ),
              ),
            ),
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
            icon: const Icon(Icons.forum),
            onPressed: () => setState(() => _showMessages = !_showMessages),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _spawnMode ? Colors.orange : null,
        onPressed: () => setState(() => _spawnMode = !_spawnMode),
        icon: const Icon(Icons.add_location_alt),
        label: Text(_spawnMode ? 'Tap map to spawn' : 'Spawn'),
      ),
      body: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: ListenableBuilder(
                    listenable: client,
                    builder: (_, __) => FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: s.center,
                        initialZoom: 7,
                        onTap: _onMapTap,
                        onLongPress: _onMapLongPress,
                        onSecondaryTap: _onMapLongPress,
                        onMapReady: () => setState(() => _mapReady = true),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.openvector.client',
                        ),
                        MarkerLayer(markers: _buildNavMarkers()),
                        MarkerLayer(markers: _buildAircraftMarkers()),
                      ],
                    ),
                  ),
                ),
                _buildControlBar(),
              ],
            ),
          ),
          if (_showMessages) MessagesPanel(client: client),
        ],
      ),
    );
  }

  Widget _buildControlBar() {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          if (_selected != null)
            ListenableBuilder(
              listenable: client,
              builder: (_, __) {
                final ac = client.aircraft[_selected];
                final mine = ac?.trackedBy == client.myCallsign;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.tonalIcon(
                    onPressed: _toggleTrack,
                    icon: Icon(mine ? Icons.link_off : Icons.link),
                    label: Text(mine ? 'Drop $_selected' : 'Track $_selected'),
                  ),
                );
              },
            ),
          Expanded(
            child: TextField(
              controller: _cmd,
              textInputAction: TextInputAction.send,
              onSubmitted: _sendCommand,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: _selected == null
                    ? 'Command (e.g. SPAWN AAL123 …)'
                    : 'Command for $_selected (FH 270, C 12000, DCT ALPHA)',
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: () => _sendCommand(_cmd.text),
          ),
        ],
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

  Color get _color {
    if (selected) return Colors.amber;
    final owner = aircraft.trackedBy;
    if (owner == null) return Colors.lightBlueAccent; // untracked
    if (owner == myCallsign) return Colors.greenAccent; // mine
    return Colors.orangeAccent; // tracked by another controller
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
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
