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
  String? _chatTarget; // active conversation / message recipient
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
      _chatTarget = null;
    });
  }

  void _openChat(String recipient) {
    client.openConversation(recipient);
    setState(() {
      _chatTarget = recipient;
      _selected = null;
      _showMessages = true;
    });
  }

  bool _ownsSelected() =>
      _selected != null &&
      client.aircraft[_selected]?.trackedBy == client.myCallsign;

  // ---- Unified command line: commands and messages share one input ----
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
        final to = _resolveRecipient(parts[1]);
        client.sendText(to, parts.sublist(2).join(' '));
        _openChat(to);
        break;
      case '.chat':
      case '.c':
        if (parts.length < 2) {
          _toast('Usage: .chat <recipient>');
          return;
        }
        _openChat(_resolveRecipient(parts[1]));
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
      case '.kick':
        if (!(client.session?.isSupervisor ?? false)) {
          _toast('Supervisor only (connect as _SUP / _ADM)');
          return;
        }
        if (parts.length < 2) {
          _toast('Usage: .kick <callsign>');
          return;
        }
        client.kick(parts[1]);
        _toast('Kicked ${parts[1].toUpperCase()}');
        break;
      case '.ho':
      case '.handoff':
        if (_selected == null) {
          _toast('Select an aircraft you control first');
          return;
        }
        if (!_ownsSelected()) {
          _toast('You do not control $_selected');
          return;
        }
        if (parts.length < 2) {
          _toast('Usage: .ho <controller>');
          return;
        }
        client.initiateHandoff(_selected!, parts[1]);
        _toast('Handoff $_selected → ${parts[1].toUpperCase()}');
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

  Future<void> _confirmKick(String callsign) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Kick $callsign?'),
        content: const Text('This disconnects the connection from the network.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Kick')),
        ],
      ),
    );
    if (ok == true) {
      client.kick(callsign);
      _toast('Kicked $callsign');
    }
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
          autocorrect: false,
          enableSuggestions: false,
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
            if (s.isSupervisor) ...[
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('SUP',
                    style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
              ),
            ],
          ],
        ),
        actions: [
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
          _wallopBanner(),
          _handoffBanner(),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _leftPanel()),
                if (_showMessages)
                  SizedBox(
                    width: 360,
                    child: MessagesPanel(
                      client: client,
                      activeId: _chatTarget,
                      onSelect: (id) => setState(() {
                        _chatTarget = id;
                        _selected = null;
                      }),
                    ),
                  ),
              ],
            ),
          ),
          _commandBar(),
        ],
      ),
    );
  }

  Widget _wallopBanner() {
    return ListenableBuilder(
      listenable: client,
      builder: (_, __) {
        if (client.activeWallops.isEmpty) return const SizedBox.shrink();
        return Column(
          children: [
            for (final w in client.activeWallops)
              Container(
                color: const Color(0xFF4A0E0E),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    const Icon(Icons.campaign, color: Colors.redAccent),
                    const SizedBox(width: 8),
                    Expanded(child: Text('WALLOP ${w.from}: ${w.text}')),
                    TextButton(
                      onPressed: () {
                        _openChat(w.from);
                        client.dismissWallop(w);
                      },
                      child: const Text('Reply'),
                    ),
                    TextButton(
                      onPressed: () => client.dismissWallop(w),
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _handoffBanner() {
    return ListenableBuilder(
      listenable: client,
      builder: (_, __) {
        if (client.pendingHandoffs.isEmpty) return const SizedBox.shrink();
        return Column(
          children: [
            for (final ph in client.pendingHandoffs)
              Container(
                color: const Color(0xFF3A2E00),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    const Icon(Icons.swap_horiz, color: Colors.amberAccent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          'Handoff: ${ph.aircraft} from ${ph.from}'),
                    ),
                    TextButton(
                      onPressed: () => client.acceptHandoff(ph),
                      child: const Text('Accept'),
                    ),
                    TextButton(
                      onPressed: () => client.rejectHandoff(ph),
                      child: const Text('Reject'),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _leftPanel() {
    final isSup = client.session?.isSupervisor ?? false;
    return DefaultTabController(
      length: isSup ? 3 : 2,
      child: Container(
        color: const Color(0xFF0B0F0D),
        child: ListenableBuilder(
          listenable: client,
          builder: (_, __) => Column(
            children: [
              TabBar(
                isScrollable: isSup,
                tabs: [
                  Tab(text: 'Aircraft ${client.aircraft.length}'),
                  Tab(text: 'ATC ${client.controllers.length}'),
                  if (isSup)
                    Tab(
                        text: 'Network '
                            '${client.networkControllers.length + client.networkPilots.length}'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _aircraftList(),
                    _controllerList(),
                    if (isSup) _networkList(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String text) => Container(
        width: double.infinity,
        color: Colors.white10,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1,
                fontWeight: FontWeight.bold,
                color: Colors.white70)),
      );

  Widget _netKickButton(String callsign) => IconButton(
        tooltip: 'Kick',
        iconSize: 20,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32),
        icon: const Icon(Icons.gpp_bad, color: Colors.redAccent),
        onPressed: () => _confirmKick(callsign),
      );

  Widget _networkList() {
    final controllers = client.networkControllers;
    final pilots = client.networkPilots;
    if (controllers.isEmpty && pilots.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Waiting for datafeed…\nCheck the Datafeed URL.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38)),
        ),
      );
    }
    return ListView(
      children: [
        _sectionHeader('CONTROLLERS (${controllers.length})'),
        for (final c in controllers)
          ListTile(
            dense: true,
            leading: const Icon(Icons.headset_mic, size: 18),
            title: Text(c.callsign,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
                '${facilityLabel(c.facility)}  ${frequencyMhz(c.frequency)}'
                '${c.name.isNotEmpty ? '  ·  ${c.name}' : ''}',
                style: const TextStyle(fontSize: 12)),
            trailing: _netKickButton(c.callsign),
            onTap: () => _openChat(c.callsign),
          ),
        _sectionHeader('PILOTS (${pilots.length})'),
        for (final p in pilots)
          ListTile(
            dense: true,
            leading: Icon(Icons.flight,
                size: 18,
                color: p.controller.isNotEmpty
                    ? Colors.greenAccent
                    : Colors.lightBlueAccent),
            title: Text(p.callsign,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(_netPilotDetail(p),
                style: const TextStyle(fontSize: 12)),
            trailing: _netKickButton(p.callsign),
            onTap: () => _openChat(p.callsign),
          ),
      ],
    );
  }

  String _netPilotDetail(NetPilot p) {
    final fl = (p.altitude / 100).round().toString().padLeft(3, '0');
    final route = (p.dep.isNotEmpty || p.dest.isNotEmpty)
        ? '   ${p.dep.isEmpty ? '?' : p.dep}→${p.dest.isEmpty ? '?' : p.dest}'
        : '';
    final ctrl = p.controller.isNotEmpty ? '   ◂ ${p.controller}' : '';
    return 'FL$fl  ${p.groundspeed}kt$route$ctrl';
  }

  Widget _aircraftList() {
    final list = client.aircraft.values.toList()
      ..sort((a, b) => a.callsign.compareTo(b.callsign));
    if (list.isEmpty) {
      return const Center(
          child: Text('No aircraft — Spawn one',
              style: TextStyle(color: Colors.white38)));
    }
    return ListView.separated(
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) => _aircraftRow(list[i]),
    );
  }

  Widget _aircraftRow(Aircraft ac) {
    final fl = (ac.altitude / 100).round().toString().padLeft(3, '0');
    final hdg = ac.heading.round().toString().padLeft(3, '0');
    final owner = ac.trackedBy;
    final mine = owner == client.myCallsign;
    final ownerStr = (owner != null && !mine) ? '   ◂ $owner' : '';
    final fp = client.flightPlans[ac.callsign];
    final route = fp != null
        ? '${fp.dep.isEmpty ? '?' : fp.dep} → ${fp.dest.isEmpty ? '?' : fp.dest}'
        : null;

    return ListTile(
      dense: true,
      selected: ac.callsign == _selected,
      selectedTileColor: Colors.white10,
      leading: Icon(Icons.circle,
          size: 14, color: trackColor(ac, client.myCallsign)),
      title: Text(ac.callsign,
          style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('FL$fl  ${ac.groundspeed}kt  H$hdg  sq ${ac.squawk}$ownerStr',
              style: const TextStyle(fontSize: 12)),
          if (route != null)
            Text(route,
                style: const TextStyle(
                    fontSize: 11, color: Colors.lightBlueAccent)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Flight plan',
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32),
            icon: const Icon(Icons.description_outlined),
            onPressed: () => _openFlightPlanEditor(ac.callsign),
          ),
          IconButton(
            tooltip: mine ? 'Drop track' : 'Track',
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32),
            icon: Icon(mine ? Icons.link : Icons.link_off,
                color: mine ? Colors.greenAccent : Colors.white54),
            onPressed: () => _toggleTrack(ac.callsign),
          ),
          if (client.session?.isSupervisor ?? false)
            IconButton(
              tooltip: 'Kick',
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32),
              icon: const Icon(Icons.gpp_bad, color: Colors.redAccent),
              onPressed: () => _confirmKick(ac.callsign),
            ),
        ],
      ),
      onTap: () => _selectAircraft(ac.callsign),
    );
  }

  Future<void> _openFlightPlanEditor(String callsign) async {
    client.requestFlightPlan(callsign); // refresh from server for next time
    final fp = client.flightPlans[callsign] ?? FlightPlan();

    final acft = TextEditingController(text: fp.aircraft);
    final dep = TextEditingController(text: fp.dep);
    final dest = TextEditingController(text: fp.dest);
    final cruise =
        TextEditingController(text: fp.cruise == '0' ? '' : fp.cruise);
    final route = TextEditingController(text: fp.route);
    final remarks = TextEditingController(text: fp.remarks);
    var rules = fp.rules;

    InputDecoration dec(String l) => InputDecoration(
        labelText: l, border: const OutlineInputBorder(), isDense: true);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Flight plan — $callsign'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        value: rules,
                        isExpanded: true,
                        decoration: dec('Rules'),
                        items: const [
                          DropdownMenuItem(value: 'I', child: Text('IFR')),
                          DropdownMenuItem(value: 'V', child: Text('VFR')),
                          DropdownMenuItem(value: 'D', child: Text('DVFR')),
                          DropdownMenuItem(value: 'S', child: Text('SVFR')),
                        ],
                        onChanged: (v) => setLocal(() => rules = v ?? rules),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                        flex: 3,
                        child: TextField(
                            controller: acft,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: dec('Aircraft'))),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: dep,
                            autocorrect: false,
                            enableSuggestions: false,
                            textCapitalization: TextCapitalization.characters,
                            decoration: dec('From'))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: TextField(
                            controller: dest,
                            autocorrect: false,
                            enableSuggestions: false,
                            textCapitalization: TextCapitalization.characters,
                            decoration: dec('To'))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: TextField(
                            controller: cruise,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: dec('Cruise'))),
                  ]),
                  const SizedBox(height: 8),
                  TextField(
                      controller: route,
                      autocorrect: false,
                      enableSuggestions: false,
                      minLines: 1,
                      maxLines: 3,
                      decoration: dec('Route')),
                  const SizedBox(height: 8),
                  TextField(
                      controller: remarks,
                      autocorrect: false,
                      enableSuggestions: false,
                      minLines: 1,
                      maxLines: 3,
                      decoration: dec('Remarks')),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('File')),
          ],
        ),
      ),
    );

    if (ok == true) {
      fp.rules = rules;
      fp.aircraft = acft.text.trim();
      fp.dep = dep.text.trim().toUpperCase();
      fp.dest = dest.text.trim().toUpperCase();
      fp.cruise = cruise.text.trim().isEmpty ? '0' : cruise.text.trim();
      fp.route = route.text.trim();
      fp.remarks = remarks.text.trim();
      client.amendFlightPlan(callsign, fp);
    }
  }

  Widget _controllerList() {
    final list = client.controllers.values.toList()
      ..sort((a, b) => a.callsign.compareTo(b.callsign));
    if (list.isEmpty) {
      return const Center(
          child: Text('No other controllers online',
              style: TextStyle(color: Colors.white38)));
    }
    return ListView.separated(
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final c = list[i];
        final canHandoff = _ownsSelected();
        return ListTile(
          dense: true,
          leading: const Icon(Icons.headset_mic, size: 18),
          title: Text(c.callsign,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('${c.facilityName}   ${c.frequencyMhz}',
              style: const TextStyle(fontSize: 12)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canHandoff)
                IconButton(
                  tooltip: 'Handoff $_selected to ${c.callsign}',
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32),
                  icon: const Icon(Icons.swap_horiz),
                  onPressed: () {
                    client.initiateHandoff(_selected!, c.callsign);
                    _toast('Handoff $_selected → ${c.callsign}');
                  },
                ),
              if (client.session?.isSupervisor ?? false)
                IconButton(
                  tooltip: 'Kick',
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32),
                  icon: const Icon(Icons.gpp_bad, color: Colors.redAccent),
                  onPressed: () => _confirmKick(c.callsign),
                ),
            ],
          ),
          onTap: () => _openChat(c.callsign),
        );
      },
    );
  }

  Widget _commandBar() {
    final chatting = _chatTarget != null;
    final hint = chatting
        ? 'Message $_chatTarget   ·   .cmd to run a command'
        : _selected != null
            ? '$_selected: FH 270 / C 5000 / .ho <atc>'
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
                autocorrect: false,
                enableSuggestions: false,
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
