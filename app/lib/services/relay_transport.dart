import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'protocol.dart';
import 'transport.dart';

/// Internet transport: a WebSocket connection to the 1190 Chat relay server.
///
/// The relay only ever sees ciphertext (`ct`) plus routing metadata; message
/// bodies and file bytes are sealed end-to-end by [CryptoService]. Files use
/// the server's store-and-forward: sender uploads chunk frames, then signals
/// `filestored`; the recipient is told `fileready`, auto-requests with
/// `filereq`, receives the chunk frames, then `filedone`.
class RelayTransport extends Transport {
  RelayTransport({
    required this.serverBase,
    required this.userId,
    required this.publicKeyB64,
    required this.displayName,
  });

  /// e.g. "http://10.0.0.5:8090" or "ws://host:8090" or "https://relay.example".
  String serverBase;
  String userId;
  String publicKeyB64;
  String displayName;

  WebSocket? _ws;
  bool _running = false;
  bool _intentionalClose = false;
  int _attempt = 0;
  Timer? _reconnectTimer;

  final _json = StreamController<Map<String, dynamic>>.broadcast();
  final _binary = StreamController<Uint8List>.broadcast();
  final _fileComplete = StreamController<String>.broadcast();
  final _state = StreamController<void>.broadcast();

  @override
  String get label => 'Relay';

  @override
  bool get isConnected => _ws != null;

  @override
  bool canReach(String to) => isConnected && to != userId;

  @override
  Stream<Map<String, dynamic>> get json => _json.stream;
  @override
  Stream<Uint8List> get binary => _binary.stream;
  @override
  Stream<String> get fileComplete => _fileComplete.stream;
  @override
  Stream<void> get stateChanged => _state.stream;

  Uri get _wsUri {
    var base = serverBase.trim();
    if (base.startsWith('https://')) {
      base = 'wss://${base.substring('https://'.length)}';
    } else if (base.startsWith('http://')) {
      base = 'ws://${base.substring('http://'.length)}';
    } else if (!base.startsWith('ws://') && !base.startsWith('wss://')) {
      base = 'ws://$base';
    }
    final u = Uri.parse(base);
    return u.replace(path: u.path.isEmpty ? '/ws' : u.path);
  }

  Uri get _httpUri {
    var base = serverBase.trim();
    if (base.startsWith('ws://')) {
      base = 'http://${base.substring('ws://'.length)}';
    } else if (base.startsWith('wss://')) {
      base = 'https://${base.substring('wss://'.length)}';
    } else if (!base.startsWith('http')) {
      base = 'http://$base';
    }
    return Uri.parse(base);
  }

  /// Register (or refresh) this identity with the relay. Idempotent.
  Future<bool> register() async {
    try {
      final res = await http
          .post(
            _httpUri.replace(path: '/register'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({
              'userId': userId,
              'publicKey': publicKeyB64,
              'displayName': displayName,
            }),
          )
          .timeout(const Duration(seconds: 8));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Look up a remote user's public key + display name via the relay.
  Future<Map<String, dynamic>?> lookupUser(String id) async {
    try {
      final res = await http
          .get(_httpUri.replace(path: '/users/$id'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      return Map<String, dynamic>.from(jsonDecode(res.body));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _intentionalClose = false;
    await register();
    await _connect();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _intentionalClose = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final ws = _ws;
    _ws = null;
    try {
      await ws?.close();
    } catch (_) {}
    _state.add(null);
  }

  Future<void> _connect() async {
    if (!_running || _intentionalClose) return;
    try {
      final ws = await WebSocket.connect(_wsUri.toString())
          .timeout(const Duration(seconds: 10));
      _ws = ws;
      _attempt = 0;
      ws.pingInterval = const Duration(seconds: 25);
      sendJson({'type': Envelope.hello, 'userId': userId});

      ws.listen(
        _onData,
        onError: (_) => _scheduleReconnect(),
        onDone: () => _scheduleReconnect(),
        cancelOnError: true,
      );
    } catch (_) {
      _ws = null;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    final wasConnected = _ws != null;
    _ws = null;
    if (wasConnected) _state.add(null);
    if (!_running || _intentionalClose) return;
    _reconnectTimer?.cancel();
    final delay = Duration(seconds: (1 << _attempt.clamp(0, 5)));
    _attempt++;
    _reconnectTimer = Timer(delay, _connect);
  }

  void _onData(dynamic data) {
    if (data is String) {
      Map<String, dynamic> e;
      try {
        e = Map<String, dynamic>.from(jsonDecode(data));
      } catch (_) {
        return;
      }
      _handleEnvelope(e);
    } else if (data is List<int>) {
      _binary.add(Uint8List.fromList(data));
    }
  }

  void _handleEnvelope(Map<String, dynamic> e) {
    switch (e['type']) {
      case Envelope.welcome:
        // Handshake complete: now safe to flush the outbox.
        _state.add(null);
        break;
      case Envelope.fileDone:
        final fid = e['fid'] as String?;
        if (fid != null) _fileComplete.add(fid);
        break;
      case Envelope.error:
        // Control frame: ignore for chat logic.
        break;
      default:
        // msg, ginvite, typing, receipt, presence, ack, fileready -> ChatStore.
        _json.add(e);
    }
  }

  @override
  void sendJson(Map<String, dynamic> envelope) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.add(jsonEncode(envelope));
    } catch (_) {}
  }

  @override
  void sendBinary(Uint8List frame) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.add(frame);
    } catch (_) {}
  }

  @override
  void notifyFileStored(String fid, String to) {
    sendJson({'type': Envelope.fileStored, 'fid': fid, 'to': to});
  }

  @override
  void requestFile(String fid) {
    sendJson({'type': Envelope.fileReq, 'fid': fid});
  }

  @override
  void confirmFileReceived(String fid) {
    sendJson({'type': Envelope.fileAck, 'fid': fid});
  }

  Future<void> dispose() async {
    await stop();
    await _json.close();
    await _binary.close();
    await _fileComplete.close();
    await _state.close();
  }
}
