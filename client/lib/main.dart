import 'package:flutter/material.dart';

import 'ui/connect_page.dart';

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
      home: const ConnectPage(),
    );
  }
}
