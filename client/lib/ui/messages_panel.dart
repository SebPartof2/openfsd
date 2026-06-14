import 'package:flutter/material.dart';

import '../fsd/fsd_client.dart';
import '../fsd/models.dart';

/// Tabbed message panel: one thread per conversation (direct controller, ATC
/// chat, frequency, SIM, server). Sending is done from the unified command line;
/// selecting a tab makes it the active reply target.
class MessagesPanel extends StatefulWidget {
  final FsdClient client;
  final String? activeId;
  final ValueChanged<String> onSelect;

  const MessagesPanel({
    super.key,
    required this.client,
    required this.activeId,
    required this.onSelect,
  });

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

  String _label(String id) {
    if (id == '@49999') return 'ATC';
    if (id == '*S') return 'WALLOP';
    if (id.startsWith('@')) {
      final d = id.substring(1);
      final full = '1$d';
      return full.length >= 4
          ? '${full.substring(0, 3)}.${full.substring(3)}'
          : id;
    }
    return id;
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
      child: ListenableBuilder(
        listenable: client,
        builder: (_, __) {
          final ids = client.conversationOrder;
          final active = widget.activeId;
          final msgs = (active != null ? client.conversations[active] : null) ??
              const <FsdMessage>[];
          _autoScroll();

          return Column(
            children: [
              SizedBox(
                height: 44,
                child: ids.isEmpty
                    ? const Center(
                        child: Text('No messages',
                            style: TextStyle(color: Colors.white38)))
                    : ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        children: [
                          for (final id in ids)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 3, vertical: 6),
                              child: ChoiceChip(
                                label: Text(_label(id),
                                    style: const TextStyle(fontSize: 12)),
                                selected: id == active,
                                onSelected: (_) => widget.onSelect(id),
                              ),
                            ),
                        ],
                      ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(8),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) => _row(msgs[i]),
                ),
              ),
            ],
          );
        },
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
                text: '${m.from}: ',
                style: TextStyle(
                    color: _channelColor(m.channel),
                    fontWeight: FontWeight.bold)),
            TextSpan(text: m.text, style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
