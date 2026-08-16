/// 与 PROTOCOL.md 一致的协议类型。
library;

class Device {
  final String id;
  final String name;
  final bool online;
  final String status; // active | pending
  final String? version;
  final int lastSeen;

  const Device({
    required this.id,
    required this.name,
    required this.online,
    this.status = 'active',
    this.version,
    required this.lastSeen,
  });

  bool get isPending => status == 'pending';

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: j['id'] as String,
        name: j['name'] as String,
        online: j['online'] as bool? ?? false,
        status: j['status'] as String? ?? 'active',
        version: j['version'] as String?,
        lastSeen: j['lastSeen'] as int? ?? 0,
      );
}

class CmdRequest {
  final String id;
  final String deviceId;
  final String method;
  final String path;
  final Map<String, dynamic>? body;

  const CmdRequest({
    required this.id,
    required this.deviceId,
    required this.method,
    required this.path,
    this.body,
  });

  Map<String, dynamic> toJson() => {
        'type': 'cmd',
        'id': id,
        'deviceID': deviceId,
        'cmd': {
          'method': method,
          'path': path,
          if (body != null) 'body': body,
        },
      };
}

class CmdResult {
  final String id;
  final bool ok;
  final dynamic data;
  final String? error;

  const CmdResult({required this.id, required this.ok, this.data, this.error});
}

// ---------- opencode 会话/消息类型（与 v1 实测一致） ----------

class Session {
  final String id;
  final String title;
  final String directory;
  final int updated;

  const Session({
    required this.id,
    required this.title,
    required this.directory,
    required this.updated,
  });

  factory Session.fromJson(Map<String, dynamic> j) => Session(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        directory: j['directory'] as String? ?? '',
        updated: (j['time'] is Map ? j['time']['updated'] : null) as int? ?? 0,
      );
}

class Part {
  final String? id;
  final String type;
  final String? text;
  final String? tool;
  final String? messageID;
  final dynamic state;
  final dynamic input;

  const Part({
    this.id,
    required this.type,
    this.text,
    this.tool,
    this.messageID,
    this.state,
    this.input,
  });

  factory Part.fromJson(Map<String, dynamic> j) => Part(
        id: j['id'] as String?,
        type: j['type'] as String? ?? 'text',
        text: j['text'] as String?,
        tool: j['tool'] as String?,
        messageID: j['messageID'] as String?,
        state: j['state'],
        input: j['input'],
      );

  bool get isTool => type == 'tool';

  String get toolStatus {
    final s = state;
    if (s is String) return s;
    if (s is Map && s['status'] is String) return s['status'] as String;
    return 'pending';
  }

  dynamic get toolInput {
    if (state is Map && state!['input'] != null) return state!['input'];
    return input;
  }
}

class Message {
  final String id;
  final String role;
  final List<Part> parts;

  const Message({required this.id, required this.role, required this.parts});

  factory Message.fromJson(Map<String, dynamic> j) {
    final rawParts = (j['parts'] as List?) ?? const [];
    return Message(
      id: (j['info'] is Map ? j['info']['id'] : null) as String? ?? '',
      role: (j['info'] is Map ? j['info']['role'] : null) as String? ?? 'assistant',
      parts: rawParts.map((p) => Part.fromJson(p as Map<String, dynamic>)).toList(),
    );
  }
}

class PermissionAsk {
  final String permissionId;
  final String sessionId;
  final String tool;
  final dynamic input;
  final String? userText;

  const PermissionAsk({
    required this.permissionId,
    required this.sessionId,
    required this.tool,
    this.input,
    this.userText,
  });

  factory PermissionAsk.fromProps(Map<String, dynamic> p) => PermissionAsk(
        permissionId: (p['id'] ?? p['permissionID']) as String,
        sessionId: p['sessionID'] as String? ?? '',
        tool: (p['permission'] ?? p['tool'] ?? 'unknown') as String,
        input: p['metadata'] ?? p['patterns'] ?? p['input'],
        userText: p['userText'] as String?,
      );
}
