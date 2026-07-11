import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/subscription_service.dart';
import '../services/feature_gate_service.dart';
import '../services/platform_service.dart';
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
  DateTime? _echeance;

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

    // Limite Gratuit : 5 membres max par tontine
    if (!SubscriptionService.peutAjouterMembre(membres.length - 1) &&
        membres.length > FeatureGate.maxMembresGratuit) {
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

    // Limite Gratuit : 1 tontine
    if (!isPremium && provider.mesTontines.isNotEmpty) {
      if (!mounted) return;
      afficherDialogUpgrade(
        context,
        limiteInfo: LimiteInfo(
          type: LimiteType.tontines,
          titre: 'Limite de tontines atteinte',
          message: FeatureGate.messageLimite(
            limite: LimiteType.tontines,
            actuel: provider.mesTontines.length,
            max: FeatureGate.maxTontinesGratuit,
          ),
          actuel: provider.mesTontines.length,
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
      echeance: _echeance?.toIso8601String(),
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

  void _ajouterMembre() {
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

  Future<void> _choisirDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 30)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365 * 5)),
      locale: const Locale('fr', 'FR'),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(
            primary: AppColors.encre,
            onPrimary: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() => _echeance = picked);
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
                        const ChampLabel(
                            label: 'Cotisation par membre (FCFA)'),
                        TextField(
                          controller: _montantCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            hintText: 'Ex : 10 000',
                          ),
                        ),
                        const ChampLabel(label: 'Périodicité'),
                        _SelectChamp(
                          value: _periode,
                          items: const {
                            'hebdo': 'Chaque semaine',
                            'mensuel': 'Chaque mois',
                          },
                          onChanged: (v) => setState(() => _periode = v!),
                        ),
                        const ChampLabel(
                            label: 'Prochaine échéance (facultatif)'),
                        GestureDetector(
                          onTap: _choisirDate,
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
                                  _echeance == null
                                      ? 'Choisir une date...'
                                      : '${_echeance!.day.toString().padLeft(2, '0')}/${_echeance!.month.toString().padLeft(2, '0')}/${_echeance!.year}',
                                  style: TextStyle(
                                    fontSize: 15.5,
                                    color: _echeance == null
                                        ? AppColors.texteDoux
                                        : AppColors.texte,
                                  ),
                                ),
                                const Spacer(),
                                const Icon(Icons.calendar_today,
                                    size: 18, color: AppColors.texteDoux),
                              ],
                            ),
                          ),
                        ),
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
