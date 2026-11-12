import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 房间通信状态
enum RoomSocketStatus { disconnected, connecting, connected, reconnecting, error }

/// 消息类型 —— 与 `zyxc-record-app/lib/module/chat/audio/my_dual_websocket_manager.dart`
/// 的 `WebSocketMessageType` 保持一致（value 逐个对齐，方便日后整体迁移）。
class WsType {
  static const String heartbeat = 'heartbeat';
  static const String connectionSuccess = 'ws_connection_success';
  static const String join = 'join';
  static const String leave = 'leave';
  static const String startRecord = 'start_record';
  static const String stopRecord = 'stop_record';
  static const String chat = 'chat';
}

/// 房间消息模型：`{"type": ..., "content": ...}`
/// 服务端会把 content 原样搬进 `data` 并补 `_roomId/_userId/_timestamp`。
class RoomMessage {
  final String type;
  final dynamic content;

  RoomMessage({required this.type, required this.content});

  String toJson() => json.encode({'type': type, 'content': content});

  factory RoomMessage.fromRaw(String type, dynamic content) =>
      RoomMessage(type: type, content: content);

  @override
  String toString() => 'RoomMessage($type, $content)';
}

/// 极简版对讲 WebSocket 管理器。
///
/// 结构照抄原工程（单例 + 4 条流 + 心跳 + 指数重连），只砍掉和录音业务
/// 无关的部分（统计、eventBus、主题同步）。
class RoomSocketManager {
  static final RoomSocketManager instance = RoomSocketManager._internal();
  factory RoomSocketManager() => instance;
  RoomSocketManager._internal();

  WebSocket? _webSocket;
  String _url = '';

  RoomSocketStatus _status = RoomSocketStatus.disconnected;
  RoomSocketStatus get status => _status;
  bool get isConnected => _status == RoomSocketStatus.connected;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int maxReconnectAttempts = 5;

  Timer? _heartbeatTimer;
  static const Duration heartbeatInterval = Duration(seconds: 5);

  final _textController = StreamController<RoomMessage>.broadcast();
  final _pingController = StreamController<RoomMessage>.broadcast();
  final _binaryController = StreamController<Uint8List>.broadcast();
  final _statusController = StreamController<RoomSocketStatus>.broadcast();

  Stream<RoomMessage> get textMessageStream => _textController.stream;
  Stream<RoomMessage> get pingMessageStream => _pingController.stream;
  Stream<Uint8List> get binaryMessageStream => _binaryController.stream;
  Stream<RoomSocketStatus> get statusStream => _statusController.stream;

  Future<bool> connect(String url) async {
    if (_status == RoomSocketStatus.connected && _url == url) return true;
    if (_status == RoomSocketStatus.connecting) return false;

    _url = url;
    _updateStatus(RoomSocketStatus.connecting);
    try {
      _webSocket = await WebSocket.connect(url);
      _setupListeners();
      _updateStatus(RoomSocketStatus.connected);
      _reconnectAttempts = 0;
      _startHeartbeat();
      return true;
    } catch (e) {
      debugPrint('WebSocket 连接失败: $e');
      _updateStatus(RoomSocketStatus.error);
      _scheduleReconnect();
      return false;
    }
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopHeartbeat();
    _reconnectAttempts = 0;
    await _webSocket?.close();
    _webSocket = null;
    _updateStatus(RoomSocketStatus.disconnected);
  }

  Future<bool> sendMessage(RoomMessage message) async {
    final ws = _webSocket;
    if (ws == null) return false;
    try {
      ws.add(message.toJson());
      return true;
    } catch (e) {
      debugPrint('发送失败: $e');
      return false;
    }
  }

  /// 上行音频：裸 opus 包（服务端按二进制透传/混音）
  Future<bool> sendBinaryMessage(Uint8List packet) async {
    final ws = _webSocket;
    if (ws == null) return false;
    try {
      ws.add(packet);
      return true;
    } catch (e) {
      return false;
    }
  }

  void _setupListeners() {
    _webSocket!.listen(
      (data) {
        if (data is String) {
          if (data == WsType.connectionSuccess) {
            _updateStatus(RoomSocketStatus.connected);
            return;
          }
          try {
            final jsonData = jsonDecode(data) as Map;
            final type = jsonData['type']?.toString() ?? '';
            final content = jsonData['data'] ?? {};
            final msg = RoomMessage.fromRaw(type, content);
            if (type == WsType.heartbeat) {
              _pingController.add(msg);
            } else {
              _textController.add(msg);
            }
          } catch (e) {
            debugPrint('消息解析失败: $e / $data');
          }
        } else if (data is List<int>) {
          _binaryController.add(
            data is Uint8List ? data : Uint8List.fromList(data),
          );
        }
      },
      onError: (Object e) {
        debugPrint('WebSocket 错误: $e');
        _updateStatus(RoomSocketStatus.error);
        _scheduleReconnect();
      },
      onDone: () {
        debugPrint('WebSocket 已关闭');
        _updateStatus(RoomSocketStatus.disconnected);
        _scheduleReconnect();
      },
    );
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (!isConnected) return;
      sendMessage(RoomMessage(type: WsType.heartbeat, content: {}));
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= maxReconnectAttempts) {
      debugPrint('重连次数已达上限');
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () async {
      _reconnectAttempts++;
      _updateStatus(RoomSocketStatus.reconnecting);
      final ok = await connect(_url);
      if (!ok) _scheduleReconnect();
    });
  }

  void _updateStatus(RoomSocketStatus s) {
    _status = s;
    _statusController.add(s);
  }
}

/// 给 UI 用的中文状态文案
String roomStatusText(RoomSocketStatus s) {
  switch (s) {
    case RoomSocketStatus.disconnected:
      return '未连接';
    case RoomSocketStatus.connecting:
      return '连接中…';
    case RoomSocketStatus.connected:
      return '已连接';
    case RoomSocketStatus.reconnecting:
      return '重连中…';
    case RoomSocketStatus.error:
      return '连接错误';
  }
}
