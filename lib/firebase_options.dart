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
  // ⚠️  appId : remplacer par la valeur GOOGLE_APP_ID de votre
  //     GoogleService-Info.plist (format : 1:1095188462472:ios:XXXXXXXX)
  //     après avoir créé l'app iOS dans Firebase Console.
  //
  // Les autres clés (apiKey, messagingSenderId, projectId, storageBucket)
  // sont partagées avec le projet Firebase et sont déjà correctes.
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey:            'AIzaSyDTDJv-sdY07yD4rlSfDvdRIYzEWUvlggo',
    appId:             '1:1095188462472:ios:REPLACE_WITH_IOS_APP_ID',
    messagingSenderId: '1095188462472',
    projectId:         'tontineclair',
    storageBucket:     'tontineclair.firebasestorage.app',
    // iosClientId : optionnel, requis uniquement pour Google Sign-In iOS
    // iosClientId: '1095188462472-REPLACE.apps.googleusercontent.com',
  );
}
