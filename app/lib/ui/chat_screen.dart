import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/chat_store.dart';
import 'home_screen.dart' show conversationTitle;
import 'widgets.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _composing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatStore>().openConversation(widget.conversationId);
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onInputChanged(String v) {
    final hasText = v.trim().isNotEmpty;
    if (hasText != _composing) {
      setState(() => _composing = hasText);
    }
    if (hasText) {
      context.read<ChatStore>().sendTyping(widget.conversationId);
    }
  }

  Future<void> _sendText() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    setState(() => _composing = false);
    await context.read<ChatStore>().sendText(widget.conversationId, text);
  }

  Future<void> _pickAndSendFile({bool imageOnly = false}) async {
    final picked = await FilePicker.pickFile(
      type: imageOnly ? FileType.image : FileType.any,
    );
    final path = picked?.path;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    final size = await file.length();
    final name = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : 'file';
    final mime = _guessMime(name);
    final kind = (imageOnly || mime.startsWith('image/'))
        ? MessageKind.image
        : MessageKind.file;
    if (!mounted) return;
    await context.read<ChatStore>().sendFile(
          widget.conversationId,
          path,
          fileName: name,
          size: size,
          mime: mime,
          kind: kind,
        );
  }

  static String _guessMime(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'mp3' => 'audio/mpeg',
      'wav' => 'audio/wav',
      'pdf' => 'application/pdf',
      'zip' => 'application/zip',
      'txt' => 'text/plain',
      'json' => 'application/json',
      _ => 'application/octet-stream',
    };
  }

  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo / Image'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndSendFile(imageOnly: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Any file'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndSendFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _onFileTap(Message m) {
    final path = m.localPath;
    if (path == null) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                m.fileName ?? 'file',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Saved location'),
              subtitle: Text(path, style: const TextStyle(fontSize: 12)),
            ),
            if (m.kind == MessageKind.image)
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('View full screen'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => _ImageViewer(path: path, name: m.fileName ?? 'image'),
                    ),
                  );
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final scheme = Theme.of(context).colorScheme;
    final conv = store.conversations[widget.conversationId];
    if (conv == null) {
      return const Scaffold(body: Center(child: Text('Conversation unavailable')));
    }
    final title = conversationTitle(store, conv);
    final msgs = store.messagesIn(widget.conversationId);
    final typing = store.isPeerTyping(widget.conversationId);

    String subtitle;
    if (conv.isGroup) {
      subtitle = '${conv.memberIds.length} members';
    } else {
      final other =
          conv.memberIds.firstWhere((m) => m != store.myId, orElse: () => '');
      final c = store.contacts[other];
      final lan = store.nearbyPeers.containsKey(other);
      subtitle = lan
          ? 'Nearby • direct LAN'
          : (c?.presence == Presence.online
              ? 'Online • via relay'
              : (store.relayConnected ? 'Offline' : 'Disconnected'));
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            PeerAvatar(
              name: title,
              radius: 18,
              presence: conv.isGroup
                  ? Presence.unknown
                  : (store.nearbyPeers.containsKey(
                          conv.memberIds.firstWhere((m) => m != store.myId, orElse: () => ''))
                      ? Presence.lan
                      : (store.contacts[conv.memberIds.firstWhere((m) => m != store.myId, orElse: () => '')]?.presence ??
                          Presence.unknown)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  Text(
                    typing ? 'typing…' : subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: typing ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: msgs.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.lock_outline, size: 44, color: scheme.outline),
                          const SizedBox(height: 12),
                          Text(
                            'Messages are end-to-end encrypted',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Only you and ${conv.isGroup ? 'group members' : title} can read them.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    itemCount: msgs.length + (typing ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (typing && index == 0) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 9),
                                decoration: BoxDecoration(
                                  color: scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const TypingDots(),
                              ),
                            ],
                          ),
                        );
                      }
                      final i = typing ? index - 1 : index;
                      final m = msgs[msgs.length - 1 - i];
                      final prev = i + 1 < msgs.length
                          ? msgs[msgs.length - 2 - i]
                          : null;
                      final showSender = conv.isGroup &&
                          !m.outgoing &&
                          (prev == null || prev.senderId != m.senderId);
                      double? progress;
                      if (m.isAttachment) {
                        if (m.outgoing) {
                          final pr = store.sendProgress[m.id];
                          progress = (pr != null && pr < 1.0) ? pr : null;
                        } else {
                          progress = m.localPath == null
                              ? (m.transferProgress < 1.0 ? m.transferProgress : null)
                              : null;
                        }
                      }
                      return MessageBubble(
                        message: m,
                        senderName: store.displayNameFor(m.senderId),
                        showSender: showSender,
                        progress: progress,
                        onTapFile: m.isAttachment ? () => _onFileTap(m) : null,
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton.filledTonal(
                    icon: const Icon(Icons.attach_file_rounded),
                    onPressed: _showAttachmentSheet,
                    tooltip: 'Send file or image',
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      onChanged: _onInputChanged,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendText(),
                      decoration: InputDecoration(
                        hintText: 'Message…',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _composing
                      ? IconButton.filled(
                          icon: const Icon(Icons.send_rounded),
                          onPressed: _sendText,
                          tooltip: 'Send',
                        )
                      : const SizedBox.shrink(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.path, required this.name});

  final String path;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.file(File(path),
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image, color: Colors.white54, size: 64)),
        ),
      ),
    );
  }
}
