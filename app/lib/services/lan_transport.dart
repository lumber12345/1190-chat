import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';
import 'transport.dart';

/// A peer discovered on the local network.
class LanPeer {
  LanPeer({
    required this.userId,
    required this.displayName,
    required this.publicKeyB64,
    required this.address,
    required this.port,
    required this.lastSeen,
  });

  final String userId;
  final String displayName;
  final String publicKeyB64;
  String address;
  int port;
  int lastSeen;
}

/// Peer-to-peer transport for devices on the same local network.
///
/// Discovery: each device periodically UDP-broadcasts a small beacon with its
/// userId, display name, X25519 public key and the TCP port of its WebSocket
/// server. Peers that hear a beacon can connect directly (WebSocket) and
/// exchange sealed envelopes and file-chunk frames with no relay involved.
///
/// Everything on the wire is still end-to-end encrypted; LAN just changes the
/// path, not the trust model.
class LanTransport extends Transport {
  LanTransport({
    required this.selfUserId,
    required this.publicKeyB64,
    required this.displayName,
    this.discoveryPort = 45123,
  });

  String selfUserId;
  String publicKeyB64;
  String displayName;
  final int discoveryPort;

  static const Duration _beaconInterval = Duration(seconds: 2);
  static const Duration _peerTimeout = Duration(seconds: 9);

  HttpServer? _http;
  RawDatagramSocket? _udp;
  Timer? _beaconTimer;
  Timer? _sweepTimer;
  bool _running = false;

  int _wsPort = 0;

  final Map<String, LanPeer> _peers = {};
  final Map<String, WebSocket> _sockets = {};
  final Map<String, List<dynamic>> _pending = {};

  // userId -> socket for inbound (server-accepted) connections awaiting hello.
  final Map<WebSocket, String?> _inboundOwner = {};

  final _json = StreamController<Map<String, dynamic>>.broadcast();
  final _binary = StreamController<Uint8List>.broadcast();
  final _fileComplete = StreamController<String>.broadcast();
  final _state = StreamController<void>.broadcast();
  final _peersChanged = StreamController<void>.broadcast();

  Map<String, LanPeer> get peers => Map.unmodifiable(_peers);
  Stream<void> get peersChanged => _peersChanged.stream;

  @override
  String get label => 'LAN';

  @override
  bool get isConnected => _running && _http != null;

  @override
  bool canReach(String userId) {
    if (userId == selfUserId) return false;
    final p = _peers[userId];
    if (p == null) return false;
    return DateTime.now().millisecondsSinceEpoch - p.lastSeen <
        _peerTimeout.inMilliseconds;
  }

  @override
  Stream<Map<String, dynamic>> get json => _json.stream;
  @override
  Stream<Uint8List> get binary => _binary.stream;
  @override
  Stream<String> get fileComplete => _fileComplete.stream;
  @override
  Stream<void> get stateChanged => _state.stream;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _startServer();
    await _startDiscovery();
    _beaconTimer = Timer.periodic(_beaconInterval, (_) => _broadcast());
    _sweepTimer = Timer.periodic(const Duration(seconds: 3), (_) => _sweep());
    _broadcast();
    _state.add(null);
  }

  @override
  Future<void> stop() async {
    _running = false;
    _beaconTimer?.cancel();
    _sweepTimer?.cancel();
    for (final s in _sockets.values) {
      try {
        await s.close();
      } catch (_) {}
    }
    _sockets.clear();
    try {
      _udp?.close();
    } catch (_) {}
    _udp = null;
    try {
      await _http?.close(force: true);
    } catch (_) {}
    _http = null;
    _peers.clear();
    _state.add(null);
    _peersChanged.add(null);
  }

  Future<void> _startServer() async {
    try {
      _http = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _wsPort = _http!.port;
      _http!.listen((req) async {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          try {
            final ws = await WebSocketTransformer.upgrade(req);
            _attachInbound(ws);
          } catch (_) {
            req.response.statusCode = 500;
            await req.response.close();
          }
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
    } catch (_) {
      _http = null;
    }
  }

  void _attachInbound(WebSocket ws) {
    _inboundOwner[ws] = null;
    ws.listen(
      (data) => _onSocketData(ws, data),
      onError: (_) => _dropInbound(ws),
      onDone: () => _dropInbound(ws),
      cancelOnError: true,
    );
  }

  void _dropInbound(WebSocket ws) {
    final owner = _inboundOwner.remove(ws);
    if (owner != null && _sockets[owner] == ws) {
      _sockets.remove(owner);
    }
    try {
      ws.close();
    } catch (_) {}
  }

  Future<void> _startDiscovery() async {
    try {
      _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
      );
      _udp!.broadcastEnabled = true;
      _udp!.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = _udp!.receive();
          if (dg == null) return;
          _handleBeacon(dg.data, dg.address);
        }
      });
    } catch (_) {
      _udp = null;
    }
  }

  void _broadcast() {
    final udp = _udp;
    if (udp == null || _wsPort == 0) return;
    final beacon = utf8.encode(jsonEncode({
      'proto': 'chat1190',
      'v': 1,
      'userId': selfUserId,
      'name': displayName,
      'pub': publicKeyB64,
      'port': _wsPort,
      'ts': DateTime.now().millisecondsSinceEpoch,
    }));
    try {
      udp.send(beacon, InternetAddress('255.255.255.255'), discoveryPort);
    } catch (_) {}
  }

  void _handleBeacon(Uint8List data, InternetAddress from) {
    Map<String, dynamic> b;
    try {
      b = Map<String, dynamic>.from(jsonDecode(utf8.decode(data)));
    } catch (_) {
      return;
    }
    if (b['proto'] != 'chat1190') return;
    final uid = b['userId'] as String?;
    if (uid == null || uid == selfUserId) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = _peers[uid];
    final port = (b['port'] as num?)?.toInt() ?? 0;
    if (existing == null) {
      _peers[uid] = LanPeer(
        userId: uid,
        displayName: b['name'] as String? ?? uid,
        publicKeyB64: b['pub'] as String? ?? '',
        address: from.address,
        port: port,
        lastSeen: now,
      );
      _peersChanged.add(null);
      _emitPresence(uid, true, b);
    } else {
      existing.lastSeen = now;
      existing.address = from.address;
      if (port != 0) existing.port = port;
      if ((b['name'] as String?) != null) {
        // display name may change; keep fresh
      }
    }
  }

  void _emitPresence(String uid, bool online, Map<String, dynamic> beacon) {
    _json.add({
      'type': Envelope.presence,
      'userId': uid,
      'online': online,
      'lan': true,
      'name': beacon['name'],
      'pub': beacon['pub'],
    });
  }

  void _sweep() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final lost = <String>[];
    _peers.forEach((uid, p) {
      if (now - p.lastSeen > _peerTimeout.inMilliseconds) lost.add(uid);
    });
    for (final uid in lost) {
      _peers.remove(uid);
      final s = _sockets.remove(uid);
      try {
        s?.close();
      } catch (_) {}
      _json.add({
        'type': Envelope.presence,
        'userId': uid,
        'online': false,
        'lan': true,
      });
      _peersChanged.add(null);
    }
  }

  Future<WebSocket?> _socketTo(String userId) async {
    final existing = _sockets[userId];
    if (existing != null) return existing;
    final peer = _peers[userId];
    if (peer == null || peer.port == 0) return null;
    try {
      final ws = await WebSocket.connect('ws://${peer.address}:${peer.port}/ws')
          .timeout(const Duration(seconds: 6));
      _sockets[userId] = ws;
      _inboundOwner[ws] = userId;
      ws.pingInterval = const Duration(seconds: 20);
      ws.listen(
        (data) => _onSocketData(ws, data),
        onError: (_) => _onSocketClosed(userId, ws),
        onDone: () => _onSocketClosed(userId, ws),
        cancelOnError: true,
      );
      // Identify ourselves.
      ws.add(jsonEncode({
        'type': Envelope.hello,
        'userId': selfUserId,
        'name': displayName,
        'pub': publicKeyB64,
      }));
      // Flush anything queued while connecting.
      final q = _pending.remove(userId);
      if (q != null) {
        for (final item in q) {
          ws.add(item);
        }
      }
      return ws;
    } catch (_) {
      return null;
    }
  }

  void _onSocketClosed(String userId, WebSocket ws) {
    if (_sockets[userId] == ws) _sockets.remove(userId);
    _inboundOwner.remove(ws);
  }

  void _onSocketData(WebSocket ws, dynamic data) {
    if (data is String) {
      Map<String, dynamic> e;
      try {
        e = Map<String, dynamic>.from(jsonDecode(data));
      } catch (_) {
        return;
      }
      if (e['type'] == Envelope.hello) {
        // Peer identifying itself on an inbound connection.
        final uid = e['userId'] as String?;
        if (uid != null) {
          _inboundOwner[ws] = uid;
          // Prefer the inbound socket for this peer if we lack one.
          _sockets.putIfAbsent(uid, () => ws);
        }
        return;
      }
      if (e['type'] == Envelope.fileDone) {
        final fid = e['fid'] as String?;
        if (fid != null) _fileComplete.add(fid);
        return;
      }
      _json.add(e);
    } else if (data is List<int>) {
      _binary.add(Uint8List.fromList(data));
    }
  }

  @override
  void sendJson(Map<String, dynamic> envelope) {
    final to = envelope['to'] as String?;
    if (to == null) return;
    _send(to, jsonEncode(envelope));
  }

  @override
  void sendBinary(Uint8List frame) {
    final to = FrameCodec.peekTo(frame);
    if (to == null) return;
    _send(to, frame);
  }

  void _send(String to, dynamic payload) {
    final ws = _sockets[to];
    if (ws != null) {
      try {
        ws.add(payload);
        return;
      } catch (_) {
        _sockets.remove(to);
      }
    }
    (_pending[to] ??= []).add(payload);
    // Kick off a connection; _socketTo flushes _pending on success.
    unawaited(_socketTo(to));
  }

  Future<void> dispose() async {
    await stop();
    await _json.close();
    await _binary.close();
    await _fileComplete.close();
    await _state.close();
    await _peersChanged.close();
  }
}
