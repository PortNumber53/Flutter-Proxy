import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/main.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const ProxyApp());
    expect(find.text('HTTP Proxy'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
  });
}
