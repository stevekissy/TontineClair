import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/feature_gate_service.dart';
import '../services/storage_service.dart';
import '../services/echeance_service.dart';
import '../services/devise_service.dart';
import '../services/kyc_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';
import 'code_cree_screen.dart';
import 'kyc_screen.dart';
import '../utils/app_localizations.dart';

class CreationScreen extends StatefulWidget {
  const CreationScreen({super.key});

  @override
  State<CreationScreen> createState() => _CreationScreenState();
}

class _CreationScreenState extends State<CreationScreen> {
  final _nomCtrl = TextEditingController();
  final _montantCtrl = TextEditingController();
  String _periode = 'mensuel';
  String _methode = 'tirage';
  String _devise = 'XOF'; // devise par défaut : FCFA

  final List<TextEditingController> _membresCtrl = [
    TextEditingController(),
    TextEditingController(),
  ];

  final List<TextEditingController> _gestNomCtrl   = [TextEditingController()];
  final List<TextEditingController> _gestPinCtrl   = [TextEditingController()];
  final List<TextEditingController> _gestEmailCtrl = [TextEditingController()];

  bool _loading = false;
  String? _erreur;
  String _typeTontine = 'gratuite'; // 'gratuite' | 'premium'

  // ── KYC Smile ID ─────────────────────────────────────────────
  bool _kycValide = false;     // true une fois que Smile ID a confirmé verified
  bool _kycEnCours = false;    // spinner pendant la vérification du statut

  /// KYC obligatoire si et seulement si la tontine est de type Premium.
  /// Compte Gratuit → jamais de KYC.
  bool get _kycRequis => _typeTontine == 'premium';

  @override
  void dispose() {
    _nomCtrl.dispose();
    _montantCtrl.dispose();
    for (final c in _membresCtrl) {
      c.dispose();
    }
    for (final c in _gestNomCtrl) {
      c.dispose();
    }
    for (final c in _gestPinCtrl) {
      c.dispose();
    }
    for (final c in _gestEmailCtrl) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _creer() async {
    final nom = _nomCtrl.text.trim();
    final montantStr = _montantCtrl.text.trim();
    final membres = _membresCtrl
        .map((c) => c.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final gestNoms   = _gestNomCtrl.map((c) => c.text.trim()).toList();
    final gestPins   = _gestPinCtrl.map((c) => c.text.trim()).toList();
    final gestEmails = _gestEmailCtrl.map((c) => c.text.trim().toLowerCase()).toList();

    // Validations
    if (nom.isEmpty) {
      setState(() => _erreur = 'Donnez un nom à la tontine.');
      return;
    }

    // ── Gate KYC Smile ID : obligatoire pour toute tontine Premium ──────────
    if (_kycRequis && !_kycValide) {
      // Vérifier le statut KYC actuel depuis Supabase
      final gestNomKyc = _gestNomCtrl.isNotEmpty
          ? _gestNomCtrl.first.text.trim()
          : '';
      setState(() => _kycEnCours = true);
      final userId = gestNomKyc.isNotEmpty ? gestNomKyc : 'unknown';
      final bloquant = await KycService.kycBloquantPourPremium(userId);
      if (!mounted) { setState(() => _kycEnCours = false); return; }
      setState(() => _kycEnCours = false);

      if (bloquant) {
        // Lancer le parcours KYC Smile ID complet
        final result = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => KycScreen(userId: userId),
          ),
        );
        if (!mounted) return;
        if (result != true) {
          // L'utilisateur a fermé sans compléter
          setState(() => _erreur =
            'La vérification d\'identité est obligatoire pour créer une tontine Premium. '
            'Vous devez compléter votre vérification Smile ID avant de continuer.');
          return;
        }
        // Re-vérifier après le parcours KYC
        final encoreBloquant = await KycService.kycBloquantPourPremium(userId);
        if (!mounted) return;
        if (encoreBloquant) {
          setState(() => _erreur =
            'Votre vérification est en cours d\'analyse (Smile ID). '
            'Vous pourrez créer cette tontine Premium dès que votre identité sera confirmée.');
          return;
        }
      }
      setState(() => _kycValide = true);
    }
    if (montantStr.isEmpty || int.tryParse(montantStr) == null) {
      setState(() => _erreur = 'Montant invalide.');
      return;
    }
    if (membres.length < 2) {
      setState(() => _erreur = 'Au moins 2 membres requis.');
      return;
    }

    final provider = context.read<TontineProvider>();
    final estGratuite = _typeTontine == 'gratuite';

    // ── Limite Gratuite : 5 membres MAX par tontine ───────────────────────
    if (estGratuite && membres.length > FeatureGate.maxMembresGratuit) {
      setState(() => _erreur =
          'Formule Gratuite : maximum ${FeatureGate.maxMembresGratuit} membres. '
          'Choisissez la formule Premium pour ajouter plus de membres.');
      return;
    }

    // ── Limite Gratuite : 1 tontine créée max ────────────────────────────
    final nbCrees = await StorageService.getNbTontinesCrees();
    if (estGratuite && nbCrees >= FeatureGate.maxTontinesGratuit) {
      if (!mounted) return;
      setState(() => _erreur =
          'Vous avez déjà ${FeatureGate.maxTontinesGratuit} tontine gratuite. '
          'Choisissez la formule Premium pour créer des tontines illimitées.');
      return;
    }

    for (int i = 0; i < gestNoms.length; i++) {
      if (gestNoms[i].isEmpty) {
        setState(() => _erreur = 'Nom du gestionnaire ${i + 1} manquant.');
        return;
      }
      final pin = gestPins[i];
      if (pin.length < 4) {
        setState(() => _erreur = 'PIN de ${gestNoms[i]} trop court (4 chiffres min.).');
        return;
      }
      // Email de récupération obligatoire
      final email = gestEmails[i];
      if (email.isEmpty) {
        setState(() => _erreur = 'Email de récupération de ${gestNoms[i]} manquant.');
        return;
      }
      final emailReg = RegExp(r'^[\w.+\-]+@[\w\-]+\.[\w.]+$');
      if (!emailReg.hasMatch(email)) {
        setState(() => _erreur = 'Email de ${gestNoms[i]} invalide (ex: nom@gmail.com).');
        return;
      }
    }

    // Vérifier que tous les PINs gestionnaires sont différents entre eux
    if (gestPins.length > 1) {
      final pinsUniques = gestPins.toSet();
      if (pinsUniques.length < gestPins.length) {
        setState(() => _erreur =
            'Chaque gestionnaire doit avoir un PIN différent. Deux PINs identiques détectés.');
        return;
      }
    }

    setState(() {
      _loading = true;
      _erreur = null;
    });

    final gestionnaires = List.generate(
      gestNoms.length,
      (i) => Gestionnaire(
        nom:   gestNoms[i],
        pin:   gestPins[i],
        email: gestEmails[i],
      ),
    );

    final code = await provider.creer(
      nom: nom,
      montant: int.parse(montantStr),
      periode: _periode,
      methodeOrdre: _methode,
      devise: _devise,
      membres: membres,
      gestionnaires: gestionnaires,
      tier: _typeTontine,
    );

    if (!mounted) return;
    setState(() => _loading = false);

    if (code != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CodeCreerScreen(code: code, nom: nom),
        ),
      );
    } else {
      setState(() => _erreur = provider.erreur ?? 'Erreur lors de la création.');
      provider.clearErreur();
    }
  }

  /// Libellé de l'échéance calculée automatiquement selon la périodicité
  String _labelEcheanceAuto() {
    final auto = EcheanceService.prochaineEcheance(periode: _periode);
    final d = auto.day.toString().padLeft(2, '0');
    final m = auto.month.toString().padLeft(2, '0');
    final y = auto.year;
    return '$d/$m/$y';
  }

  void _ajouterMembre() {
    // Gratuite : max 5 membres. Bloquer l'ajout du 6e et plus.
    if (_typeTontine == 'gratuite' && _membresCtrl.length >= FeatureGate.maxMembresGratuit) {
      setState(() => _erreur =
          'Formule Gratuite : ${FeatureGate.maxMembresGratuit} membres maximum. '
          'Passez en Premium pour des membres illimités.');
      return;
    }
    setState(() {
      _erreur = null;
      _membresCtrl.add(TextEditingController());
    });
  }

  void _retirerMembre(int i) {
    _membresCtrl[i].dispose();
    setState(() => _membresCtrl.removeAt(i));
  }

  void _ajouterGest() {
    setState(() {
      _gestNomCtrl.add(TextEditingController());
      _gestPinCtrl.add(TextEditingController());
      _gestEmailCtrl.add(TextEditingController());
    });
  }

  void _retirerGest(int i) {
    _gestNomCtrl[i].dispose();
    _gestPinCtrl[i].dispose();
    _gestEmailCtrl[i].dispose();
    setState(() {
      _gestNomCtrl.removeAt(i);
      _gestPinCtrl.removeAt(i);
      _gestEmailCtrl.removeAt(i);
    });
  }

  /// Ouvre le sélecteur de devise avec recherche
  Future<void> _choisirDevise() async {
    final deviseChoisie = await showModalBottomSheet<Devise>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SelectorDevise(codeActuel: _devise),
    );
    if (deviseChoisie != null && mounted) {
      setState(() => _devise = deviseChoisie.code);
    }
  }

  /// Bannière KYC — visible uniquement si type = Premium
  Widget _banniereKyc() {
    if (!_kycRequis) return const SizedBox.shrink();
    if (_kycEnCours) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 10),
        child: Row(children: [
          SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.or)),
          SizedBox(width: 10),
          Text('Vérification identité en cours…',
            style: TextStyle(fontSize: 13, color: AppColors.texteDoux)),
        ]),
      );
    }
    final valide = _kycValide;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: valide ? const Color(0xFFE3F1EA) : const Color(0xFFFFF3CD),
          border: Border.all(
            color: valide
                ? const Color(0xFF2E7D5B).withValues(alpha: 0.4)
                : const Color(0xFFF59E0B).withValues(alpha: 0.6),
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              valide ? Icons.shield_rounded : Icons.fingerprint_rounded,
              size: 20,
              color: valide ? const Color(0xFF2E7D5B) : const Color(0xFFF59E0B),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    valide
                        ? 'Identité vérifiée ✓ (Smile ID)'
                        : 'Vérification d\'identité obligatoire',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: valide
                          ? const Color(0xFF1B5E3B)
                          : const Color(0xFF78350F),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    valide
                        ? 'Votre identité a été confirmée par Smile ID.'
                        : 'Tontine Premium — votre identité sera vérifiée avant la création.',
                    style: TextStyle(
                      fontSize: 12,
                      color: valide
                          ? const Color(0xFF2E7D5B)
                          : const Color(0xFF92400E),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding:
                  const EdgeInsets.fromLTRB(16, 0, 16, 100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      const LogoTontineClair(),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back, size: 16),
                        label: const Text('Mes tontines'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.encre,
                          textStyle: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Nouvelle tontine',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 30,
                      color: AppColors.encre,
                      letterSpacing: -0.02,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Elle sera créée en ligne : tu recevras un code à partager aux membres.',
                    style: TextStyle(fontSize: 15, color: AppColors.texteDoux),
                  ),
                  SizedBox(height: 16),
                  // ── Bannière KYC — visible si Premium ─────────────
                  _banniereKyc(),
                  _SelecteurTypeTontine(
                    valeur: _typeTontine,
                    onChanged: (v) => setState(() {
                      _typeTontine = v;
                      _erreur = null;
                    }),
                  ),
                  SizedBox(height: 8),
                  CarteTC(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ChampLabel(label: context.tr('nom_tontine')),
                        TextField(
                          controller: _nomCtrl,
                          maxLength: 50,
                          decoration: const InputDecoration(
                            hintText: 'Ex : Tontine des commerçantes d\'Adjamé',
                            counterText: '',
                          ),
                        ),
                        // ── Devise + Montant côte à côte ──────────────────
                        const ChampLabel(label: 'Devise'),
                        GestureDetector(
                          onTap: _choisirDevise,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 13),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(
                                  color: AppColors.lignes, width: 1.5),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Text(
                                  () {
                                    final d = DeviseService.parCode(_devise);
                                    return '${d.drapeau}  ${d.symbole} — ${d.nom}';
                                  }(),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: AppColors.encre,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                const Icon(Icons.keyboard_arrow_down_rounded,
                                    size: 20, color: AppColors.texteDoux),
                              ],
                            ),
                          ),
                        ),
                        const ChampLabel(label: 'Cotisation par membre'),
                        TextField(
                          controller: _montantCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            hintText: 'Ex : 10 000',
                            suffixText: DeviseService.parCode(_devise).symbole,
                            suffixStyle: const TextStyle(
                              color: AppColors.texteDoux,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const ChampLabel(label: 'Périodicité'),
                        _SelectChamp(
                          value: _periode,
                          items: EcheanceService.periodiciteOptions,
                          onChanged: (v) => setState(() => _periode = v!),
                        ),
                        // Aide : échéance calculée automatiquement
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 9),
                            decoration: BoxDecoration(
                              color: AppColors.succesFond,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.auto_awesome_rounded,
                                    size: 14, color: AppColors.succes),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    'Prochaine échéance calculée automatiquement : ${_labelEcheanceAuto()}',
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      color: AppColors.succes,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        const ChampLabel(label: "Méthode d'ordre de passage"),
                        _SelectChamp(
                          value: _methode,
                          items: const {
                            'tirage':
                                '🎲 Tirage au sort certifié (après création)',
                            'rotation': 'Rotation classique (ordre de saisie)',
                            'manuel': 'Ordre manuel (à faire valider par vote)',
                          },
                          onChanged: (v) => setState(() => _methode = v!),
                        ),
                        const ChampAide(
                          texte:
                              'Le tirage certifié mélange les membres avec un générateur aléatoire cryptographique, puis verrouille l\'ordre définitivement.',
                        ),
                      ],
                    ),
                  ),
                  // Membres
                  CarteTC(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Membres',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 17,
                            color: AppColors.encre,
                          ),
                        ),
                        const ChampAide(
                            texte:
                                'Le premier de la liste reçoit la cagnotte au tour 1, etc. Formule gratuite : 5 membres max.'),
                        const SizedBox(height: 12),
                        ...List.generate(
                          _membresCtrl.length,
                          (i) => _LigneMembre(
                            ctrl: _membresCtrl[i],
                            placeholder: 'Membre ${i + 1} — ex : Awa K.',
                            onRetirer: _membresCtrl.length > 2
                                ? () => _retirerMembre(i)
                                : null,
                          ),
                        ),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: _ajouterMembre,
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              border: Border.all(
                                  color: AppColors.encreDoux,
                                  width: 1.5,
                                  style: BorderStyle.solid),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Center(
                              child: Text(
                                '+ Ajouter un membre',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: AppColors.encre,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Gestionnaires
                  CarteTC(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Gestionnaires autorisés',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 17,
                            color: AppColors.encre,
                          ),
                        ),
                        const ChampAide(
                            texte:
                                'Chacun avec son PIN personnel (4-6 chiffres). L\'email de récupération est requis pour réinitialiser le PIN.'),
                        const SizedBox(height: 12),
                        ...List.generate(
                          _gestNomCtrl.length,
                          (i) => _LigneGestionnaire(
                            nomCtrl:   _gestNomCtrl[i],
                            pinCtrl:   _gestPinCtrl[i],
                            emailCtrl: _gestEmailCtrl[i],
                            index: i,
                            onRetirer: _gestNomCtrl.length > 1
                                ? () => _retirerGest(i)
                                : null,
                          ),
                        ),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: _ajouterGest,
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              border: Border.all(
                                  color: AppColors.encreDoux, width: 1.5),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Center(
                              child: Text(
                                '+ Ajouter un gestionnaire',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: AppColors.encre,
                                ),
                              ),
                            ),
                          ),
                        ),
                        ChampErreur(texte: _erreur),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Bouton bas
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      AppColors.fondPapier,
                      AppColors.fondPapier.withValues(alpha: 0),
                    ],
                  ),
                ),
                padding: EdgeInsets.fromLTRB(16, 14, 16, 18),
                child: BtnPrincipal(
                  label: context.tr('creer_la_tontine'),
                  onTap: _creer,
                  loading: _loading,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LigneMembre extends StatelessWidget {
  final TextEditingController ctrl;
  final String placeholder;
  final VoidCallback? onRetirer;

  const _LigneMembre({
    required this.ctrl,
    required this.placeholder,
    this.onRetirer,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: ctrl,
              maxLength: 30,
              decoration: InputDecoration(
                hintText: placeholder,
                counterText: '',
              ),
            ),
          ),
          if (onRetirer != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onRetirer,
              child: Container(
                width: 44,
                height: 48,
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.lignes, width: 1.5),
                  borderRadius: BorderRadius.circular(12),
                  color: Colors.white,
                ),
                child: const Center(
                  child: Text(
                    '✕',
                    style: TextStyle(
                      fontSize: 18,
                      color: AppColors.alerte,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LigneGestionnaire extends StatelessWidget {
  final TextEditingController nomCtrl;
  final TextEditingController pinCtrl;
  final TextEditingController emailCtrl;
  final int index;
  final VoidCallback? onRetirer;

  const _LigneGestionnaire({
    required this.nomCtrl,
    required this.pinCtrl,
    required this.emailCtrl,
    required this.index,
    this.onRetirer,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Ligne 1 : Nom + PIN + bouton supprimer ──────────────────────
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: nomCtrl,
                  maxLength: 40,
                  decoration: InputDecoration(
                    hintText: 'Gestionnaire ${index + 1}',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: pinCtrl,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    hintText: 'PIN',
                    counterText: '',
                  ),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.15,
                  ),
                ),
              ),
              if (onRetirer != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onRetirer,
                  child: Container(
                    width: 44,
                    height: 48,
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.lignes, width: 1.5),
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.white,
                    ),
                    child: const Center(
                      child: Text(
                        '✕',
                        style: TextStyle(fontSize: 18, color: AppColors.alerte),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          // ── Ligne 2 : Email de récupération ─────────────────────────────
          const SizedBox(height: 6),
          TextField(
            controller: emailCtrl,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            maxLength: 100,
            decoration: InputDecoration(
              hintText: 'Email de récupération (ex: nom@gmail.com)',
              prefixIcon: const Icon(Icons.email_outlined, size: 18),
              counterText: '',
              helperText: 'Utilisé uniquement si le PIN est oublié',
              helperStyle: const TextStyle(
                fontSize: 11,
                color: AppColors.encreDoux,
              ),
            ),
          ),
          if (index < 999) // séparateur visuel entre gestionnaires
            const Divider(height: 20, color: AppColors.lignes),
        ],
      ),
    );
  }
}

class _SelectChamp extends StatelessWidget {
  final String value;
  final Map<String, String> items;
  final ValueChanged<String?> onChanged;

  const _SelectChamp({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.lignes, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.lignes, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.encre, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      ),
      items: items.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: onChanged,
      style: const TextStyle(
        fontSize: 15.5,
        color: AppColors.texte,
      ),
    );
  }
}

// ─── Sélecteur de devise avec recherche ───────────────────────────────────────

class _SelectorDevise extends StatefulWidget {
  final String codeActuel;
  const _SelectorDevise({required this.codeActuel});

  @override
  State<_SelectorDevise> createState() => _SelectorDeviseState();
}

class _SelectorDeviseState extends State<_SelectorDevise> {
  final _searchCtrl = TextEditingController();
  List<Devise> _filtrees = DeviseService.listeTrier;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _filtrer(String query) {
    final q = query.toLowerCase();
    setState(() {
      _filtrees = DeviseService.listeTrier
          .where((d) =>
              d.code.toLowerCase().contains(q) ||
              d.symbole.toLowerCase().contains(q) ||
              d.nom.toLowerCase().contains(q))
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.80,
      child: Column(
        children: [
          // ── Barre poignée ──
          const SizedBox(height: 10),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: AppColors.lignes,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          // ── Titre ──
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.language_rounded, size: 20, color: AppColors.encre),
                SizedBox(width: 8),
                Text(
                  'Choisir la devise',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                    color: AppColors.encre,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // ── Recherche ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _filtrer,
              decoration: InputDecoration(
                hintText: 'Rechercher une devise…',
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.lignes),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.lignes),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // ── Liste ──
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _filtrees.length,
              itemBuilder: (ctx, i) {
                final d = _filtrees[i];
                final estSelec = d.code == widget.codeActuel;
                // Séparateur après les devises prioritaires
                final estPrioritaire =
                    DeviseService.codesPrioritaires.contains(d.code);
                final prochainEstPrioritaire = i + 1 < _filtrees.length &&
                    DeviseService.codesPrioritaires
                        .contains(_filtrees[i + 1].code);
                final afficherSeparateur =
                    estPrioritaire && !prochainEstPrioritaire;

                return Column(
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 2),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      tileColor: estSelec
                          ? AppColors.encre.withValues(alpha: 0.07)
                          : null,
                      leading: Text(
                        d.drapeau,
                        style: const TextStyle(fontSize: 22),
                      ),
                      title: Text(
                        '${d.symbole}  —  ${d.nom}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: estSelec
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: AppColors.encre,
                        ),
                      ),
                      subtitle: Text(
                        d.code,
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.texteDoux),
                      ),
                      trailing: estSelec
                          ? const Icon(Icons.check_circle_rounded,
                              color: AppColors.succes, size: 20)
                          : null,
                      onTap: () => Navigator.pop(ctx, d),
                    ),
                    if (afficherSeparateur) ...[
                      const SizedBox(height: 4),
                      const Divider(height: 1, color: AppColors.lignes),
                      const SizedBox(height: 4),
                    ],
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ─── Sélecteur de type de tontine : Gratuite / Premium ───────────────────────

class _SelecteurTypeTontine extends StatelessWidget {
  final String valeur;
  final ValueChanged<String> onChanged;

  const _SelecteurTypeTontine({required this.valeur, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Type de tontine',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            color: AppColors.encre,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _CarteOption(
                titre: 'Gratuite',
                sousTitre: '1 tontine\n5 membres max\nPaiements manuels',
                icone: '🆓',
                selectionne: valeur == 'gratuite',
                onTap: () => onChanged('gratuite'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _CarteOption(
                titre: 'Premium',
                sousTitre: 'Tontines illimitées\nMembres illimités\nPaiement automatisé',
                icone: '⭐',
                selectionne: valeur == 'premium',
                onTap: () => onChanged('premium'),
                couleurAccent: const Color(0xFFF59E0B),
              ),
            ),
          ],
        ),

      ],
    );
  }
}

class _CarteOption extends StatelessWidget {
  final String titre;
  final String sousTitre;
  final String icone;
  final bool selectionne;
  final VoidCallback onTap;
  final Color couleurAccent;

  const _CarteOption({
    required this.titre,
    required this.sousTitre,
    required this.icone,
    required this.selectionne,
    required this.onTap,
    this.couleurAccent = AppColors.encre,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selectionne
              ? couleurAccent.withValues(alpha: 0.08)
              : Colors.white,
          border: Border.all(
            color: selectionne ? couleurAccent : AppColors.lignes,
            width: selectionne ? 2 : 1.5,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(icone, style: const TextStyle(fontSize: 20)),
                const Spacer(),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selectionne ? couleurAccent : Colors.transparent,
                    border: Border.all(
                      color: selectionne ? couleurAccent : AppColors.lignes,
                      width: 2,
                    ),
                  ),
                  child: selectionne
                      ? const Icon(Icons.check, size: 12, color: Colors.white)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              titre,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: selectionne ? couleurAccent : AppColors.encre,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              sousTitre,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.texteDoux,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
