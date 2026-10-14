import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../security/token_store.dart';

enum ConnectionStatus { connecting, connected, disconnected }

sealed class RealtimeEvent {
  const RealtimeEvent();
}

class MessageCreatedEvent extends RealtimeEvent {
  const MessageCreatedEvent(this.payload);
  final Map<String, dynamic> payload;
}

class MessageUpdatedEvent extends RealtimeEvent {
  const MessageUpdatedEvent(this.payload);
  final Map<String, dynamic> payload;
}

class MessageReadEvent extends RealtimeEvent {
  const MessageReadEvent(this.payload);
  final Map<String, dynamic> payload;
}

class ConversationUpdatedEvent extends RealtimeEvent {
  const ConversationUpdatedEvent(this.payload);
  final Map<String, dynamic> payload;
}

class ReconnectedEvent extends RealtimeEvent {
  const ReconnectedEvent();
}

/// One app-wide SignalR JSON transport. REST is queried after reconnect so a
/// dropped socket cannot permanently lose a message.
class RealtimeService {
  RealtimeService(this._dio, this._tokenStore);

  final Dio _dio;
  final TokenStore _tokenStore;
  final _events = StreamController<RealtimeEvent>.broadcast();
  final _statuses = StreamController<ConnectionStatus>.broadcast();
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _retryTimer;
  Timer? _heartbeat;
  Completer<void>? _handshake;
  String _buffer = '';
  bool _disposed = false;
  bool _connecting = false;
  ConnectionStatus status = ConnectionStatus.disconnected;

  Stream<RealtimeEvent> get events => _events.stream;
  Stream<ConnectionStatus> get statuses => _statuses.stream;

  Future<void> connect() async {
    if (_disposed || _connecting || _socket != null) return;
    _connecting = true;
    _setStatus(ConnectionStatus.connecting);
    try {
      final response = await _dio.post(
        '/hubs/chat/negotiate',
        queryParameters: {'negotiateVersion': 1},
      );
      final negotiation = Map<String, dynamic>.from(response.data as Map);
      final connectionToken =
          (negotiation['connectionToken'] ?? negotiation['connectionId'])
              as String;
      final httpUri = Uri.parse('${AppConfig.apiBaseUrl}/hubs/chat');
      final wsUri = httpUri.replace(
        scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
        queryParameters: {...httpUri.queryParameters, 'id': connectionToken},
      );
      final token = await _tokenStore.readAccessToken();
      final socket = await WebSocket.connect(
        wsUri.toString(),
        headers: {
          if (token != null) HttpHeaders.authorizationHeader: 'Bearer $token',
        },
      );
      if (_disposed) {
        await socket.close();
        return;
      }
      _socket = socket;
      _buffer = '';
      _handshake = Completer<void>();
      _socketSubscription = socket.listen(
        _onData,
        onError: (_) => _onDisconnected(),
        onDone: _onDisconnected,
        cancelOnError: true,
      );
      socket.add('${jsonEncode({'protocol': 'json', 'version': 1})}\x1e');
      await _handshake!.future.timeout(const Duration(seconds: 10));
      _retryTimer?.cancel();
      _setStatus(ConnectionStatus.connected);
      _events.add(const ReconnectedEvent());
      _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
        _socket?.add('${jsonEncode({'type': 6})}\x1e');
      });
    } catch (_) {
      await _socketSubscription?.cancel();
      await _socket?.close();
      _socket = null;
      _setStatus(ConnectionStatus.disconnected);
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  void _onData(dynamic data) {
    _buffer += data is String ? data : utf8.decode(data as List<int>);
    while (true) {
      final end = _buffer.indexOf('\x1e');
      if (end < 0) break;
      final frame = _buffer.substring(0, end);
      _buffer = _buffer.substring(end + 1);
      if (frame.isEmpty) continue;
      try {
        final message = Map<String, dynamic>.from(jsonDecode(frame) as Map);
        if (_handshake?.isCompleted == false) {
          final error = message['error'];
          if (error == null) {
            _handshake!.complete();
          } else {
            _handshake!.completeError(StateError(error.toString()));
          }
          continue;
        }
        if (message['type'] == 1) _dispatchInvocation(message);
        if (message['type'] == 7) _onDisconnected();
      } catch (_) {
        // A malformed event cannot stop the REST sync or future events.
      }
    }
  }

  void _dispatchInvocation(Map<String, dynamic> message) {
    final args = message['arguments'];
    if (args is! List || args.isEmpty || args.first is! Map) return;
    final payload = Map<String, dynamic>.from(args.first as Map);
    switch (message['target']) {
      case 'MessageCreated':
        _events.add(MessageCreatedEvent(payload));
      case 'MessageUpdated':
        _events.add(MessageUpdatedEvent(payload));
      case 'MessageRead':
        _events.add(MessageReadEvent(payload));
      case 'ConversationUpdated':
        _events.add(ConversationUpdatedEvent(payload));
    }
  }

  void _onDisconnected() {
    _heartbeat?.cancel();
    _socket = null;
    _setStatus(ConnectionStatus.disconnected);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_disposed || _retryTimer?.isActive == true) return;
    _retryTimer = Timer(const Duration(seconds: 5), connect);
  }

  void _setStatus(ConnectionStatus value) {
    status = value;
    if (!_statuses.isClosed) _statuses.add(value);
  }

  Future<void> dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    _heartbeat?.cancel();
    await _socketSubscription?.cancel();
    await _socket?.close();
    await _events.close();
    await _statuses.close();
  }
}
