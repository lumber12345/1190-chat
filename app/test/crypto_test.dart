import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:chat1190/services/crypto_service.dart';
import 'package:chat1190/services/protocol.dart';

void main() {
  group('CryptoService identity & key agreement', () {
    test('userId is deterministic from the public key', () async {
      final a = await CryptoService.generate('Alice');
      final id1 = CryptoService.userIdFromPublicKey(a.publicKey);
      final id2 = CryptoService.userIdFromPublicKey(a.publicKey);
      expect(id1, id2);
      expect(a.userId, id1);
      expect(id1.startsWith('c_'), isTrue);
    });

    test('restore rebuilds the same identity from the seed', () async {
      final a = await CryptoService.generate('Alice');
      final restored = await CryptoService.restore(
        seed: a.identity.seed,
        userId: a.userId,
        displayName: 'Alice',
      );
      expect(restored.publicKey, a.publicKey);
      expect(restored.userId, a.userId);
    });

    test('both peers derive the identical conversation key (ECDH+HKDF)',
        () async {
      final alice = await CryptoService.generate('Alice');
      final bob = await CryptoService.generate('Bob');
      const convId = 'dm_alice_bob';
      final ka = await alice.conversationKey(bob.publicKey, convId: convId);
      final kb = await bob.conversationKey(alice.publicKey, convId: convId);
      expect(await ka.extractBytes(), await kb.extractBytes());
    });

    test('conversation key is bound to the convId (different id -> different key)',
        () async {
      final alice = await CryptoService.generate('Alice');
      final bob = await CryptoService.generate('Bob');
      final k1 = await alice.conversationKey(bob.publicKey, convId: 'convA');
      final k2 = await alice.conversationKey(bob.publicKey, convId: 'convB');
      expect(await k1.extractBytes(), isNot(await k2.extractBytes()));
    });
  });

  group('AES-GCM seal / open', () {
    test('round-trips JSON payloads', () async {
      final alice = await CryptoService.generate('Alice');
      final bob = await CryptoService.generate('Bob');
      const convId = 'dm_x';
      final ka = await alice.conversationKey(bob.publicKey, convId: convId);
      final kb = await bob.conversationKey(alice.publicKey, convId: convId);

      final aad = Envelope.aadFor('msg', convId, alice.userId);
      final body = {'id': '1', 'kind': 'text', 'text': 'hello bob 🔒'};
      final sealed = await alice.sealJson(ka, body, aad: aad);

      final opened = await bob.openJson(kb, sealed, aad: aad);
      expect(opened['text'], 'hello bob 🔒');
      expect(opened['id'], '1');
    });

    test('tampering with ciphertext fails authentication', () async {
      final alice = await CryptoService.generate('Alice');
      final bob = await CryptoService.generate('Bob');
      const convId = 'dm_x';
      final ka = await alice.conversationKey(bob.publicKey, convId: convId);
      final kb = await bob.conversationKey(alice.publicKey, convId: convId);

      final sealed = await alice.sealJson(ka, {'t': 'secret'});
      final tampered = Uint8List.fromList(sealed.bytes);
      tampered[tampered.length ~/ 2] ^= 0xFF; // flip a byte

      expect(
        () => bob.openJson(kb, SealedBox(tampered)),
        throwsA(anything),
      );
    });

    test('wrong AAD fails authentication (prevents re-targeting)', () async {
      final alice = await CryptoService.generate('Alice');
      final bob = await CryptoService.generate('Bob');
      const convId = 'dm_x';
      final ka = await alice.conversationKey(bob.publicKey, convId: convId);
      final kb = await bob.conversationKey(alice.publicKey, convId: convId);

      final sealed =
          await alice.sealJson(ka, {'t': 'x'}, aad: Envelope.aadFor('msg', convId, alice.userId));
      expect(
        () => bob.openJson(kb, sealed, aad: Envelope.aadFor('msg', 'other', alice.userId)),
        throwsA(anything),
      );
    });
  });

  group('File chunk encryption', () {
    test('chunk nonces are unique per index', () {
      final base = CryptoService.generate('A');
      return base.then((svc) {
        final n0 = CryptoService.chunkNonce(Uint8List(12), 0);
        final n1 = CryptoService.chunkNonce(Uint8List(12), 1);
        final n2 = CryptoService.chunkNonce(Uint8List(12), 256);
        expect(n0, isNot(n1));
        expect(n1, isNot(n2));
        expect(svc.publicKey.length, 32);
      });
    });

    test('seal/open round-trips arbitrary bytes across chunks', () async {
      final svc = await CryptoService.generate('Sender');
      final fileKey = svc.newFileKey();
      final nonce = svc.newFileNonce();

      final original = Uint8List.fromList(
        List<int>.generate(300 * 1024, (i) => i % 251),
      );
      const chunkSize = 128 * 1024;
      final reassembled = BytesBuilder();
      var seq = 0;
      for (var off = 0; off < original.length; off += chunkSize) {
        final end = (off + chunkSize).clamp(0, original.length);
        final chunk = Uint8List.sublistView(original, off, end);
        final sealed = await svc.sealChunk(fileKey, nonce, seq, chunk);
        final clear = await svc.openChunk(fileKey, nonce, seq, sealed);
        reassembled.add(clear);
        seq++;
      }
      expect(reassembled.toBytes(), original);
    });

    test('wrong file key cannot decrypt a chunk', () async {
      final svc = await CryptoService.generate('Sender');
      final fileKey = svc.newFileKey();
      final wrongKey = svc.newFileKey();
      final nonce = svc.newFileNonce();
      final sealed = await svc.sealChunk(
        fileKey,
        nonce,
        0,
        Uint8List.fromList(utf8.encode('top secret')),
      );
      expect(
        () => svc.openChunk(wrongKey, nonce, 0, sealed),
        throwsA(anything),
      );
    });
  });

  test('fingerprint is stable and grouped', () async {
    final a = await CryptoService.generate('Alice');
    expect(a.identity.fingerprint, a.identity.fingerprint);
    expect(RegExp(r'^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$')
        .hasMatch(a.identity.fingerprint), isTrue);
  });
}

