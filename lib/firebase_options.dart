// File generated manually from google-services.json
// Project: tontineclair
// Package: com.tontineclair.app

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      // Web n'est pas configuré — lever une erreur claire
      throw UnsupportedError(
        'DefaultFirebaseOptions have not been configured for web. '
        'You can reconfigure this by running the FlutterFire CLI again.',
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for ios. '
          'You can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.macOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for macos. '
          'You can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.windows:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for windows. '
          'You can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux. '
          'You can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  // Valeurs extraites de android/app/google-services.json
  // project_number: 1095188462472
  // project_id: tontineclair
  // mobilesdk_app_id: 1:1095188462472:android:6be86e829730f77977d83d
  // api_key: AIzaSyDTDJv-sdY07yD4rlSfDvdRIYzEWUvlggo
  // storage_bucket: tontineclair.firebasestorage.app
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDTDJv-sdY07yD4rlSfDvdRIYzEWUvlggo',
    appId: '1:1095188462472:android:6be86e829730f77977d83d',
    messagingSenderId: '1095188462472',
    projectId: 'tontineclair',
    storageBucket: 'tontineclair.firebasestorage.app',
  );
}
