import 'package:flutter_test/flutter_test.dart';
import 'package:tontine/main.dart';
import 'package:tontine/services/locale_service.dart';

void main() {
  testWidgets('TontineClair app smoke test', (WidgetTester tester) async {
    // LocaleService ne peut pas être initialisé (SharedPreferences absent en test)
    // — ce test vérifie uniquement que le widget se monte sans crash
    final ls = LocaleService();
    await tester.pumpWidget(TontineClaireApp(localeService: ls));
    expect(find.byType(AppShell), findsOneWidget);
  });
}
