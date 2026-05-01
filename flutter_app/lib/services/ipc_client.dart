import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// IPC client for communicating with the Go VPN core service
/// over a Unix Domain Socket using JSON-RPC 2.0.
class IpcClient {
  Socket? _socket;
  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  final StreamController<Map<String, dynamic>> _notificationController =
      StreamController.broadcast();
  StringBuffer _buffer = StringBuffer();

  /// Stream of server-initiated notifications (e.g., log entries, status updates).
  Stream<Map<String, dynamic>> get notifications =>
      _notificationController.stream;

  /// Connects to the Go core service via Unix Domain Socket.
  Future<void> connect(String socketPath) async {
    try {
      final address = InternetAddress(socketPath, type: InternetAddressType.unix);
      _socket = await Socket.connect(address, 0);
      _socket!.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
      );
    } catch (e) {
      throw Exception('Failed to connect to IPC socket at $socketPath: $e');
    }
  }

  /// Sends a JSON-RPC 2.0 request and waits for the response.
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    if (_socket == null) {
      throw StateError('IPC client not connected');
    }

    final id = _nextId++;
    final request = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };

    final completer = Completer<dynamic>();
    _pending[id] = completer;

    final data = '${jsonEncode(request)}\n';
    _socket!.add(utf8.encode(data));

    // Timeout after 30 seconds.
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('IPC call "$method" timed out');
      },
    );
  }

  /// Closes the IPC connection.
  Future<void> disconnect() async {
    _pending.clear();
    await _socket?.close();
    _socket = null;
  }

  void _onData(List<int> data) {
    _buffer.write(utf8.decode(data));
    final lines = _buffer.toString().split('\n');

    // Keep the last incomplete line in the buffer.
    _buffer = StringBuffer(lines.last);

    for (int i = 0; i < lines.length - 1; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        _handleMessage(json);
      } catch (e) {
        // Skip malformed JSON lines.
      }
    }
  }

  void _handleMessage(Map<String, dynamic> msg) {
    // Check if this is a response (has 'id' field).
    if (msg.containsKey('id') && msg['id'] != null) {
      final id = msg['id'] as int;
      final completer = _pending.remove(id);
      if (completer == null) return;

      if (msg.containsKey('error') && msg['error'] != null) {
        final error = msg['error'] as Map<String, dynamic>;
        completer.completeError(
          Exception('RPC error ${error['code']}: ${error['message']}'),
        );
      } else {
        completer.complete(msg['result']);
      }
    } else {
      // Server-initiated notification (no id).
      _notificationController.add(msg);
    }
  }

  void _onError(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pending.clear();
  }

  void _onDone() {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('IPC connection closed'));
      }
    }
    _pending.clear();
    _socket = null;
  }

  /// Whether the client is currently connected.
  bool get isConnected => _socket != null;
}
