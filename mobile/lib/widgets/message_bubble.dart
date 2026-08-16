import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../api/protocol.dart';

const _stateColors = {
  'pending': Colors.grey,
  'running': Colors.orange,
  'completed': Colors.green,
  'error': Colors.red,
  'cancelled': Colors.grey,
};

class ToolCard extends StatelessWidget {
  final Part part;
  const ToolCard({super.key, required this.part});

  @override
  Widget build(BuildContext context) {
    final status = part.toolStatus;
    final color = _stateColors[status] ?? Colors.grey;
    String body = '';
    final input = part.toolInput;
    if (input != null) {
      body = _pretty(input);
      if (body.length > 400) body = '${body.substring(0, 400)}…';
    }
    final output = (part.state is Map) ? part.state!['output'] : null;
    if (status == 'completed' && output != null) {
      var out = _pretty(output);
      if (out.length > 200) out = '${out.substring(0, 200)}…';
      body = body.isEmpty ? '输出: $out' : '$body\n\n输出: $out';
    }
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  part.tool ?? 'tool',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              Text(status,
                  style: TextStyle(fontSize: 11, color: color, letterSpacing: 0.5)),
            ],
          ),
          if (body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(body,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF57606A), fontFamily: 'monospace')),
            ),
        ],
      ),
    );
  }

  static String _pretty(dynamic v) {
    if (v is String) return v;
    return const JsonEncoder.withIndent('  ').convert(v);
  }
}

class MessageBubble extends StatelessWidget {
  final String role;
  final List<Part> parts;
  const MessageBubble({super.key, required this.role, required this.parts});

  @override
  Widget build(BuildContext context) {
    final isUser = role == 'user';
    // 思考内容不在消息内渲染（由聊天页按回合统一显示一条）
    final toolParts = parts.where((p) => p.isTool).toList();
    final textParts = parts
        .where((p) => p.type == 'text' && (p.text ?? '').isNotEmpty)
        .toList();
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFF1F6FEB) : const Color(0xFFF2F3F5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (toolParts.isEmpty && textParts.isEmpty)
              const Text('…', style: TextStyle(color: Colors.grey)),
            for (final p in toolParts) ToolCard(part: p),
            if (textParts.isNotEmpty)
              isUser
                  ? Text(
                      textParts.map((p) => p.text!).join('\n'),
                      style: const TextStyle(
                          fontSize: 15, height: 1.5, color: Colors.white),
                    )
                  : MarkdownBody(
                      data: textParts.map((p) => p.text!).join('\n'),
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(
                            fontSize: 15, height: 1.5, color: Color(0xFF1F2328)),
                        strong: const TextStyle(
                            fontWeight: FontWeight.w700, color: Color(0xFF1F2328)),
                        code: const TextStyle(
                            fontSize: 13,
                            fontFamily: 'monospace',
                            color: Color(0xFF24292F),
                            backgroundColor: Color(0xFFE8ECF0)),
                        codeblockDecoration: BoxDecoration(
                          color: const Color(0xFF0D1117),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        codeblockPadding: const EdgeInsets.all(10),
                        blockquoteDecoration: BoxDecoration(
                          color: const Color(0xFFE8ECF0),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        h1: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF1F2328)),
                        h2: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF1F2328)),
                        h3: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF1F2328)),
                        listBullet: const TextStyle(color: Color(0xFF57606A)),
                        blockquote: const TextStyle(color: Color(0xFF57606A)),
                        horizontalRuleDecoration: const BoxDecoration(
                          border: Border(top: BorderSide(color: Color(0xFFD0D7DE))),
                        ),
                      ),
                      selectable: true,
                    ),
          ],
        ),
      ),
    );
  }
}

/// 思考内容：折叠为单行横向滚动条，点击展开/收起
class ReasoningStrip extends StatefulWidget {
  final String text;
  final bool thinking;
  const ReasoningStrip({super.key, required this.text, this.thinking = false});

  @override
  State<ReasoningStrip> createState() => _ReasoningStripState();
}

class _ReasoningStripState extends State<ReasoningStrip> {
  bool _expanded = false;
  final _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final label = _expanded
        ? '收起思考'
        : widget.thinking
            ? '🤔 思考中…'
            : '🧠 已思考 · 点击展开';
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF2FF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFB6D4FF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('🧠', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(label,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1F6FEB))),
                ),
              ],
            ),
            if (text.isNotEmpty)
              _expanded
                  ? Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(text,
                          style: const TextStyle(
                              fontSize: 13, height: 1.5, color: Color(0xFF57606A))),
                    )
                  : SingleChildScrollView(
                      controller: _scrollCtrl,
                      scrollDirection: Axis.horizontal,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(text,
                            maxLines: 1,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF57606A))),
                      ),
                    ),
          ],
        ),
      ),
    );
  }
}
