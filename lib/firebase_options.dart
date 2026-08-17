// Généré depuis android/app/google-services.json + config iOS Firebase
// project_id : tontineclair | project_number : 1095188462472
//
// ⚠️  iOS GOOGLE_APP_ID : remplacer la valeur ci-dessous après avoir créé
//     l'app iOS dans Firebase Console → Project settings → Add app → iOS
//     Bundle ID : com.tontineclair.app
//     Puis récupérer GOOGLE_APP_ID depuis GoogleService-Info.plist téléchargé.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      // Web non configuré — Firebase Web nécessite une config séparée
      throw UnsupportedError(
        'Firebase Web non configuré. Ajouter une app Web dans Firebase Console.',
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return ios; // macOS utilise la même config que iOS
      default:
        throw UnsupportedError(
          'Plateforme ${defaultTargetPlatform.name} non supportée par Firebase.',
        );
    }
  }

  // ── Android ───────────────────────────────────────────────────────────────
  static const FirebaseOptions android = FirebaseOptions(
    apiKey:            'AIzaSyDTDJv-sdY07yD4rlSfDvdRIYzEWUvlggo',
    appId:             '1:1095188462472:android:6be86e829730f77977d83d',
    messagingSenderId: '1095188462472',
    projectId:         'tontineclair',
    storageBucket:     'tontineclair.firebasestorage.app',
  );

  // ── iOS ───────────────────────────────────────────────────────────────────
  // App iOS enregistrée dans Firebase Console — clés officielles.
  // GOOGLE_APP_ID : 1:1095188462472:ios:0bdc2a4d895ba93b77d83d
  // API_KEY iOS (distincte de la clé Android) : AIzaSyDkLrJhHQo_trXGxOECLqJ5e7mzY5anAzw
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey:            'AIzaSyDkLrJhHQo_trXGxOECLqJ5e7mzY5anAzw',
    appId:             '1:1095188462472:ios:0bdc2a4d895ba93b77d83d',
    messagingSenderId: '1095188462472',
    projectId:         'tontineclair',
    storageBucket:     'tontineclair.firebasestorage.app',
  );
}
