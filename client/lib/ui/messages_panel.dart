import 'package:flutter/material.dart';

import '../fsd/fsd_client.dart';
import '../fsd/models.dart';

/// A dockable FSD message window: scrollback of all text traffic plus a send bar
/// with an addressable recipient.
class MessagesPanel extends StatefulWidget {
  final FsdClient client;
  const MessagesPanel({super.key, required this.client});

  @override
  State<MessagesPanel> createState() => _MessagesPanelState();
}

class _MessagesPanelState extends State<MessagesPanel> {
  final _to = TextEditingController(text: '@49999');
  final _text = TextEditingController();
  final _scroll = ScrollController();

  FsdClient get client => widget.client;

  void _send() {
    final to = _to.text.trim();
    final text = _text.text.trim();
    if (to.isEmpty || text.isEmpty) return;
    client.sendText(to, text);
    _text.clear();
    _autoScroll();
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
      width: 340,
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
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Row(children: [
                  SizedBox(
                    width: 96,
                    child: TextField(
                      controller: _to,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'To',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Message',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.send), onPressed: _send),
                ]),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(spacing: 6, children: [
                    _quickTo('ATC', '@49999'),
                    _quickTo('Wallop', '*S'),
                    _quickTo('SIM', 'SIM'),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickTo(String label, String value) => ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 11)),
        onPressed: () => _to.text = value,
        visualDensity: VisualDensity.compact,
      );

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
