import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

class TirageScreen extends StatefulWidget {
  final String code;

  const TirageScreen({super.key, required this.code});

  @override
  State<TirageScreen> createState() => _TirageScreenState();
}

class _TirageScreenState extends State<TirageScreen> {
  bool _tirageFait = false;
  List<Membre> _membresOrdonnes = [];

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;
    if (tontine == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final data = tontine.data;
    final estGest = provider.estDebloque;
    final membres = data.membres;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: Row(
                children: [
                  const LogoTontineClair(),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('Retour'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.encre,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    'Tirage au sort certifié',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 28,
                      color: AppColors.encre,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Mélange cryptographique irréversible — l\'ordre est verrouillé définitivement après tirage.',
                    style: TextStyle(fontSize: 14, color: AppColors.texteDoux),
                  ),
                  const SizedBox(height: 20),
                  if (data.tirageVerrouille) ...[
                    _BandeauVerrouille(membres: membres, estGest: estGest),
                  ] else if (_tirageFait) ...[
                    _ResultatTirage(
                      membres: _membresOrdonnes,
                      estGest: estGest,
                      onVerrouiller: () => _verrouiller(context, provider, data),
                      onAnnuler: () => setState(() {
                        _tirageFait = false;
                        _membresOrdonnes = [];
                      }),
                    ),
                  ] else ...[
                    // État initial
                    CarteTC(
                      child: Column(
                        children: [
                          const Icon(
                            Icons.shuffle,
                            size: 48,
                            color: AppColors.encre,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Tirage au sort',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 20,
                              color: AppColors.encre,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'L\'ordre actuel est : ${data.methodeOrdre == 'rotation' ? 'Rotation classique' : data.methodeOrdre}.\n\n${membres.length} membres seront mélangés avec un générateur aléatoire cryptographique.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 14,
                              color: AppColors.texteDoux,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (estGest)
                            BtnKola(
                              label: '🎲 Lancer le tirage',
                              onTap: () => _lancerTirage(membres),
                            )
                          else
                            const Text(
                              'Seul un gestionnaire peut lancer le tirage.',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.texteDoux,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Ordre actuel
                    const Text(
                      'Ordre actuel',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                        color: AppColors.encre,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ...membres.asMap().entries.map(
                      (e) => _LigneOrdre(membre: e.value, rang: e.key + 1),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _lancerTirage(List<Membre> membres) {
    // Mélange cryptographique Fisher-Yates
    final list = List<Membre>.from(membres);
    final random = Random.secure();
    for (int i = list.length - 1; i > 0; i--) {
      final j = random.nextInt(i + 1);
      final tmp = list[i];
      list[i] = list[j];
      list[j] = tmp;
    }
    setState(() {
      _tirageFait = true;
      _membresOrdonnes = list;
    });
  }

  Future<void> _verrouiller(
    BuildContext context,
    TontineProvider provider,
    TontineData data,
  ) async {
    final ok = await afficherModalePin(
      context,
      titre: 'Verrouiller le tirage',
      sousTitre: 'Cette action est définitive. Confirme ton identité.',
      onValider: (pin) async {
        final ref = Formatters.genererReference();
        // Générer une empreinte cryptographique de l'ordre
        final ordreStr = _membresOrdonnes.map((m) => m.id).join(',');
        final empreinte = sha256
            .convert(utf8.encode('$ordreStr|${DateTime.now().toIso8601String()}'))
            .toString()
            .substring(0, 16)
            .toUpperCase();

        final newData = data.toJson();
        newData['membres'] = _membresOrdonnes
            .asMap()
            .entries
            .map((e) {
              final m = e.value.toJson();
              m['id'] = 'm${e.key + 1}';
              return m;
            })
            .toList();
        newData['tirageVerrouille'] = true;
        newData['ordreVerrouille'] = true;
        // tourActuel = index 0-based (0 = premier tour, 1-based affiché = 1)
        newData['tourActuel'] = 0;
        newData['cycleTermine'] = false;
        newData['methodeOrdre'] = 'tirage';

        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        journal.insert(0, {
          'quoi': 'TIRAGE_VERROUILLE|empreinte:$empreinte',
          'gestionnaire': provider.gestActifNom ?? '',
          'quand': DateTime.now().toIso8601String(),
          'reference': ref,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    if (ok == true && context.mounted) {
      setState(() => _tirageFait = false);
      afficherToast(context, 'Tirage verrouillé et signé !');
    }
  }
}

class _BandeauVerrouille extends StatelessWidget {
  final List<Membre> membres;
  final bool estGest;

  const _BandeauVerrouille({required this.membres, required this.estGest});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.succesFond,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.succes.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Text('🔒', style: TextStyle(fontSize: 24)),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tirage verrouillé',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: AppColors.succes,
                      ),
                    ),
                    Text(
                      'L\'ordre est définitif. Seul un vote peut le modifier.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppColors.succes,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Ordre de passage',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: AppColors.encre,
          ),
        ),
        const SizedBox(height: 10),
        ...membres.asMap().entries.map(
          (e) => _LigneOrdre(membre: e.value, rang: e.key + 1),
        ),
      ],
    );
  }
}

class _ResultatTirage extends StatelessWidget {
  final List<Membre> membres;
  final bool estGest;
  final VoidCallback onVerrouiller;
  final VoidCallback onAnnuler;

  const _ResultatTirage({
    required this.membres,
    required this.estGest,
    required this.onVerrouiller,
    required this.onAnnuler,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CarteTC(
          child: Column(
            children: [
              const Text(
                '🎲 Résultat du tirage',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: AppColors.encre,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Verrouille l\'ordre pour le rendre définitif.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.texteDoux,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ...membres.asMap().entries.map(
          (e) => _LigneOrdre(membre: e.value, rang: e.key + 1, isNouvel: true),
        ),
        const SizedBox(height: 16),
        if (estGest) ...[
          BtnPrincipal(
            label: '🔒 Verrouiller cet ordre',
            onTap: onVerrouiller,
          ),
          const SizedBox(height: 10),
          BtnSecondaire(
            label: '🔄 Relancer',
            onTap: onAnnuler,
          ),
        ],
      ],
    );
  }
}

class _LigneOrdre extends StatelessWidget {
  final Membre membre;
  final int rang;
  final bool isNouvel;

  const _LigneOrdre({
    required this.membre,
    required this.rang,
    this.isNouvel = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isNouvel ? AppColors.fondGestion : AppColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isNouvel ? AppColors.encreDoux : AppColors.lignes,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.encre,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '$rang',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            membre.nom,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 15,
              color: AppColors.texte,
            ),
          ),
          if (rang == 1) ...[
            const Spacer(),
            const Text(
              'Tour 1',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.encreDoux,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
