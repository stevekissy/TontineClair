import Flutter
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// AppDelegate — TontineClair
//
// Firebase est initialisé UNIQUEMENT via Dart (firebase_options.dart) :
//   await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)
//
// NE PAS appeler FirebaseApp.configure() ici — cela provoquerait une double
// initialisation et crasherait l'app si GoogleService-Info.plist est absent
// ou incomplet (GOOGLE_APP_ID placeholder).
//
// Les notifications push (FCM) sont gérées par le plugin firebase_messaging
// via FlutterFire, qui s'enregistre automatiquement après Firebase.initializeApp().
// ─────────────────────────────────────────────────────────────────────────────

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
