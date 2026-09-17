import 'dart:convert';
import 'dart:typed_data';

/// Wire protocol shared by both transports (LAN direct + internet relay).
///
/// Text frames are JSON envelopes; binary frames carry encrypted file chunks:
///   [uint32 BE header length][header JSON (utf8)][ciphertext]
///   header: { "t": "chunk", "fid": ..., "seq": n, "conv": ..., "from": ..., "to": ... }
class Envelope {
  Envelope._();

  // client -> peer (sealed E2E)
  static const msg = 'msg';

  // ephemeral
  static const typing = 'typing';
  static const receipt = 'receipt';

  // group invitation (sealed E2E, contains group key)
  static const ginvite = 'ginvite';

  // transport control
  static const hello = 'hello';
  static const welcome = 'welcome';
  static const ack = 'ack';
  static const presence = 'presence';
  static const error = 'error';

  // file lifecycle
  static const fileStored = 'filestored'; // sender -> relay: upload finished
  static const fileReady = 'fileready'; // relay -> recipient: fetch it
  static const fileReq = 'filereq'; // recipient -> relay
  static const fileDone = 'filedone'; // relay/LAN peer -> recipient: stream end
  static const fileAck = 'fileack'; // recipient -> relay: delete stored copy

  /// Build the additional-authenticated-data that binds a sealed payload to
  /// its routing metadata. `conv` already encodes the member set (dm id is the
  /// sorted pair; group id is shared), and `from` is implicitly authenticated
  /// because only the true sender can produce a decryptable ciphertext.
  static Uint8List aadFor(String type, String conv, String from) =>
      Uint8List.fromList(utf8.encode('$type|$conv|$from'));
}

/// A decoded inbound binary chunk frame.
class ChunkFrame {
  ChunkFrame({
    required this.fid,
    required this.seq,
    required this.conv,
    required this.from,
    required this.to,
    required this.ciphertext,
  });

  final String fid;
  final int seq;
  final String conv;
  final String from;
  final String to;
  final Uint8List ciphertext;

  Map<String, dynamic> get header => {
        't': 'chunk',
        'fid': fid,
        'seq': seq,
        'conv': conv,
        'from': from,
        'to': to,
      };
}

class FrameCodec {
  FrameCodec._();

  /// Encode a chunk frame for the wire.
  static Uint8List encodeChunk(ChunkFrame f) {
    final hdr = Uint8List.fromList(utf8.encode(jsonEncode(f.header)));
    final out = Uint8List(4 + hdr.length + f.ciphertext.length);
    final bd = ByteData.sublistView(out, 0, 4);
    bd.setUint32(0, hdr.length, Endian.big);
    out.setRange(4, 4 + hdr.length, hdr);
    out.setRange(4 + hdr.length, out.length, f.ciphertext);
    return out;
  }

  /// Decode a wire frame. Returns null if malformed.
  static ChunkFrame? decodeChunk(Uint8List data) {
    if (data.length < 8) return null;
    final hdrLen = ByteData.sublistView(data, 0, 4).getUint32(0, Endian.big);
    if (hdrLen <= 0 || hdrLen > 4096 || data.length < 4 + hdrLen) return null;
    Map<String, dynamic> hdr;
    try {
      hdr = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(data.sublist(4, 4 + hdrLen))),
      );
    } catch (_) {
      return null;
    }
    if (hdr['t'] != 'chunk') return null;
    return ChunkFrame(
      fid: hdr['fid'] as String? ?? '',
      seq: (hdr['seq'] as num?)?.toInt() ?? 0,
      conv: hdr['conv'] as String? ?? '',
      from: hdr['from'] as String? ?? '',
      to: hdr['to'] as String? ?? '',
      ciphertext: Uint8List.fromList(data.sublist(4 + hdrLen)),
    );
  }

  /// Read the `to` field out of a binary frame without full decode.
  static String? peekTo(Uint8List data) => decodeChunk(data)?.to;
}
