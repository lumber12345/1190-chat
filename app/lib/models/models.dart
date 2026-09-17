import 'dart:convert';
import 'dart:typed_data';

/// High-level models shared across the app.

enum MessageKind { text, image, file, notice }

enum DeliveryState {
  sending, // sealed, not yet handed to a transport
  sent, // accepted by transport / relay
  delivered, // recipient acknowledged receipt
  read, // recipient opened it
  failed,
}

enum Presence { unknown, online, offline, lan }

class Contact {
  Contact({
    required this.id,
    required this.displayName,
    required this.publicKey,
    this.presence = Presence.unknown,
    this.lastSeen = 0,
  });

  /// Stable user id (the routing handle).
  final String id;
  String displayName;

  /// X25519 public key, 32 bytes.
  Uint8List publicKey;

  Presence presence;
  int lastSeen;

  bool get isNearby => presence == Presence.lan;

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'publicKey': base64Encode(publicKey),
        'presence': presence.name,
        'lastSeen': lastSeen,
      };

  static Contact fromJson(Map<String, dynamic> j) => Contact(
        id: j['id'] as String,
        displayName: j['displayName'] as String? ?? j['id'] as String,
        publicKey: base64Decode(j['publicKey'] as String),
        presence: Presence.values.firstWhere(
          (p) => p.name == j['presence'],
          orElse: () => Presence.unknown,
        ),
        lastSeen: (j['lastSeen'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toRow() => {
        'id': id,
        'displayName': displayName,
        'publicKey': publicKey,
        'lastSeen': lastSeen,
      };

  static Contact fromRow(Map<String, dynamic> r) => Contact(
        id: r['id'] as String,
        displayName: r['displayName'] as String? ?? r['id'] as String,
        publicKey: r['publicKey'] is Uint8List
            ? r['publicKey'] as Uint8List
            : Uint8List.fromList((r['publicKey'] as List<int>)),
        lastSeen: (r['lastSeen'] as num?)?.toInt() ?? 0,
      );
}

class Conversation {
  Conversation({
    required this.id,
    required this.memberIds,
    this.title,
    this.isGroup = false,
    this.lastMessagePreview = '',
    this.lastMessageAt = 0,
    this.unread = 0,
  });

  /// For 1:1 this is a deterministic id derived from the two member ids.
  final String id;
  final List<String> memberIds;
  String? title;
  final bool isGroup;
  String lastMessagePreview;
  int lastMessageAt;
  int unread;

  Map<String, dynamic> toRow() => {
        'id': id,
        'memberIds': jsonEncode(memberIds),
        'title': title,
        'isGroup': isGroup ? 1 : 0,
        'lastMessagePreview': lastMessagePreview,
        'lastMessageAt': lastMessageAt,
        'unread': unread,
      };

  static Conversation fromRow(Map<String, dynamic> r) => Conversation(
        id: r['id'] as String,
        memberIds: List<String>.from(jsonDecode(r['memberIds'] as String)),
        title: r['title'] as String?,
        isGroup: (r['isGroup'] as int? ?? 0) == 1,
        lastMessagePreview: r['lastMessagePreview'] as String? ?? '',
        lastMessageAt: (r['lastMessageAt'] as num?)?.toInt() ?? 0,
        unread: (r['unread'] as num?)?.toInt() ?? 0,
      );

  /// Deterministic 1:1 conversation id for two peers (order-independent).
  static String dmId(String a, String b) {
    final parts = [a, b]..sort();
    return 'dm_${parts.join("_")}';
  }
}

class Message {
  Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.kind,
    this.text = '',
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.fileId,
    this.localPath,
    this.createdAt = 0,
    this.state = DeliveryState.sending,
    this.outgoing = false,
    this.transferProgress = 0.0,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final MessageKind kind;
  String text;
  String? fileName;
  int? fileSize;
  String? mimeType;

  /// Correlation id for the encrypted blob (relay store-and-forward / LAN stream).
  String? fileId;
  String? localPath;
  int createdAt;
  DeliveryState state;
  bool outgoing;

  /// 0..1 transfer progress while sending/receiving a file.
  double transferProgress;

  bool get isAttachment =>
      kind == MessageKind.file || kind == MessageKind.image;

  Map<String, dynamic> toRow() => {
        'id': id,
        'conversationId': conversationId,
        'senderId': senderId,
        'kind': kind.name,
        'text': text,
        'fileName': fileName,
        'fileSize': fileSize,
        'mimeType': mimeType,
        'fileId': fileId,
        'localPath': localPath,
        'createdAt': createdAt,
        'state': state.name,
        'outgoing': outgoing ? 1 : 0,
      };

  static Message fromRow(Map<String, dynamic> r) => Message(
        id: r['id'] as String,
        conversationId: r['conversationId'] as String,
        senderId: r['senderId'] as String,
        kind: MessageKind.values.firstWhere(
          (k) => k.name == r['kind'],
          orElse: () => MessageKind.text,
        ),
        text: r['text'] as String? ?? '',
        fileName: r['fileName'] as String?,
        fileSize: (r['fileSize'] as num?)?.toInt(),
        mimeType: r['mimeType'] as String?,
        fileId: r['fileId'] as String?,
        localPath: r['localPath'] as String?,
        createdAt: (r['createdAt'] as num?)?.toInt() ?? 0,
        state: DeliveryState.values.firstWhere(
          (s) => s.name == r['state'],
          orElse: () => DeliveryState.sent,
        ),
        outgoing: (r['outgoing'] as int? ?? 0) == 1,
      );
}

/// Plaintext body of a sealed message (before encryption).
class MessageBody {
  MessageBody({
    required this.id,
    required this.kind,
    this.text = '',
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.fileId,
    this.fileKeyB64,
    this.fileNonceB64,
  });

  final String id;
  final String kind; // text | image | file
  String text;
  String? fileName;
  int? fileSize;
  String? mimeType;
  String? fileId;

  /// Random per-file AES-256-GCM key (base64), only present in the sealed offer.
  String? fileKeyB64;
  String? fileNonceB64;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        if (text.isNotEmpty) 'text': text,
        if (fileName != null) 'fileName': fileName,
        if (fileSize != null) 'fileSize': fileSize,
        if (mimeType != null) 'mimeType': mimeType,
        if (fileId != null) 'fileId': fileId,
        if (fileKeyB64 != null) 'fileKey': fileKeyB64,
        if (fileNonceB64 != null) 'fileNonce': fileNonceB64,
      };

  static MessageBody fromJson(Map<String, dynamic> j) => MessageBody(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? 'text',
        text: j['text'] as String? ?? '',
        fileName: j['fileName'] as String?,
        fileSize: (j['fileSize'] as num?)?.toInt(),
        mimeType: j['mimeType'] as String?,
        fileId: j['fileId'] as String?,
        fileKeyB64: j['fileKey'] as String?,
        fileNonceB64: j['fileNonce'] as String?,
      );
}

/// Deterministic 1:1 conversation id helper exposed for tests.
String conversationIdFor(String me, String peer) => Conversation.dmId(me, peer);

/// Convenience: format a byte count.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double v = bytes / 1024.0;
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024.0;
    i++;
  }
  return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${units[i]}';
}
