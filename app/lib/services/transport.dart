import 'dart:typed_data';

/// A transport moves opaque JSON envelopes and binary file-chunk frames
/// between this device and a peer (either directly over LAN, or via the
/// internet relay). Neither transport can read the payload: message bodies
/// and file bytes are sealed end-to-end in [CryptoService].
abstract class Transport {
  /// Human label ("LAN" / "Relay").
  String get label;

  /// Whether the transport is up and usable.
  bool get isConnected;

  /// Whether this transport can currently deliver to [userId].
  bool canReach(String userId);

  /// Inbound JSON envelopes (already validated as JSON objects).
  Stream<Map<String, dynamic>> get json;

  /// Inbound binary chunk frames (raw wire bytes; decode with FrameCodec).
  Stream<Uint8List> get binary;

  /// Emits a `fid` once all chunks for that file have been received locally
  /// (recipient side). Fired on LAN `file_done` / relay `filedone`.
  Stream<String> get fileComplete;

  /// Fires whenever [isConnected] changes.
  Stream<void> get stateChanged;

  Future<void> start();
  Future<void> stop();

  /// Send a JSON envelope. The envelope must contain a `to` field.
  void sendJson(Map<String, dynamic> envelope);

  /// Send a binary chunk frame. The frame header must contain a `to` field.
  void sendBinary(Uint8List frame);

  /// Sender-side hook: notify that an upload finished (relay store-and-forward).
  /// LAN implementations no-op because chunks are streamed live.
  void notifyFileStored(String fid, String to) {}

  /// Recipient-side hook for the relay: request a stored file. LAN no-ops.
  void requestFile(String fid) {}

  /// Recipient-side hook: confirm a file was fully received and finalized.
  /// The relay uses this to (eventually) delete its stored copy; LAN no-ops.
  void confirmFileReceived(String fid) {}
}
