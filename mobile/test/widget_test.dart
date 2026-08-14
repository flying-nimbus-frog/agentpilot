import 'package:flutter_test/flutter_test.dart';

import 'package:opencode_remote/main.dart';

void main() {
  testWidgets('登录页冒烟测试', (WidgetTester tester) async {
    await tester.pumpWidget(OpenCodeRemoteApp(saved: null));
    expect(find.text('OpenCode Remote'), findsNothing);
    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
  });
}
