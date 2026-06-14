import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fsd/fsd_client.dart';

class ConnectPage extends StatefulWidget {
  final FsdClient client;
  const ConnectPage({super.key, required this.client});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  // Defaults: Honolulu Tower (PHNL).
  final _host = TextEditingController(text: 'connect.radar.contact');
  final _port = TextEditingController(text: '6809');
  final _callsign = TextEditingController(text: 'HNL_TWR');
  final _cid = TextEditingController(text: '1');
  final _password = TextEditingController();
  final _rating = TextEditingController(text: '12');
  final _lat = TextEditingController(text: '21.3187');
  final _lon = TextEditingController(text: '-157.9224');
  final _vis = TextEditingController(text: '500');
  final _datafeed = TextEditingController(
      text: 'https://admin.radar.contact/api/v1/data/openfsd-data.json');

  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    for (final c in [
      _host,
      _port,
      _callsign,
      _cid,
      _password,
      _rating,
      _lat,
      _lon,
      _vis,
      _datafeed,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _host.text = p.getString('host') ?? _host.text;
      _port.text = p.getString('port') ?? _port.text;
      _callsign.text = p.getString('callsign') ?? _callsign.text;
      _cid.text = p.getString('cid') ?? _cid.text;
      _password.text = p.getString('password') ?? _password.text;
      _rating.text = p.getString('rating') ?? _rating.text;
      _lat.text = p.getString('lat') ?? _lat.text;
      _lon.text = p.getString('lon') ?? _lon.text;
      _vis.text = p.getString('vis') ?? _vis.text;
      _datafeed.text = p.getString('datafeed') ?? _datafeed.text;
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('host', _host.text.trim());
    await p.setString('port', _port.text.trim());
    await p.setString('callsign', _callsign.text.trim());
    await p.setString('cid', _cid.text.trim());
    await p.setString('password', _password.text);
    await p.setString('rating', _rating.text.trim());
    await p.setString('lat', _lat.text.trim());
    await p.setString('lon', _lon.text.trim());
    await p.setString('vis', _vis.text.trim());
    await p.setString('datafeed', _datafeed.text.trim());
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });

    await _savePrefs();

    final callsign = _callsign.text.trim().toUpperCase();
    final session = FsdSession(
      host: _host.text.trim(),
      port: int.tryParse(_port.text) ?? 6809,
      callsign: callsign,
      cid: int.tryParse(_cid.text) ?? 0,
      password: _password.text,
      rating: int.tryParse(_rating.text) ?? 1,
      facility: facilityForCallsign(callsign),
      center: LatLng(
        double.tryParse(_lat.text) ?? 0,
        double.tryParse(_lon.text) ?? 0,
      ),
      visRangeNm: double.tryParse(_vis.text) ?? 500,
      datafeedUrl: _datafeed.text.trim(),
    );

    // On success, HomePage swaps to the scope automatically.
    await widget.client.connect(session);

    if (!mounted) return;
    setState(() {
      _connecting = false;
      if (!widget.client.connected) {
        _error = widget.client.error ?? 'Could not connect';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.radar, color: Colors.greenAccent, size: 28),
                  SizedBox(width: 10),
                  Text('OpenVector',
                      style: TextStyle(
                          fontSize: 28, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 24),
              _section('Server', [
                Row(children: [
                  Expanded(flex: 3, child: _field('Address', _host)),
                  const SizedBox(width: 12),
                  Expanded(flex: 1, child: _field('Port', _port)),
                ]),
              ]),
              _section('Controller', [
                TextField(
                  controller: _callsign,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Callsign',
                    helperText:
                        'Position is set by the suffix (_GND, _TWR, …); '
                        '_SUP/_ADM enables supervisor mode',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 6),
                _positionHint(),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _field('CID', _cid)),
                  const SizedBox(width: 12),
                  Expanded(child: _field('Network rating', _rating)),
                ]),
                const SizedBox(height: 12),
                _field('Password', _password, obscure: true),
              ]),
              _section('Scope centre', [
                Row(children: [
                  Expanded(child: _field('Latitude', _lat)),
                  const SizedBox(width: 12),
                  Expanded(child: _field('Longitude', _lon)),
                  const SizedBox(width: 12),
                  Expanded(child: _field('Range (NM)', _vis)),
                ]),
              ]),
              _section('Supervisor', [
                _field('Datafeed URL', _datafeed),
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Used for the network-wide view when connected as _SUP/_ADM.',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ),
              ]),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)),
                ),
              const SizedBox(height: 16),
              SizedBox(
                height: 48,
                child: FilledButton.icon(
                  onPressed: _connecting ? null : _connect,
                  icon: _connecting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.login),
                  label: Text(_connecting ? 'Connecting…' : 'Connect'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _positionHint() {
    final cs = _callsign.text.trim();
    final fac = facilityLabel(facilityForCallsign(cs));
    final sup = isSupervisorCallsign(cs);
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          Chip(
            label: Text('Position: $fac'),
            visualDensity: VisualDensity.compact,
          ),
          if (sup)
            Chip(
              avatar: const Icon(Icons.shield, size: 16, color: Colors.black),
              backgroundColor: Colors.amber,
              label: const Text('Supervisor',
                  style: TextStyle(color: Colors.black)),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title.toUpperCase(),
                style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.bold,
                    color: Colors.greenAccent.shade100)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController c, {bool obscure = false}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}
