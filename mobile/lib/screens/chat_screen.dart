import 'dart:async';

import 'package:flutter/material.dart';

import '../api/protocol.dart';
import '../api/relay.dart';
import '../widgets/message_bubble.dart';
import '../widgets/permission_card.dart';

class ChatScreen extends StatefulWidget {
  final RelayApp app;
  final Device device;
  final Session session;
  final String title;
  const ChatScreen({
    super.key,
    required this.app,
    required this.device,
    required this.session,
    required this.title,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  List<Message> _messages = [];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<dynamic>? _sub;

  String _state = '空闲';
  PermissionAsk? _permission;
  bool _loading = true;
  String? _error;
  DateTime _lastEvent = DateTime.now();
  Timer? _watchdog;

  String get _sid => widget.session.id;
  String get _did => widget.device.id;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = widget.app.events.listen(_onEvent);
    // 看门狗：运行中超过 90s 无任何事件 → 视为卡死，重置状态并刷新
    _watchdog = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_state == '运行中' &&
          DateTime.now().difference(_lastEvent).inSeconds > 90) {
        setState(() => _state = '空闲');
        _load();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _watchdog?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await widget.app.cmd(_did, 'GET', '/session/$_sid/message?limit=200');
      if (!r.ok) throw ApiError(r.error ?? '加载失败');
      setState(() {
        _messages = (r.data as List?)
                ?.map((e) => Message.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
        _loading = false;
      });
      _scrollToBottom();
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _onEvent(Map<String, dynamic> ev) {
    final props = (ev['properties'] as Map?)?.cast<String, dynamic>() ?? {};
    final sid = props['sessionID'];
    if (sid != _sid) return;
    _lastEvent = DateTime.now();
    switch (ev['type']) {
      case 'message.created':
      case 'message.updated':
        _onMessageMeta(props);
        break;
      case 'message.part.updated':
        final part = props['part'];
        if (part is Map) {
          setState(() {
            _state = '运行中';
            _applyPart(Part.fromJson(part.cast<String, dynamic>()));
          });
          // reverse 列表自动锚定底部，无需滚动（避免抖动）
        }
        break;
      case 'permission.asked':
      case 'permission.ask':
        setState(() => _permission = PermissionAsk.fromProps(props));
        break;
      case 'session.status':
        final st = props['status'];
        final t = st is Map ? st['type'] : null;
        if (t == 'busy') {
          setState(() => _state = '运行中');
        } else if (t == 'idle') {
          setState(() => _state = '空闲');
          _load();
        }
        break;
      case 'session.idle':
        setState(() => _state = '空闲');
        _load();
        break;
      case 'session.error':
        setState(() => _state = '出错');
        _load();
        break;
      default:
        break;
    }
  }

  /// 按 messageID 归组更新消息（同一消息的所有 part 合并进一个气泡）
  void _applyPart(Part part) {
    final mid = (part.messageID?.isNotEmpty ?? false) ? part.messageID : null;
    Message? target;
    int targetIdx = -1;
    for (var i = 0; i < _messages.length; i++) {
      if (_messages[i].id == mid ||
          (mid == null && _messages[i].parts.any((p) => p.id == part.id))) {
        target = _messages[i];
        targetIdx = i;
        break;
      }
    }
    if (target == null) {
      // 新消息：role 由 message.created 事件保证（见 _onMessageMeta），兜底用 _lastRole
      _messages = [
        ..._messages,
        Message(id: mid ?? '', role: _lastRole(), parts: [part])
      ];
      return;
    }
    final parts = List<Part>.from(target.parts);
    final idx = parts.indexWhere((p) => p.id == part.id);
    if (idx >= 0) {
      parts[idx] = part;
    } else {
      parts.add(part);
    }
    _messages[targetIdx] = Message(id: target.id, role: target.role, parts: parts);
  }

  /// message.created/updated 事件：记录消息 role，确保用户/助手消息在正确一侧
  void _onMessageMeta(Map<String, dynamic> props) {
    final info = props['info'];
    if (info is Map && info['id'] is String) {
      final id = info['id'] as String;
      final role = info['role'] as String? ?? 'assistant';
      setState(() {
        final i = _messages.indexWhere((m) => m.id == id);
        if (i >= 0) {
          final m = _messages[i];
          _messages[i] = Message(id: id, role: role, parts: m.parts);
        } else {
          _messages = [..._messages, Message(id: id, role: role, parts: [])];
        }
      });
    }
  }

  String _lastRole() {
    if (_messages.isEmpty) return 'assistant';
    final last = _messages.last;
    return last.role == 'user' ? 'assistant' : 'user';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      // reverse 列表：offset 0 = 最新消息在底部
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _state == '运行中') return;
    if (!widget.app.wsAlive.value) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('连接已断开，正在重连，请稍后再发')));
      }
      return;
    }
    setState(() {
      _input.clear();
      _state = '运行中';
    });
    final r = await widget.app.cmd(_did, 'POST', '/session/$_sid/prompt_async',
        {'parts': [{'type': 'text', 'text': text}]});
    if (!r.ok && mounted) {
      setState(() {
        _state = '空闲';
        _error = r.error;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('发送失败: ${r.error}')));
    }
  }

  Future<void> _abort() async {
    await widget.app.cmd(_did, 'POST', '/session/$_sid/abort');
    if (mounted) setState(() => _state = '空闲');
  }

  Future<void> _respond(String response) async {
    final p = _permission;
    if (p == null) return;
    setState(() => _permission = null);
    final r = await widget.app.cmd(_did, 'POST',
        '/session/$_sid/permissions/${p.permissionId}', {'response': response});
    if (!r.ok && mounted) {
      setState(() => _error = r.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stateColor = switch (_state) {
      '运行中' => Colors.orange,
      '出错' => Colors.red,
      _ => Colors.green,
    };
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title.isEmpty ? '会话' : widget.title,
                style: const TextStyle(fontSize: 16)),
            Row(children: [
              Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(color: stateColor, shape: BoxShape.circle)),
              const SizedBox(width: 4),
              Text(_state, style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(width: 6),
            ValueListenableBuilder<bool>(
              valueListenable: widget.app.wsAlive,
              builder: (_, alive, __) => Text(
                alive ? '●' : '○ 连接断开',
                style: TextStyle(
                  fontSize: 11,
                  color: alive ? Colors.green : Colors.red,
                ),
              ),
            ),
            ]),
          ],
        ),
        actions: [
          if (_state == '运行中')
            TextButton(
              onPressed: _abort,
              child: const Text('中止', style: TextStyle(color: Colors.red)),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Container(
              width: double.infinity,
              color: const Color(0xFFFFF1F0),
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scroll,
                    reverse: true, // 底部锚定：新消息/键盘弹出都不遮挡最新内容
                    padding: const EdgeInsets.all(14),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => MessageBubble(
                        role: _messages[_messages.length - 1 - i].role,
                        parts: _messages[_messages.length - 1 - i].parts),
                  ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xFFE1E4E8))),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      // 运行中也保持可用（键盘不收起，可提前输入下一条）
                      decoration: const InputDecoration(
                        hintText: '给电脑上的 opencode 下指令…',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(18))),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1F6FEB),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    ),
                    onPressed: _send,
                    child: const Text('发送'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomSheet: _permission != null
          ? PermissionCard(permission: _permission!, onRespond: _respond)
          : null,
    );
  }
}
