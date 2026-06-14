import 'package:flutter/material.dart';

import '../fsd/fsd_client.dart';
import '../fsd/models.dart';

/// Display-only FSD message log. Sending is done from the unified command line.
class MessagesPanel extends StatefulWidget {
  final FsdClient client;
  const MessagesPanel({super.key, required this.client});

  @override
  State<MessagesPanel> createState() => _MessagesPanelState();
}

class _MessagesPanelState extends State<MessagesPanel> {
  final _scroll = ScrollController();

  FsdClient get client => widget.client;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Color _channelColor(String channel) {
    switch (channel) {
      case 'SERVER':
        return Colors.white70;
      case 'SIM':
        return Colors.greenAccent;
      case 'ATC':
        return Colors.lightBlueAccent;
      case 'FREQ':
        return Colors.amberAccent;
      case 'WALLOP':
        return Colors.redAccent;
      default:
        return Colors.white;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0E1411),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(8),
            child: Row(children: [
              Icon(Icons.forum, size: 18),
              SizedBox(width: 8),
              Text('Messages', style: TextStyle(fontWeight: FontWeight.bold)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: client,
              builder: (_, __) {
                _autoScroll();
                final msgs = client.messages;
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(8),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) => _row(msgs[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(FsdMessage m) {
    final t =
        '${m.time.hour.toString().padLeft(2, '0')}:${m.time.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontSize: 12, height: 1.2),
          children: [
            TextSpan(
                text: '$t ', style: const TextStyle(color: Colors.white38)),
            TextSpan(
              text: '[${m.channel}] ',
              style: TextStyle(
                  color: _channelColor(m.channel),
                  fontWeight: FontWeight.bold),
            ),
            TextSpan(
                text: '${m.from}: ',
                style: const TextStyle(color: Colors.white70)),
            TextSpan(text: m.text, style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
