// ─────────────────────────────────────────────────────────────────────────────
// PhoneOtpService — vérification numéro de téléphone via Firebase Phone Auth
//
// Utilisé uniquement pour le gestionnaire principal (index 0) lors de la
// création d'une tontine. Les gestionnaires secondaires utilisent la double
// saisie (anti-typo, sans SMS).
//
// Flux :
//  1. envoyerOtp(numero)          → Firebase envoie SMS avec code à 6 chiffres
//  2. verifierOtp(verificationId, smsCode) → retourne le numéro confirmé ou erreur
// ─────────────────────────────────────────────────────────────────────────────

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class PhoneOtpService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // ── Étape 1 : Envoyer le SMS OTP ─────────────────────────────────────────
  // Retourne un [PhoneOtpResult] avec soit verificationId (succès envoi),
  // soit un message d'erreur.
  static Future<PhoneOtpResult> envoyerOtp(String numero) async {
    final completer = _OtpCompleter();

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: numero,
        timeout: const Duration(seconds: 60),

        // ── Cas 1 : Android auto-résolution (pas besoin de saisir le code)
        verificationCompleted: (PhoneAuthCredential credential) {
          if (kDebugMode) {
            debugPrint('[OTP] ✅ Auto-résolution Android: ${credential.smsCode}');
          }
          if (!completer.isCompleted) {
            completer.complete(PhoneOtpResult.autoVerified(
              verificationId: credential.verificationId ?? '',
              credential: credential,
            ));
          }
        },

        // ── Cas 2 : Erreur d'envoi (numéro invalide, quota dépassé…)
        verificationFailed: (FirebaseAuthException e) {
          if (kDebugMode) {
            debugPrint('[OTP] ❌ Échec vérification: ${e.code} — ${e.message}');
          }
          if (!completer.isCompleted) {
            completer.complete(PhoneOtpResult.erreur(_messageErreur(e)));
          }
        },

        // ── Cas 3 : SMS envoyé, l'utilisateur doit saisir le code
        codeSent: (String verificationId, int? resendToken) {
          if (kDebugMode) {
            debugPrint('[OTP] 📱 SMS envoyé — verificationId: $verificationId');
          }
          if (!completer.isCompleted) {
            completer.complete(PhoneOtpResult.codeSent(
              verificationId: verificationId,
              resendToken: resendToken,
            ));
          }
        },

        // ── Cas 4 : Timeout (60 secondes dépassées)
        codeAutoRetrievalTimeout: (String verificationId) {
          if (kDebugMode) {
            debugPrint('[OTP] ⏱ Timeout auto-récupération: $verificationId');
          }
          // Ne pas compléter ici si déjà complété par codeSent
        },
      );
    } catch (e) {
      if (!completer.isCompleted) {
        completer.complete(PhoneOtpResult.erreur(
          'Erreur inattendue lors de l\'envoi du SMS : $e',
        ));
      }
    }

    return completer.future;
  }

  // ── Étape 2 : Vérifier le code OTP saisi par l'utilisateur ───────────────
  // Retourne null si succès, ou un message d'erreur si code incorrect.
  static Future<String?> verifierOtp({
    required String verificationId,
    required String smsCode,
  }) async {
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode.trim(),
      );

      // On vérifie la credential sans connexion permanente :
      // on utilise signInWithCredential puis on déconnecte immédiatement
      // (l'app n'utilise pas Firebase Auth comme système de login global)
      final result = await _auth.signInWithCredential(credential);
      if (kDebugMode) {
        debugPrint('[OTP] ✅ Numéro vérifié: ${result.user?.phoneNumber}');
      }

      // Déconnexion immédiate — on n'utilise pas Firebase Auth comme session
      await _auth.signOut();
      return null; // null = succès

    } on FirebaseAuthException catch (e) {
      if (kDebugMode) {
        debugPrint('[OTP] ❌ Code incorrect: ${e.code}');
      }
      return _messageErreurCode(e);
    } catch (e) {
      return 'Erreur de vérification : $e';
    }
  }

  // ── Messages d'erreur en français ────────────────────────────────────────
  static String _messageErreur(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-phone-number':
        return 'Numéro de téléphone invalide. Vérifiez le format (+225XXXXXXXXXX).';
      case 'too-many-requests':
        return 'Trop de tentatives. Réessayez dans quelques minutes.';
      case 'quota-exceeded':
        return 'Quota SMS dépassé. Réessayez plus tard.';
      case 'network-request-failed':
        return 'Pas de connexion internet. Vérifiez votre réseau.';
      case 'missing-phone-number':
        return 'Numéro de téléphone manquant.';
      case 'app-not-authorized':
        return 'Application non autorisée pour cette vérification.';
      default:
        return e.message ?? 'Erreur lors de l\'envoi du SMS (${e.code}).';
    }
  }

  static String _messageErreurCode(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-verification-code':
        return 'Code incorrect. Vérifiez le SMS et réessayez.';
      case 'invalid-verification-id':
        return 'Session expirée. Renvoyez le code SMS.';
      case 'session-expired':
        return 'Code expiré (5 min). Appuyez sur "Renvoyer le code".';
      case 'too-many-requests':
        return 'Trop de tentatives. Attendez quelques minutes.';
      default:
        return e.message ?? 'Code invalide (${e.code}).';
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Modèles de résultat
// ─────────────────────────────────────────────────────────────────────────────

enum PhoneOtpStatus { codeSent, autoVerified, erreur }

class PhoneOtpResult {
  final PhoneOtpStatus status;
  final String? verificationId;
  final int? resendToken;
  final PhoneAuthCredential? credential;
  final String? erreurMessage;

  const PhoneOtpResult._({
    required this.status,
    this.verificationId,
    this.resendToken,
    this.credential,
    this.erreurMessage,
  });

  factory PhoneOtpResult.codeSent({
    required String verificationId,
    int? resendToken,
  }) =>
      PhoneOtpResult._(
        status: PhoneOtpStatus.codeSent,
        verificationId: verificationId,
        resendToken: resendToken,
      );

  factory PhoneOtpResult.autoVerified({
    required String verificationId,
    required PhoneAuthCredential credential,
  }) =>
      PhoneOtpResult._(
        status: PhoneOtpStatus.autoVerified,
        verificationId: verificationId,
        credential: credential,
      );

  factory PhoneOtpResult.erreur(String message) =>
      PhoneOtpResult._(status: PhoneOtpStatus.erreur, erreurMessage: message);

  bool get estSucces =>
      status == PhoneOtpStatus.codeSent ||
      status == PhoneOtpStatus.autoVerified;
}

// ── Completer helper (évite d'appeler complete() deux fois) ──────────────────
class _OtpCompleter {
  bool isCompleted = false;
  final _completerInternal = _SimpleCompleter<PhoneOtpResult>();

  Future<PhoneOtpResult> get future => _completerInternal.future;

  void complete(PhoneOtpResult result) {
    if (isCompleted) return;
    isCompleted = true;
    _completerInternal.complete(result);
  }
}

// Minimal async completer wrapper
class _SimpleCompleter<T> {
  late T _value;
  bool _done = false;

  Future<T> get future async {
    if (_done) return _value;
    // Poll until done (max 65 seconds — Firebase timeout is 60s)
    for (int i = 0; i < 650; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (_done) return _value;
    }
    throw TimeoutException('OTP timeout après 65 secondes');
  }

  void complete(T value) {
    _value = value;
    _done = true;
  }
}

class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);
  @override
  String toString() => message;
}
