import 'package:flutter_test/flutter_test.dart';
import 'package:tontine/main.dart';

void main() {
  testWidgets('TontineClair app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const TontineClaireApp());
    expect(find.byType(AppShell), findsOneWidget);
  });
}
