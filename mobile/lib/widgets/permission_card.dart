import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/protocol.dart';

class PermissionCard extends StatelessWidget {
  final PermissionAsk permission;
  final void Function(String response) onRespond;

  const PermissionCard(
      {super.key, required this.permission, required this.onRespond});

  @override
  Widget build(BuildContext context) {
    String inputText = '';
    if (permission.input != null) {
      inputText = permission.input is String
          ? permission.input as String
          : const JsonEncoder.withIndent('  ').convert(permission.input);
      if (inputText.length > 900) inputText = '${inputText.substring(0, 900)}…';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        boxShadow: [
          BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, -2)),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('⚠️ 需要你的授权',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(permission.tool,
                style: const TextStyle(fontSize: 13, color: Color(0xFF57606A))),
            if (inputText.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(10),
                constraints: const BoxConstraints(maxHeight: 220),
                decoration: BoxDecoration(
                  color: const Color(0xFFF6F8FA),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SingleChildScrollView(
                  child: Text(inputText,
                      style: const TextStyle(
                          fontSize: 12, fontFamily: 'monospace', color: Color(0xFF24292F))),
                ),
              ),
            const SizedBox(height: 12),
            _Btn('总是允许', const Color(0xFF2DA44E), () => onRespond('always')),
            const SizedBox(height: 8),
            _Btn('允许一次', const Color(0xFF1F6FEB), () => onRespond('once')),
            const SizedBox(height: 8),
            _Btn('拒绝', const Color(0xFFCF222E), () => onRespond('reject')),
          ],
        ),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _Btn(this.label, this.color, this.onTap);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 13),
        ),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }
}
