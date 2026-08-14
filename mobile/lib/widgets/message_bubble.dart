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
            if (parts.isEmpty)
              const Text('…', style: TextStyle(color: Colors.grey)),
            for (final p in parts)
              if (p.isTool)
                ToolCard(part: p)
              else if (p.type == 'text' && (p.text ?? '').isNotEmpty)
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
