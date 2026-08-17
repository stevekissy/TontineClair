import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:smile_id/smile_id.dart';
import 'firebase_options.dart';
import 'services/storage_service.dart';
import 'services/tontine_provider.dart';
import 'services/notification_service.dart';
import 'services/rappel_service.dart';
import 'services/locale_service.dart';
import 'services/subscription_service.dart';
import 'utils/app_theme.dart';
import 'utils/app_colors.dart';
import 'utils/app_localizations.dart';
import 'screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialiser les locales françaises
  await initializeDateFormatting('fr_FR', null);

  // Charger la config Supabase stockée
  await StorageService.loadSupabaseConfig();

  // Initialiser Firebase + notifications push
  // firebase_options.dart garantit l'init correcte en release Android
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await NotificationService.initialiser();

  // Initialiser le SDK natif Smile ID (KYC identité Premium).
  // AWAIT obligatoire : le SDK doit être prêt avant que l'utilisateur
  // puisse appuyer sur le bouton. L'init se fait pendant le splash screen,
  // donc l'utilisateur ne voit aucun délai.
  // En cas d'échec, l'app démarre quand même — onError() du widget gère
  // les erreurs au moment de l'utilisation.
  try {
    await SmileID.initialize(useSandbox: false, enableCrashReporting: false);
    if (kDebugMode) debugPrint('[SmileID] ✅ initialized OK');
  } catch (e, st) {
    // Init a échoué mais on ne bloque pas l'app.
    // onError() dans SmileIDDocumentVerification affichera l'erreur.
    // On catch Object (inclut Error + Exception + PlatformException iOS)
    if (kDebugMode) {
      debugPrint('[SmileID] ⚠️ initialize error: $e');
      debugPrint('[SmileID] ⚠️ stacktrace: $st');
    }
  }

  // Initialiser Google Play Billing / Apple StoreKit
  // (unawaited — ne bloque pas le démarrage, se fait en arrière-plan)
  SubscriptionService.initialiser();

  // Vérifier l'expiration de l'abonnement au démarrage
  SubscriptionService.verifierExpiration();

  // Vérifier les échéances de toutes les tontines au démarrage
  // (unawaited — ne bloque pas le démarrage de l'app)
  RappelService.verifierToutesAuDemarrage();

  // Charger la langue sauvegardée
  final localeService = LocaleService();
  await localeService.initialiser();

  // Style de la barre système
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: AppColors.fondPapier,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(TontineClaireApp(localeService: localeService));
}

class TontineClaireApp extends StatelessWidget {
  final LocaleService localeService;

  const TontineClaireApp({super.key, required this.localeService});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TontineProvider()..initialiser()),
        ChangeNotifierProvider<LocaleService>.value(value: localeService),
      ],
      // AppLocalizationsWrapper écoute LocaleService et rebuilde uniquement
      // les widgets qui utilisent context.tr() — sans toucher MaterialApp.locale
      // ce qui évite tout rechargement des données (tontines, etc.)
      // Directionality RTL activé uniquement pour l'arabe — les autres langues restent LTR.
      child: Consumer<LocaleService>(
        builder: (_, ls, __) => AppLocalizationsWrapper(
          localeService: ls,
          child: Directionality(
            textDirection: ls.langue.code == 'ar'
                ? TextDirection.rtl
                : TextDirection.ltr,
            child: MaterialApp(
              title: 'TontineClair',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.theme,
              home: const AppShell(),
              // CRITIQUE : pas de locale: ici — évite la réinitialisation des tontines
              // Le RTL est géré par Directionality ci-dessus
            ),
          ),
        ),
      ),
    );
  }
}

// Les credentials Supabase sont injectés en dur dans SupabaseService.
// Le ConfigScreen n'est plus affiché au démarrage.
// Accès développeur : appui long sur le logo TontineClair dans AccueilScreen.
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return const SplashScreen();
  }
}
