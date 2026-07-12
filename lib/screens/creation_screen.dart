import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/subscription_service.dart';
import '../services/feature_gate_service.dart';
import '../services/platform_service.dart';
import '../services/storage_service.dart';
import '../services/echeance_service.dart';
import '../services/devise_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';
import 'abonnement_screen.dart';
import 'code_cree_screen.dart';

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

  List<TextEditingController> _membresCtrl = [
    TextEditingController(),
    TextEditingController(),
  ];

  List<TextEditingController> _gestNomCtrl = [TextEditingController()];
  List<TextEditingController> _gestPinCtrl = [TextEditingController()];

  bool _loading = false;
  String? _erreur;

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
    super.dispose();
  }

  Future<void> _creer() async {
    final nom = _nomCtrl.text.trim();
    final montantStr = _montantCtrl.text.trim();
    final membres = _membresCtrl
        .map((c) => c.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final gestNoms =
        _gestNomCtrl.map((c) => c.text.trim()).toList();
    final gestPins =
        _gestPinCtrl.map((c) => c.text.trim()).toList();

    // Validations
    if (nom.isEmpty) {
      setState(() => _erreur = 'Donnez un nom à la tontine.');
      return;
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
    // Plan Premium : lu depuis SubscriptionService (source unique)
    final isPremium = SubscriptionService.isPremium;

    // ── Limite Gratuit : 5 membres MAX par tontine ────────────────────────
    // Bloquer UNIQUEMENT si l'utilisateur essaie d'ajouter un 6e membre ou plus.
    // Un compte Gratuit peut avoir exactement 5 membres dans sa tontine.
    if (!isPremium && membres.length > FeatureGate.maxMembresGratuit) {
      if (!mounted) return;
      afficherDialogUpgrade(
        context,
        limiteInfo: LimiteInfo(
          type: LimiteType.membres,
          titre: 'Limite de membres atteinte',
          message: FeatureGate.messageLimite(
            limite: LimiteType.membres,
            actuel: membres.length,
            max: FeatureGate.maxMembresGratuit,
          ),
          actuel: membres.length,
          max: FeatureGate.maxMembresGratuit,
        ),
        onUpgrade: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AbonnementScreen(
              code: '',
              platformeForce: PlatformService.current,
            ),
          ),
        ),
      );
      return;
    }

    // ── Limite Gratuit : 1 tontine CRÉÉE max ──────────────────────────────
    // Compter uniquement les tontines où l'utilisateur est gestionnaire
    // (créées par lui), pas celles qu'il a simplement rejointes.
    // On utilise nbTontinesCrees stocké localement.
    final nbCrees = await StorageService.getNbTontinesCrees();
    if (!isPremium && nbCrees >= FeatureGate.maxTontinesGratuit) {
      if (!mounted) return;
      afficherDialogUpgrade(
        context,
        limiteInfo: LimiteInfo(
          type: LimiteType.tontines,
          titre: 'Limite de tontines atteinte',
          message: FeatureGate.messageLimite(
            limite: LimiteType.tontines,
            actuel: nbCrees,
            max: FeatureGate.maxTontinesGratuit,
          ),
          actuel: nbCrees,
          max: FeatureGate.maxTontinesGratuit,
        ),
        onUpgrade: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AbonnementScreen(
              code: '',
              platformeForce: PlatformService.current,
            ),
          ),
        ),
      );
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
      (i) => Gestionnaire(nom: gestNoms[i], pin: gestPins[i]),
    );

    final code = await provider.creer(
      nom: nom,
      montant: int.parse(montantStr),
      periode: _periode,
      methodeOrdre: _methode,
      devise: _devise,
      membres: membres,
      gestionnaires: gestionnaires,
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
    final isPremium = SubscriptionService.isPremium;
    // Gratuit : max 5 membres. Bloquer l'ajout du 6e et plus.
    if (!isPremium && _membresCtrl.length >= FeatureGate.maxMembresGratuit) {
      afficherDialogUpgrade(
        context,
        limiteInfo: LimiteInfo(
          type: LimiteType.membres,
          titre: 'Limite atteinte — 5 membres max',
          message: 'La formule Gratuite autorise jusqu\'à ${FeatureGate.maxMembresGratuit} membres. '
              'Passez à Premium pour ajouter plus de membres.',
          actuel: _membresCtrl.length,
          max: FeatureGate.maxMembresGratuit,
        ),
        onUpgrade: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AbonnementScreen(
              code: '',
              platformeForce: PlatformService.current,
            ),
          ),
        ),
      );
      return;
    }
    setState(() => _membresCtrl.add(TextEditingController()));
  }

  void _retirerMembre(int i) {
    _membresCtrl[i].dispose();
    setState(() => _membresCtrl.removeAt(i));
  }

  void _ajouterGest() {
    setState(() {
      _gestNomCtrl.add(TextEditingController());
      _gestPinCtrl.add(TextEditingController());
    });
  }

  void _retirerGest(int i) {
    _gestNomCtrl[i].dispose();
    _gestPinCtrl[i].dispose();
    setState(() {
      _gestNomCtrl.removeAt(i);
      _gestPinCtrl.removeAt(i);
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
                  const SizedBox(height: 6),
                  const Text(
                    'Elle sera créée en ligne : tu recevras un code à partager aux membres.',
                    style: TextStyle(fontSize: 15, color: AppColors.texteDoux),
                  ),
                  const SizedBox(height: 16),
                  CarteTC(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const ChampLabel(label: 'Nom de la tontine'),
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
                                'Chacun avec son PIN personnel (4-6 chiffres). Chaque gestionnaire garde son PIN secret.'),
                        const SizedBox(height: 12),
                        ...List.generate(
                          _gestNomCtrl.length,
                          (i) => _LigneGestionnaire(
                            nomCtrl: _gestNomCtrl[i],
                            pinCtrl: _gestPinCtrl[i],
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
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                child: BtnPrincipal(
                  label: 'Créer la tontine',
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
  final int index;
  final VoidCallback? onRetirer;

  const _LigneGestionnaire({
    required this.nomCtrl,
    required this.pinCtrl,
    required this.index,
    this.onRetirer,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
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
      value: value,
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
