import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../fsd/fsd_client.dart';
import '../fsd/models.dart';

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

  FsdClient get client => widget.client;

  void _onMapTap(TapPosition _, LatLng point) {
    if (_spawnMode) {
      _openSpawnDialog(point);
      setState(() => _spawnMode = false);
    } else {
      setState(() => _selected = null);
    }
  }

  void _sendCommand(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    final firstWord = text.split(RegExp(r'\s+')).first.toUpperCase();

    // Prefix the selected callsign for per-aircraft commands.
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
    if (ac.trackedByMe) {
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
                      decoration: const InputDecoration(labelText: 'Altitude'))),
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
      client.sendSimCommand(
          'SPAWN ${callsign.text.trim().toUpperCase()} '
          '${at.latitude.toStringAsFixed(5)} ${at.longitude.toStringAsFixed(5)} '
          '${hdg.text.trim()} ${alt.text.trim()} ${spd.text.trim()}');
    }
  }

  List<Marker> _buildMarkers() {
    final now = DateTime.now();
    return client.aircraft.values.map((ac) {
      final selected = ac.callsign == _selected;
      return Marker(
        point: ac.extrapolated(now),
        width: 120,
        height: 64,
        child: _AircraftSymbol(
          aircraft: ac,
          selected: selected,
          onTap: () => setState(() => _selected = ac.callsign),
        ),
      );
    }).toList();
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
              padding: const EdgeInsets.only(right: 16),
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
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _spawnMode ? Colors.orange : null,
        onPressed: () => setState(() => _spawnMode = !_spawnMode),
        icon: const Icon(Icons.add_location_alt),
        label: Text(_spawnMode ? 'Tap map to spawn' : 'Spawn'),
      ),
      body: Column(
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
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.openvector.client',
                  ),
                  MarkerLayer(markers: _buildMarkers()),
                ],
              ),
            ),
          ),
          _buildControlBar(),
        ],
      ),
    );
  }

  Widget _buildControlBar() {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (_selected != null)
                ListenableBuilder(
                  listenable: client,
                  builder: (_, __) {
                    final ac = client.aircraft[_selected];
                    final tracked = ac?.trackedByMe ?? false;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilledButton.tonalIcon(
                        onPressed: _toggleTrack,
                        icon: Icon(tracked ? Icons.link_off : Icons.link),
                        label: Text(tracked ? 'Drop $_selected' : 'Track $_selected'),
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
                        : 'Command for $_selected (e.g. FH 270, C 12000, DCT ALPHA)',
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: () => _sendCommand(_cmd.text),
              ),
            ],
          ),
          ListenableBuilder(
            listenable: client,
            builder: (_, __) {
              final last =
                  client.messages.isEmpty ? '' : client.messages.last;
              return Align(
                alignment: Alignment.centerLeft,
                child: Text(last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12)),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AircraftSymbol extends StatelessWidget {
  final Aircraft aircraft;
  final bool selected;
  final VoidCallback onTap;

  const _AircraftSymbol({
    required this.aircraft,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? Colors.amber
        : (aircraft.trackedByMe ? Colors.greenAccent : Colors.lightBlueAccent);
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
                '${aircraft.callsign}\n'
                '${(aircraft.altitude / 100).round().toString().padLeft(3, '0')} '
                '${aircraft.groundspeed}',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: color, fontSize: 10, height: 1.1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
