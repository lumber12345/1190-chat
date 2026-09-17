import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:chat1190/models/models.dart';
import 'package:chat1190/services/protocol.dart';

void main() {
  group('FrameCodec', () {
    test('chunk frame round-trips', () {
      final cipher = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final frame = FrameCodec.encodeChunk(ChunkFrame(
        fid: 'fid-123',
        seq: 7,
        conv: 'dm_a_b',
        from: 'nk_alice',
        to: 'nk_bob',
        ciphertext: cipher,
      ));
      final decoded = FrameCodec.decodeChunk(frame);
      expect(decoded, isNotNull);
      expect(decoded!.fid, 'fid-123');
      expect(decoded.seq, 7);
      expect(decoded.conv, 'dm_a_b');
      expect(decoded.from, 'nk_alice');
      expect(decoded.to, 'nk_bob');
      expect(decoded.ciphertext, cipher);
      expect(FrameCodec.peekTo(frame), 'nk_bob');
    });

    test('matches the relay server wire format ([u32 hdr][hdr json][cipher])',
        () {
      final cipher = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame = FrameCodec.encodeChunk(ChunkFrame(
        fid: 'f1',
        seq: 0,
        conv: 'c',
        from: 'a',
        to: 'b',
        ciphertext: cipher,
      ));
      final hdrLen = ByteData.sublistView(frame, 0, 4).getUint32(0, Endian.big);
      final hdr =
          jsonDecode(utf8.decode(frame.sublist(4, 4 + hdrLen))) as Map<String, dynamic>;
      expect(hdr['t'], 'chunk');
      expect(hdr['fid'], 'f1');
      expect(frame.sublist(4 + hdrLen), cipher);
    });

    test('malformed frames decode to null', () {
      expect(FrameCodec.decodeChunk(Uint8List(4)), isNull);
      expect(
        FrameCodec.decodeChunk(Uint8List.fromList([0, 0, 0, 99, 1, 2])),
        isNull,
      );
      final bad = Uint8List.fromList([0, 0, 0, 2, 123, 45, 67, 89]);
      expect(FrameCodec.decodeChunk(bad), isNull);
    });
  });

  group('Models', () {
    test('dmId is order independent', () {
      expect(Conversation.dmId('nk_a', 'nk_b'), Conversation.dmId('nk_b', 'nk_a'));
      expect(conversationIdFor('nk_a', 'nk_b'), 'dm_nk_a_nk_b');
    });

    test('message body round-trips through JSON', () {
      final body = MessageBody(
        id: 'm1',
        kind: 'file',
        fileName: 'report.pdf',
        fileSize: 12345,
        mimeType: 'application/pdf',
        fileId: 'fid',
        fileKeyB64: base64Encode([1, 2, 3]),
        fileNonceB64: base64Encode([4, 5, 6]),
      );
      final decoded = MessageBody.fromJson(
        jsonDecode(jsonEncode(body.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.id, 'm1');
      expect(decoded.kind, 'file');
      expect(decoded.fileName, 'report.pdf');
      expect(decoded.fileSize, 12345);
      expect(decoded.fileKeyB64, base64Encode([1, 2, 3]));
    });

    test('message row round-trips', () {
      final m = Message(
        id: 'x',
        conversationId: 'c',
        senderId: 's',
        kind: MessageKind.image,
        text: '',
        fileName: 'a.png',
        fileSize: 9,
        createdAt: 42,
        state: DeliveryState.delivered,
        outgoing: true,
      );
      final r = Message.fromRow(m.toRow());
      expect(r.kind, MessageKind.image);
      expect(r.state, DeliveryState.delivered);
      expect(r.outgoing, isTrue);
      expect(r.createdAt, 42);
    });

    test('formatBytes', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });
  });

  group('Envelope', () {
    test('aadFor binds type, conv and sender', () {
      final a = Envelope.aadFor('msg', 'conv1', 'alice');
      final b = Envelope.aadFor('msg', 'conv1', 'alice');
      final c = Envelope.aadFor('msg', 'conv2', 'alice');
      expect(a, b);
      expect(a, isNot(c));
    });
  });
}
