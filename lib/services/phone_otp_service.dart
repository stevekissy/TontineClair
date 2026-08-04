// ─────────────────────────────────────────────────────────────────────────────
// PhoneOtpService — vérification numéro de téléphone via Firebase Phone Auth
//
// Utilisé pour le gestionnaire principal (index 0) lors de la création d'une
// tontine ET pour la modification du numéro dans le profil.
//
// Flux :
//  1. envoyerOtp(numero)                        → Firebase envoie SMS 6 chiffres
//  2. verifierOtp(verificationId, smsCode)       → retourne null (succès) ou erreur
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class PhoneOtpService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // ── Étape 1 : Envoyer le SMS OTP ─────────────────────────────────────────
  // Retourne un [PhoneOtpResult] avec soit verificationId (succès),
  // soit un message d'erreur.
  static Future<PhoneOtpResult> envoyerOtp(String numero) async {
    // Completer Dart standard — thread-safe, pas de polling
    final completer = Completer<PhoneOtpResult>();

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: numero,
        timeout: const Duration(seconds: 60),

        // ── Cas 1 : Android auto-résolution (rare)
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
            debugPrint('[OTP] ❌ Échec: ${e.code} — ${e.message}');
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

        // ── Cas 4 : Timeout auto-récupération (65s)
        codeAutoRetrievalTimeout: (String verificationId) {
          if (kDebugMode) {
            debugPrint('[OTP] ⏱ Timeout auto-récupération: $verificationId');
          }
          // Ne compléter que si ni codeSent ni verificationFailed n'a répondu
          if (!completer.isCompleted) {
            completer.complete(PhoneOtpResult.codeSent(
              verificationId: verificationId,
              resendToken: null,
            ));
          }
        },
      );
    } catch (e) {
      if (!completer.isCompleted) {
        completer.complete(PhoneOtpResult.erreur(
          'Erreur inattendue lors de l\'envoi du SMS : $e',
        ));
      }
    }

    // Timeout global de sécurité : 65s (Firebase timeout = 60s)
    return completer.future.timeout(
      const Duration(seconds: 65),
      onTimeout: () => PhoneOtpResult.erreur(
        'Délai dépassé. Vérifiez votre connexion et réessayez.',
      ),
    );
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

      // Vérifier via signInWithCredential puis déconnecter immédiatement
      // (l'app n'utilise pas Firebase Auth comme système de login global)
      final result = await _auth.signInWithCredential(credential)
          .timeout(const Duration(seconds: 30));

      if (kDebugMode) {
        debugPrint('[OTP] ✅ Numéro vérifié: ${result.user?.phoneNumber}');
      }

      // Déconnexion immédiate — on n'utilise pas Firebase Auth comme session
      await _auth.signOut();
      return null; // null = succès

    } on FirebaseAuthException catch (e) {
      if (kDebugMode) debugPrint('[OTP] ❌ Code incorrect: ${e.code}');
      return _messageErreurCode(e);
    } on TimeoutException {
      return 'Délai de vérification dépassé. Réessayez.';
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
      case 'blocked':
        return 'Numéro bloqué temporairement. Réessayez dans 24h.';
      default:
        return e.message ?? 'Erreur lors de l\'envoi du SMS (${e.code}).';
    }
  }

  static String _messageErreurCode(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-verification-code':
        return 'Code incorrect. Vérifiez le SMS et réessayez.';
      case 'invalid-verification-id':
        return 'Session expirée. Appuyez sur "Renvoyer le code".';
      case 'session-expired':
        return 'Code expiré (5 min). Appuyez sur "Renvoyer le code".';
      case 'too-many-requests':
        return 'Trop de tentatives. Attendez quelques minutes.';
      case 'credential-already-in-use':
        return 'Ce numéro est déjà utilisé par un autre compte.';
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
