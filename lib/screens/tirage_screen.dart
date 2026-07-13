import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';

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
              padding: EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: Row(
                children: [
                  LogoTontineClair(),
                  Spacer(),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.arrow_back, size: 16),
                    label: Text(context.tr('retour')),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.encre,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(16),
                children: [
                  Text(
                    context.tr('tirage_certifie'),
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
                    _BandeauVerrouille(data: data, estGest: estGest),
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
                          Icon(
                            Icons.shuffle,
                            size: 48,
                            color: AppColors.encre,
                          ),
                          SizedBox(height: 12),
                          Text(
                            context.tr('tirage'),
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
                            Text(
                              'Seul un gestionnaire peut lancer le tirage.',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.texteDoux,
                              ),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(height: 12),
                    // Ordre actuel
                    Text(
                      context.tr('ordre_actuel'),
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
      titre: context.tr('verrouiller_tirage'),
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
        // IMPORTANT : on conserve les IDs Supabase originaux des membres.
        // Ne PAS réassigner m['id'] = 'm${e.key + 1}' — cela casserait la
        // jointure entre ordre[] et membres[] dans membresActifs.
        newData['membres'] = _membresOrdonnes
            .map((m) => m.toJson())
            .toList();
        // ordre[] = liste des IDs des membres dans l'ordre de passage
        newData['ordre'] = _membresOrdonnes.map((m) => m.id).toList();
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
      final tontineCode = provider.courante?.code ?? widget.code;
      final ordreNoms = _membresOrdonnes.map((m) => m.nom).join(', ');
      SupabaseService.envoyerNotification(
        code: tontineCode,
        type: 'tirage_verrouille',
        titre: '🔒 Tirage verrouillé',
        message: 'L\'ordre de passage est définitif : $ordreNoms',
      );
    }
  }
}

class _BandeauVerrouille extends StatelessWidget {
  final TontineData data;
  final bool estGest;

  const _BandeauVerrouille({required this.data, required this.estGest});

  @override
  Widget build(BuildContext context) {
    // Utilise membresActifs pour respecter l'ordre de passage défini dans ordre[]
    final membresOrdonnes = data.membresActifs;
    final nbTours = data.nbTours;
    final tourActuel = data.tourActuel; // index 0-based
    final beneficiaireId = data.beneficiaireId;

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
              Text('🔒', style: TextStyle(fontSize: 24)),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr('tirage_verrouille'),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: AppColors.succes,
                      ),
                    ),
                    Text(
                      'L\'ordre est définitif. Tour ${data.numerTour} sur $nbTours.',
                      style: const TextStyle(
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
        // ── Carte bénéficiaire actuel ────────────────────────────────────
        if (!data.cycleTermine && !data.cycleEnAttente && beneficiaireId != null) ...[
          Container(
            padding: EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.encre,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Text('🏆', style: TextStyle(fontSize: 20)),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('beneficiaire_tour'),
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                      Text(
                        data.beneficiaireNomOuFallback,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.or.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Tour ${data.numerTour}/$nbTours',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: AppColors.or,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ] else if (data.cycleEnAttente) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.fondConsultation,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(
              children: [
                Text('⏳', style: TextStyle(fontSize: 16)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Aucun tour démarré — le premier tour n\'a pas encore commencé.',
                    style: TextStyle(fontSize: 13, color: AppColors.encre),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 12),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              context.tr('ordre_passage'),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: AppColors.encre,
              ),
            ),
            Text(
              '${membresOrdonnes.length} membre${membresOrdonnes.length > 1 ? 's' : ''}',
              style: const TextStyle(fontSize: 13, color: AppColors.texteDoux),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ...membresOrdonnes.asMap().entries.map(
          (e) => _LigneOrdre(
            membre: e.value,
            rang: e.key + 1,
            // La ligne est "active" si c'est le bénéficiaire du tour actuel
            estBeneficiaireActuel: e.value.id == beneficiaireId,
            // La ligne est "servie" si ce membre a déjà été bénéficiaire
            // (son rang est inférieur au tour actuel, qui est 0-based)
            estServi: !data.cycleTermine && !data.cycleEnAttente && e.key < tourActuel,
          ),
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
  // true = c'est le bénéficiaire du tour actuel (mise en évidence)
  final bool estBeneficiaireActuel;
  // true = ce membre a déjà été servi dans ce cycle
  final bool estServi;

  const _LigneOrdre({
    required this.membre,
    required this.rang,
    this.isNouvel = false,
    this.estBeneficiaireActuel = false,
    this.estServi = false,
  });

  @override
  Widget build(BuildContext context) {
    // Couleurs selon l'état
    final Color couleurFond;
    final Color couleurBordure;
    final Color couleurCercle;
    final Color couleurTexte;

    if (estBeneficiaireActuel) {
      couleurFond = AppColors.or.withValues(alpha: 0.12);
      couleurBordure = AppColors.or.withValues(alpha: 0.6);
      couleurCercle = AppColors.or;
      couleurTexte = AppColors.encre;
    } else if (estServi) {
      couleurFond = AppColors.succesFond;
      couleurBordure = AppColors.succes.withValues(alpha: 0.3);
      couleurCercle = AppColors.succes;
      couleurTexte = AppColors.texteDoux;
    } else if (isNouvel) {
      couleurFond = AppColors.fondGestion;
      couleurBordure = AppColors.encreDoux;
      couleurCercle = AppColors.encre;
      couleurTexte = AppColors.texte;
    } else {
      couleurFond = AppColors.carte;
      couleurBordure = AppColors.lignes;
      couleurCercle = AppColors.encre;
      couleurTexte = AppColors.texte;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: couleurFond,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: couleurBordure),
      ),
      child: Row(
        children: [
          // Cercle avec le numéro de rang
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: couleurCercle,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: estServi
                  ? const Text(
                      '✓',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: Colors.white,
                      ),
                    )
                  : Text(
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  membre.nom,
                  style: TextStyle(
                    fontWeight: estBeneficiaireActuel
                        ? FontWeight.w700
                        : FontWeight.w600,
                    fontSize: 15,
                    color: couleurTexte,
                  ),
                ),
                if (estServi)
                  Text(
                    context.tr('deja_servi'),
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.succes,
                    ),
                  ),
              ],
            ),
          ),
          // Badge bénéficiaire actuel
          if (estBeneficiaireActuel)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.or,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                '🏆 Tour actuel',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.encre,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
