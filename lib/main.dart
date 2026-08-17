import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:smile_id/smile_id.dart';
import 'package:smile_id/generated/smileid_messages.g.dart';
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

  // Initialiser Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Initialiser les notifications push — non-bloquant : une erreur ici ne doit
  // jamais empêcher runApp() de démarrer. L'app sera fonctionnelle sans notifs.
  try {
    await NotificationService.initialiser();
  } catch (e, st) {
    if (kDebugMode) {
      debugPrint('[main] ⚠️ NotificationService.initialiser() failed: $e');
      debugPrintStack(stackTrace: st);
    }
    // Continue — runApp() sera appelé normalement ci-dessous.
  }

  // ── SMILE ID — initializeWithConfig (credentials injectés en Dart) ────────
  //
  // POURQUOI initializeWithConfig et NON initialize() :
  //   SmileID.initialize() (sans config) appelle SmileID.getConfig(from:) côté
  //   natif Swift pour lire smile_config.json depuis le bundle iOS. Cette méthode
  //   contient un force-unwrap non protégé qui lève "Swift runtime failure:
  //   Unexpectedly found nil while unwrapping an Optional value" si le fichier
  //   est absent, mal formé, ou si le bundle n'est pas encore prêt.
  //   Ce crash est natif (SmileIDSDK.xcframework) et IMPOSSIBLE à intercepter
  //   depuis Dart — il tue le processus avant que le moteur Dart ne reprenne.
  //
  //   initializeWithConfig(config:) contourne getConfig(from:) en passant les
  //   credentials directement via Pigeon (channel Flutter↔natif) : le SDK n'a
  //   plus besoin de lire le fichier JSON au démarrage.
  //   smile_config.json est conservé dans le target Runner comme ressource de
  //   secours pour la compatibilité Android et les outils CLI SmileID, mais
  //   l'app iOS ne dépend plus de son parsing natif pour démarrer.
  //
  // UNE SEULE INITIALISATION : ici dans main(). Les appels SmileID.initialize()
  // redondants dans KycScreen ont été supprimés.
  //
  // CREDENTIALS (source : smile_config.json + kyc_screen.dart) :
  //   partner_id  : 9035
  //   prodBaseUrl : https://api.smileidentity.com/v1/
  //   sandboxUrl  : https://testapi.smileidentity.com/v1/
  //   useSandbox  : false (production)
  try {
    const smilePartnerId   = '9035';
    const smileAuthToken   =
        'VpG6p3R7shpe6cgLd6Lx8kZapVLIjiLtCGLPvpiO41+'
        '17ooS62Wdx1RJFaSzkIlCZGxR4vp4spqoq5TB0PjhUO0snjxw'
        'ErmxRhAiYhyTT+rlYcJ99QvxqQqYKQ44nQCNKTFl6jLledHoo'
        'V5UA1eJ6Jn66DJKUcLJ8dCGmNKx4lw=';
    const smileProdUrl     = 'https://api.smileidentity.com/v1/';
    const smileSandboxUrl  = 'https://testapi.smileidentity.com/v1/';

    final smileConfig = FlutterConfig(
      partnerId:      smilePartnerId,
      authToken:      smileAuthToken,
      prodBaseUrl:    smileProdUrl,
      sandboxBaseUrl: smileSandboxUrl,
    );

    await SmileID.initializeWithConfig(
      config:               smileConfig,
      useSandbox:           false,
      enableCrashReporting: false,
    );

    if (kDebugMode) debugPrint('[SmileID] ✅ initializeWithConfig OK (partner=$smilePartnerId)');
  } catch (e, st) {
    // Non-bloquant : KYC sera indisponible mais l'app démarre normalement.
    if (kDebugMode) {
      debugPrint('[SmileID] ⚠️ initializeWithConfig error: $e');
      debugPrintStack(stackTrace: st);
    }
  }
  // ── FIN INITIALISATION SMILE ID ───────────────────────────────────────────

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
