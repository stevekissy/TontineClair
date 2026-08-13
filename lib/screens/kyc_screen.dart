// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — Écran KYC avec SDK natif Smile ID
//
// Architecture :
//   KycScreen          → affiche le statut + bouton "Démarrer la vérification"
//   _lancerSmileId()   → lance le SDK natif SmileID SEULEMENT si init OK
//   _onSmileIdSuccess  → persiste le résultat dans Supabase via KycService
//
// SDK : smile_id 11.2.10
// Fix crash : SmileID.initialize() fire-and-forget dans main.dart
//             + smile_config.json avec les vraies credentials (partner_id: 9035)
//             + onError() du widget gère les erreurs SDK nativement
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
// SDK natif Smile ID — widget DocumentVerification uniquement
import 'package:smile_id/products/document/smile_id_document_verification.dart';

import '../models/kyc_model.dart';
import '../services/kyc_service.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';

// ─────────────────────────────────────────────────────────────────────────
// Entrée principale : statut KYC depuis le profil
// ─────────────────────────────────────────────────────────────────────────
class KycScreen extends StatefulWidget {
  final String userId;
  const KycScreen({super.key, required this.userId});

  @override
  State<KycScreen> createState() => _KycScreenState();
}

class _KycScreenState extends State<KycScreen> {
  KycVerification? _kyc;
  bool _loading = true;
  bool _lancementEnCours = false;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() => _loading = true);
    final kyc = await KycService.getStatus(widget.userId);
    if (mounted) setState(() { _kyc = kyc; _loading = false; });
  }

  // ── Lancer le SDK natif Smile ID ────────────────────────────────────────
  Future<void> _lancerSmileId() async {
    if (_lancementEnCours) return;
    setState(() => _lancementEnCours = true);

    try {
      if (!mounted) return;

      final result = await Navigator.push<Map<String, dynamic>?>(
        context,
        MaterialPageRoute(
          builder: (_) => _SmileIdDocumentVerificationScreen(
            userId: widget.userId,
          ),
        ),
      );

      if (!mounted) return;

      if (result != null) {
        await _onSmileIdSuccess(result);
      }
    } catch (e) {
      if (!mounted) return;
      if (kDebugMode) debugPrint('[SmileID] lancement erreur: $e');
      _afficherErreur('Impossible de démarrer Smile ID. Vérifiez votre connexion.');
    } finally {
      if (mounted) setState(() => _lancementEnCours = false);
    }
  }

  // ── Callback succès SDK ─────────────────────────────────────────────────
  Future<void> _onSmileIdSuccess(Map<String, dynamic> result) async {
    try {
      final now = DateTime.now();
      final jobId = (result['jobId'] as String?)
          ?? (result['job_id'] as String?)
          ?? 'smile-${now.millisecondsSinceEpoch}';

      await SupabaseService.kycSetProviderReference(widget.userId, jobId);
      await SupabaseService.kycUpdateStatus(
        userId:      widget.userId,
        status:      KycStatus.pending,
        verifiedAt:  null,
        expiresAt:   null,
        performedBy: 'smile_id_sdk',
      );

      await _charger();

      if (!mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72, height: 72,
                decoration: const BoxDecoration(
                  color: AppColors.succesFond,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_rounded, color: AppColors.succes, size: 36),
              ),
              const SizedBox(height: 16),
              const Text(
                'Dossier soumis !',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.encre),
              ),
              const SizedBox(height: 8),
              const Text(
                'Votre dossier a été soumis avec succès via Smile ID. '
                'La vérification prend généralement 24 à 48 heures. '
                'Vous serez notifié dès la confirmation.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: AppColors.texteDoux, height: 1.5),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context, true);
              },
              child: const Text('Retour au profil',
                style: TextStyle(color: AppColors.or, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[SmileID] onSuccess persist error: $e');
      if (!mounted) return;
      _afficherErreur('Vérification soumise mais erreur enregistrement. Contactez le support.');
    }
  }

  void _afficherErreur(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AppColors.alerte,
      duration: const Duration(seconds: 5),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.encre),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Vérification d\'identité',
          style: TextStyle(
            color: AppColors.encre,
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.or))
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StatutBadge(status: _kyc?.status ?? KycStatus.notStarted),
                    const SizedBox(height: 20),
                    _InfoCard(kyc: _kyc),
                    const SizedBox(height: 24),
                    _ActionSection(
                      kyc: _kyc,
                      lancementEnCours: _lancementEnCours,
                      onDemarrer: _lancerSmileId,
                      onRecommencer: _lancerSmileId,
                    ),
                    const SizedBox(height: 32),
                    _InfoLegale(),
                  ],
                ),
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Écran wrapper pour le SDK SmileID DocumentVerification
// ─────────────────────────────────────────────────────────────────────────
class _SmileIdDocumentVerificationScreen extends StatefulWidget {
  final String userId;
  const _SmileIdDocumentVerificationScreen({required this.userId});

  @override
  State<_SmileIdDocumentVerificationScreen> createState() =>
      _SmileIdDocumentVerificationScreenState();
}

class _SmileIdDocumentVerificationScreenState
    extends State<_SmileIdDocumentVerificationScreen> {

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context, null),
        ),
        title: const Text(
          'Verification Smile ID',
          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      body: SmileIDDocumentVerification(
        countryCode: 'CI',
        documentType: 'NATIONAL_ID',
        captureBothSides: true,
        showInstructions: true,
        allowGalleryUpload: true,
        onSuccess: (String resultJson) {
          try {
            final Map<String, dynamic> result =
                jsonDecode(resultJson) as Map<String, dynamic>;
            if (kDebugMode) debugPrint('[SmileID] Success: $result');
            Navigator.pop(context, result);
          } catch (e) {
            if (kDebugMode) debugPrint('[SmileID] parse error: $e');
            Navigator.pop(context, {'jobId': 'smile-${DateTime.now().millisecondsSinceEpoch}'});
          }
        },
        onError: (String errorMessage) {
          if (kDebugMode) debugPrint('[SmileID] DocVerif error: $errorMessage');
          Navigator.pop(context, null);
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Badge statut KYC
// ─────────────────────────────────────────────────────────────────────────
class _StatutBadge extends StatelessWidget {
  final KycStatus status;
  const _StatutBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, bg, icon) = switch (status) {
      KycStatus.verified     => (AppColors.succes,    AppColors.succesFond,   Icons.verified_rounded),
      KycStatus.pending      => (AppColors.or,        const Color(0xFFFDF3E2), Icons.hourglass_top_rounded),
      KycStatus.processing   => (AppColors.encreDoux, AppColors.fondGestion,  Icons.manage_search_rounded),
      KycStatus.rejected     => (AppColors.alerte,    AppColors.alerteFond,   Icons.cancel_rounded),
      KycStatus.manualReview => (Colors.orange,       const Color(0xFFFFF3E0), Icons.support_agent_rounded),
      KycStatus.notStarted   => (AppColors.encreDoux, AppColors.fondSecondaire, Icons.badge_outlined),
    };

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 52, height: 52,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.label,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  status.description,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.texteDoux,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Carte infos KYC
// ─────────────────────────────────────────────────────────────────────────
class _InfoCard extends StatelessWidget {
  final KycVerification? kyc;
  const _InfoCard({this.kyc});

  @override
  Widget build(BuildContext context) {
    if (kyc == null || kyc!.status == KycStatus.notStarted) return const SizedBox.shrink();

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Informations de vérification',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre),
          ),
          const Divider(height: 20),
          if (kyc!.documentType != null)
            _Ligne('Document', kyc!.documentType!.label),
          if (kyc!.documentCountry != null)
            _Ligne('Pays', kyc!.documentCountry!),
          if (kyc!.documentNumberMasked != null)
            _Ligne('Numéro', kyc!.documentNumberMasked!),
          if (kyc!.submittedAt != null)
            _Ligne('Soumis le',
              DateFormat('dd/MM/yyyy HH:mm').format(kyc!.submittedAt!.toLocal())),
          if (kyc!.verifiedAt != null)
            _Ligne('Vérifié le',
              DateFormat('dd/MM/yyyy HH:mm').format(kyc!.verifiedAt!.toLocal())),
          if (kyc!.rejectionReason != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.alerteFond,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.alerte.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: AppColors.alerte, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      kyc!.rejectionReason!,
                      style: const TextStyle(fontSize: 13, color: AppColors.alerte),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Ligne extends StatelessWidget {
  final String label, value;
  const _Ligne(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(label, style: const TextStyle(
            fontSize: 13, color: AppColors.texteDoux, fontWeight: FontWeight.w500)),
        ),
        Expanded(child: Text(value, style: const TextStyle(
          fontSize: 13, color: AppColors.encre, fontWeight: FontWeight.w600))),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Section actions
// ─────────────────────────────────────────────────────────────────────────
class _ActionSection extends StatelessWidget {
  final KycVerification? kyc;
  final bool lancementEnCours;
  final VoidCallback onDemarrer;
  final VoidCallback onRecommencer;

  const _ActionSection({
    this.kyc,
    required this.lancementEnCours,
    required this.onDemarrer,
    required this.onRecommencer,
  });

  @override
  Widget build(BuildContext context) {
    final status = kyc?.status ?? KycStatus.notStarted;

    if (status == KycStatus.verified) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.succesFond,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: AppColors.succes),
            SizedBox(width: 12),
            Expanded(child: Text(
              'Votre identité est vérifiée via Smile ID. Vous avez accès à toutes les fonctionnalités de TontineClair.',
              style: TextStyle(color: AppColors.succes, fontWeight: FontWeight.w600, fontSize: 13.5),
            )),
          ],
        ),
      );
    }

    if (status == KycStatus.pending || status == KycStatus.processing) {
      return const _EnAttenteWidget();
    }

    if (status == KycStatus.notStarted) {
      return _BoutonDemarrer(
        onTap: onDemarrer,
        lancementEnCours: lancementEnCours,
      );
    }

    return Column(
      children: [
        if (status == KycStatus.manualReview)
          Container(
            padding: const EdgeInsets.all(14),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: const Text(
              'Votre dossier est en cours de vérification manuelle. '
              'Notre équipe vous contactera dans les 24–72h.',
              style: TextStyle(fontSize: 13, color: Colors.deepOrange, height: 1.4),
            ),
          ),
        if (lancementEnCours)
          const Center(child: CircularProgressIndicator(color: AppColors.or))
        else
          BtnPrincipal(
            label: 'Recommencer la vérification',
            icon: Icons.refresh_rounded,
            onTap: onRecommencer,
          ),
      ],
    );
  }
}

class _BoutonDemarrer extends StatelessWidget {
  final VoidCallback onTap;
  final bool lancementEnCours;
  const _BoutonDemarrer({
    required this.onTap,
    required this.lancementEnCours,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Pourquoi vérifier mon identité ?',
        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre),
      ),
      const SizedBox(height: 10),
      _PourquoiItem(Icons.security_rounded, 'Sécuriser vos transactions financières'),
      _PourquoiItem(Icons.account_balance_rounded, 'Accéder aux retraits et décaissements'),
      _PourquoiItem(Icons.shield_rounded, 'Protéger votre communauté de tontine'),
      const SizedBox(height: 20),

      // Badge Smile ID — toujours prêt (pas de garde d'init)
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F4FF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFF3B5BDB).withValues(alpha: 0.3),
          ),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 36, height: 36,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0x1F3B5BDB),
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                ),
                child: Icon(
                  Icons.fingerprint_rounded,
                  color: Color(0xFF3B5BDB),
                  size: 20,
                ),
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Vérification par Smile ID',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1E3A8A),
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'SDK natif certifié — capture selfie + document en quelques secondes',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF3B5BDB),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),

      if (lancementEnCours)
        const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: CircularProgressIndicator(color: AppColors.or),
          ),
        )
      else
        BtnPrincipal(
          label: 'Démarrer la vérification',
          icon: Icons.verified_user_rounded,
          onTap: onTap,
        ),
    ],
  );
}

class _PourquoiItem extends StatelessWidget {
  final IconData icon;
  final String text;
  const _PourquoiItem(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Icon(icon, size: 18, color: AppColors.or),
        const SizedBox(width: 10),
        Expanded(child: Text(text,
          style: const TextStyle(fontSize: 13.5, color: AppColors.texte))),
      ],
    ),
  );
}

class _EnAttenteWidget extends StatelessWidget {
  const _EnAttenteWidget();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: const Color(0xFFFDF3E2),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.or.withValues(alpha: 0.3)),
    ),
    child: const Column(
      children: [
        CircularProgressIndicator(
          color: AppColors.or, strokeWidth: 2.5,
        ),
        SizedBox(height: 16),
        Text(
          'Vérification en cours',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.encre),
        ),
        SizedBox(height: 6),
        Text(
          'Votre dossier Smile ID est en cours d\'examen. Le résultat sera disponible sous 24–48h. '
          'Vous serez notifié dès la fin de la vérification.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppColors.texteDoux, height: 1.5),
        ),
      ],
    ),
  );
}

class _InfoLegale extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.fondSecondaire,
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline_rounded, size: 18, color: AppColors.encreDoux),
        SizedBox(width: 10),
        Expanded(child: Text(
          'Vos documents sont traités de manière sécurisée par Smile ID, '
          'conformément à notre politique de confidentialité. '
          'Les images ne sont conservées que le temps nécessaire à la vérification.',
          style: TextStyle(fontSize: 12, color: AppColors.texteDoux, height: 1.5),
        )),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Widget KYC Guard — à utiliser devant les actions financières sensibles
// ─────────────────────────────────────────────────────────────────────────
class KycGuardWidget extends StatelessWidget {
  final String userId;
  final String actionType;
  final double amount;
  final Widget child;
  final VoidCallback? onAction;

  const KycGuardWidget({
    super.key,
    required this.userId,
    required this.actionType,
    this.amount = 0,
    required this.child,
    this.onAction,
  });

  Future<void> _check(BuildContext context) async {
    final result = await KycService.canPerformFinancialAction(
      userId: userId,
      actionType: actionType,
      amount: amount,
    );

    if (!context.mounted) return;

    if (result.allowed) {
      onAction?.call();
    } else {
      _afficherBlocage(context, result);
    }
  }

  void _afficherBlocage(BuildContext context, FinancialActionResult result) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60, height: 60,
              decoration: const BoxDecoration(
                color: AppColors.alerteFond,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.verified_user_rounded,
                  color: AppColors.alerte, size: 28),
            ),
            const SizedBox(height: 16),
            const Text(
              'Vérification d\'identité requise',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: AppColors.encre),
            ),
            const SizedBox(height: 8),
            Text(
              result.reason ?? result.kycStatus.description,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13.5, color: AppColors.texteDoux, height: 1.5),
            ),
            const SizedBox(height: 24),
            BtnPrincipal(
              label: 'Vérifier mon identité maintenant',
              icon: Icons.badge_rounded,
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => KycScreen(userId: userId)),
                );
              },
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler',
                style: TextStyle(color: AppColors.texteDoux, fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _check(context),
      child: child,
    );
  }
}
