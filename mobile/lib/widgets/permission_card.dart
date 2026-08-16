import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/protocol.dart';

/// 权限/补充信息悬浮面板：键盘上方展示，可滚动，支持文本输入
class PermissionCard extends StatefulWidget {
  final PermissionAsk permission;
  final double keyboardInset;
  final void Function(String response) onRespond;

  const PermissionCard({
    super.key,
    required this.permission,
    required this.keyboardInset,
    required this.onRespond,
  });

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  final _answer = TextEditingController();

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  /// 判断是否为"补充信息"类型（question 工具 / 有 userText 的请求）
  bool get _isQuestion =>
      widget.permission.tool == 'question' ||
      (widget.permission.userText?.isNotEmpty ?? false);

  String get _inputText {
    final input = widget.permission.input;
    if (input == null) return '';
    if (input is String) return input;
    return const JsonEncoder.withIndent('  ').convert(input);
  }

  @override
  Widget build(BuildContext context) {
    final input = _inputText;
    return Positioned.fill(
      child: GestureDetector(
        onTap: () {},
        child: Container(
          color: Colors.black38,
          alignment: Alignment.center,
          child: Padding(
            // 键盘避让：面板整体在输入法上方
            padding: EdgeInsets.only(
                bottom: widget.keyboardInset, top: 48, left: 16, right: 16),
            child: Container(
              width: double.infinity,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.55,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black26, blurRadius: 20, offset: Offset(0, 6)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
                    child: Row(
                      children: [
                        Text(_isQuestion ? '📝 需要补充信息' : '⚠️ 需要你的授权',
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1F2328))),
                        const Spacer(),
                        IconButton(
                          onPressed: () => widget.onRespond('reject'),
                          icon: const Icon(Icons.close,
                              color: Color(0xFF57606A)),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.permission.userText?.isNotEmpty ?? false)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(widget.permission.userText!,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      height: 1.5,
                                      color: Color(0xFF1F2328))),
                            ),
                          if (widget.permission.tool != 'question')
                            Text(widget.permission.tool,
                                style: const TextStyle(
                                    fontSize: 13, color: Color(0xFF57606A))),
                          if (input.isNotEmpty)
                            Container(
                              margin: const EdgeInsets.only(top: 8),
                              padding: const EdgeInsets.all(10),
                              constraints: const BoxConstraints(maxHeight: 200),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF6F8FA),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: SingleChildScrollView(
                                child: Text(input,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontFamily: 'monospace',
                                        color: Color(0xFF24292F))),
                              ),
                            ),
                          if (_isQuestion) ...[
                            const SizedBox(height: 12),
                            TextField(
                              controller: _answer,
                              autofocus: true,
                              minLines: 1,
                              maxLines: 4,
                              decoration: const InputDecoration(
                                hintText: '输入补充信息…',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: _isQuestion
                        ? Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF1F6FEB),
                                    foregroundColor: Colors.white,
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 13),
                                  ),
                                  onPressed: () => widget
                                      .onRespond(_answer.text.trim()),
                                  child: const Text('提交',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w700)),
                                ),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton(
                                onPressed: () => widget.onRespond('reject'),
                                child: const Text('取消'),
                              ),
                            ],
                          )
                        : Column(
                            children: [
                              _Btn('总是允许', const Color(0xFF2DA44E),
                                  () => widget.onRespond('always')),
                              const SizedBox(height: 8),
                              _Btn('允许一次', const Color(0xFF1F6FEB),
                                  () => widget.onRespond('once')),
                              const SizedBox(height: 8),
                              _Btn('拒绝', const Color(0xFFCF222E),
                                  () => widget.onRespond('reject')),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
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
