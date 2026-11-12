// 极简对讲中继（零依赖，只用 dart:io）。
//
// 为什么需要它：`Aec3RoomPage` 是「两人无耳机对讲」的验证页，必须有东西
// 把 A 的上行 opus 送给 B、把 B 的送给 A。原工程的 voip-server（Go + libopus）
// 做的是 MCU 混音，两人场景下「原包转发」与「混音后下发」在听感上等价，
// 但少一层解码-重编码，延迟更低 —— 更适合拿来验 AEC。
//
// 协议与 voip-server **逐字段对齐**（这样页面的代码可以直接搬回去）：
//
//   连接建立      → 服务端先发文本 "ws_connection_success"
//   {"type":"join","content":{"roomId","userId"}}
//                 → 广播 {"type":"join","data":{...,"_roomId","_userId"}}
//                 → 给自己回 {"type":"join","data":{success,clientsNum,...}}
//   {"type":"heartbeat","content":{...}}
//                 → 回 {"type":"heartbeat","data":{room,clientsNum,timestamp,...}}
//   其他 type      → 补 _roomId/_userId/_timestamp 后广播给房间内其他人
//   二进制         → 原样转发给房间内其他人（这就是 opus 包）
//
// 跑法：
//   dart run tool/relay_server.dart --port 8089
//   （手机和电脑要在同一局域网；页面里填 ws://<电脑 IP>:8089）

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class _Client {
  _Client(this.ws);
  final WebSocket ws;
  String? roomId;
  String? userId;
}

final Map<String, Set<_Client>> _rooms = {};

Future<void> main(List<String> args) async {
  int port = 8089;
  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.tryParse(args[i + 1]) ?? port;
    }
  }

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  print('▶ 中继已启动: ws://<本机IP>:$port   （监听 0.0.0.0:$port）');
  for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in ni.addresses) {
      print('   局域网可用: ws://${a.address}:$port');
    }
  }

  await for (final req in server) {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response
        ..statusCode = HttpStatus.ok
        ..write('AEC3 relay alive. 用 ws:// 连接。\\n');
      await req.response.close();
      continue;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    _handle(_Client(ws));
  }
}

void _handle(_Client client) {
  final ws = client.ws;
  // 与原服务端一致：连上先给一句提示
  ws.add('ws_connection_success');
  print('＋ 连接建立 ${ws.hashCode}');

  ws.listen(
    (dynamic data) {
      if (data is String) {
        _onText(client, data);
      } else if (data is List<int>) {
        _onBinary(client, data);
      }
    },
    onDone: () {
      final room = client.roomId;
      final uid = client.userId;
      if (room != null) _rooms[room]?.remove(client);
      if (room != null && uid != null) {
        _broadcast(room, {
          'type': 'leave',
          'data': {
            'text': '$uid 离开了房间',
            '_roomId': room,
            '_userId': uid,
            '_timestamp': DateTime.now().millisecondsSinceEpoch,
          },
        }, except: client);
      }
      print('－ 连接关闭 ${ws.hashCode} room=$room user=$uid');
    },
    onError: (Object e) => print('! 连接错误 ${ws.hashCode}: $e'),
    cancelOnError: true,
  );
}

void _onText(_Client client, String raw) {
  Map<String, dynamic> msg;
  try {
    msg = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return;
  }
  final type = msg['type']?.toString() ?? '';
  dynamic content = msg['content'] ?? msg['data'] ?? {};
  if (content is String) {
    try {
      content = jsonDecode(content);
    } catch (_) {
      content = {};
    }
  }
  final map = (content is Map) ? content : <String, dynamic>{};

  switch (type) {
    case 'join':
      final roomId = map['roomId']?.toString() ?? '';
      final userId = map['userId']?.toString() ?? '';
      if (roomId.isEmpty || userId.isEmpty) return;

      final oldRoom = client.roomId;
      if (oldRoom != null) {
        _rooms[oldRoom]?.remove(client);
        _broadcast(oldRoom, {
          'type': 'leave',
          'data': {
            'text': '${client.userId} 离开了房间',
            '_roomId': oldRoom,
            '_userId': client.userId,
            '_timestamp': DateTime.now().millisecondsSinceEpoch,
          },
        }, except: client);
      }

      client.roomId = roomId;
      client.userId = userId;
      _rooms.putIfAbsent(roomId, () => <_Client>{}).add(client);

      _broadcast(roomId, {
        'type': 'join',
        'data': {
          'text': '$userId 加入了房间',
          '_roomId': roomId,
          '_userId': userId,
          '_timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      }, except: client);

      client.ws.add(jsonEncode({
        'type': 'join',
        'data': {
          'success': true,
          '_roomId': roomId,
          '_userId': userId,
          'clientsNum': _rooms[roomId]?.length ?? 1,
        },
      }));
      print('→ join room=$roomId user=$userId 人数=${_rooms[roomId]?.length}');
      break;

    case 'leave':
      final roomId = client.roomId;
      final userId = client.userId;
      if (roomId == null || userId == null) return;
      _rooms[roomId]?.remove(client);
      client.roomId = null;
      _broadcast(roomId, {
        'type': 'leave',
        'data': {
          'text': '$userId 离开了房间',
          '_roomId': roomId,
          '_userId': userId,
          '_timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      }, except: client);
      break;

    case 'heartbeat':
      final roomId = client.roomId ?? '';
      client.ws.add(jsonEncode({
        'type': 'heartbeat',
        'data': {
          'room': roomId,
          'clientsNum': _rooms[roomId]?.length ?? 0,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      }));
      break;

    default:
      final roomId = client.roomId;
      final userId = client.userId;
      if (roomId == null || userId == null) return;
      // start_record 必须带 delayedTimestamp（与原服务端一致的校验）
      if (type == 'start_record' && !map.containsKey('delayedTimestamp')) return;
      final out = Map<String, dynamic>.from(map)
        ..['_roomId'] = roomId
        ..['_userId'] = userId
        ..['_timestamp'] = DateTime.now().millisecondsSinceEpoch;
      _broadcast(roomId, {'type': type, 'data': out}, except: client);
      break;
  }
}

/// 二进制 = 裸 opus 包，转发给房间内其他人（两人场景等价于服务端混音）
void _onBinary(_Client client, List<int> data) {
  final roomId = client.roomId;
  if (roomId == null) return;
  for (final peer in _rooms[roomId] ?? const <_Client>{}) {
    if (identical(peer, client)) continue;
    try {
      peer.ws.add(data);
    } catch (_) {}
  }
}

void _broadcast(
  String roomId,
  Map<String, dynamic> payload, {
  _Client? except,
}) {
  final text = jsonEncode(payload);
  for (final peer in _rooms[roomId] ?? const <_Client>{}) {
    if (identical(peer, except)) continue;
    try {
      peer.ws.add(text);
    } catch (_) {}
  }
}
