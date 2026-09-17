import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/chat_store.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _nameController = TextEditingController();
  final _serverController = TextEditingController();
  bool _busy = false;
  bool _showServer = false;

  @override
  void dispose() {
    _nameController.dispose();
    _serverController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    final store = context.read<ChatStore>();
    if (_showServer && _serverController.text.trim().isNotEmpty) {
      await store.setServerUrl(_serverController.text.trim());
    }
    await store.completeOnboarding(_nameController.text);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primaryContainer, scheme.surface],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(
                          Icons.bolt_rounded,
                          size: 44,
                          color: scheme.onPrimary,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Welcome to 1190 Chat',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'End-to-end encrypted messaging and file transfer. '
                        'Devices on the same network connect directly; '
                        'everywhere else, an encrypted relay carries sealed '
                        'packets it cannot read.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.45,
                            ),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _nameController,
                        autofocus: true,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Display name',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _busy ? null : _finish(),
                      ),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: () => setState(() => _showServer = !_showServer),
                        icon: const Icon(Icons.dns_outlined, size: 18),
                        label: Text(
                          _showServer ? 'Hide relay server' : 'Add relay server (optional)',
                        ),
                      ),
                      if (_showServer) ...[
                        TextField(
                          controller: _serverController,
                          decoration: const InputDecoration(
                            labelText: 'Relay server URL',
                            hintText: 'http://192.168.1.10:8090',
                            prefixIcon: Icon(Icons.cloud_outlined),
                            border: OutlineInputBorder(),
                            helperText:
                                'Leave empty to use LAN-only mode. You run this server yourself (see server/ folder).',
                          ),
                          keyboardType: TextInputType.url,
                        ),
                        const SizedBox(height: 12),
                      ],
                      FilledButton.icon(
                        onPressed: _busy ? null : _finish,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.arrow_forward_rounded),
                        label: Text(
                          _busy ? 'Generating keys…' : 'Create my identity',
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Icon(Icons.shield_outlined,
                              size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'A X25519 key pair is generated on this device and never leaves it.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
