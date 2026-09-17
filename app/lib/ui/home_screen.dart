import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/chat_store.dart';
import 'chat_screen.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [ChatsTab(), NearbyTab(), SettingsTab()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.wifi_tethering_outlined),
            selectedIcon: Icon(Icons.wifi_tethering),
            label: 'Nearby',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

String conversationTitle(ChatStore store, Conversation c) {
  if (c.isGroup) return c.title ?? 'Group';
  final other = c.memberIds.firstWhere((m) => m != store.myId, orElse: () => c.id);
  return store.displayNameFor(other);
}

Presence conversationPresence(ChatStore store, Conversation c) {
  if (c.isGroup) return Presence.unknown;
  final other =
      c.memberIds.firstWhere((m) => m != store.myId, orElse: () => '');
  return store.contacts[other]?.presence ?? Presence.unknown;
}

void openChat(BuildContext context, String convId) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ChatScreen(conversationId: convId)),
  );
}

/* ------------------------------------------------------------------ Chats */

class ChatsTab extends StatelessWidget {
  const ChatsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final scheme = Theme.of(context).colorScheme;
    final convs = store.conversations.values.toList()
      ..sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));

    return Scaffold(
      appBar: AppBar(
        title: const Text('1190 Chat'),
        actions: [
          _ConnectionChip(),
          IconButton(
            tooltip: 'New group',
            icon: const Icon(Icons.group_add_outlined),
            onPressed: () => _showNewGroupDialog(context, store),
          ),
        ],
      ),
      body: convs.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.chat_bubble_outline,
                        size: 56, color: scheme.outline),
                    const SizedBox(height: 16),
                    Text(
                      'No conversations yet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Head to the Nearby tab to find devices on your network, '
                      'or add a contact by their 1190 Chat ID.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              itemCount: convs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final c = convs[i];
                final title = conversationTitle(store, c);
                final presence = conversationPresence(store, c);
                return ListTile(
                  leading: c.isGroup
                      ? PeerAvatar(
                          name: title, color: scheme.tertiaryContainer)
                      : PeerAvatar(name: title, presence: presence),
                  title: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    c.lastMessagePreview.isEmpty
                        ? 'No messages yet'
                        : c.lastMessagePreview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (c.lastMessageAt > 0)
                        Text(
                          formatTime(c.lastMessageAt),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      if (c.unread > 0) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${c.unread}',
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onPrimary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  onTap: () => openChat(context, c.id),
                );
              },
            ),
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final scheme = Theme.of(context).colorScheme;
    final lanOn = store.lanActive;
    final relayOn = store.relayConnected;
    final label = relayOn
        ? 'Relay online'
        : lanOn
            ? 'LAN active'
            : 'Offline';
    final color = relayOn
        ? Colors.green
        : lanOn
            ? Colors.lightGreen
            : scheme.outline;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ----------------------------------------------------------------- Nearby */

class NearbyTab extends StatelessWidget {
  const NearbyTab({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final scheme = Theme.of(context).colorScheme;

    final nearby = store.nearbyPeers.values.toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    final contacts = store.contacts.values.toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby & Contacts'),
        actions: [
          IconButton(
            tooltip: 'Add contact by ID',
            icon: const Icon(Icons.person_add_alt),
            onPressed: () => _showAddContactDialog(context, store),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _sectionHeader(context, 'On this network', nearby.length),
          if (nearby.isEmpty)
            _emptyHint(
              context,
              store.lanEnabled
                  ? 'Listening for nearby devices… Make sure the other device has 1190 Chat open on the same Wi‑Fi/network.'
                  : 'LAN discovery is disabled in Settings.',
            )
          else
            ...nearby.map(
              (peer) => ListTile(
                leading: PeerAvatar(name: peer.displayName, presence: Presence.lan),
                title: Text(peer.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  '${peer.address} • ${peer.userId}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  // Ensure we have their key as a contact, then open the DM.
                  try {
                    await store.addContactById(peer.userId);
                  } catch (_) {}
                  if (!context.mounted) return;
                  final conv = store.openDm(peer.userId);
                  openChat(context, conv.id);
                },
              ),
            ),
          const SizedBox(height: 8),
          _sectionHeader(context, 'All contacts', contacts.length),
          if (contacts.isEmpty)
            _emptyHint(
              context,
              'No contacts yet. Tap + to add someone by their 1190 Chat ID, or tap a nearby device above.',
            )
          else
            ...contacts.map(
              (c) => ListTile(
                leading: PeerAvatar(name: c.displayName, presence: c.presence),
                title: Text(c.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(c.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  final conv = store.openDm(c.id);
                  openChat(context, conv.id);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title, int count) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('$count',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }

  Widget _emptyHint(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Text(text,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
    );
  }
}

/* --------------------------------------------------------------- dialogs */

Future<void> _showAddContactDialog(BuildContext context, ChatStore store) async {
  final controller = TextEditingController();
  final id = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Add contact'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Enter their 1190 Chat ID (starts with c_). They can find it under Settings.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'c_…',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add')),
      ],
    ),
  );
  if (id == null || id.isEmpty || !context.mounted) return;
  try {
    await store.addContactById(id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact added')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }
}

Future<void> _showNewGroupDialog(BuildContext context, ChatStore store) async {
  final contacts = store.contacts.values.toList();
  if (contacts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Add at least one contact first')),
    );
    return;
  }
  final selected = <String>{};
  final titleController = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('New group'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(
                  labelText: 'Group name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: contacts
                      .map(
                        (c) => CheckboxListTile(
                          value: selected.contains(c.id),
                          title: Text(c.displayName),
                          subtitle: Text(c.id,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onChanged: (v) => setLocal(() {
                            if (v == true) {
                              selected.add(c.id);
                            } else {
                              selected.remove(c.id);
                            }
                          }),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.pop(ctx, true),
            child: const Text('Create'),
          ),
        ],
      ),
    ),
  );
  if (ok == true && selected.isNotEmpty) {
    await store.createGroup(titleController.text, selected.toList());
  }
}

/* --------------------------------------------------------------- Settings */

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  late final TextEditingController _serverController;

  @override
  void initState() {
    super.initState();
    _serverController =
        TextEditingController(text: context.read<ChatStore>().serverUrl);
  }

  @override
  void dispose() {
    _serverController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          ListTile(
            leading: PeerAvatar(name: store.myName, color: scheme.primaryContainer),
            title: Text(store.myName,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(store.myId),
            trailing: IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _editName(context, store),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('Your 1190 Chat ID'),
            subtitle: Text(store.myId),
            trailing: IconButton(
              icon: const Icon(Icons.copy_rounded),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: store.myId));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('ID copied')),
                );
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('Key fingerprint'),
            subtitle: Text(store.myFingerprint),
            trailing: IconButton(
              icon: const Icon(Icons.copy_rounded),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: store.myFingerprint));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Fingerprint copied')),
                );
              },
            ),
          ),
          const Divider(),
          SwitchListTile(
            secondary: const Icon(Icons.wifi_tethering_outlined),
            title: const Text('LAN discovery'),
            subtitle: Text(
              store.lanActive
                  ? 'Visible to nearby devices'
                  : 'Find & transfer directly on the same network',
            ),
            value: store.lanEnabled,
            onChanged: (v) => store.setLanEnabled(v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_outlined),
            title: const Text('Internet relay'),
            subtitle: Text(
              store.relayConnected ? 'Connected' : 'Reach contacts anywhere',
            ),
            value: store.relayEnabled,
            onChanged: (v) => store.setRelayEnabled(v),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Relay server URL'),
            subtitle: TextField(
              controller: _serverController,
              decoration: const InputDecoration(
                hintText: 'http://host:8090',
                isDense: true,
              ),
              keyboardType: TextInputType.url,
              onSubmitted: (v) => store.setServerUrl(v),
            ),
            trailing: TextButton(
              onPressed: () => store.setServerUrl(_serverController.text),
              child: const Text('Save'),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About 1190 Chat'),
            subtitle: const Text(
              'v0.1.0 • X25519 + AES-256-GCM end-to-end encryption',
            ),
          ),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
            title: Text('Reset app data', style: TextStyle(color: scheme.error)),
            subtitle: const Text('Erase identity, contacts and messages'),
            onTap: () => _confirmReset(context, store),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _editName(BuildContext context, ChatStore store) async {
    final controller = TextEditingController(text: store.myName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await store.updateDisplayName(name);
    }
  }

  Future<void> _confirmReset(BuildContext context, ChatStore store) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset everything?'),
        content: const Text(
          'This erases your identity keys, contacts and all messages on this '
          'device. This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (ok == true) await store.resetAll();
  }
}
