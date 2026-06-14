import 'package:flutter/material.dart';

import '../fsd/fsd_client.dart';
import '../fsd/models.dart';
import 'messages_panel.dart';

const _globalVerbs = {'SPAWN', 'FIX', 'FIXES'};

/// Colour for an aircraft by track ownership.
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
  final _cmd = TextEditingController();

  String? _selected; // aircraft being commanded
  String? _chatTarget; // recipient for plain-text messages (set via .chat)
  bool _showMessages = true;

  FsdClient get client => widget.client;

  @override
  void dispose() {
    _cmd.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _selectAircraft(String callsign) {
    setState(() {
      _selected = callsign;
      _chatTarget = null; // commanding an aircraft, not chatting
    });
  }

  // ---- Unified command line: commands and messages share one input ----
  //
  // Routing on submit:
  //   .cmd …          -> CRC-style dot command (always)
  //   SPAWN/FIX …      -> server command (always)
  //   chat target set  -> sent as a text message to that recipient
  //   aircraft selected-> sent as a command for that aircraft
  //   otherwise        -> sent as a server command
  void _submit(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;

    if (text.startsWith('.')) {
      _runDotCommand(text);
      _cmd.clear();
      return;
    }

    final firstWord = text.split(RegExp(r'\s+')).first.toUpperCase();
    if (_globalVerbs.contains(firstWord)) {
      client.sendSimCommand(text);
    } else if (_chatTarget != null) {
      client.sendText(_chatTarget!, text);
    } else if (_selected != null) {
      client.sendSimCommand('$_selected $text');
    } else {
      client.sendSimCommand(text);
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
        setState(() {
          _chatTarget = _resolveRecipient(parts[1]);
          _selected = null;
          _showMessages = true;
        });
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

  void _toggleTrack(String callsign) {
    final ac = client.aircraft[callsign];
    if (ac == null) return;
    if (ac.trackedBy == client.myCallsign) {
      client.dropTrack(callsign);
    } else {
      client.initiateTrack(callsign);
    }
  }

  Future<void> _openSpawnDialog() async {
    final callsign = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Spawn aircraft'),
        content: TextField(
          controller: callsign,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Callsign'),
          onSubmitted: (_) => Navigator.pop(ctx, true),
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

    if (ok == true && callsign.text.trim().isNotEmpty) {
      client.spawnAtField(callsign.text);
    }
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
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _aircraftList()),
                if (_showMessages)
                  SizedBox(width: 360, child: MessagesPanel(client: client)),
              ],
            ),
          ),
          _commandBar(),
        ],
      ),
    );
  }

  Widget _aircraftList() {
    return Container(
      color: const Color(0xFF0B0F0D),
      child: ListenableBuilder(
        listenable: client,
        builder: (_, __) {
          final list = client.aircraft.values.toList()
            ..sort((a, b) => a.callsign.compareTo(b.callsign));
          if (list.isEmpty) {
            return const Center(
              child: Text('No aircraft — Spawn one',
                  style: TextStyle(color: Colors.white38)),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) => _aircraftRow(list[i]),
          );
        },
      ),
    );
  }

  Widget _aircraftRow(Aircraft ac) {
    final fl = (ac.altitude / 100).round().toString().padLeft(3, '0');
    final hdg = ac.heading.round().toString().padLeft(3, '0');
    final owner = ac.trackedBy;
    final mine = owner == client.myCallsign;
    final ownerStr = (owner != null && !mine) ? '   ◂ $owner' : '';

    return ListTile(
      dense: true,
      selected: ac.callsign == _selected,
      selectedTileColor: Colors.white10,
      leading: Icon(Icons.circle,
          size: 14, color: trackColor(ac, client.myCallsign)),
      title: Text(ac.callsign,
          style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(
        'FL$fl   ${ac.groundspeed} kt   H$hdg   sq ${ac.squawk}$ownerStr',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: IconButton(
        tooltip: mine ? 'Drop track' : 'Track',
        icon: Icon(mine ? Icons.link : Icons.link_off,
            color: mine ? Colors.greenAccent : Colors.white54),
        onPressed: () => _toggleTrack(ac.callsign),
      ),
      onTap: () => _selectAircraft(ac.callsign),
    );
  }

  Widget _commandBar() {
    final chatting = _chatTarget != null;
    final hint = chatting
        ? 'Message $_chatTarget   ·   .cmd to run a command'
        : _selected != null
            ? '$_selected: FH 270 / C 5000 / S 210   ·   .msg …'
            : 'Command or .msg <cs> hi   ·   SPAWN AAL123';

    return Material(
      color: const Color(0xFF0E1411),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Spawn aircraft',
              icon: const Icon(Icons.add_circle, color: Colors.greenAccent),
              onPressed: _openSpawnDialog,
            ),
            if (chatting)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InputChip(
                  avatar: const Icon(Icons.chat_bubble_outline, size: 16),
                  label: Text(_chatTarget!),
                  onDeleted: () => setState(() => _chatTarget = null),
                ),
              )
            else if (_selected != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InputChip(
                  avatar: const Icon(Icons.flight, size: 16),
                  label: Text(_selected!),
                  onDeleted: () => setState(() => _selected = null),
                ),
              ),
            Expanded(
              child: TextField(
                controller: _cmd,
                textInputAction: TextInputAction.send,
                onSubmitted: _submit,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  hintText: hint,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: () => _submit(_cmd.text),
            ),
          ],
        ),
      ),
    );
  }
}
