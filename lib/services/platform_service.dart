// ignore_for_file: avoid_print
import 'package:flutter/foundation.dart';
// ignore: depend_on_referenced_packages
import 'dart:io' show Platform;

/// Source unique de détection de plateforme.
/// Ne jamais éparpiller Platform.isAndroid / kIsWeb dans les pages.
///
/// Utilisation :
///   PlatformService.isWeb     → true sur navigateur
///   PlatformService.isAndroid → true sur Android (pas web)
///   PlatformService.isIOS     → true sur iOS (pas web)
///   PlatformService.current   → PlatformType enum
class PlatformService {
  PlatformService._();

  static bool get isWeb => kIsWeb;

  static bool get isAndroid {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  static bool get isIOS {
    if (kIsWeb) return false;
    try {
      return Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  static bool get isMobile => isAndroid || isIOS;

  static PlatformType get current {
    if (isWeb) return PlatformType.web;
    if (isAndroid) return PlatformType.android;
    if (isIOS) return PlatformType.ios;
    return PlatformType.web; // fallback desktop → web billing
  }

  /// Label lisible pour les logs / debug
  static String get label {
    switch (current) {
      case PlatformType.web:
        return 'web';
      case PlatformType.android:
        return 'android';
      case PlatformType.ios:
        return 'ios';
    }
  }
}

enum PlatformType { web, android, ios }
