// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — Parcours KYC complet (6 étapes)
//
// Étape 1 : Statut actuel + bouton démarrer
// Étape 2 : Informations personnelles
// Étape 3 : Type de document + pays
// Étape 4 : Photo recto (et verso si requis)
// Étape 5 : Selfie avec instruction liveness
// Étape 6 : Confirmation + consentement + envoi
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../models/kyc_model.dart';
import '../services/kyc_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';

// ─────────────────────────────────────────────────────────────────────────
// Entrée principale : statut KYC depuis le profil
// ─────────────────────────────────────────────────────────────────────────
class KycScreen extends StatefulWidget {
  final String userId; // nom du gestionnaire

  const KycScreen({super.key, required this.userId});

  @override
  State<KycScreen> createState() => _KycScreenState();
}

class _KycScreenState extends State<KycScreen> {
  KycVerification? _kyc;
  bool _loading = true;

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

  Future<void> _demarrer() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _KycParcours(userId: widget.userId),
      ),
    );
    if (result == true) _charger();
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
                      onDemarrer: _demarrer,
                      onRecommencer: _demarrer,
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
  final VoidCallback onDemarrer;
  final VoidCallback onRecommencer;

  const _ActionSection({
    this.kyc, required this.onDemarrer, required this.onRecommencer,
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
              'Votre identité est vérifiée. Vous avez accès à toutes les fonctionnalités de TontineClair.',
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
      return _BoutonDemarrer(onTap: onDemarrer);
    }

    // rejected ou manual_review → permettre de recommencer
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
  const _BoutonDemarrer({required this.onTap});

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
    child: Column(
      children: [
        const CircularProgressIndicator(
          color: AppColors.or, strokeWidth: 2.5,
        ),
        const SizedBox(height: 16),
        const Text(
          'Vérification en cours',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.encre),
        ),
        const SizedBox(height: 6),
        const Text(
          'Votre dossier est en cours d\'examen. Le résultat sera disponible sous 24–48h. '
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
          'Vos documents sont traités de manière sécurisée conformément à notre politique de confidentialité. '
          'Les images ne sont conservées que le temps nécessaire à la vérification.',
          style: TextStyle(fontSize: 12, color: AppColors.texteDoux, height: 1.5),
        )),
      ],
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// PARCOURS KYC — Stepper multi-étapes
// ═══════════════════════════════════════════════════════════════════════════
class _KycParcours extends StatefulWidget {
  final String userId;
  const _KycParcours({required this.userId});

  @override
  State<_KycParcours> createState() => _KycParcoursState();
}

class _KycParcoursState extends State<_KycParcours> {
  int _etape = 0;

  // ── Données collectées ──────────────────────────────────────────────────
  final _nomCtrl  = TextEditingController();
  final _numCtrl  = TextEditingController();
  DateTime? _dateNaissance;
  String _pays = 'CI';
  KycDocumentType _docType = KycDocumentType.nationalId;
  XFile? _docFront;
  XFile? _docBack;
  XFile? _selfie;
  bool _consentement = false;

  bool _soumettant = false;
  String? _erreur;

  final List<String> _etapes = [
    'Identité',
    'Document',
    'Recto',
    'Selfie',
    'Confirmation',
  ];

  @override
  void dispose() {
    _nomCtrl.dispose();
    _numCtrl.dispose();
    super.dispose();
  }

  void _suivant() {
    final err = _valider();
    if (err != null) {
      setState(() => _erreur = err);
      return;
    }
    setState(() { _erreur = null; _etape++; });
  }

  void _precedent() {
    if (_etape > 0) setState(() { _etape--; _erreur = null; });
  }

  String? _valider() {
    switch (_etape) {
      case 0:
        if (_nomCtrl.text.trim().isEmpty) return 'Veuillez saisir votre nom complet.';
        if (_dateNaissance == null) return 'Veuillez saisir votre date de naissance.';
        if (DateTime.now().year - _dateNaissance!.year < 18) {
          return 'Vous devez avoir au moins 18 ans pour utiliser TontineClair.';
        }
        return null;
      case 1:
        if (_numCtrl.text.trim().isEmpty) return 'Veuillez saisir le numéro du document.';
        return null;
      case 2:
        if (_docFront == null) return 'Veuillez photographier le recto du document.';
        if (_docType.requiresBack && _docBack == null) {
          return 'Veuillez photographier le verso du document.';
        }
        return null;
      case 3:
        if (_selfie == null) return 'Veuillez prendre votre selfie.';
        return null;
      case 4:
        if (!_consentement) return 'Vous devez accepter les conditions avant de soumettre.';
        return null;
      default:
        return null;
    }
  }

  Future<void> _soumettre() async {
    final err = _valider();
    if (err != null) { setState(() => _erreur = err); return; }

    setState(() { _soumettant = true; _erreur = null; });

    final data = KycSubmissionData(
      fullName:       _nomCtrl.text.trim(),
      dateOfBirth:    _dateNaissance!,
      country:        _pays,
      documentType:   _docType,
      documentNumber: _numCtrl.text.trim(),
      docFrontPath:   _docFront!.path,
      docBackPath:    _docBack?.path,
      selfiePath:     _selfie!.path,
      consentGiven:   _consentement,
    );

    final result = await KycService.submit(userId: widget.userId, data: data);

    if (!mounted) return;
    setState(() => _soumettant = false);

    if (result.success) {
      await _afficherSucces(result);
    } else {
      setState(() => _erreur = result.message);
    }
  }

  Future<void> _afficherSucces(KycResult result) async {
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
            Text(
              result.message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13.5, color: AppColors.texteDoux, height: 1.5),
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: AppColors.encre),
          onPressed: () => _confirmerAbandon(),
        ),
        title: Text(
          'Étape ${_etape + 1} sur ${_etapes.length}',
          style: const TextStyle(
            color: AppColors.encre, fontWeight: FontWeight.w700, fontSize: 16),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(6),
          child: LinearProgressIndicator(
            value: (_etape + 1) / _etapes.length,
            backgroundColor: AppColors.lignes,
            valueColor: const AlwaysStoppedAnimation(AppColors.or),
            minHeight: 4,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Indicateur d'étapes
                    _StepIndicator(etapes: _etapes, courant: _etape),
                    const SizedBox(height: 28),

                    // Contenu de l'étape
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.05, 0), end: Offset.zero,
                          ).animate(anim),
                          child: child,
                        ),
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(_etape),
                        child: _buildEtape(),
                      ),
                    ),

                    // Erreur
                    if (_erreur != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.alerteFond,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.alerte.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline_rounded,
                                color: AppColors.alerte, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_erreur!,
                                style: const TextStyle(
                                    color: AppColors.alerte, fontSize: 13)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Boutons navigation
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Row(
                children: [
                  if (_etape > 0)
                    Expanded(
                      flex: 1,
                      child: OutlinedButton(
                        onPressed: _precedent,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: const BorderSide(color: AppColors.lignes),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Retour',
                          style: TextStyle(color: AppColors.encre, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  if (_etape > 0) const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: _soumettant
                        ? const Center(child: CircularProgressIndicator(color: AppColors.or))
                        : BtnPrincipal(
                            label: _etape == _etapes.length - 1 ? 'Soumettre' : 'Suivant',
                            icon: _etape == _etapes.length - 1
                                ? Icons.send_rounded
                                : Icons.arrow_forward_rounded,
                            onTap: _etape == _etapes.length - 1 ? _soumettre : _suivant,
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEtape() {
    switch (_etape) {
      case 0: return _EtapeIdentite(
        nomCtrl: _nomCtrl,
        dateNaissance: _dateNaissance,
        onDateChanged: (d) => setState(() => _dateNaissance = d),
      );
      case 1: return _EtapeDocument(
        docType: _docType,
        pays: _pays,
        numCtrl: _numCtrl,
        onDocTypeChanged: (t) => setState(() { _docType = t; _docBack = null; }),
        onPaysChanged: (p) => setState(() => _pays = p),
      );
      case 2: return _EtapePhotos(
        docType: _docType,
        docFront: _docFront,
        docBack: _docBack,
        onFrontChanged: (f) => setState(() => _docFront = f),
        onBackChanged:  (b) => setState(() => _docBack  = b),
      );
      case 3: return _EtapeSelfie(
        selfie: _selfie,
        onSelfieChanged: (s) => setState(() => _selfie = s),
      );
      case 4: return _EtapeConfirmation(
        nom: _nomCtrl.text.trim(),
        dateNaissance: _dateNaissance,
        pays: _pays,
        docType: _docType,
        numMasque: _numCtrl.text.trim().length > 4
            ? '${'*' * (_numCtrl.text.trim().length - 4)}'
              '${_numCtrl.text.trim().substring(_numCtrl.text.trim().length - 4)}'
            : '****',
        consentement: _consentement,
        onConsentChanged: (v) => setState(() => _consentement = v ?? false),
      );
      default: return const SizedBox.shrink();
    }
  }

  void _confirmerAbandon() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Abandonner ?',
          style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text(
          'Votre progression sera perdue. Voulez-vous vraiment quitter ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Continuer',
              style: TextStyle(color: AppColors.encre, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () { Navigator.pop(context); Navigator.pop(context, false); },
            child: const Text('Quitter',
              style: TextStyle(color: AppColors.alerte, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Step Indicator
// ─────────────────────────────────────────────────────────────────────────
class _StepIndicator extends StatelessWidget {
  final List<String> etapes;
  final int courant;
  const _StepIndicator({required this.etapes, required this.courant});

  @override
  Widget build(BuildContext context) => Row(
    children: List.generate(etapes.length, (i) {
      final done    = i < courant;
      final active  = i == courant;
      return Expanded(
        child: Row(
          children: [
            Column(
              children: [
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: done ? AppColors.succes : active ? AppColors.or : AppColors.lignes,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: done
                        ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
                        : Text('${i + 1}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: active ? Colors.white : AppColors.encreDoux,
                            )),
                  ),
                ),
                const SizedBox(height: 4),
                Text(etapes[i],
                  style: TextStyle(
                    fontSize: 9,
                    color: active ? AppColors.or : AppColors.texteDoux,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                  )),
              ],
            ),
            if (i < etapes.length - 1)
              Expanded(
                child: Container(
                  height: 2,
                  margin: const EdgeInsets.only(bottom: 16),
                  color: done ? AppColors.succes : AppColors.lignes,
                ),
              ),
          ],
        ),
      );
    }),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Étape 1 : Identité
// ─────────────────────────────────────────────────────────────────────────
class _EtapeIdentite extends StatelessWidget {
  final TextEditingController nomCtrl;
  final DateTime? dateNaissance;
  final ValueChanged<DateTime?> onDateChanged;

  const _EtapeIdentite({
    required this.nomCtrl,
    required this.dateNaissance,
    required this.onDateChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _TitreEtape(
          icon: Icons.person_rounded,
          titre: 'Vos informations personnelles',
          sousTitre: 'Entrez vos informations telles qu\'elles apparaissent sur votre pièce d\'identité.',
        ),
        const SizedBox(height: 24),
        const ChampLabel(label: 'Nom et prénoms complets *'),
        TextFormField(
          controller: nomCtrl,
          textCapitalization: TextCapitalization.words,
          decoration: _inputDecoration('Ex : KONÉ Amadou Bakary'),
        ),
        const SizedBox(height: 16),
        const ChampLabel(label: 'Date de naissance *'),
        GestureDetector(
          onTap: () async {
            // FIX KYC : suppression de locale:'fr' (nécessite GlobalMaterialLocalizations absent)
            // FIX KYC : protection if (d != null) — évite de réinitialiser la date si l'user annule
            final d = await showDatePicker(
              context: context,
              initialDate: dateNaissance ?? DateTime(1990),
              firstDate: DateTime(1900),
              lastDate: DateTime.now().subtract(const Duration(days: 365 * 18)),
              builder: (ctx, child) => Theme(
                data: Theme.of(ctx).copyWith(
                  colorScheme: const ColorScheme.light(primary: AppColors.or),
                ),
                child: child!,
              ),
            );
            if (d != null) onDateChanged(d);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.lignes),
            ),
            child: Row(
              children: [
                const Icon(Icons.calendar_today_rounded,
                    size: 18, color: AppColors.encreDoux),
                const SizedBox(width: 10),
                Text(
                  dateNaissance != null
                      ? DateFormat('dd/MM/yyyy').format(dateNaissance!)
                      : 'JJ/MM/AAAA',
                  style: TextStyle(
                    fontSize: 15,
                    color: dateNaissance != null ? AppColors.encre : AppColors.texteDoux,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Étape 2 : Type de document
// ─────────────────────────────────────────────────────────────────────────
class _EtapeDocument extends StatelessWidget {
  final KycDocumentType docType;
  final String pays;
  final TextEditingController numCtrl;
  final ValueChanged<KycDocumentType> onDocTypeChanged;
  final ValueChanged<String> onPaysChanged;

  const _EtapeDocument({
    required this.docType,
    required this.pays,
    required this.numCtrl,
    required this.onDocTypeChanged,
    required this.onPaysChanged,
  });

  static const _pays = {
    'CI': 'Côte d\'Ivoire 🇨🇮',
    'SN': 'Sénégal 🇸🇳',
    'CM': 'Cameroun 🇨🇲',
    'BF': 'Burkina Faso 🇧🇫',
    'ML': 'Mali 🇲🇱',
    'GN': 'Guinée 🇬🇳',
    'TG': 'Togo 🇹🇬',
    'BJ': 'Bénin 🇧🇯',
    'NE': 'Niger 🇳🇪',
    'GH': 'Ghana 🇬🇭',
    'NG': 'Nigeria 🇳🇬',
    'FR': 'France 🇫🇷',
    'BE': 'Belgique 🇧🇪',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _TitreEtape(
          icon: Icons.badge_rounded,
          titre: 'Votre pièce d\'identité',
          sousTitre: 'Choisissez le type et le pays d\'émission de votre document officiel.',
        ),
        const SizedBox(height: 24),

        const ChampLabel(label: 'Pays d\'émission *'),
        DropdownButtonFormField<String>(
          initialValue: pays,
          decoration: _inputDecoration('Sélectionner le pays'),
          items: _pays.entries.map((e) => DropdownMenuItem(
            value: e.key,
            child: Text(e.value),
          )).toList(),
          onChanged: (v) => v != null ? onPaysChanged(v) : null,
        ),
        const SizedBox(height: 16),

        const ChampLabel(label: 'Type de document *'),
        ...KycDocumentType.values.map((type) => _DocTypeCard(
          type: type,
          selected: docType == type,
          onTap: () => onDocTypeChanged(type),
        )),
        const SizedBox(height: 16),

        const ChampLabel(label: 'Numéro du document *'),
        TextFormField(
          controller: numCtrl,
          textCapitalization: TextCapitalization.characters,
          decoration: _inputDecoration('Ex : CI1234567890'),
        ),
        const SizedBox(height: 12),

        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.fondSecondaire,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: AppColors.encreDoux),
              SizedBox(width: 8),
              Expanded(child: Text(
                'Le numéro sera masqué dans notre système. Seuls les 4 derniers chiffres seront visibles.',
                style: TextStyle(fontSize: 12, color: AppColors.texteDoux),
              )),
            ],
          ),
        ),
      ],
    );
  }
}

class _DocTypeCard extends StatelessWidget {
  final KycDocumentType type;
  final bool selected;
  final VoidCallback onTap;
  const _DocTypeCard({required this.type, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: selected ? AppColors.or.withValues(alpha: 0.08) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? AppColors.or : AppColors.lignes,
          width: selected ? 2 : 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
            color: selected ? AppColors.or : AppColors.texteDoux,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(type.label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: selected ? AppColors.encre : AppColors.texte,
                )),
              if (type.requiresBack)
                const Text('Recto + Verso requis',
                  style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
            ],
          )),
        ],
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Étape 3 : Photos du document
// ─────────────────────────────────────────────────────────────────────────
class _EtapePhotos extends StatelessWidget {
  final KycDocumentType docType;
  final XFile? docFront;
  final XFile? docBack;
  final ValueChanged<XFile?> onFrontChanged;
  final ValueChanged<XFile?> onBackChanged;

  const _EtapePhotos({
    required this.docType,
    required this.docFront,
    required this.docBack,
    required this.onFrontChanged,
    required this.onBackChanged,
  });

  Future<XFile?> _prendre() async {
    final picker = ImagePicker();
    return picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      maxWidth: 1600,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _TitreEtape(
          icon: Icons.document_scanner_rounded,
          titre: 'Photo de votre document',
          sousTitre: 'Assurez-vous que votre document est bien éclairé, entièrement visible et lisible.',
        ),
        const SizedBox(height: 16),
        _Consigne(Icons.wb_sunny_outlined,   'Placez-vous dans un endroit bien éclairé'),
        _Consigne(Icons.crop_free_rounded,   'Centrez le document dans le cadre'),
        _Consigne(Icons.no_flash_rounded,    'Évitez les reflets et les ombres'),
        _Consigne(Icons.image_rounded,       'Vérifiez que le texte est parfaitement lisible'),
        const SizedBox(height: 24),

        // Recto
        _PhotoCapture(
          label: 'Recto',
          description: 'Face avant du document',
          file: docFront,
          onPrendre: () async {
            final f = await _prendre();
            onFrontChanged(f);
          },
          onReprendre: () async {
            final f = await _prendre();
            onFrontChanged(f);
          },
        ),

        // Verso (si requis)
        if (docType.requiresBack) ...[
          const SizedBox(height: 16),
          _PhotoCapture(
            label: 'Verso',
            description: 'Face arrière du document',
            file: docBack,
            onPrendre: () async {
              final f = await _prendre();
              onBackChanged(f);
            },
            onReprendre: () async {
              final f = await _prendre();
              onBackChanged(f);
            },
          ),
        ],
      ],
    );
  }
}

class _PhotoCapture extends StatelessWidget {
  final String label, description;
  final XFile? file;
  final VoidCallback onPrendre;
  final VoidCallback onReprendre;

  const _PhotoCapture({
    required this.label,
    required this.description,
    this.file,
    required this.onPrendre,
    required this.onReprendre,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text(label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre)),
          const SizedBox(width: 6),
          Text(description,
            style: const TextStyle(fontSize: 12, color: AppColors.texteDoux)),
        ]),
        const SizedBox(height: 8),
        if (file == null)
          GestureDetector(
            onTap: onPrendre,
            child: Container(
              height: 150,
              decoration: BoxDecoration(
                color: AppColors.fondSecondaire,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.or.withValues(alpha: 0.4),
                  style: BorderStyle.solid,
                ),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.photo_camera_rounded, size: 36, color: AppColors.or),
                  SizedBox(height: 8),
                  Text('Appuyer pour photographier',
                    style: TextStyle(color: AppColors.encreDoux, fontWeight: FontWeight.w600, fontSize: 13.5)),
                ],
              ),
            ),
          )
        else
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.file(
                  File(file!.path),
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                top: 8, right: 8,
                child: GestureDetector(
                  onTap: onReprendre,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh_rounded, color: Colors.white, size: 14),
                        SizedBox(width: 4),
                        Text('Reprendre', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 8, left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.succes.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_rounded, color: Colors.white, size: 14),
                      SizedBox(width: 4),
                      Text('Photo prise', style: TextStyle(color: Colors.white, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Étape 4 : Selfie
// ─────────────────────────────────────────────────────────────────────────
class _EtapeSelfie extends StatelessWidget {
  final XFile? selfie;
  final ValueChanged<XFile?> onSelfieChanged;
  const _EtapeSelfie({this.selfie, required this.onSelfieChanged});

  Future<void> _prendrePhoto(BuildContext context) async {
    final picker = ImagePicker();
    final photo = await picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.front,
      imageQuality: 85,
      maxWidth: 1200,
    );
    onSelfieChanged(photo);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _TitreEtape(
          icon: Icons.face_rounded,
          titre: 'Selfie de vérification',
          sousTitre: 'Prenez une photo de vous face à la caméra. Cela confirme que vous êtes bien le titulaire du document.',
        ),
        const SizedBox(height: 16),
        _Consigne(Icons.face_outlined,         'Regard droit vers la caméra frontale'),
        _Consigne(Icons.wb_sunny_outlined,     'Visage bien éclairé, sans ombres'),
        _Consigne(Icons.no_photography_outlined, 'Pas de lunettes de soleil ni de chapeau'),
        _Consigne(Icons.sentiment_neutral_rounded, 'Expression neutre, bouche fermée'),
        const SizedBox(height: 24),

        if (selfie == null)
          GestureDetector(
            onTap: () => _prendrePhoto(context),
            child: Container(
              height: 220,
              decoration: BoxDecoration(
                color: AppColors.fondSecondaire,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.or.withValues(alpha: 0.4)),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.camera_front_rounded, size: 52, color: AppColors.or),
                  SizedBox(height: 12),
                  Text('Appuyer pour prendre le selfie',
                    style: TextStyle(color: AppColors.encreDoux, fontWeight: FontWeight.w600, fontSize: 14)),
                  SizedBox(height: 6),
                  Text('Caméra frontale activée',
                    style: TextStyle(color: AppColors.texteDoux, fontSize: 12)),
                ],
              ),
            ),
          )
        else
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.file(
                  File(selfie!.path),
                  height: 260,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                top: 8, right: 8,
                child: GestureDetector(
                  onTap: () => _prendrePhoto(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh_rounded, color: Colors.white, size: 14),
                        SizedBox(width: 4),
                        Text('Reprendre', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Étape 5 : Confirmation + Consentement
// ─────────────────────────────────────────────────────────────────────────
class _EtapeConfirmation extends StatelessWidget {
  final String nom, pays, numMasque;
  final DateTime? dateNaissance;
  final KycDocumentType docType;
  final bool consentement;
  final ValueChanged<bool?> onConsentChanged;

  const _EtapeConfirmation({
    required this.nom,
    required this.dateNaissance,
    required this.pays,
    required this.docType,
    required this.numMasque,
    required this.consentement,
    required this.onConsentChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _TitreEtape(
          icon: Icons.fact_check_rounded,
          titre: 'Vérifiez vos informations',
          sousTitre: 'Relisez attentivement avant de soumettre. Une fois envoyé, votre dossier sera examiné par notre partenaire de vérification.',
        ),
        const SizedBox(height: 20),
        CarteTC(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Récapitulatif',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre)),
              const Divider(height: 20),
              _LigneResume('Nom complet', nom),
              if (dateNaissance != null)
                _LigneResume('Date de naissance', DateFormat('dd/MM/yyyy').format(dateNaissance!)),
              _LigneResume('Pays', pays),
              _LigneResume('Document', docType.label),
              _LigneResume('Numéro', numMasque),
              _LigneResume('Photos', '✓ Recto${docType.requiresBack ? ' + Verso' : ''} + Selfie'),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Consentement obligatoire
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: consentement ? AppColors.succesFond : AppColors.fondSecondaire,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: consentement
                  ? AppColors.succes.withValues(alpha: 0.4)
                  : AppColors.lignes,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: consentement,
                onChanged: onConsentChanged,
                activeColor: AppColors.or,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              ),
              const SizedBox(width: 4),
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'J\'accepte que mes informations et documents d\'identité soient traités '
                    'afin de vérifier mon identité conformément à la politique de confidentialité de TontineClair '
                    'et à celle de notre partenaire de vérification Smile ID.',
                    style: TextStyle(fontSize: 13, color: AppColors.texte, height: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.fondSecondaire,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.shield_rounded, size: 18, color: AppColors.or),
              SizedBox(width: 8),
              Expanded(child: Text(
                'Les images seront supprimées dans les 30 jours suivant la vérification. '
                'Vos données sont traitées de façon sécurisée et chiffrée.',
                style: TextStyle(fontSize: 12, color: AppColors.texteDoux, height: 1.5),
              )),
            ],
          ),
        ),
      ],
    );
  }
}

class _LigneResume extends StatelessWidget {
  final String label, value;
  const _LigneResume(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        SizedBox(
          width: 130,
          child: Text(label,
            style: const TextStyle(fontSize: 13, color: AppColors.texteDoux, fontWeight: FontWeight.w500)),
        ),
        Expanded(child: Text(value,
          style: const TextStyle(fontSize: 13, color: AppColors.encre, fontWeight: FontWeight.w600))),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Helpers communs
// ─────────────────────────────────────────────────────────────────────────
class _TitreEtape extends StatelessWidget {
  final IconData icon;
  final String titre, sousTitre;
  const _TitreEtape({required this.icon, required this.titre, required this.sousTitre});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 48, height: 48,
        decoration: BoxDecoration(
          color: AppColors.or.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: AppColors.or, size: 24),
      ),
      const SizedBox(height: 14),
      Text(titre, style: const TextStyle(
        fontWeight: FontWeight.w800, fontSize: 20, color: AppColors.encre)),
      const SizedBox(height: 6),
      Text(sousTitre, style: const TextStyle(
        fontSize: 13.5, color: AppColors.texteDoux, height: 1.5)),
    ],
  );
}

class _Consigne extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Consigne(this.icon, this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      Icon(icon, size: 16, color: AppColors.encreDoux),
      const SizedBox(width: 8),
      Text(text, style: const TextStyle(fontSize: 13, color: AppColors.texte)),
    ]),
  );
}

InputDecoration _inputDecoration(String hint) => InputDecoration(
  hintText: hint,
  hintStyle: const TextStyle(color: AppColors.texteDoux, fontSize: 14),
  filled: true,
  fillColor: Colors.white,
  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: const BorderSide(color: AppColors.lignes),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: const BorderSide(color: AppColors.lignes),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: const BorderSide(color: AppColors.or, width: 2),
  ),
);

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
              decoration: BoxDecoration(
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
