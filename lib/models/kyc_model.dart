// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — Modèle KYC
// ═══════════════════════════════════════════════════════════════════════════

enum KycStatus {
  notStarted,
  pending,
  processing,
  verified,
  rejected,
  manualReview;

  /// Depuis la valeur base de données
  static KycStatus fromString(String? s) {
    switch (s) {
      case 'not_started':    return KycStatus.notStarted;
      case 'pending':        return KycStatus.pending;
      case 'processing':     return KycStatus.processing;
      case 'verified':       return KycStatus.verified;
      case 'rejected':       return KycStatus.rejected;
      case 'manual_review':  return KycStatus.manualReview;
      default:               return KycStatus.notStarted;
    }
  }

  String toDbString() {
    switch (this) {
      case KycStatus.notStarted:   return 'not_started';
      case KycStatus.pending:      return 'pending';
      case KycStatus.processing:   return 'processing';
      case KycStatus.verified:     return 'verified';
      case KycStatus.rejected:     return 'rejected';
      case KycStatus.manualReview: return 'manual_review';
    }
  }

  String get label {
    switch (this) {
      case KycStatus.notStarted:   return 'Non vérifié';
      case KycStatus.pending:      return 'En attente';
      case KycStatus.processing:   return 'En cours d\'analyse';
      case KycStatus.verified:     return 'Vérifié ✓';
      case KycStatus.rejected:     return 'Refusé';
      case KycStatus.manualReview: return 'Vérification manuelle requise';
    }
  }

  String get description {
    switch (this) {
      case KycStatus.notStarted:
        return 'Votre identité n\'a pas encore été vérifiée.';
      case KycStatus.pending:
        return 'Votre dossier a été soumis et sera examiné sous 24–48h.';
      case KycStatus.processing:
        return 'Votre dossier est en cours d\'analyse par notre équipe.';
      case KycStatus.verified:
        return 'Votre identité est vérifiée. Vous avez accès à toutes les fonctionnalités.';
      case KycStatus.rejected:
        return 'Votre vérification a été refusée. Veuillez corriger les informations et recommencer.';
      case KycStatus.manualReview:
        return 'Votre dossier nécessite une vérification manuelle. Contactez le support.';
    }
  }

  bool get isBlocking =>
      this == KycStatus.notStarted ||
      this == KycStatus.rejected;

  bool get isVerified => this == KycStatus.verified;
}

// ─────────────────────────────────────────────────────────────────────────
enum KycDocumentType {
  nationalId,
  passport,
  driversLicense,
  residencePermit,
  voterId;

  static KycDocumentType fromString(String? s) {
    switch (s) {
      case 'national_id':       return KycDocumentType.nationalId;
      case 'passport':          return KycDocumentType.passport;
      case 'drivers_license':   return KycDocumentType.driversLicense;
      case 'residence_permit':  return KycDocumentType.residencePermit;
      case 'voter_id':          return KycDocumentType.voterId;
      default:                  return KycDocumentType.nationalId;
    }
  }

  String toDbString() {
    switch (this) {
      case KycDocumentType.nationalId:      return 'national_id';
      case KycDocumentType.passport:        return 'passport';
      case KycDocumentType.driversLicense:  return 'drivers_license';
      case KycDocumentType.residencePermit: return 'residence_permit';
      case KycDocumentType.voterId:         return 'voter_id';
    }
  }

  String get label {
    switch (this) {
      case KycDocumentType.nationalId:      return 'Carte Nationale d\'Identité';
      case KycDocumentType.passport:        return 'Passeport';
      case KycDocumentType.driversLicense:  return 'Permis de conduire';
      case KycDocumentType.residencePermit: return 'Titre de séjour';
      case KycDocumentType.voterId:         return 'Carte d\'électeur';
    }
  }

  bool get requiresBack {
    // Ces documents ont un verso
    return this == KycDocumentType.nationalId ||
           this == KycDocumentType.driversLicense ||
           this == KycDocumentType.voterId;
  }
}

// ─────────────────────────────────────────────────────────────────────────
class KycVerification {
  final String?           id;
  final String            userId;
  final String            provider;
  final String?           providerReference;
  final KycStatus         status;
  final KycDocumentType?  documentType;
  final String?           documentCountry;
  final String?           documentNumberMasked;
  final String?           rejectionReason;
  final DateTime?         submittedAt;
  final DateTime?         verifiedAt;
  final DateTime?         expiresAt;
  final DateTime?         updatedAt;

  const KycVerification({
    this.id,
    required this.userId,
    this.provider = 'mock',
    this.providerReference,
    this.status = KycStatus.notStarted,
    this.documentType,
    this.documentCountry,
    this.documentNumberMasked,
    this.rejectionReason,
    this.submittedAt,
    this.verifiedAt,
    this.expiresAt,
    this.updatedAt,
  });

  factory KycVerification.empty(String userId) => KycVerification(
    userId: userId,
    status: KycStatus.notStarted,
  );

  factory KycVerification.fromMap(Map<String, dynamic> m) => KycVerification(
    id:                   m['id'] as String?,
    userId:               m['user_id'] as String? ?? '',
    provider:             m['provider'] as String? ?? 'mock',
    providerReference:    m['provider_reference'] as String?,
    status:               KycStatus.fromString(m['status'] as String?),
    documentType:         m['document_type'] != null
                            ? KycDocumentType.fromString(m['document_type'] as String)
                            : null,
    documentCountry:      m['document_country'] as String?,
    documentNumberMasked: m['document_number_masked'] as String?,
    rejectionReason:      m['rejection_reason'] as String?,
    submittedAt:          m['submitted_at'] != null
                            ? DateTime.tryParse(m['submitted_at'] as String)
                            : null,
    verifiedAt:           m['verified_at'] != null
                            ? DateTime.tryParse(m['verified_at'] as String)
                            : null,
    expiresAt:            m['expires_at'] != null
                            ? DateTime.tryParse(m['expires_at'] as String)
                            : null,
    updatedAt:            m['updated_at'] != null
                            ? DateTime.tryParse(m['updated_at'] as String)
                            : null,
  );
}

// ─────────────────────────────────────────────────────────────────────────
/// Données saisies par l'utilisateur pendant le parcours KYC
class KycSubmissionData {
  final String            fullName;
  final DateTime          dateOfBirth;
  final String            country;          // code ISO ex: 'CI'
  final KycDocumentType   documentType;
  final String            documentNumber;
  final String            docFrontPath;     // chemin local fichier
  final String?           docBackPath;      // null si pas de verso
  final String            selfiePath;       // chemin local fichier
  final bool              consentGiven;

  const KycSubmissionData({
    required this.fullName,
    required this.dateOfBirth,
    required this.country,
    required this.documentType,
    required this.documentNumber,
    required this.docFrontPath,
    this.docBackPath,
    required this.selfiePath,
    required this.consentGiven,
  });

  /// Numéro masqué pour affichage sécurisé
  String get documentNumberMasked {
    if (documentNumber.length <= 4) return '****';
    return '${'*' * (documentNumber.length - 4)}${documentNumber.substring(documentNumber.length - 4)}';
  }
}

// ─────────────────────────────────────────────────────────────────────────
/// Résultat d'une vérification KYC
class KycResult {
  final bool    success;
  final String  message;
  final KycStatus? newStatus;

  const KycResult({
    required this.success,
    required this.message,
    this.newStatus,
  });

  factory KycResult.error(String msg) =>
      KycResult(success: false, message: msg);

  factory KycResult.ok(String msg, KycStatus status) =>
      KycResult(success: true, message: msg, newStatus: status);
}

// ─────────────────────────────────────────────────────────────────────────
/// Résultat de canPerformFinancialAction
class FinancialActionResult {
  final bool    allowed;
  final String? reason;
  final KycStatus kycStatus;

  const FinancialActionResult({
    required this.allowed,
    required this.kycStatus,
    this.reason,
  });
}
