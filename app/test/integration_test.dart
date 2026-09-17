import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat1190/models/models.dart';
import 'package:chat1190/services/chat_store.dart';
import 'package:chat1190/services/protocol.dart';
import 'package:chat1190/services/storage_service.dart';
import 'package:chat1190/services/transport.dart';

/* ------------------------------------------------- in-memory fake network */

class FakeHub {
  final Map<String, FakeTransport> byUser = {};

  /// Every envelope that crosses the wire (for inspection in tests).
  final List<Map<String, dynamic>> wire = [];

  /// Every binary frame that crosses the wire.
  final List<Uint8List> wireBinary = [];

  void register(FakeTransport t) => byUser[t.userId] = t;

  void routeJson(Map<String, dynamic> env) {
    wire.add(env);
    final to = env['to'] as String?;
    if (to == null) return;
    final target = byUser[to];
    if (target == null) return;
    if (env['type'] == Envelope.fileDone) {
      target.emitFileComplete(env['fid'] as String);
    } else {
      target.emitJson(Map<String, dynamic>.from(env));
    }
  }

  void routeBinary(Uint8List frame) {
    wireBinary.add(frame);
    final to = FrameCodec.peekTo(frame);
    if (to == null) return;
    byUser[to]?.emitBinary(frame);
  }
}

class FakeTransport extends Transport {
  FakeTransport(this.userId, this.hub) {
    hub.register(this);
  }

  final String userId;
  final FakeHub hub;

  final _json = StreamController<Map<String, dynamic>>.broadcast();
  final _binary = StreamController<Uint8List>.broadcast();
  final _fileComplete = StreamController<String>.broadcast();
  final _state = StreamController<void>.broadcast();

  void emitJson(Map<String, dynamic> e) => _json.add(e);
  void emitBinary(Uint8List b) => _binary.add(b);
  void emitFileComplete(String fid) => _fileComplete.add(fid);

  @override
  String get label => 'Fake';
  @override
  bool get isConnected => true;
  @override
  bool canReach(String to) => to != userId && hub.byUser.containsKey(to);
  @override
  Stream<Map<String, dynamic>> get json => _json.stream;
  @override
  Stream<Uint8List> get binary => _binary.stream;
  @override
  Stream<String> get fileComplete => _fileComplete.stream;
  @override
  Stream<void> get stateChanged => _state.stream;

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}

  @override
  void sendJson(Map<String, dynamic> envelope) => hub.routeJson(envelope);
  @override
  void sendBinary(Uint8List frame) => hub.routeBinary(frame);
}

/* ------------------------------------------------------------------ harness */

Future<bool> waitFor(bool Function() pred, {int timeoutMs = 5000}) async {
  final start = DateTime.now();
  while (DateTime.now().difference(start).inMilliseconds < timeoutMs) {
    if (pred()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return pred();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late FakeHub hub;
  late ChatStore alice;
  late ChatStore bob;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('chat1190_it_');
    // Mock path_provider so getApplicationDocumentsDirectory/getTemporary
    // resolve inside our throwaway temp dir.
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tmp.path);

    hub = FakeHub();
    alice = ChatStore(
      storage: StorageService(fileName: 'alice.sqlite'),
      autoStartTransports: false,
    );
    bob = ChatStore(
      storage: StorageService(fileName: 'bob.sqlite'),
      autoStartTransports: false,
    );
    await alice.bootstrap();
    await bob.bootstrap();
    expect(alice.status, BootStatus.needsOnboarding);
    await alice.completeOnboarding('Alice');
    await bob.completeOnboarding('Bob');

    // Cross-register identities (simulates a LAN beacon / relay lookup).
    await alice.debugAddContact(
      Contact(id: bob.myId, displayName: 'Bob', publicKey: bob.myPublicKey),
    );
    await bob.debugAddContact(
      Contact(id: alice.myId, displayName: 'Alice', publicKey: alice.myPublicKey),
    );

    alice.debugAddTransport(FakeTransport(alice.myId, hub));
    bob.debugAddTransport(FakeTransport(bob.myId, hub));
  });

  tearDown(() async {
    // Give the event loop time to deliver cross-store events (e.g. receipts
    // that hop Alice->Bob->Alice) and let both inbox chains + DB writes
    // settle before we close the databases and delete the temp dir.
    for (var i = 0; i < 25; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
      await alice.debugDrain();
      await bob.debugDrain();
    }
    alice.dispose();
    bob.dispose();
    await alice.storage.close();
    await bob.storage.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('end-to-end encrypted text message flows Alice -> Bob', () async {
    final convId = Conversation.dmId(alice.myId, bob.myId);
    alice.openDm(bob.myId);
    bob.openDm(alice.myId);

    await alice.sendText(convId, 'Hey Bob, this is sealed 🔐');

    // Alice sees her outgoing message.
    final aliceMsgs = alice.messagesIn(convId);
    expect(aliceMsgs.length, 1);
    expect(aliceMsgs.single.text, 'Hey Bob, this is sealed 🔐');
    expect(aliceMsgs.single.outgoing, isTrue);

    // Bob receives and decrypts it.
    final ok = await waitFor(() => bob.messagesIn(convId).isNotEmpty);
    expect(ok, isTrue, reason: 'Bob never received the message');
    final got = bob.messagesIn(convId).single;
    expect(got.text, 'Hey Bob, this is sealed 🔐');
    expect(got.senderId, alice.myId);
    expect(got.outgoing, isFalse);

    // Delivery receipt propagates back to Alice.
    final delivered = await waitFor(() =>
        alice.messagesIn(convId).single.state.index >=
        DeliveryState.delivered.index);
    expect(delivered, isTrue);
  });

  test('the wire carries only ciphertext (no plaintext leaks)', () async {
    final convId = Conversation.dmId(alice.myId, bob.myId);
    alice.openDm(bob.myId);
    await alice.sendText(convId, 'secret payload 12345');

    expect(hub.wire, isNotEmpty);
    final env = hub.wire.firstWhere((e) => e['type'] == Envelope.msg);
    // The wire envelope must not contain the plaintext anywhere.
    expect(env.toString().contains('secret payload'), isFalse);
    expect(env['ct'], isA<String>());
    // Even a holder of both public keys cannot read it without a private key.
    expect(env['ct'] != base64Of('secret payload 12345'), isTrue);
  });

  test('encrypted file transfer Alice -> Bob preserves bytes', () async {
    final convId = Conversation.dmId(alice.myId, bob.myId);
    alice.openDm(bob.myId);
    bob.openDm(alice.myId);

    // Create a ~400KB source file (multi-chunk at 128KB).
    final srcBytes = Uint8List.fromList(
      List<int>.generate(400 * 1024, (i) => (i * 7 + 13) % 256),
    );
    final src = File('${tmp.path}/alice_source.bin');
    await src.writeAsBytes(srcBytes);

    await alice.sendFile(
      convId,
      src.path,
      fileName: 'alice_source.bin',
      size: srcBytes.length,
      mime: 'application/octet-stream',
    );

    // Sender progress completes.
    final sentOk = await waitFor(() =>
        alice.messagesIn(convId).single.state == DeliveryState.sent);
    expect(sentOk, isTrue, reason: 'send did not complete');

    // Receiver finalizes with identical bytes.
    final recvOk = await waitFor(() {
      final ms = bob.messagesIn(convId);
      return ms.isNotEmpty && ms.single.localPath != null;
    }, timeoutMs: 15000);
    expect(recvOk, isTrue, reason: 'Bob never finalized the file');

    final received = bob.messagesIn(convId).single;
    expect(received.fileName, 'alice_source.bin');
    final got = await File(received.localPath!).readAsBytes();
    expect(got, srcBytes);
    expect(received.state, DeliveryState.delivered);
  });

  test('typing indicator and read receipts propagate', () async {
    final convId = Conversation.dmId(alice.myId, bob.myId);
    alice.openDm(bob.myId);
    bob.openDm(alice.myId);

    alice.sendTyping(convId);
    final typingSeen = await waitFor(() => bob.isPeerTyping(convId));
    expect(typingSeen, isTrue);

    await alice.sendText(convId, 'read me');
    final arrived = await waitFor(() => bob.messagesIn(convId).isNotEmpty);
    expect(arrived, isTrue);

    // Bob opens the conversation -> read receipt back to Alice.
    await bob.openConversation(convId);
    final readSeen = await waitFor(() =>
        alice.messagesIn(convId).single.state == DeliveryState.read);
    expect(readSeen, isTrue);
  });

  test('messages persist and reload from sqlite', () async {
    final convId = Conversation.dmId(alice.myId, bob.myId);
    alice.openDm(bob.myId);
    await alice.sendText(convId, 'persisted message');

    final alice2 = ChatStore(
      storage: StorageService(fileName: 'alice.sqlite'),
      autoStartTransports: false,
    );
    // Reuse the same identity by pointing at alice's stored seed.
    await alice2.bootstrap();
    expect(alice2.status, BootStatus.ready);
    expect(alice2.messagesIn(convId).any((m) => m.text == 'persisted message'),
        isTrue);
    alice2.dispose();
    await alice2.storage.close();
  });
}

String base64Of(String s) => base64Encode(utf8.encode(s));
