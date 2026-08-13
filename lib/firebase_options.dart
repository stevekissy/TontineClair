// Généré manuellement depuis android/app/google-services.json
// project_id: tontineclair — package: com.tontineclair.app

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Web non configuré.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError('Plateforme non supportée.');
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDTDJv-sdY07yD4rlSfDvdRIYzEWUvlggo',
    appId: '1:1095188462472:android:6be86e829730f77977d83d',
    messagingSenderId: '1095188462472',
    projectId: 'tontineclair',
    storageBucket: 'tontineclair.firebasestorage.app',
  );
}
