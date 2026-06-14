import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../fsd/fsd_client.dart';
import 'scope_page.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _host = TextEditingController(text: 'connect.radar.contact');
  final _port = TextEditingController(text: '6809');
  final _callsign = TextEditingController(text: 'LAX_APP');
  final _cid = TextEditingController(text: '1');
  final _password = TextEditingController();
  final _rating = TextEditingController(text: '12');
  final _facility = TextEditingController(text: '5');
  final _lat = TextEditingController(text: '34.0');
  final _lon = TextEditingController(text: '-118.0');
  final _vis = TextEditingController(text: '500');

  bool _connecting = false;
  String? _error;

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });

    final client = FsdClient();
    final session = FsdSession(
      host: _host.text.trim(),
      port: int.tryParse(_port.text) ?? 6809,
      callsign: _callsign.text.trim().toUpperCase(),
      cid: int.tryParse(_cid.text) ?? 0,
      password: _password.text,
      rating: int.tryParse(_rating.text) ?? 1,
      facility: int.tryParse(_facility.text) ?? 5,
      center: LatLng(
        double.tryParse(_lat.text) ?? 0,
        double.tryParse(_lon.text) ?? 0,
      ),
      visRangeNm: double.tryParse(_vis.text) ?? 500,
    );

    await client.connect(session);

    if (!mounted) return;
    if (!client.connected) {
      setState(() {
        _connecting = false;
        _error = client.error ?? 'Could not connect';
      });
      client.dispose();
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ScopePage(client: client)),
    ).then((_) {
      client.dispose();
      if (mounted) setState(() => _connecting = false);
    });
  }

  Widget _field(String label, TextEditingController c, {bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: c,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OpenVector — Connect')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(children: [
                Expanded(flex: 3, child: _field('Server host', _host)),
                const SizedBox(width: 8),
                Expanded(flex: 1, child: _field('Port', _port)),
              ]),
              _field('Callsign', _callsign),
              Row(children: [
                Expanded(child: _field('CID', _cid)),
                const SizedBox(width: 8),
                Expanded(child: _field('Rating', _rating)),
                const SizedBox(width: 8),
                Expanded(child: _field('Facility', _facility)),
              ]),
              _field('Password', _password, obscure: true),
              Row(children: [
                Expanded(child: _field('Center lat', _lat)),
                const SizedBox(width: 8),
                Expanded(child: _field('Center lon', _lon)),
                const SizedBox(width: 8),
                Expanded(child: _field('Vis (NM)', _vis)),
              ]),
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)),
                ),
              FilledButton.icon(
                onPressed: _connecting ? null : _connect,
                icon: _connecting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.radar),
                label: Text(_connecting ? 'Connecting…' : 'Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
