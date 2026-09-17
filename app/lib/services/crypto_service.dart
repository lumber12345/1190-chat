import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as hash;

/// A sealed (encrypted) payload: `nonce(12) || ciphertext || mac(16)`.
class SealedBox {
  SealedBox(this.bytes);

  final Uint8List bytes;

  static const nonceLength = 12;
  static const macLength = 16;

  static SealedBox fromSecretBox(SecretBox box) =>
      SealedBox(Uint8List.fromList(box.concatenation()));

  SecretBox toSecretBox() => SecretBox.fromConcatenation(
        bytes,
        nonceLength: nonceLength,
        macLength: macLength,
      );
}

/// The local user's long-term identity.
class Identity {
  Identity({
    required this.userId,
    required this.displayName,
    required this.seed,
    required this.publicKey,
    required this.keyPair,
  });

  final String userId;
  String displayName;

  /// 32-byte X25519 seed (the private key material). Guard this.
  final Uint8List seed;

  /// 32-byte X25519 public key.
  final Uint8List publicKey;

  final SimpleKeyPair keyPair;

  String get publicKeyB64 => base64Encode(publicKey);

  /// Short human-friendly fingerprint, e.g. "ABCD-1234-EF56".
  String get fingerprint {
    final h = hash.sha256.convert(publicKey).toString().toUpperCase();
    return '${h.substring(0, 4)}-${h.substring(4, 8)}-${h.substring(8, 12)}';
  }
}

/// All cryptographic operations for 1190 Chat.
///
/// Design:
///  * Long-term identity is an X25519 key pair derived from a 32-byte seed.
///  * userId is a deterministic short handle bound to the public key
///    (hex prefix of SHA-256(pubkey)) so an id can never be spoofed onto
///    a different key without also knowing the private key.
///  * 1:1 conversation keys come from X25519 ECDH + HKDF-SHA256, salted with
///    the sorted public keys and bound to an info string. Both sides derive
///    the identical symmetric key without ever sending it.
///  * Message bodies and file chunks are sealed with AES-256-GCM.
class CryptoService {
  CryptoService._(this.identity, this._x25519, this._aesGcm);

  final Identity identity;
  final X25519 _x25519;
  final AesGcm _aesGcm;
  final Random _rng = Random.secure();
  final Map<String, SecretKey> _convKeyCache = {};

  Uint8List get publicKey => identity.publicKey;
  String get userId => identity.userId;

  /// Derive a userId deterministically from a public key.
  static String userIdFromPublicKey(Uint8List publicKey) {
    final h = hash.sha256.convert(publicKey).toString();
    return 'c_${h.substring(0, 16)}';
  }

  /// Create a brand-new identity with a fresh random seed.
  static Future<CryptoService> generate(String displayName) async {
    final x = X25519();
    final seed = Uint8List(32);
    final rng = Random.secure();
    for (var i = 0; i < seed.length; i++) {
      seed[i] = rng.nextInt(256);
    }
    final keyPair = await x.newKeyPairFromSeed(seed);
    final pub = await keyPair.extractPublicKey();
    final pubBytes = Uint8List.fromList(pub.bytes);
    final id = Identity(
      userId: userIdFromPublicKey(pubBytes),
      displayName: displayName,
      seed: seed,
      publicKey: pubBytes,
      keyPair: keyPair,
    );
    return CryptoService._(id, x, AesGcm.with256bits());
  }

  /// Restore an identity from a previously stored seed.
  static Future<CryptoService> restore({
    required Uint8List seed,
    required String userId,
    required String displayName,
  }) async {
    final x = X25519();
    final keyPair = await x.newKeyPairFromSeed(seed);
    final pub = await keyPair.extractPublicKey();
    final id = Identity(
      userId: userId,
      displayName: displayName,
      seed: seed,
      publicKey: Uint8List.fromList(pub.bytes),
      keyPair: keyPair,
    );
    return CryptoService._(id, x, AesGcm.with256bits());
  }

  Uint8List randomBytes(int n) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  /// Deterministic 1:1 conversation key with a peer, given their public key.
  ///
  /// [convId] binds the derived key to the conversation label (defence in
  /// depth); it must be identical on both sides (see Conversation.dmId).
  Future<SecretKey> conversationKey(
    Uint8List peerPublicKey, {
    String? convId,
  }) async {
    final cacheKey =
        '${base64Encode(peerPublicKey)}|${convId ?? ''}';
    final cached = _convKeyCache[cacheKey];
    if (cached != null) return cached;

    final remote = SimplePublicKey(peerPublicKey, type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(
      keyPair: identity.keyPair,
      remotePublicKey: remote,
    );
    final sharedBytes = await shared.extractBytes();

    // Salt with the order-independent pair of public keys.
    final a = base64Encode(identity.publicKey);
    final b = base64Encode(peerPublicKey);
    final pair = [a, b]..sort();
    final salt = utf8.encode(pair.join('|'));
    final info = utf8.encode('1190chat/dm/v1/${convId ?? ''}');

    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(sharedBytes),
      nonce: salt,
      info: info,
    );
    _convKeyCache[cacheKey] = derived;
    return derived;
  }

  /// Derive a symmetric group key contribution is not needed: groups use a
  /// random key distributed pairwise-sealed. See TransferManager/ChatStore.

  /// Seal plaintext with a symmetric key. [aad] is authenticated but not
  /// encrypted (used to bind routing metadata).
  Future<SealedBox> seal(
    SecretKey key,
    Uint8List plaintext, {
    Uint8List? aad,
  }) async {
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: key,
      aad: aad ?? const [],
    );
    return SealedBox.fromSecretBox(box);
  }

  /// Open a sealed box. Throws [SecretBoxAuthenticationError] on tamper.
  Future<Uint8List> open(
    SecretKey key,
    SealedBox sealed, {
    Uint8List? aad,
  }) async {
    final clear = await _aesGcm.decrypt(
      sealed.toSecretBox(),
      secretKey: key,
      aad: aad ?? const [],
    );
    return Uint8List.fromList(clear);
  }

  /// Seal a JSON-encodable map.
  Future<SealedBox> sealJson(SecretKey key, Map<String, dynamic> obj,
          {Uint8List? aad}) =>
      seal(key, Uint8List.fromList(utf8.encode(jsonEncode(obj))), aad: aad);

  /// Open a sealed box into a JSON map.
  Future<Map<String, dynamic>> openJson(
    SecretKey key,
    SealedBox sealed, {
    Uint8List? aad,
  }) async {
    final bytes = await open(key, sealed, aad: aad);
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)));
  }

  // ----- File encryption helpers -----

  /// Fresh random 256-bit file key.
  Uint8List newFileKey() => randomBytes(32);

  /// Fresh random 96-bit base nonce for a file stream.
  Uint8List newFileNonce() => randomBytes(12);

  /// Build a unique per-chunk nonce: `baseNonce(12) XOR/|| counter`.
  /// We use `baseNonce[0..8] || counter(4 bytes BE)` to guarantee uniqueness
  /// across chunks without reusing (key, nonce) pairs.
  static Uint8List chunkNonce(Uint8List baseNonce, int index) {
    final out = Uint8List(12);
    out.setRange(0, 8, baseNonce);
    out[8] = (index >> 24) & 0xFF;
    out[9] = (index >> 16) & 0xFF;
    out[10] = (index >> 8) & 0xFF;
    out[11] = index & 0xFF;
    return out;
  }

  /// Encrypt a single file chunk under [fileKey].
  Future<Uint8List> sealChunk(
    Uint8List fileKey,
    Uint8List baseNonce,
    int index,
    Uint8List chunk,
  ) async {
    final box = await _aesGcm.encrypt(
      chunk,
      secretKey: SecretKey(fileKey),
      nonce: chunkNonce(baseNonce, index),
    );
    return Uint8List.fromList(box.concatenation());
  }

  /// Decrypt a single file chunk under [fileKey].
  Future<Uint8List> openChunk(
    Uint8List fileKey,
    Uint8List baseNonce,
    int index,
    Uint8List sealed,
  ) async {
    final box = SecretBox.fromConcatenation(
      sealed,
      nonceLength: SealedBox.nonceLength,
      macLength: SealedBox.macLength,
    );
    final clear = await _aesGcm.decrypt(box, secretKey: SecretKey(fileKey));
    return Uint8List.fromList(clear);
  }
}
