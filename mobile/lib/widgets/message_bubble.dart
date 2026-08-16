import 'dart:convert';

import 'package:flutter/material.dart';

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
    // 合并同一消息的所有思考 part 为一条（折叠单行）
    final reasoningText = parts
        .where((p) => p.type == 'reasoning')
        .map((p) => p.text ?? '')
        .where((t) => t.isNotEmpty)
        .join('\n');
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
            if (parts.isEmpty && reasoningText.isEmpty && toolParts.isEmpty && textParts.isEmpty)
              const Text('…', style: TextStyle(color: Colors.grey)),
            if (reasoningText.isNotEmpty) ReasoningStrip(text: reasoningText),
            for (final p in toolParts) ToolCard(part: p),
            for (final p in textParts)
              Text(p.text!,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.5,
                    color: isUser ? Colors.white : const Color(0xFF1F2328),
                  )),
          ],
        ),
      ),
    );
  }
}

/// 思考内容：折叠为单行横向滚动条，点击展开/收起
class ReasoningStrip extends StatefulWidget {
  final String text;
  const ReasoningStrip({super.key, required this.text});

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
    final thinking = text.isEmpty;
    final label = _expanded
        ? '收起思考'
        : thinking
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
