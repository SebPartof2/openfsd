import 'package:flutter/material.dart';

import 'fsd/fsd_client.dart';
import 'ui/connect_page.dart';
import 'ui/scope_page.dart';

void main() {
  runApp(const OpenVectorApp());
}

class OpenVectorApp extends StatelessWidget {
  const OpenVectorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenVector',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00C853),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

/// Owns the single FsdClient for the app's lifetime and swaps between the
/// connect screen and the scope based on connection state. Because the scope is
/// not pushed as a route, there is no back button: disconnecting returns here.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final FsdClient _client = FsdClient();
  late bool _connected = _client.connected;

  @override
  void initState() {
    super.initState();
    _client.addListener(_onClientChanged);
  }

  void _onClientChanged() {
    if (_client.connected != _connected) {
      setState(() => _connected = _client.connected);
    }
  }

  @override
  void dispose() {
    _client.removeListener(_onClientChanged);
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _connected
        ? ScopePage(client: _client)
        : ConnectPage(client: _client);
  }
}
