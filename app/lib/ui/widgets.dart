import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';

/// Circular avatar with initials and a presence dot.
class PeerAvatar extends StatelessWidget {
  const PeerAvatar({
    super.key,
    required this.name,
    this.presence = Presence.unknown,
    this.radius = 22,
    this.color,
  });

  final String name;
  final Presence presence;
  final double radius;
  final Color? color;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = color ?? scheme.primaryContainer;
    final dotColor = switch (presence) {
      Presence.lan => Colors.green,
      Presence.online => Colors.lightGreen,
      Presence.offline => Colors.grey,
      Presence.unknown => Colors.transparent,
    };
    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: Stack(
        children: [
          Container(
            width: radius * 2,
            height: radius * 2,
            decoration: BoxDecoration(
              color: base,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              _initials,
              style: TextStyle(
                fontSize: radius * 0.75,
                fontWeight: FontWeight.w600,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ),
          if (presence != Presence.unknown)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: radius * 0.55,
                height: radius * 0.55,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Delivery state ticks for outgoing messages.
class StatusTicks extends StatelessWidget {
  const StatusTicks({super.key, required this.state, this.color});

  final DeliveryState state;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final icon = switch (state) {
      DeliveryState.sending => Icons.schedule,
      DeliveryState.sent => Icons.check,
      DeliveryState.delivered => Icons.done_all,
      DeliveryState.read => Icons.done_all,
      DeliveryState.failed => Icons.error_outline,
    };
    final c = switch (state) {
      DeliveryState.read => Colors.lightBlueAccent,
      DeliveryState.failed => Colors.redAccent,
      _ => color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return Icon(icon, size: 15, color: c);
  }
}

String formatTime(int millis) {
  final dt = DateTime.fromMillisecondsSinceEpoch(millis);
  final now = DateTime.now();
  if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
    return DateFormat.Hm().format(dt);
  }
  if (now.difference(dt).inDays < 7) {
    return DateFormat.E().format(dt);
  }
  return DateFormat.yMd().format(dt);
}

/// A chat bubble for text or attachment messages.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.senderName,
    required this.showSender,
    required this.progress,
    this.onTapFile,
  });

  final Message message;
  final String senderName;
  final bool showSender;
  final double? progress; // null when not transferring
  final VoidCallback? onTapFile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final outgoing = message.outgoing;
    final bubbleColor =
        outgoing ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final textColor =
        outgoing ? scheme.onPrimaryContainer : scheme.onSurface;

    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(outgoing ? 18 : 4),
            bottomRight: Radius.circular(outgoing ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!outgoing && showSender)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  senderName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ),
            _content(context, textColor),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  formatTime(message.createdAt),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: textColor.withValues(alpha: 0.6),
                  ),
                ),
                if (outgoing) ...[
                  const SizedBox(width: 4),
                  StatusTicks(state: message.state, color: textColor),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, Color textColor) {
    switch (message.kind) {
      case MessageKind.text:
        return SelectableText(
          message.text,
          style: TextStyle(fontSize: 14.5, color: textColor, height: 1.3),
        );
      case MessageKind.notice:
        return Text(
          message.text,
          style: TextStyle(
            fontSize: 12.5,
            fontStyle: FontStyle.italic,
            color: textColor,
          ),
        );
      case MessageKind.image:
      case MessageKind.file:
        return _FileBody(
          message: message,
          progress: progress,
          textColor: textColor,
          onTap: onTapFile,
        );
    }
  }
}

class _FileBody extends StatelessWidget {
  const _FileBody({
    required this.message,
    required this.progress,
    required this.textColor,
    this.onTap,
  });

  final Message message;
  final double? progress;
  final Color textColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isImage = message.kind == MessageKind.image &&
        message.localPath != null &&
        progress == null;
    final transferring = progress != null && progress! < 1.0;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                File(message.localPath!),
                width: 260,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          InkWell(
            onTap: transferring ? null : onTap,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    message.kind == MessageKind.image
                        ? Icons.image_outlined
                        : _iconForMime(message.mimeType),
                    color: textColor,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.fileName ?? 'file',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                        Text(
                          message.fileSize != null
                              ? formatBytes(message.fileSize!)
                              : '',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: textColor.withValues(alpha: 0.65),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (transferring)
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: progress,
                        color: textColor,
                      ),
                    )
                  else if (message.localPath != null)
                    Icon(Icons.download_done, size: 18, color: textColor)
                  else if (message.state == DeliveryState.failed)
                    Icon(Icons.error_outline, size: 18, color: Colors.redAccent),
                ],
              ),
            ),
          ),
          if (transferring)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static IconData _iconForMime(String? mime) {
    if (mime == null) return Icons.insert_drive_file_outlined;
    if (mime.startsWith('video/')) return Icons.videocam_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (mime.contains('zip') || mime.contains('compressed')) {
      return Icons.folder_zip_outlined;
    }
    if (mime.startsWith('text/')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }
}

/// Animated three-dot typing indicator.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = (_c.value - i * 0.18) % 1.0;
            final dy = -3 * (t < 0.35 ? (t / 0.35) : (1 - t) / 0.65).clamp(0.0, 1.0);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Transform.translate(
                offset: Offset(0, dy),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
