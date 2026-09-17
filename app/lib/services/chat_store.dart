import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'crypto_service.dart';
import 'lan_transport.dart';
import 'protocol.dart';
import 'relay_transport.dart';
import 'storage_service.dart';
import 'transport.dart';

enum BootStatus { loading, needsOnboarding, ready }

const _uuid = Uuid();

/// A file being received: holds the per-file key until all chunks arrive.
class _PendingReceive {
  _PendingReceive({
    required this.messageId,
    required this.conv,
    required this.from,
    required this.fileKey,
    required this.fileNonce,
    required this.expectedSize,
    required this.tempPath,
    required this.sink,
  });

  final String messageId;
  final String conv;
  final String from;
  final Uint8List fileKey;
  final Uint8List fileNonce;
  final int expectedSize;
  final String tempPath;
  final IOSink sink;
  int received = 0;
  int nextSeq = 0;
}

/// A queued outbound item awaiting a reachable transport.
class _OutboxItem {
  _OutboxItem({
    required this.envelopes,
    this.fileSend,
  });
  final List<Map<String, dynamic>> envelopes;
  _PendingSend? fileSend;
}

/// A queued outbound file (offer + local path) awaiting a reachable peer.
class _PendingSend {
  _PendingSend({
    required this.messageId,
    required this.conv,
    required this.recipients,
    required this.filePath,
    required this.fileKey,
    required this.fileNonce,
    required this.fid,
    required this.size,
  });
  final String messageId;
  final String conv;
  final List<String> recipients;
  final String filePath;
  final Uint8List fileKey;
  final Uint8List fileNonce;
  final String fid;
  final int size;
}

/// Central application state: identity, contacts, conversations, messages,
/// transports, encryption and file transfer. A single [ChangeNotifier] the UI
/// listens to.
class ChatStore extends ChangeNotifier {
  ChatStore({StorageService? storage, this.autoStartTransports = true})
      : storage = storage ?? StorageService();

  final StorageService storage;

  /// When false, [bootstrap]/[completeOnboarding] skip starting the real
  /// LAN/relay transports. Tests attach in-memory fakes via
  /// [debugAttachTransport].
  final bool autoStartTransports;
  CryptoService? _crypto;

  BootStatus status = BootStatus.loading;
  String? bootError;

  final Map<String, Contact> contacts = {};
  final Map<String, Conversation> conversations = {};
  final Map<String, List<Message>> messages = {};

  // settings
  String serverUrl = '';
  bool relayEnabled = true;
  bool lanEnabled = true;

  // transports
  LanTransport? _lan;
  RelayTransport? _relay;
  final List<Transport> _extraTransports = [];
  final List<StreamSubscription> _subs = [];

  // transfer state
  final Map<String, _PendingReceive> _incoming = {};
  final Map<String, double> sendProgress = {}; // messageId -> 0..1
  final List<_OutboxItem> _outbox = [];

  // `fileready` notifications that arrived before their sealed offer was
  // processed (keyed by fid). Requested as soon as the offer registers.
  final Set<String> _deferredReady = {};

  // Serializes ALL inbound event processing so an offer, its chunks and its
  // completion are always handled in wire order.
  Future<void> _inboxChain = Future.value();

  void _enqueueInbox(Future<void> Function() task) {
    _inboxChain = _inboxChain.then((_) => task()).catchError((_) {});
  }

  /// Fire-and-forget persistence futures, so tests can await full flush.
  final List<Future<void>> _pendingWrites = [];

  void _persist(Future<void> f) {
    _pendingWrites.add(f);
    unawaited(f.whenComplete(() => _pendingWrites.remove(f)));
  }

  /// Await all queued inbound processing and pending DB writes. Used by tests
  /// for deterministic teardown; harmless in production.
  @visibleForTesting
  Future<void> debugDrain() async {
    await _inboxChain;
    while (_pendingWrites.isNotEmpty) {
      await Future.wait(List<Future<void>>.from(_pendingWrites));
    }
  }

  // typing
  final Map<String, DateTime> _peerTyping = {};
  final Map<String, DateTime> _lastTypingSent = {};

  String get myId => _crypto?.userId ?? '';
  String get myName => _crypto?.identity.displayName ?? '';
  String get myFingerprint => _crypto?.identity.fingerprint ?? '';
  Uint8List get myPublicKey => _crypto?.publicKey ?? Uint8List(0);

  bool get relayConnected => _relay?.isConnected ?? false;
  bool get lanActive => _lan?.isConnected ?? false;
  Map<String, LanPeer> get nearbyPeers => _lan?.peers ?? const {};

  // ---------------------------------------------------------------- boot

  Future<void> bootstrap() async {
    try {
      await storage.open();
      serverUrl = await storage.getSetting('serverUrl') ?? '';
      relayEnabled = (await storage.getSetting('relayEnabled')) != 'false';
      lanEnabled = (await storage.getSetting('lanEnabled')) != 'false';

      final id = await storage.loadIdentity();
      if (id == null) {
        status = BootStatus.needsOnboarding;
        notifyListeners();
        return;
      }
      _crypto = await CryptoService.restore(
        seed: id.seed,
        userId: id.userId,
        displayName: id.displayName,
      );
      await _loadPersisted();
      status = BootStatus.ready;
      notifyListeners();
      if (autoStartTransports) await _startTransports();
    } catch (e, st) {
      bootError = '$e\n$st';
      status = BootStatus.needsOnboarding;
      notifyListeners();
    }
  }

  Future<void> _loadPersisted() async {
    for (final c in await storage.allContacts()) {
      contacts[c.id] = c;
    }
    for (final c in await storage.allConversations()) {
      conversations[c.id] = c;
      messages[c.id] = await storage.messagesFor(c.id);
    }
  }

  Future<void> completeOnboarding(String displayName) async {
    final name = displayName.trim().isEmpty ? 'Anonymous' : displayName.trim();
    _crypto = await CryptoService.generate(name);
    await storage.saveIdentity(
      userId: _crypto!.userId,
      displayName: name,
      seed: _crypto!.identity.seed,
    );
    status = BootStatus.ready;
    notifyListeners();
    if (autoStartTransports) await _startTransports();
  }

  Future<void> updateDisplayName(String name) async {
    final crypto = _crypto;
    if (crypto == null) return;
    crypto.identity.displayName = name.trim();
    await storage.setKV('identity.displayName', crypto.identity.displayName);
    // refresh relay registration + LAN beacon
    if (_relay != null) {
      _relay!.displayName = crypto.identity.displayName;
      await _relay!.register();
    }
    if (_lan != null) _lan!.displayName = crypto.identity.displayName;
    notifyListeners();
  }

  Future<void> setServerUrl(String url) async {
    serverUrl = url.trim();
    await storage.setSetting('serverUrl', serverUrl);
    await _restartRelay();
    notifyListeners();
  }

  Future<void> setRelayEnabled(bool v) async {
    relayEnabled = v;
    await storage.setSetting('relayEnabled', v.toString());
    if (v) {
      await _restartRelay();
    } else {
      await _relay?.stop();
    }
    notifyListeners();
  }

  Future<void> setLanEnabled(bool v) async {
    lanEnabled = v;
    await storage.setSetting('lanEnabled', v.toString());
    if (v) {
      await _lan?.start();
    } else {
      await _lan?.stop();
    }
    notifyListeners();
  }

  Future<void> _startTransports() async {
    final crypto = _crypto;
    if (crypto == null) return;

    if (lanEnabled) {
      _lan = LanTransport(
        selfUserId: crypto.userId,
        publicKeyB64: crypto.identity.publicKeyB64,
        displayName: crypto.identity.displayName,
      );
      _wireTransport(_lan!);
      _subs.add(_lan!.peersChanged.listen((_) => notifyListeners()));
      await _lan!.start();
    }
    if (relayEnabled && serverUrl.isNotEmpty) {
      await _restartRelay();
    }
  }

  Future<void> _restartRelay() async {
    final crypto = _crypto;
    if (crypto == null) return;
    await _relay?.dispose();
    if (!relayEnabled || serverUrl.isEmpty) {
      _relay = null;
      return;
    }
    _relay = RelayTransport(
      serverBase: serverUrl,
      userId: crypto.userId,
      publicKeyB64: crypto.identity.publicKeyB64,
      displayName: crypto.identity.displayName,
    );
    _wireTransport(_relay!);
    await _relay!.start();
  }

  void _wireTransport(Transport t) {
    _subs.add(t.json.listen((e) => _enqueueInbox(() => _onEnvelope(e))));
    _subs.add(
      t.binary.listen((b) => _enqueueInbox(() => _onBinaryFrame(b))),
    );
    _subs.add(
      t.fileComplete.listen((fid) => _enqueueInbox(() => _onFileComplete(fid))),
    );
    _subs.add(t.stateChanged.listen((_) {
      notifyListeners();
      _flushOutbox();
    }));
  }

  Transport? _routeTo(String userId) {
    // LAN first (direct, no server), then any test transports, then relay.
    if (_lan?.canReach(userId) ?? false) return _lan;
    for (final t in _extraTransports) {
      if (t.canReach(userId)) return t;
    }
    if (_relay?.canReach(userId) ?? false) return _relay;
    return null;
  }

  @visibleForTesting
  void debugAddTransport(Transport t) {
    _extraTransports.add(t);
    _wireTransport(t);
  }

  // ------------------------------------------------------------ contacts

  Future<void> addContactById(String id) async {
    final trimmed = id.trim();
    if (trimmed.isEmpty || trimmed == myId) return;
    // Prefer LAN-known key, else ask the relay.
    Uint8List? pub;
    String? name;
    final peer = _lan?.peers[trimmed];
    if (peer != null && peer.publicKeyB64.isNotEmpty) {
      pub = base64Decode(peer.publicKeyB64);
      name = peer.displayName;
    } else if (_relay != null) {
      final res = await _relay!.lookupUser(trimmed);
      if (res != null && res['publicKey'] != null) {
        pub = base64Decode(res['publicKey'] as String);
        name = res['displayName'] as String?;
      }
    }
    if (pub == null) throw Exception('Could not find user "$trimmed"');
    final c = Contact(
      id: trimmed,
      displayName: (name == null || name.isEmpty) ? trimmed : name,
      publicKey: pub,
    );
    contacts[trimmed] = c;
    await storage.upsertContact(c);
    _ensureConversationFor(trimmed);
    notifyListeners();
  }

  void _upsertContactFromPresence(
    String id, {
    String? name,
    String? pubB64,
    required Presence presence,
  }) {
    var c = contacts[id];
    if (c == null) {
      if (pubB64 == null || pubB64.isEmpty) return; // can't DM without a key
      c = Contact(
        id: id,
        displayName: (name == null || name.isEmpty) ? id : name,
        publicKey: base64Decode(pubB64),
        presence: presence,
        lastSeen: DateTime.now().millisecondsSinceEpoch,
      );
      contacts[id] = c;
      storage.upsertContact(c);
    } else {
      c.presence = presence;
      if (name != null && name.isNotEmpty) c.displayName = name;
      if (pubB64 != null && pubB64.isNotEmpty) {
        final newPub = base64Decode(pubB64);
        if (!listEquals(newPub, c.publicKey)) c.publicKey = newPub;
      }
      c.lastSeen = DateTime.now().millisecondsSinceEpoch;
      storage.upsertContact(c);
    }
  }

  Conversation _ensureConversationFor(String peerId) {
    final id = Conversation.dmId(myId, peerId);
    var conv = conversations[id];
    if (conv == null) {
      conv = Conversation(id: id, memberIds: [myId, peerId]);
      conversations[id] = conv;
      messages[id] ??= [];
      storage.upsertConversation(conv);
    }
    return conv;
  }

  Conversation openDm(String peerId) {
    final conv = _ensureConversationFor(peerId);
    messages[conv.id] ??= [];
    return conv;
  }

  /// Directly register a contact whose public key is already known (used by
  /// tests and could back a QR-code exchange in future).
  @visibleForTesting
  Future<void> debugAddContact(Contact c) async {
    contacts[c.id] = c;
    await storage.upsertContact(c);
    _ensureConversationFor(c.id);
    notifyListeners();
  }

  // ------------------------------------------------------------ sending

  Future<SecretKey> _dmKey(String peerId, String convId) async {
    final c = contacts[peerId];
    if (c == null) throw Exception('Unknown contact $peerId');
    return _crypto!.conversationKey(c.publicKey, convId: convId);
  }

  Future<void> sendText(String convId, String text) async {
    final crypto = _crypto;
    if (crypto == null || text.trim().isEmpty) return;
    final conv = conversations[convId];
    if (conv == null) return;

    final msgId = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final body = MessageBody(id: msgId, kind: 'text', text: text);
    final msg = Message(
      id: msgId,
      conversationId: convId,
      senderId: myId,
      kind: MessageKind.text,
      text: text,
      createdAt: now,
      state: DeliveryState.sending,
      outgoing: true,
    );
    _addMessage(msg, preview: text);

    if (conv.isGroup) {
      final groupKey = await _groupKey(convId);
      if (groupKey == null) {
        _setState(msgId, DeliveryState.failed);
        return;
      }
      final envelopes = <Map<String, dynamic>>[];
      for (final member in conv.memberIds.where((m) => m != myId)) {
        envelopes.add(
          await _sealEnvelope(
            type: Envelope.msg,
            conv: convId,
            to: member,
            body: body,
            key: groupKey,
            ts: now,
          ),
        );
      }
      _dispatch(msgId, envelopes, conv, preview: text);
    } else {
      final peer = conv.memberIds.firstWhere((m) => m != myId);
      final key = await _dmKey(peer, convId);
      final env = await _sealEnvelope(
        type: Envelope.msg,
        conv: convId,
        to: peer,
        body: body,
        key: key,
        ts: now,
      );
      _dispatch(msgId, [env], conv, preview: text);
    }
  }

  Future<Map<String, dynamic>> _sealEnvelope({
    required String type,
    required String conv,
    required String to,
    required MessageBody body,
    required SecretKey key,
    required int ts,
  }) async {
    final crypto = _crypto!;
    final aad = Envelope.aadFor(type, conv, crypto.userId);
    final sealed = await crypto.sealJson(key, body.toJson(), aad: aad);
    return {
      'type': type,
      'id': body.id,
      'conv': conv,
      'from': crypto.userId,
      'to': to,
      'ts': ts,
      'ct': base64Encode(sealed.bytes),
    };
  }

  void _dispatch(
    String msgId,
    List<Map<String, dynamic>> envelopes,
    Conversation conv, {
    String preview = '',
    _PendingSend? fileSend,
  }) {
    var anySent = false;
    for (final env in envelopes) {
      final to = env['to'] as String;
      final t = _routeTo(to);
      if (t != null) {
        t.sendJson(env);
        anySent = true;
      }
    }
    if (anySent) {
      _setState(msgId, DeliveryState.sent);
      // For files, begin the chunk upload once the offer is out.
      if (fileSend != null) {
        unawaited(_uploadFile(fileSend));
      }
    } else {
      _setState(msgId, DeliveryState.sending);
      _outbox.add(_OutboxItem(envelopes: envelopes, fileSend: fileSend));
    }
  }

  void _flushOutbox() {
    if (_outbox.isEmpty) return;
    final remaining = <_OutboxItem>[];
    for (final item in _outbox) {
      var anySent = false;
      for (final env in item.envelopes) {
        final t = _routeTo(env['to'] as String);
        if (t != null) {
          t.sendJson(env);
          anySent = true;
        }
      }
      if (anySent) {
        final id = item.envelopes.isNotEmpty
            ? item.envelopes.first['id'] as String?
            : null;
        if (id != null) _setState(id, DeliveryState.sent);
        if (item.fileSend != null) unawaited(_uploadFile(item.fileSend!));
      } else {
        remaining.add(item);
      }
    }
    _outbox
      ..clear()
      ..addAll(remaining);
  }

  // ------------------------------------------------------------ files

  Future<void> sendFile(
    String convId,
    String filePath, {
    required String fileName,
    required int size,
    String? mime,
    MessageKind kind = MessageKind.file,
  }) async {
    final crypto = _crypto;
    final conv = conversations[convId];
    if (crypto == null || conv == null) return;

    final msgId = _uuid.v4();
    final fid = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final fileKey = crypto.newFileKey();
    final fileNonce = crypto.newFileNonce();

    final body = MessageBody(
      id: msgId,
      kind: kind == MessageKind.image ? 'image' : 'file',
      fileName: fileName,
      fileSize: size,
      mimeType: mime,
      fileId: fid,
      fileKeyB64: base64Encode(fileKey),
      fileNonceB64: base64Encode(fileNonce),
    );

    final msg = Message(
      id: msgId,
      conversationId: convId,
      senderId: myId,
      kind: kind,
      text: '',
      fileName: fileName,
      fileSize: size,
      mimeType: mime,
      fileId: fid,
      localPath: filePath,
      createdAt: now,
      state: DeliveryState.sending,
      outgoing: true,
    );
    _addMessage(msg, preview: '📎 $fileName');
    sendProgress[msgId] = 0.0;

    final recipients = conv.memberIds.where((m) => m != myId).toList();
    final pending = _PendingSend(
      messageId: msgId,
      conv: convId,
      recipients: recipients,
      filePath: filePath,
      fileKey: fileKey,
      fileNonce: fileNonce,
      fid: fid,
      size: size,
    );

    final envelopes = <Map<String, dynamic>>[];
    if (conv.isGroup) {
      final gk = await _groupKey(convId);
      if (gk == null) {
        _setState(msgId, DeliveryState.failed);
        return;
      }
      for (final member in recipients) {
        envelopes.add(
          await _sealEnvelope(
            type: Envelope.msg,
            conv: convId,
            to: member,
            body: body,
            key: gk,
            ts: now,
          ),
        );
      }
    } else {
      final key = await _dmKey(recipients.first, convId);
      envelopes.add(
        await _sealEnvelope(
          type: Envelope.msg,
          conv: convId,
          to: recipients.first,
          body: body,
          key: key,
          ts: now,
        ),
      );
    }
    _dispatch(msgId, envelopes, conv,
        preview: '📎 $fileName', fileSend: pending);
  }

  Future<void> _uploadFile(_PendingSend s) async {
    final crypto = _crypto;
    if (crypto == null) return;
    final file = File(s.filePath);
    if (!await file.exists()) {
      _setState(s.messageId, DeliveryState.failed);
      return;
    }

    // Group recipients by their chosen transport. The relay stores chunks
    // once per fid (server-side), so a single upload serves all relay-routed
    // recipients; LAN/direct peers each get their own stream.
    final relayTargets = <String>[];
    final directByTransport = <Transport, List<String>>{};
    for (final to in s.recipients) {
      final t = _routeTo(to);
      if (t == null) continue;
      if (t is RelayTransport) {
        relayTargets.add(to);
      } else {
        (directByTransport[t] ??= []).add(to);
      }
    }
    if (relayTargets.isEmpty && directByTransport.isEmpty) {
      // Nobody reachable right now — keep the whole send in the outbox.
      _setState(s.messageId, DeliveryState.sending);
      final already = _outbox.any((o) => o.fileSend?.messageId == s.messageId);
      if (!already) {
        _outbox.add(_OutboxItem(envelopes: const [], fileSend: s));
      }
      return;
    }

    const chunkSize = 128 * 1024;
    final raf = await file.open();
    try {
      var seq = 0;
      var sent = 0;
      while (true) {
        final chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) break;
        final sealed = await crypto.sealChunk(
          s.fileKey,
          s.fileNonce,
          seq,
          Uint8List.fromList(chunk),
        );
        Uint8List frameFor(String to) => FrameCodec.encodeChunk(
              ChunkFrame(
                fid: s.fid,
                seq: seq,
                conv: s.conv,
                from: myId,
                to: to,
                ciphertext: sealed,
              ),
            );
        if (relayTargets.isNotEmpty) {
          // One copy to the relay store; the server keys purely by fid.
          _relay!.sendBinary(frameFor(relayTargets.first));
        }
        directByTransport.forEach((t, targets) {
          for (final to in targets) {
            t.sendBinary(frameFor(to));
          }
        });
        seq++;
        sent += chunk.length;
        sendProgress[s.messageId] = s.size == 0 ? 1.0 : sent / s.size;
        notifyListeners();
      }
      // Signal completion per transport.
      for (final to in relayTargets) {
        _relay!.notifyFileStored(s.fid, to);
      }
      directByTransport.forEach((t, targets) {
        for (final to in targets) {
          t.sendJson({
            'type': Envelope.fileDone,
            'fid': s.fid,
            'conv': s.conv,
            'from': myId,
            'to': to,
          });
        }
      });
      sendProgress[s.messageId] = 1.0;
      _setState(s.messageId, DeliveryState.sent);
      notifyListeners();
    } catch (_) {
      _setState(s.messageId, DeliveryState.failed);
    } finally {
      await raf.close();
    }
  }

  Future<void> _beginReceive(MessageBody body, String conv, String from) async {
    final fid = body.fileId;
    final keyB64 = body.fileKeyB64;
    final nonceB64 = body.fileNonceB64;
    if (fid == null || keyB64 == null || nonceB64 == null) return;
    if (_incoming.containsKey(fid)) return;
    final tmp = await storage.tempDir();
    final tempPath = p.join(tmp.path, '$fid.part');
    final sink = File(tempPath).openWrite();
    _incoming[fid] = _PendingReceive(
      messageId: body.id,
      conv: conv,
      from: from,
      fileKey: base64Decode(keyB64),
      fileNonce: base64Decode(nonceB64),
      expectedSize: body.fileSize ?? 0,
      tempPath: tempPath,
      sink: sink,
    );
    if (_deferredReady.remove(fid)) {
      _relay?.requestFile(fid);
    }
  }

  Future<void> _onBinaryFrame(Uint8List data) async {
    final frame = FrameCodec.decodeChunk(data);
    if (frame == null) return;
    final pr = _incoming[frame.fid];
    if (pr == null) return; // offer not seen yet; chunks will be re-requested
    final crypto = _crypto;
    if (crypto == null) return;
    try {
      final clear = await crypto.openChunk(
        pr.fileKey,
        pr.fileNonce,
        frame.seq,
        frame.ciphertext,
      );
      pr.sink.add(clear);
      pr.received += clear.length;
      pr.nextSeq = frame.seq + 1;
      final msg = _findMessage(pr.conv, pr.messageId);
      if (msg != null) {
        msg.transferProgress = pr.expectedSize == 0
            ? 0
            : (pr.received / pr.expectedSize).clamp(0.0, 1.0);
      }
      notifyListeners();
    } catch (_) {
      // decryption failed — ignore chunk
    }
  }

  Future<void> _onFileComplete(String fid) async {
    final pr = _incoming.remove(fid);
    if (pr == null) return;
    try {
      await pr.sink.flush();
      await pr.sink.close();
    } catch (_) {}
    final dir = await storage.filesDir();
    final msg = _findMessage(pr.conv, pr.messageId);
    final safeName = _sanitize(msg?.fileName ?? '$fid.bin');
    final dest = p.join(dir.path, '${fid.substring(0, 8)}_$safeName');
    try {
      await File(pr.tempPath).rename(dest);
    } catch (_) {
      try {
        await File(pr.tempPath).copy(dest);
        await File(pr.tempPath).delete();
      } catch (_) {}
    }
    if (msg != null) {
      msg.localPath = dest;
      msg.transferProgress = 1.0;
      msg.state = DeliveryState.delivered;
      await storage.updateMessageLocalPath(msg.id, dest);
      await storage.updateMessageState(msg.id, DeliveryState.delivered);
      // send a delivered receipt back
      _sendReceipt(pr.conv, pr.from, msg.id, 'delivered');
    }
    // Tell the relay it can eventually delete its stored copy.
    _relay?.confirmFileReceived(fid);
    notifyListeners();
  }

  String _sanitize(String name) =>
      name.replaceAll(RegExp(r'[^\w.\- ]'), '_');

  Message? _findMessage(String conv, String id) {
    final list = messages[conv];
    if (list == null) return null;
    for (final m in list) {
      if (m.id == id) return m;
    }
    return null;
  }

  // ------------------------------------------------------------ groups

  Future<SecretKey?> _groupKey(String convId) async {
    final stored = await storage.getKV('groupKey.$convId');
    if (stored != null) return SecretKey(base64Decode(stored));
    return null;
  }

  Future<void> createGroup(String title, List<String> memberIds) async {
    final crypto = _crypto;
    if (crypto == null) return;
    final members = {...memberIds, myId}.toList();
    if (members.length < 2) return;
    final convId = 'grp_${_uuid.v4().substring(0, 12)}';
    final groupKey = crypto.randomBytes(32);
    await storage.setKV('groupKey.$convId', base64Encode(groupKey));

    final conv = Conversation(
      id: convId,
      memberIds: members,
      title: title.trim().isEmpty ? 'Group' : title.trim(),
      isGroup: true,
      lastMessageAt: DateTime.now().millisecondsSinceEpoch,
    );
    conversations[convId] = conv;
    messages[convId] = [];
    await storage.upsertConversation(conv);

    // Send each member a sealed invitation containing the group key.
    for (final member in members.where((m) => m != myId)) {
      final c = contacts[member];
      if (c == null) continue;
      final dmKey = await crypto.conversationKey(
        c.publicKey,
        convId: Conversation.dmId(myId, member),
      );
      final inviteId = _uuid.v4();
      final now = DateTime.now().millisecondsSinceEpoch;
      final body = MessageBody(
        id: inviteId,
        kind: 'ginvite',
        text: jsonEncode({
          'groupId': convId,
          'title': conv.title,
          'members': members,
          'groupKey': base64Encode(groupKey),
        }),
      );
      final env = await _sealEnvelope(
        type: Envelope.ginvite,
        conv: Conversation.dmId(myId, member),
        to: member,
        body: body,
        key: dmKey,
        ts: now,
      );
      final t = _routeTo(member);
      if (t != null) {
        t.sendJson(env);
      } else {
        _outbox.add(_OutboxItem(envelopes: [env]));
      }
    }
    notifyListeners();
  }

  Future<void> _handleGroupInvite(
    Map<String, dynamic> e,
  ) async {
    final crypto = _crypto;
    if (crypto == null) return;
    final from = e['from'] as String;
    final conv = e['conv'] as String;
    final c = contacts[from];
    if (c == null) return;
    final key = await crypto.conversationKey(c.publicKey, convId: conv);
    final aad = Envelope.aadFor(Envelope.ginvite, conv, from);
    Map<String, dynamic> body;
    try {
      body = await crypto.openJson(
        key,
        SealedBox(base64Decode(e['ct'] as String)),
        aad: aad,
      );
    } catch (_) {
      return;
    }
    final payload = jsonDecode(body['text'] as String) as Map<String, dynamic>;
    final groupId = payload['groupId'] as String;
    final title = payload['title'] as String? ?? 'Group';
    final members = List<String>.from(payload['members'] as List);
    final groupKey = base64Decode(payload['groupKey'] as String);
    await storage.setKV('groupKey.$groupId', base64Encode(groupKey));
    if (conversations[groupId] == null) {
      final gconv = Conversation(
        id: groupId,
        memberIds: members,
        title: title,
        isGroup: true,
        lastMessageAt: DateTime.now().millisecondsSinceEpoch,
      );
      conversations[groupId] = gconv;
      messages[groupId] = [];
      await storage.upsertConversation(gconv);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ inbound

  Future<void> _onEnvelope(Map<String, dynamic> e) async {
    switch (e['type']) {
      case Envelope.presence:
        _onPresence(e);
        break;
      case Envelope.msg:
        await _onIncomingMessage(e);
        break;
      case Envelope.ginvite:
        await _handleGroupInvite(e);
        break;
      case Envelope.receipt:
        _onReceipt(e);
        break;
      case Envelope.typing:
        _onTyping(e);
        break;
      case Envelope.ack:
        _onAck(e);
        break;
      case Envelope.fileReady:
        _onFileReady(e);
        break;
    }
  }

  void _onFileReady(Map<String, dynamic> e) {
    final fid = e['fid'] as String?;
    if (fid == null) return;
    if (_incoming.containsKey(fid)) {
      _relay?.requestFile(fid);
    } else {
      // Sealed offer still unprocessed; request it once _beginReceive runs.
      _deferredReady.add(fid);
    }
  }

  void _onPresence(Map<String, dynamic> e) {
    final id = e['userId'] as String?;
    if (id == null || id == myId) return;
    final online = e['online'] == true;
    final isLan = e['lan'] == true;
    if (isLan) {
      if (online) {
        _upsertContactFromPresence(
          id,
          name: e['name'] as String?,
          pubB64: e['pub'] as String?,
          presence: Presence.lan,
        );
      } else {
        final c = contacts[id];
        if (c != null) c.presence = Presence.unknown;
      }
    } else {
      final c = contacts[id];
      if (c != null) {
        c.presence = online ? Presence.online : Presence.offline;
      }
    }
    notifyListeners();
    _flushOutbox();
  }

  Future<void> _onIncomingMessage(Map<String, dynamic> e) async {
    final crypto = _crypto;
    if (crypto == null) return;
    final conv = e['conv'] as String?;
    final from = e['from'] as String?;
    final ct = e['ct'] as String?;
    final id = e['id'] as String?;
    if (conv == null || from == null || ct == null || id == null) return;

    // Resolve decryption key.
    final SecretKey key;
    if (conv.startsWith('grp_')) {
      final gk = await _groupKey(conv);
      if (gk == null) return; // not a member yet / invite not processed
      key = gk;
    } else {
      final c = contacts[from];
      if (c == null) return; // unknown sender
      key = await crypto.conversationKey(c.publicKey, convId: conv);
    }

    final aad = Envelope.aadFor(Envelope.msg, conv, from);
    Map<String, dynamic> body;
    try {
      body = await crypto.openJson(key, SealedBox(base64Decode(ct)), aad: aad);
    } catch (_) {
      return; // undecryptable — drop
    }
    final mb = MessageBody.fromJson(body);
    // de-dupe
    if (_findMessage(conv, mb.id) != null) {
      _sendReceipt(conv, from, mb.id, 'delivered');
      return;
    }

    conversations[conv] ??= await _materializeConversation(conv, from);
    messages[conv] ??= [];

    final isFile = mb.kind == 'file' || mb.kind == 'image';
    final msg = Message(
      id: mb.id,
      conversationId: conv,
      senderId: from,
      kind: mb.kind == 'image'
          ? MessageKind.image
          : (mb.kind == 'file' ? MessageKind.file : MessageKind.text),
      text: mb.text,
      fileName: mb.fileName,
      fileSize: mb.fileSize,
      mimeType: mb.mimeType,
      fileId: mb.fileId,
      createdAt: (e['ts'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      state: DeliveryState.delivered,
      outgoing: false,
      transferProgress: isFile ? 0.0 : 1.0,
    );
    _addMessage(
      msg,
      preview: isFile ? '📎 ${mb.fileName ?? 'file'}' : mb.text,
      persist: true,
      bumpUnread: true,
    );
    if (isFile) {
      await _beginReceive(mb, conv, from);
    }
    _sendReceipt(conv, from, mb.id, 'delivered');
    notifyListeners();
  }

  Future<Conversation> _materializeConversation(String conv, String from) async {
    if (conv.startsWith('grp_')) {
      return Conversation(
        id: conv,
        memberIds: [myId, from],
        title: 'Group',
        isGroup: true,
        lastMessageAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    return Conversation(id: conv, memberIds: [myId, from]);
  }

  void _sendReceipt(String conv, String to, String ref, String state) {
    final t = _routeTo(to);
    if (t == null) return;
    t.sendJson({
      'type': Envelope.receipt,
      'conv': conv,
      'from': myId,
      'to': to,
      'ref': ref,
      'state': state,
    });
  }

  void _onReceipt(Map<String, dynamic> e) {
    final conv = e['conv'] as String?;
    final ref = e['ref'] as String?;
    final state = e['state'] as String?;
    if (conv == null || ref == null) return;
    final m = _findMessage(conv, ref);
    if (m == null || !m.outgoing) return;
    final ns = state == 'read' ? DeliveryState.read : DeliveryState.delivered;
    if (ns.index >= m.state.index) {
      m.state = ns;
      storage.updateMessageState(m.id, ns);
      notifyListeners();
    }
  }

  void _onAck(Map<String, dynamic> e) {
    // Relay accepted/queued a message; mark matching outgoing as sent.
    final id = e['id'] as String?;
    if (id == null) return;
    for (final list in messages.values) {
      for (final m in list) {
        if (m.id == id && m.outgoing && m.state == DeliveryState.sending) {
          m.state = DeliveryState.sent;
          storage.updateMessageState(id, DeliveryState.sent);
          notifyListeners();
          return;
        }
      }
    }
  }

  void _onTyping(Map<String, dynamic> e) {
    final conv = e['conv'] as String?;
    final on = e['on'] == true;
    if (conv == null) return;
    if (on) {
      _peerTyping[conv] = DateTime.now();
      Timer(const Duration(seconds: 5), () {
        final t = _peerTyping[conv];
        if (t != null &&
            DateTime.now().difference(t) > const Duration(seconds: 4)) {
          _peerTyping.remove(conv);
          notifyListeners();
        }
      });
    } else {
      _peerTyping.remove(conv);
    }
    notifyListeners();
  }

  bool isPeerTyping(String conv) {
    final t = _peerTyping[conv];
    if (t == null) return false;
    return DateTime.now().difference(t) < const Duration(seconds: 5);
  }

  void sendTyping(String convId, {bool on = true}) {
    final conv = conversations[convId];
    if (conv == null) return;
    final now = DateTime.now();
    if (on) {
      final last = _lastTypingSent[convId];
      if (last != null && now.difference(last) < const Duration(seconds: 2)) {
        return;
      }
      _lastTypingSent[convId] = now;
    }
    for (final member in conv.memberIds.where((m) => m != myId)) {
      final t = _routeTo(member);
      t?.sendJson({
        'type': Envelope.typing,
        'conv': convId,
        'from': myId,
        'to': member,
        'on': on,
      });
    }
  }

  // ------------------------------------------------------------ helpers

  void _addMessage(
    Message m, {
    String preview = '',
    bool persist = true,
    bool bumpUnread = false,
  }) {
    final list = messages[m.conversationId] ??= [];
    list.add(m);
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final conv = conversations[m.conversationId];
    if (conv != null) {
      conv.lastMessageAt = m.createdAt;
      conv.lastMessagePreview = preview.isNotEmpty
          ? preview
          : (m.outgoing ? 'You: ${m.text}' : m.text);
      if (bumpUnread && !m.outgoing) conv.unread += 1;
      if (persist) _persist(storage.upsertConversation(conv).then((_) {}));
    }
    if (persist) _persist(storage.insertMessage(m).then((_) {}));
    notifyListeners();
  }

  void _setState(String msgId, DeliveryState s) {
    for (final list in messages.values) {
      for (final m in list) {
        if (m.id == msgId) {
          m.state = s;
          storage.updateMessageState(msgId, s);
          notifyListeners();
          return;
        }
      }
    }
  }

  Future<void> openConversation(String convId) async {
    final conv = conversations[convId];
    if (conv == null) return;
    if (conv.unread != 0) {
      conv.unread = 0;
      await storage.upsertConversation(conv);
    }
    // send read receipts for incoming messages
    for (final m in messages[convId] ?? const <Message>[]) {
      if (!m.outgoing && m.state != DeliveryState.read) {
        m.state = DeliveryState.read;
        storage.updateMessageState(m.id, DeliveryState.read);
        _sendReceipt(convId, m.senderId, m.id, 'read');
      }
    }
    notifyListeners();
  }

  List<Message> messagesIn(String convId) => messages[convId] ?? const [];

  String displayNameFor(String userId) {
    if (userId == myId) return 'You';
    return contacts[userId]?.displayName ?? userId;
  }

  Future<void> resetAll() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _lan?.dispose();
    await _relay?.dispose();
    _lan = null;
    _relay = null;
    await storage.wipe();
    contacts.clear();
    conversations.clear();
    messages.clear();
    _crypto = null;
    status = BootStatus.needsOnboarding;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _lan?.dispose();
    _relay?.dispose();
    super.dispose();
  }
}
