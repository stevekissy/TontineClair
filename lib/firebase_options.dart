// Configuration Firebase — TontineClair
// project_id : tontineclair | project_number : 1095188462472
// Généré depuis google-services.json (Android) et GoogleService-Info.plist (iOS)

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
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
        return ios;
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
  // App iOS : com.tontineclair.app — enregistrée dans Firebase Console.
  // Clés issues de GoogleService-Info.plist officiel (téléchargé le 2025-08-13).
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey:            'AIzaSyDkLrJhHQo_trXGxOECLqJ5e7mzY5anAzw',
    appId:             '1:1095188462472:ios:0bdc2a4d895ba93b77d83d',
    messagingSenderId: '1095188462472',
    projectId:         'tontineclair',
    storageBucket:     'tontineclair.firebasestorage.app',
  );
}
