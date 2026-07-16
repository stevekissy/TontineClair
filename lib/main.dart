import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'services/storage_service.dart';
import 'services/locale_service.dart';
import 'utils/app_theme.dart';
import 'utils/app_localizations.dart';
import 'screens/admin_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initializeDateFormatting('fr_FR', null);
  await StorageService.loadSupabaseConfig();

  final localeService = LocaleService();
  await localeService.initialiser();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(TontineAdminApp(localeService: localeService));
}

class TontineAdminApp extends StatelessWidget {
  final LocaleService localeService;
  const TontineAdminApp({super.key, required this.localeService});

  @override
  Widget build(BuildContext context) {
    return AppLocalizationsWrapper(
      localeService: localeService,
      child: MaterialApp(
        title: 'TontineClair Admin',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.theme,
        home: const AdminScreen(),
      ),
    );
  }
}
