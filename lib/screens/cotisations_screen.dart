import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/echeance_service.dart';
import '../services/pdf_service.dart';
import '../services/paiement_service.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';
import '../services/locale_service.dart';
import '../services/blockchain_service.dart';

import 'paiement_choix_screen.dart';

// ── Bug #6 fix : StatefulWidget pour rechargement depuis Supabase à l'ouverture ──
class CotisationsScreen extends StatefulWidget {
  final String code;

  const CotisationsScreen({super.key, required this.code});

  @override
  State<CotisationsScreen> createState() => _CotisationsScreenState();
}

class _CotisationsScreenState extends State<CotisationsScreen> {
  bool _chargement = false;

  @override
  void initState() {
    super.initState();
    // Recharger depuis Supabase pour avoir la liste membres à jour
    WidgetsBinding.instance.addPostFrameCallback((_) => _recharger());
  }

  Future<void> _recharger() async {
    if (!mounted) return;
    setState(() => _chargement = true);
    try {
      await context.read<TontineProvider>().chargerTontine(widget.code);
    } finally {
      if (mounted) setState(() => _chargement = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;

    if (tontine == null || _chargement) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.encre),
              SizedBox(height: 12),
              Text(
                context.tr('chargement_cotisations'),
                style: TextStyle(color: AppColors.texteDoux),
              ),
            ],
          ),
        ),
      );
    }

    final data = tontine.data;
    final estGest = provider.estDebloque;
    final membres = data.membres;

    // ── SOURCE UNIQUE DE MEMBRES (Bug #membres fix) ───────────────────────
    // data.membresActifs résout ordre[] → membres[] avec double fallback :
    // si ordre[] vide ou IDs divergents → data.membres directement
    // = même liste que l'onglet Membres (toujours 10/10 membres affichés)
    final membresOrdre = data.membresActifs;
    final benefId = data.beneficiaireId; // null si cycleTermine

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
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _recharger,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 20),
                  children: [
                    Text(
                      context.tr('cotisations'),
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 28,
                        color: AppColors.encre,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      data.cycleTermine
                          ? 'Cycle terminé ✔ · ${membres.length} membres servis'
                          : data.cycleEnAttente
                              ? 'En attente de démarrage · ${membres.length} membres'
                              : 'Tour ${data.numerTour} sur ${data.nbTours} · ${Formatters.montant(data.montant, devise: data.devise)} par membre · ${data.nbPayes}/${membres.length} payés',
                      style: const TextStyle(fontSize: 14, color: AppColors.texteDoux),
                    ),
                    // Bandeau échéance : affiché toujours (calcul auto si non définie)
                    SizedBox(height: 8),
                    _BandeauEcheance(
                      echeance: data.echeance,
                      periode: data.periode,
                    ),
                    SizedBox(height: 16),

                    // Bug #6 fix : afficher un message si liste vide
                    if (membresOrdre.isEmpty)
                      Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            context.tr('aucun_membre'),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.texteDoux),
                          ),
                        ),
                      )
                    else
                      // Liste dans l'ordre de passage (ordre[]) — badge BÉNÉF. indépendant de paye
                      ...membresOrdre.asMap().entries.map(
                        (e) {
                          final m = e.value;
                          return _CarteMembre(
                            membre: m,
                            rang: e.key + 1,
                            montant: data.montant,
                            estGest: estGest,
                            echeance: data.echeance,
                            tontine: tontine,
                            gestActifNom: provider.gestActifNom,
                            // Badge BÉNÉFICIAIRE : indépendant du statut paye
                            isBeneficiaire: !data.cycleTermine && m.id == benefId,
                            onToggle: estGest && !data.cycleTermine
                                ? () => _togglePaiement(context, provider, tontine, m)
                                : null,
                            // ── Bouton "Payer" : visible pour TOUT membre non-payé
                            // en tontine Premium + cycle non terminé.
                            // N'exige PAS le PIN gestionnaire → accessible à tous.
                            onPayer: tontine.isPremium && !m.paye && !data.cycleTermine
                                ? () async {
                                    final result = await Navigator.push<Map<String,String>>(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => PaiementChoixScreen(
                                          code:     tontine.code,
                                          typeFlux: 'cotisation',
                                          membre:   m,
                                          montant:  data.montant,
                                        ),
                                      ),
                                    );
                                    if (result != null && context.mounted) {
                                      await _payerCotisationMembre(
                                        context, provider, tontine, m, result,
                                      );
                                    }
                                  }
                                : null,
                            // ── Bouton "Approuver" (gest, cotisation en_attente)
                            // Bloqué si le gestionnaire est le déclarant.
                            onApprouver: tontine.isPremium &&
                                    m.paiementEnAttente &&
                                    estGest &&
                                    !data.cycleTermine &&
                                    m.paiementDeclareParGest != provider.gestActifNom
                                ? () => _approuverCotisation(context, provider, tontine, m)
                                : null,
                            // ── Bouton "Annuler" (gest, cotisation en_attente ou approuvée)
                            onAnnulerPremium: tontine.isPremium &&
                                    m.paye &&
                                    estGest &&
                                    !data.cycleTermine
                                ? () => _annulerCotisation(context, provider, tontine, m)
                                : null,
                            onEnvoyerRecu: () => _envoyerRecu(context, tontine, m),
                            onRelancer: () => _relancer(context, tontine, m),
                            onGenererPdf: estGest && m.paye
                                ? () => _genererRecuPdf(context, tontine, m)
                                : null,
                          );
                        },
                      ),
                    SizedBox(height: 16),
                    // Partage récap WhatsApp (accessible à tous)
                    _BoutonRecapWhatsApp(tontine: tontine),
                    if (estGest) ...[
                      SizedBox(height: 10),
                      BtnWhatsApp(
                        label: context.tr('relancer_retardataires'),
                        onTap: () => _relancerTous(context, tontine),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// [methodePrechoisie] : si non null (vient de PaiementChoixScreen), on saute
  /// la bottom-sheet de sélection de méthode pour éviter le double-choix.
  Future<void> _togglePaiement(
    BuildContext context,
    TontineProvider provider,
    dynamic tontine,
    Membre membre, {
    String? methodePrechoisie,
    String? referencePrechoisie,
  }) async {
    if (!provider.estDebloque) return;

    final data = tontine.data;
    final nowStr = DateTime.now().toIso8601String();
    final ref = referencePrechoisie ?? Formatters.genererReference();

    if (!membre.paye) {
      // Marquer payé — si la méthode a déjà été choisie (via PaiementChoixScreen),
      // on la réutilise directement ; sinon on affiche la bottom-sheet.
      final methode = methodePrechoisie ??
          await _choisirMethode(context, devise: data.devise);
      if (methode == null || !context.mounted) return;

      final ok = await afficherModalePin(
        context,
        titre: context.tr('confirmer_paiement'),
        sousTitre: context.tr('confirmer_pin'),
        recap: [
          (label: context.tr('membre'), valeur: membre.nom),
          (label: context.tr('montant'), valeur: Formatters.montant(data.montant, devise: data.devise)),
          (label: context.tr('methode_paiement'), valeur: Formatters.methodePaiement(methode)),
          (label: context.tr('tour'), valeur: 'N° ${data.numerTour}'),
        ],
        onValider: (pin) async {
          final newData = data.toJson();
          final membres = List<Map<String, dynamic>>.from(
            (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
          );
          final idx = membres.indexWhere((m) => m['id'] == membre.id);
          if (idx >= 0) {
            membres[idx]['paye'] = true;
            membres[idx]['datePaiement'] = nowStr;
            membres[idx]['methodePaiement'] = methode;
            membres[idx]['referencePaiement'] = ref;
            // Enregistrer qui a validé le paiement
            if (provider.gestActifNom != null) {
              membres[idx]['validePar'] = provider.gestActifNom;
            }
          }
          newData['membres'] = membres;

          // ── Mettre à jour paiements{} — source de vérité pour membre.paye ──
          final paiements = Map<String, dynamic>.from(
            (newData['paiements'] as Map<String, dynamic>?) ?? {},
          );
          paiements[membre.id] = {
            'date': nowStr,
            'methode': methode,
            'reference': ref,
            'montant': data.montant,
            if (provider.gestActifNom != null) 'validePar': provider.gestActifNom,
          };
          newData['paiements'] = paiements;

          // ── Caisse : ajouter l'apport ─────────────────────────────────────
          final caisseMap = newData['caisse'];
          final caisse = List<Map<String, dynamic>>.from(
            caisseMap is Map<String, dynamic>
                ? ((caisseMap['mouvements'] as List<dynamic>?)
                        ?.cast<Map<String, dynamic>>() ?? [])
                : caisseMap is List
                    ? caisseMap.cast<Map<String, dynamic>>()
                    : [],
          );
          caisse.add({
            'id': '${ref}C',
            'type': 'cotisation',
            'montant': data.montant,
            'description': 'Cotisation ${membre.nom} — Tour ${data.numerTour}',
            'gestionnaire': provider.gestActifNom ?? '',
            'date': nowStr,
            'reference': ref,
          });
          newData['caisse'] = {'mouvements': caisse};

          final journal = List<Map<String, dynamic>>.from(
            (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
          );
          journal.insert(0, {
            'quoi': 'PAIEMENT_${membre.nom}_TOUR_${data.numerTour}',
            'gestionnaire': provider.gestActifNom ?? '',
            'quand': nowStr,
            'reference': ref,
          });
          newData['journal'] = journal;

          return provider.ecrire(newData, pin);
        },
      );

      // ── BLOCKCHAIN : cotisation manuelle validée par gestionnaire (non-bloquant) ─
      if (ok == true) {
        BlockchainService.enregistrerCotisation(
          tontineCode: provider.courante!.code,
          membreId   : membre.id,
          membreNom  : membre.nom,
          montantXof : data.montant,
          refInterne : ref,
        ).catchError((e) {
          if (kDebugMode) debugPrint('[Blockchain] cotisation_manuelle erreur: $e');
          return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
        });
      }
      // ─────────────────────────────────────────────────────────────────────────────

      if (ok == true && context.mounted) {
        afficherToast(context, 'Paiement de ${membre.nom} enregistré !');
        // Notification push à tous les membres
        final lang = Provider.of<LocaleService>(context, listen: false).langue.code;
        final t = SupabaseService.notifTexte('cotisation', lang, vars: {'nom': membre.nom});
        SupabaseService.envoyerNotification(
          code: provider.courante!.code,
          type: 'cotisation',
          titre: t['titre']!,
          message: t['message']!,
          donneesExtra: {'membre': membre.nom},
        );

        // Bug #6 : proposer le reçu WhatsApp après validation
        final membreActualise = Membre(
          id: membre.id,
          nom: membre.nom,
          tel: membre.tel,
          role: membre.role,
          paye: true,
          datePaiement: nowStr,
          methodePaiement: methode,
          referencePaiement: ref,
          score: membre.score,
        );
        if (context.mounted) {
          await _proposerRecuPostPaiement(context, tontine, membreActualise, ref, methode);
        }
      }
    } else {
      // Annuler le paiement
      String refAnnuleCapture = '';
      final ok = await afficherModalePin(
        context,
        titre: context.tr('annuler_paiement'),
        sousTitre: context.tr('annuler_paiement'),
        recap: [
          (label: 'Membre', valeur: membre.nom),
          (label: 'Montant', valeur: Formatters.montant(data.montant, devise: data.devise)),
        ],
        onValider: (pin) async {
          final newData = data.toJson();
          final now = DateTime.now().toIso8601String();

          // ── 1. Marquer le membre comme non-payé ───────────────────────────
          final membres = List<Map<String, dynamic>>.from(
            (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
          );
          final refAnnule = membres
              .firstWhere((m) => m['id'] == membre.id, orElse: () => {})['referencePaiement'] as String? ?? '?';
          refAnnuleCapture = refAnnule;
          final idx = membres.indexWhere((m) => m['id'] == membre.id);
          if (idx >= 0) {
            membres[idx]['paye'] = false;
            membres[idx].remove('datePaiement');
            membres[idx].remove('methodePaiement');
            membres[idx].remove('referencePaiement');
          }
          newData['membres'] = membres;

          // ── Retirer de paiements{} — source de vérité pour membre.paye ────
          final paiements = Map<String, dynamic>.from(
            (newData['paiements'] as Map<String, dynamic>?) ?? {},
          );
          paiements.remove(membre.id);
          newData['paiements'] = paiements;

          // ── 2. Contre-passer la caisse (sortie du montant) ────────────────
          final caisseMap = newData['caisse'];
          final caisse = List<Map<String, dynamic>>.from(
            caisseMap is Map<String, dynamic>
                ? ((caisseMap['mouvements'] as List<dynamic>?)
                        ?.cast<Map<String, dynamic>>() ?? [])
                : caisseMap is List
                    ? caisseMap.cast<Map<String, dynamic>>()
                    : [],
          );
          caisse.add({
            'id': 'ANNUL_${refAnnule}_C',
            'type': 'depense',
            'montant': -data.montant,
            'description': 'Annulation cotisation ${membre.nom} — Tour ${data.numerTour}',
            'gestionnaire': provider.gestActifNom ?? '',
            'date': now,
            'reference': 'ANNUL_$refAnnule',
          });
          newData['caisse'] = {'mouvements': caisse};

          // ── 3. Inscrire dans le journal public ────────────────────────────
          final journal = List<Map<String, dynamic>>.from(
            (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
          );
          journal.insert(0, {
            'quoi': 'ANNULATION_PAIEMENT — ${membre.nom} — Tour ${data.numerTour} — Réf: $refAnnule',
            'gestionnaire': provider.gestActifNom ?? '',
            'quand': now,
            'reference': 'ANNUL_$refAnnule',
          });
          newData['journal'] = journal;

          return provider.ecrire(newData, pin);
        },
      );

      // ── BLOCKCHAIN : annulation cotisation (non-bloquant) ─────────────────
      if (ok == true) {
        BlockchainService.enregistrerAnnulationCotisation(
          tontineCode: provider.courante!.code,
          membreId   : membre.id,
          membreNom  : membre.nom,
          montantXof : data.montant,
          numerTour  : data.numerTour,
          refInterne : 'ANNUL_$refAnnuleCapture',
        ).catchError((e) {
          if (kDebugMode) debugPrint('[Blockchain] annulation_cotisation erreur: $e');
          return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
        });
      }
      // ─────────────────────────────────────────────────────────────────────

      if (ok == true && context.mounted) {
        afficherToast(context, 'Paiement annulé et journal mis à jour.');
        // Notification push à tous les membres
        final langCode = Provider.of<LocaleService>(context, listen: false).langue.code;
        final tNotif = SupabaseService.notifTexte(
          'annulation_cotisation',
          langCode,
          vars: {
            'nom': membre.nom,
            'tour': data.numerTour.toString(),
          },
        );
        SupabaseService.envoyerNotification(
          code: provider.courante!.code,
          type: 'annulation_cotisation',
          titre: tNotif['titre']!,
          message: tNotif['message']!,
          donneesExtra: {'membre': membre.nom},
        );
      }
    }
  }

  // ── Paiement auto-déclaré par un membre — statut EN_ATTENTE ────────────────
  /// Accessible à TOUS les membres (Premium), cycle non terminé.
  /// Flux : PaiementChoixScreen → ecrireSansPin() → statut='en_attente'.
  /// La caisse est créditée UNIQUEMENT quand un gestionnaire approuve.
  /// L'approbation / annulation est réservée au gestionnaire.
  Future<void> _payerCotisationMembre(
    BuildContext context,
    TontineProvider provider,
    dynamic tontine,
    Membre membre,
    Map<String, String> paiementResult,
  ) async {
    final data      = tontine.data;
    final methode   = paiementResult['methode']   ?? 'mobile_money';
    final refSaisie = paiementResult['reference'] ?? '';
    final nowStr    = DateTime.now().toIso8601String();
    final ref       = refSaisie.isNotEmpty ? refSaisie : Formatters.genererReference();

    // ── Détecter si c'est un gestionnaire qui déclare ──────────────────
    final declareParGest = provider.estDebloque ? provider.gestActifNom : null;

    // ── Construire le nouveau JSON ──────────────────────────────────────
    final newData = data.toJson();

    // 1. Marquer le membre payé dans membres[] (paye=true pour affichage)
    final membres = List<Map<String, dynamic>>.from(
      (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
    );
    final idx = membres.indexWhere((m) => m['id'] == membre.id);
    if (idx >= 0) {
      membres[idx]['paye']              = true;
      membres[idx]['datePaiement']      = nowStr;
      membres[idx]['methodePaiement']   = methode;
      membres[idx]['referencePaiement'] = ref;
      if (declareParGest != null) membres[idx]['paiementDeclareParGest'] = declareParGest;
    }
    newData['membres'] = membres;

    // 2. paiements{} — source de vérité — statut 'en_attente' (pas encore approuvé)
    final paiements = Map<String, dynamic>.from(
      (newData['paiements'] as Map<String, dynamic>?) ?? {},
    );
    paiements[membre.id] = {
      'date'      : nowStr,
      'methode'   : methode,
      'reference' : ref,
      'montant'   : data.montant,
      'statut'    : 'en_attente',           // ← NOUVEAU : en attente d'approbation
      'autoDeclare': declareParGest == null, // true si déclaré par membre ordinaire
      if (declareParGest != null) 'declareParGest': declareParGest,
    };
    newData['paiements'] = paiements;

    // 3. CAISSE : NON créditée ici — caisse créditée UNIQUEMENT à l'approbation

    // 4. Journal public — déclaration en attente
    final journal = List<Map<String, dynamic>>.from(
      (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
    );
    journal.insert(0, {
      'quoi'       : 'DECLARATION_EN_ATTENTE — ${membre.nom} — Tour ${data.numerTour} — ${Formatters.methodePaiement(methode)} — Réf: $ref',
      'gestionnaire': declareParGest ?? membre.nom,
      'quand'      : nowStr,
      'reference'  : ref,
    });
    newData['journal'] = journal;

    // ── Écrire en DB sans PIN ────────────────────────────────────────────
    final ok = await provider.ecrireSansPin(
      newData,
      membreId               : membre.id,
      membreNom              : membre.nom,
      montantXof             : data.montant,
      typeOperationBlockchain: 'cotisation_en_attente',
      refInterne             : ref,
    );

    if (!context.mounted) return;

    if (ok) {
      afficherToast(context, '⏳ Cotisation de ${membre.nom} en attente d\'approbation.');

      // Notification push tous membres
      final lang = Provider.of<LocaleService>(context, listen: false).langue.code;
      final t = SupabaseService.notifTexte('cotisation', lang, vars: {'nom': membre.nom});
      SupabaseService.envoyerNotification(
        code        : provider.courante!.code,
        type        : 'cotisation',
        titre       : t['titre']!,
        message     : '${membre.nom} a déclaré sa cotisation — en attente d\'approbation',
        donneesExtra: {'membre': membre.nom, 'statut': 'en_attente'},
      );
    } else {
      afficherToast(context,
        'Erreur lors de l\'enregistrement. Réessayez.',
        estErreur: true,
      );
    }
  }

  // ── Approuver une cotisation (gestionnaire uniquement) ──────────────────────
  /// Prérequis : paiements[membreId].statut == 'en_attente'
  /// Effet : PIN gestionnaire → caisse++ + journal + blockchain + notif
  /// Restriction : un gestionnaire ne peut PAS approuver sa propre déclaration.
  Future<void> _approuverCotisation(
    BuildContext context,
    TontineProvider provider,
    dynamic tontine,
    Membre membre,
  ) async {
    if (!provider.estDebloque) return;

    final data   = tontine.data;
    final nowStr = DateTime.now().toIso8601String();
    final ref    = membre.referencePaiement ?? Formatters.genererReference();
    final methode = membre.methodePaiement ?? 'especes';

    // ── Garde : un gestionnaire ne peut pas approuver sa propre déclaration ──
    if (membre.paiementDeclareParGest != null &&
        membre.paiementDeclareParGest == provider.gestActifNom) {
      afficherToast(context,
        '⚠️ Vous ne pouvez pas approuver votre propre déclaration.',
        estErreur: true,
      );
      return;
    }

    String refApprobCapture = ref;

    final ok = await afficherModalePin(
      context,
      titre: 'Approuver la cotisation',
      sousTitre: 'PIN gestionnaire requis pour approuver',
      recap: [
        (label: 'Membre',   valeur: membre.nom),
        (label: 'Montant',  valeur: Formatters.montant(data.montant, devise: data.devise)),
        (label: 'Méthode',  valeur: Formatters.methodePaiement(methode)),
        (label: 'Réf.',     valeur: ref),
        (label: 'Tour',     valeur: 'N° ${data.numerTour}'),
        if (membre.paiementDeclareParGest != null)
          (label: 'Déclaré par', valeur: membre.paiementDeclareParGest!),
      ],
      onValider: (pin) async {
        final newData = data.toJson();

        // 1. Mettre à jour membres[] — valider le paiement
        final mbrs = List<Map<String, dynamic>>.from(
          (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
        );
        final idx = mbrs.indexWhere((m) => m['id'] == membre.id);
        if (idx >= 0) {
          mbrs[idx]['validePar']            = provider.gestActifNom;
          mbrs[idx]['paiementDeclareParGest'] = membre.paiementDeclareParGest;
        }
        newData['membres'] = mbrs;

        // 2. paiements{} — passer statut à 'approuve'
        final paiements = Map<String, dynamic>.from(
          (newData['paiements'] as Map<String, dynamic>?) ?? {},
        );
        final existant = Map<String, dynamic>.from(
          (paiements[membre.id] as Map<String, dynamic>?) ?? {},
        );
        existant['statut']          = 'approuve';
        existant['approuvePar']     = provider.gestActifNom;
        existant['dateApprobation'] = nowStr;
        paiements[membre.id]        = existant;
        newData['paiements']        = paiements;

        // 3. CAISSE : créditer maintenant (approbation = réception effective)
        final caisseMap = newData['caisse'];
        final caisse = List<Map<String, dynamic>>.from(
          caisseMap is Map<String, dynamic>
              ? ((caisseMap['mouvements'] as List<dynamic>?)
                      ?.cast<Map<String, dynamic>>() ?? [])
              : caisseMap is List
                  ? caisseMap.cast<Map<String, dynamic>>()
                  : [],
        );
        final refCaisse = 'APPRO_$ref';
        refApprobCapture = refCaisse;
        caisse.add({
          'id'          : '${refCaisse}C',
          'type'        : 'cotisation',
          'montant'     : data.montant,
          'description' : 'Approbation cotisation ${membre.nom} — Tour ${data.numerTour}',
          'gestionnaire': provider.gestActifNom ?? '',
          'date'        : nowStr,
          'reference'   : refCaisse,
        });
        newData['caisse'] = {'mouvements': caisse};

        // 4. Journal
        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        journal.insert(0, {
          'quoi'       : 'APPROBATION_COTISATION — ${membre.nom} — Tour ${data.numerTour} — Réf: $ref — Approuvé par: ${provider.gestActifNom}',
          'gestionnaire': provider.gestActifNom ?? '',
          'quand'      : nowStr,
          'reference'  : refCaisse,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    // ── BLOCKCHAIN : approbation cotisation (non-bloquant) ──────────────
    if (ok == true) {
      BlockchainService.enregistrerCotisation(
        tontineCode: provider.courante!.code,
        membreId   : membre.id,
        membreNom  : membre.nom,
        montantXof : data.montant,
        refInterne : refApprobCapture,
      ).catchError((e) {
        if (kDebugMode) debugPrint('[Blockchain] approbation_cotisation erreur: $e');
        return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
      });
    }

    if (ok == true && context.mounted) {
      afficherToast(context, '✅ Cotisation de ${membre.nom} approuvée — caisse créditée !');

      // Notification push
      SupabaseService.envoyerNotification(
        code        : provider.courante!.code,
        type        : 'approbation_cotisation',
        titre       : '✅ Cotisation approuvée',
        message     : 'La cotisation de ${membre.nom} a été approuvée par ${provider.gestActifNom}',
        donneesExtra: {'membre': membre.nom, 'statut': 'approuve'},
      );

      // Proposer reçu après approbation
      final membreActualise = Membre(
        id               : membre.id,
        nom              : membre.nom,
        tel              : membre.tel,
        role             : membre.role,
        paye             : true,
        datePaiement     : membre.datePaiement,
        methodePaiement  : methode,
        referencePaiement: ref,
        score            : membre.score,
        validePar        : provider.gestActifNom,
      );
      if (context.mounted) {
        await _proposerRecuPostPaiement(context, tontine, membreActualise, ref, methode);
      }
    }
  }

  // ── Annuler une cotisation (gestionnaire uniquement) ────────────────────────
  /// Fonctionne sur statut 'en_attente' ET 'approuve'.
  /// Si approuvée : contre-passe la caisse.
  Future<void> _annulerCotisation(
    BuildContext context,
    TontineProvider provider,
    dynamic tontine,
    Membre membre,
  ) async {
    if (!provider.estDebloque) return;

    final data    = tontine.data;
    final nowStr  = DateTime.now().toIso8601String();
    final refOrig = membre.referencePaiement ?? '?';
    final estApprouve = membre.paiementApprouve;

    String refAnnulCapture = '';

    final ok = await afficherModalePin(
      context,
      titre: 'Annuler la cotisation',
      sousTitre: estApprouve
          ? '⚠️ La caisse sera débitée. PIN requis.'
          : 'PIN gestionnaire requis.',
      recap: [
        (label: 'Membre',   valeur: membre.nom),
        (label: 'Montant',  valeur: Formatters.montant(data.montant, devise: data.devise)),
        (label: 'Statut',   valeur: estApprouve ? 'Approuvée ↩ contre-passée' : 'En attente'),
        (label: 'Réf.',     valeur: refOrig),
        (label: 'Tour',     valeur: 'N° ${data.numerTour}'),
      ],
      onValider: (pin) async {
        final newData = data.toJson();

        // 1. Retirer de membres[]
        final mbrs = List<Map<String, dynamic>>.from(
          (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
        );
        final idx = mbrs.indexWhere((m) => m['id'] == membre.id);
        if (idx >= 0) {
          mbrs[idx]['paye'] = false;
          mbrs[idx].remove('datePaiement');
          mbrs[idx].remove('methodePaiement');
          mbrs[idx].remove('referencePaiement');
          mbrs[idx].remove('validePar');
          mbrs[idx].remove('paiementDeclareParGest');
        }
        newData['membres'] = mbrs;

        // 2. Retirer de paiements{}
        final paiements = Map<String, dynamic>.from(
          (newData['paiements'] as Map<String, dynamic>?) ?? {},
        );
        paiements.remove(membre.id);
        newData['paiements'] = paiements;

        // 3. Caisse : contre-passer SEULEMENT si était approuvée
        if (estApprouve) {
          final caisseMap = newData['caisse'];
          final caisse = List<Map<String, dynamic>>.from(
            caisseMap is Map<String, dynamic>
                ? ((caisseMap['mouvements'] as List<dynamic>?)
                        ?.cast<Map<String, dynamic>>() ?? [])
                : caisseMap is List
                    ? caisseMap.cast<Map<String, dynamic>>()
                    : [],
          );
          final refAnnul = 'ANNUL_$refOrig';
          refAnnulCapture = refAnnul;
          caisse.add({
            'id'          : 'ANNUL_${refOrig}_C',
            'type'        : 'depense',
            'montant'     : -data.montant,
            'description' : 'Annulation cotisation approuvée ${membre.nom} — Tour ${data.numerTour}',
            'gestionnaire': provider.gestActifNom ?? '',
            'date'        : nowStr,
            'reference'   : refAnnul,
          });
          newData['caisse'] = {'mouvements': caisse};
        } else {
          refAnnulCapture = 'ANNUL_$refOrig';
        }

        // 4. Journal
        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        journal.insert(0, {
          'quoi'       : 'ANNULATION_COTISATION — ${membre.nom} — Tour ${data.numerTour} — Réf: $refOrig — Par: ${provider.gestActifNom}${estApprouve ? ' (caisse contre-passée)' : ' (en attente annulée)'}',
          'gestionnaire': provider.gestActifNom ?? '',
          'quand'      : nowStr,
          'reference'  : refAnnulCapture,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    // ── BLOCKCHAIN : annulation (non-bloquant) ───────────────────────────
    if (ok == true) {
      BlockchainService.enregistrerAnnulationCotisation(
        tontineCode: provider.courante!.code,
        membreId   : membre.id,
        membreNom  : membre.nom,
        montantXof : data.montant,
        numerTour  : data.numerTour,
        refInterne : refAnnulCapture,
      ).catchError((e) {
        if (kDebugMode) debugPrint('[Blockchain] annulation_cotisation erreur: $e');
        return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
      });
    }

    if (ok == true && context.mounted) {
      afficherToast(context,
        estApprouve
          ? 'Cotisation annulée — caisse débitée.'
          : 'Déclaration annulée.',
      );

      // Notification push
      SupabaseService.envoyerNotification(
        code        : provider.courante!.code,
        type        : 'annulation_cotisation',
        titre       : '❌ Cotisation annulée',
        message     : 'La cotisation de ${membre.nom} (Tour ${data.numerTour}) a été annulée par ${provider.gestActifNom}',
        donneesExtra: {'membre': membre.nom},
      );
    }
  }

  // ── Bug #6 : proposer reçu (WhatsApp + PDF) après validation paiement ────
  Future<void> _proposerRecuPostPaiement(
    BuildContext context,
    dynamic tontine,
    Membre membre,
    String ref,
    String methode,
  ) async {
    final data = tontine.data;
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          '📲 Envoyer le reçu ?',
          style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre),
        ),
        content: Text(
          'Paiement de ${membre.nom} enregistré (${Formatters.montant(data.montant, devise: data.devise)}).\n\nComment souhaitez-vous partager le reçu ?',
          style: TextStyle(color: AppColors.texte),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.tr('ignorer')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (context.mounted) {
                await _genererRecuPdfInterne(
                  context,
                  tontine,
                  membre,
                  ref,
                  methode,
                  DateTime.now().toIso8601String(),
                );
              }
            },
            child: const Text(
              '📄 PDF',
              style: TextStyle(color: AppColors.encre, fontWeight: FontWeight.w700),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (context.mounted) {
                _envoyerRecuDirect(context, tontine, membre, ref, methode, DateTime.now().toIso8601String());
              }
            },
            child: const Text(
              'WhatsApp',
              style: TextStyle(color: AppColors.whatsapp, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  void _envoyerRecuDirect(
    BuildContext context,
    dynamic tontine,
    Membre membre,
    String ref,
    String methode,
    String dateStr,
  ) {
    final data = tontine.data;
    final msg = Uri.encodeComponent(
      '✅ Reçu de cotisation — TontineClair\n'
      'Tontine : ${data.nom}\n'
      'Membre : ${membre.nom}\n'
      'Montant : ${Formatters.montant(data.montant, devise: data.devise)}\n'
      'Tour : ${data.numerTour}\n'
      'Date : ${Formatters.dateHeure(DateTime.tryParse(dateStr))}\n'
      'Méthode : ${Formatters.methodePaiement(methode)}\n'
      'Réf. : $ref\n'
      'Code tontine : ${tontine.code}',
    );
    final tel = (membre.tel ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
    final url = tel.isNotEmpty
        ? Uri.parse('https://wa.me/$tel?text=$msg')
        : Uri.parse('https://wa.me/?text=$msg');
    launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> _genererRecuPdfInterne(
    BuildContext context,
    dynamic tontine,
    Membre membre,
    String ref,
    String methode,
    String dateStr,
  ) async {
    try {
      await PdfService.exporterRecuCotisation(
        tontine: tontine,
        membre: membre,
        ref: ref,
        methode: methode,
        dateStr: dateStr,
        langueCode: Provider.of<LocaleService>(context, listen: false).langue.code,
      );
    } catch (e) {
      if (context.mounted) {
        afficherToast(context, 'Erreur PDF : $e', estErreur: true);
      }
    }
  }

  Future<String?> _choisirMethode(BuildContext context, {String? devise}) async {
    final methodes = PaiementService.methodesPour(devise);
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.fondPapier,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.85,
        expand: false,
        builder: (_, scrollCtrl) => Column(
          children: [
            // Poignée
            Container(
              margin: EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.lignes,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('methode_paiement'),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                        color: AppColors.encre,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close, size: 20, color: AppColors.texteDoux),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                itemCount: methodes.length,
                itemBuilder: (_, i) {
                  final m = methodes[i];
                  return ListTile(
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: AppColors.encre.withValues(alpha: 0.07),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(m.emoji, style: const TextStyle(fontSize: 18)),
                      ),
                    ),
                    title: Text(
                      m.label,
                      style: const TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: 15,
                        color: AppColors.encre,
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 18, color: AppColors.texteDoux),
                    onTap: () => Navigator.pop(ctx, m.code),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _envoyerRecu(BuildContext context, dynamic tontine, Membre membre) {
    if (!membre.paye) return;
    final data = tontine.data;
    final msg = Uri.encodeComponent(
      '✅ Reçu de cotisation — TontineClair\n'
      'Tontine : ${data.nom}\n'
      'Membre : ${membre.nom}\n'
      'Montant : ${Formatters.montant(data.montant, devise: data.devise)}\n'
      'Tour : ${data.numerTour}\n'
      'Date : ${Formatters.dateHeure(membre.datePaiement != null ? DateTime.tryParse(membre.datePaiement!) : null)}\n'
      'Méthode : ${Formatters.methodePaiement(membre.methodePaiement ?? '')}\n'
      'Réf. : ${membre.referencePaiement ?? ''}\n'
      'Code tontine : ${tontine.code}',
    );
    final tel = (membre.tel ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
    final url = tel.isNotEmpty
        ? Uri.parse('https://wa.me/$tel?text=$msg')
        : Uri.parse('https://wa.me/?text=$msg');
    launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> _genererRecuPdf(
    BuildContext context,
    dynamic tontine,
    Membre membre,
  ) async {
    if (!membre.paye) {
      afficherToast(context, 'Le membre n\'a pas encore payé.', estErreur: true);
      return;
    }
    try {
      await PdfService.exporterRecuCotisation(
        tontine: tontine,
        membre: membre,
        ref: membre.referencePaiement ?? '—',
        methode: membre.methodePaiement ?? 'especes',
        dateStr: membre.datePaiement ?? DateTime.now().toIso8601String(),
        langueCode: Provider.of<LocaleService>(context, listen: false).langue.code,
      );
    } catch (e) {
      if (context.mounted) {
        afficherToast(context, 'Erreur PDF : $e', estErreur: true);
      }
    }
  }

  void _relancer(BuildContext context, dynamic tontine, Membre membre) {
    if (membre.paye) return;
    final data = tontine.data;
    final msg = Uri.encodeComponent(
      '⏰ Rappel de cotisation — TontineClair\n'
      'Bonjour ${membre.nom},\n'
      'Ta cotisation de ${Formatters.montant(data.montant, devise: data.devise)} pour la tontine "${data.nom}" (tour ${data.numerTour}) est en attente.\n'
      '${data.echeance != null ? 'Échéance : ${Formatters.dateFormatee(DateTime.tryParse(data.echeance!))}\n' : ''}'
      'Code tontine : ${tontine.code}',
    );
    final tel = (membre.tel ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
    final url = tel.isNotEmpty
        ? Uri.parse('https://wa.me/$tel?text=$msg')
        : Uri.parse('https://wa.me/?text=$msg');
    launchUrl(url, mode: LaunchMode.externalApplication);
  }

  void _relancerTous(BuildContext context, dynamic tontine) {
    final data = tontine.data;
    final retardataires =
        data.membres.where((m) => !m.paye).map((m) => m.nom).join(', ');
    if (retardataires.isEmpty) {
      afficherToast(context, 'Tous les membres ont payé !');
      return;
    }
    final msg = Uri.encodeComponent(
      '⏰ Rappel de cotisation — TontineClair\n'
      'Tontine : ${data.nom} (tour ${data.numerTour})\n'
      'Cotisation en attente : $retardataires\n'
      'Montant : ${Formatters.montant(data.montant, devise: data.devise)}\n'
      '${data.echeance != null ? 'Échéance : ${Formatters.dateFormatee(DateTime.tryParse(data.echeance!))}\n' : ''}',
    );
    launchUrl(
      Uri.parse('https://wa.me/?text=$msg'),
      mode: LaunchMode.externalApplication,
    );
  }
}

// ─── Bouton Récap WhatsApp (même logique que DashboardScreen) ─────────────────
class _BoutonRecapWhatsApp extends StatelessWidget {
  final dynamic tontine; // Tontine

  const _BoutonRecapWhatsApp({required this.tontine});

  String _construireMessage() {
    final data = tontine.data;
    final membres = data.membres;
    final cycleTermine = data.cycleTermine;

    if (cycleTermine) {
      final buf = StringBuffer();
      buf.writeln('✅ Cycle terminé ! Chaque membre a été servi.\n');
      buf.writeln('🏦 TONTINE — ${data.nom}');
      for (final h in data.historique) {
        final tour = (h['tour'] as num?)?.toInt() ?? '?';
        final benef = h['beneficiaire'] as String? ?? h['membre'] as String? ?? '?';
        final montant = (h['totalRecu'] as num?)?.toInt()
            ?? (h['total'] as num?)?.toInt()
            ?? membres.length * data.montant;
        final dateRaw = h['date'];
        DateTime? dateD;
        if (dateRaw is int) {
          dateD = DateTime.fromMillisecondsSinceEpoch(dateRaw);
        } else if (dateRaw is String && dateRaw.isNotEmpty) {
          dateD = DateTime.tryParse(dateRaw);
        }
        buf.writeln('• Tour $tour → $benef — ${Formatters.montant(montant, devise: data.devise)}'
            '${dateD != null ? ' (${Formatters.dateFormatee(dateD)})' : ''}');
      }
      return buf.toString().trim();
    }

    final payes = membres.where((m) => m.paye).toList();
    final nonPayes = membres.where((m) => !m.paye).toList();
    final beneficiaire = data.beneficiaire;
    final montantTotal = payes.length * data.montant;
    final totalAttendu = membres.length * data.montant;

    final buf = StringBuffer();
    buf.writeln('🏦 TONTINE — ${data.nom}');
    buf.writeln('Tour ${data.numerTour}/${data.nbTours} · ${Formatters.montant(data.montant, devise: data.devise)} par membre');
    if (data.echeance != null) {
      final echD = DateTime.tryParse(data.echeance!);
      if (echD != null) buf.writeln('📅 Échéance : ${Formatters.dateFormatee(echD)}');
    }
    if (beneficiaire != null) {
      buf.writeln('🏆 Bénéficiaire du tour : ${beneficiaire.nom} — reçoit ${Formatters.montant(montantTotal, devise: data.devise)}');
    } else {
      buf.writeln('🏆 Bénéficiaire du tour : Bénéficiaire non encore désigné');
    }
    buf.writeln('');
    buf.writeln('✅ Ont cotisé (${payes.length}/${membres.length})');
    for (final m in payes) { buf.writeln('  ✓ ${m.nom}'); }
    if (nonPayes.isNotEmpty) {
      buf.writeln('');
      buf.writeln('⏳ En attente (${nonPayes.length}/${membres.length})');
      for (final m in nonPayes) { buf.writeln('  · ${m.nom}'); }
    }
    buf.writeln('');
    buf.writeln('💰 Cagnotte : ${Formatters.montant(montantTotal, devise: data.devise)} / ${Formatters.montant(totalAttendu, devise: data.devise)}');
    buf.writeln('');
    buf.writeln('Suivi en direct sur TontineClair — code ${tontine.code}');
    return buf.toString().trim();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        onPressed: () async {
          final msg = Uri.encodeComponent(_construireMessage());
          final urlApp = Uri.parse('whatsapp://send?text=$msg');
          final urlWeb = Uri.parse('https://wa.me/?text=$msg');
          bool ouvert = false;
          // Tentative 1 : app WhatsApp native (sans canLaunchUrl — non fiable Android 11+)
          try {
            ouvert = await launchUrl(urlApp, mode: LaunchMode.externalApplication);
          } catch (_) {}
          // Tentative 2 : wa.me (navigateur / WhatsApp web)
          if (!ouvert) {
            try {
              ouvert = await launchUrl(urlWeb, mode: LaunchMode.externalApplication);
            } catch (_) {}
          }
          // Fallback : copie dans le presse-papiers
          if (!ouvert && context.mounted) {
            await Clipboard.setData(ClipboardData(text: _construireMessage()));
            if (context.mounted) {
              afficherToast(context, '📋 Message copié ! Collez-le dans WhatsApp.');
            }
          }
        },
        icon: const Icon(Icons.share_outlined, size: 18, color: Colors.white),
        label: Text(
          'Partager le récap sur WhatsApp',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: Colors.white,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.whatsapp,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

// ─── Carte d'un membre ────────────────────────────────────────────────────────
class _CarteMembre extends StatelessWidget {
  final Membre membre;
  final int rang;
  final int montant;
  final bool estGest;
  final String? echeance;
  final dynamic tontine;
  final String? gestActifNom;
  /// Badge BÉNÉFICIAIRE — totalement indépendant du statut paye
  final bool isBeneficiaire;
  final VoidCallback? onToggle;
  final VoidCallback? onEnvoyerRecu;
  final VoidCallback? onRelancer;
  final VoidCallback? onGenererPdf;
  /// Callback "Payer" (Premium non-payé → écran paiement manuel)
  final VoidCallback? onPayer;
  /// Callback "Approuver" (Premium en_attente, gestionnaire, pas le déclarant)
  final VoidCallback? onApprouver;
  /// Callback "Annuler cotisation" (Premium payé, gestionnaire uniquement)
  final VoidCallback? onAnnulerPremium;

  const _CarteMembre({
    required this.membre,
    required this.rang,
    required this.montant,
    required this.estGest,
    this.echeance,
    required this.tontine,
    this.gestActifNom,
    this.isBeneficiaire = false,
    this.onToggle,
    this.onEnvoyerRecu,
    this.onRelancer,
    this.onGenererPdf,
    this.onPayer,
    this.onApprouver,
    this.onAnnulerPremium,
  });

  bool get _enRetard {
    if (membre.paye || echeance == null) return false;
    final date = DateTime.tryParse(echeance!);
    if (date == null) return false;
    return date.isBefore(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _enRetard
              ? AppColors.alerte.withValues(alpha: 0.3)
              : AppColors.lignes,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  color: AppColors.fondCode,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '$rang',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.encre,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Nom + badge BÉNÉFICIAIRE (indépendant du statut paye)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            membre.nom,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                              color: AppColors.texte,
                            ),
                          ),
                        ),
                        if (isBeneficiaire)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.or.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(color: AppColors.or.withValues(alpha: 0.5)),
                            ),
                            child: const Text(
                              'BÉNÉF.',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: AppColors.or,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (membre.paye && membre.datePaiement != null)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${Formatters.methodePaiement(membre.methodePaiement ?? '')} · ${Formatters.dateHeure(DateTime.tryParse(membre.datePaiement!))}',
                            style: const TextStyle(fontSize: 11.5, color: AppColors.texteDoux),
                          ),
                          if (membre.paiementDeclareParGest != null && membre.paiementDeclareParGest!.isNotEmpty)
                            Text(
                              'Déclaré par ${membre.paiementDeclareParGest}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFFE65100),
                                fontStyle: FontStyle.italic,
                              ),
                            )
                          else if (membre.validePar != null && membre.validePar!.isNotEmpty)
                            Text(
                              'Approuvé par ${membre.validePar}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.succes,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                        ],
                      )
                    else if (_enRetard)
                      const Text(
                        '⚠️ En retard',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppColors.alerte,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              // ── Bouton statut / toggle ──
              // Logique :
              //   Membre payé              → badge vert "✓ Payé"
              //   Premium non-payé         → bouton "Payer" (Mobile Money ou Crypto)
              //   Gest Lite non-payé       → bouton "Approuver" (toggle manuel)
              //   Membre Lite non-gest     → badge "En attente" (lecture seule)
              if (membre.paye && membre.paiementApprouve)
                // ── Approuvé → badge vert foncé
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.succesFond,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    '✓ Approuvé',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.succes,
                    ),
                  ),
                )
              else if (membre.paye && membre.paiementEnAttente)
                // ── En attente d'approbation → badge orange
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFFF9800).withValues(alpha: 0.5)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.hourglass_top_rounded, size: 11, color: Color(0xFFE65100)),
                      SizedBox(width: 3),
                      Text(
                        'En attente',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFFE65100)),
                      ),
                    ],
                  ),
                )
              else if (membre.paye)
                // ── Payé (tontine gratuite / ancien format sans statut) → badge vert
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.succesFond,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    '✓ Payé',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.succes,
                    ),
                  ),
                )
              else if (onPayer != null)
                // ── Premium non-payé → écran choix paiement
                GestureDetector(
                  onTap: onPayer,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D8A4E),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.payment_rounded, size: 12, color: Colors.white),
                        SizedBox(width: 4),
                        Text('Payer', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                      ],
                    ),
                  ),
                )
              else if (estGest)
                // ── Gestionnaire Lite non-payé → toggle manuel
                GestureDetector(
                  onTap: onToggle,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: AppColors.encre,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'Approuver',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.white),
                    ),
                  ),
                )
              else
                // ── Membre Lite non-gest → badge lecture seule
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.alerteFond,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'En attente',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.alerte),
                  ),
                ),
            ],
          ),
          // ── Ligne de référence + actions ──
          if (membre.referencePaiement != null || membre.paye) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (membre.referencePaiement != null)
                  Expanded(
                    child: Text(
                      'Réf. ${membre.referencePaiement}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.texteDoux,
                        fontFamily: 'monospace',
                      ),
                    ),
                  )
                else
                  const Spacer(),
                // ── Bug #6 : boutons Reçu PDF + WhatsApp pour membres payés ──
                if (membre.paye) ...[
                  // Bouton PDF reçu
                  if (onGenererPdf != null) ...[
                    GestureDetector(
                      onTap: onGenererPdf,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.fondCode,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(color: AppColors.lignes),
                        ),
                        child: const Text(
                          '📄 PDF',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.encre,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  // Bouton WhatsApp reçu
                  GestureDetector(
                    onTap: onEnvoyerRecu,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF25D366).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: const Color(0xFF25D366).withValues(alpha: 0.35),
                        ),
                      ),
                      child: const Text(
                        '📲 Reçu',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF128C7E),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
          // ── Relancer (non-payés, gestionnaire) ──
          if (!membre.paye && estGest) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onRelancer,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                ),
                child: const Text(
                  'Relancer sur WhatsApp',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.whatsapp,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          // ── Actions gestionnaire : Approuver (vert) + Annuler (rouge) ──────
          if (onApprouver != null || onAnnulerPremium != null) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // ── Bouton "✓ Approuver" (vert) — cotisation en_attente ──────
                if (onApprouver != null) ...[
                  GestureDetector(
                    onTap: onApprouver,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D8A4E),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF0D8A4E).withValues(alpha: 0.25),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle_outline_rounded, size: 14, color: Colors.white),
                          SizedBox(width: 5),
                          Text(
                            'Approuver',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // ── Bouton bloqué si gest = déclarant ────────────────────────
                if (membre.paiementEnAttente &&
                    estGest &&
                    membre.paiementDeclareParGest != null &&
                    membre.paiementDeclareParGest == gestActifNom &&
                    onApprouver == null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: AppColors.lignes,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_outline_rounded, size: 13, color: AppColors.texteDoux),
                        SizedBox(width: 4),
                        Text(
                          'Approbation autre gest.',
                          style: TextStyle(fontSize: 11, color: AppColors.texteDoux),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // ── Bouton "✗ Annuler" (rouge) ───────────────────────────────
                if (onAnnulerPremium != null)
                  GestureDetector(
                    onTap: onAnnulerPremium,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: AppColors.alerteFond,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: AppColors.alerte.withValues(alpha: 0.5),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.cancel_outlined, size: 14, color: AppColors.alerte),
                          SizedBox(width: 5),
                          Text(
                            'Annuler',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.alerte,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _BandeauEcheance extends StatelessWidget {
  final String? echeance;
  final String periode;

  const _BandeauEcheance({
    required this.echeance,
    required this.periode,
  });

  @override
  Widget build(BuildContext context) {
    // Calculer la prochaine échéance effective (stockée ou auto)
    final prochaineDate = EcheanceService.prochaineEcheance(
      echeanceStockee: echeance,
      periode: periode,
    );
    final statut    = EcheanceService.statutEcheance(prochaineDate, periode);
    final isRetard  = statut == 'alerte';
    final isUrgent  = statut == 'avertissement';
    final delai     = EcheanceService.texteDelai(prochaineDate, periode: periode);
    final periodeLbl = EcheanceService.labelPeriode(periode);
    final isAuto    = echeance == null || echeance!.isEmpty ||
        (DateTime.tryParse(echeance!) != null &&
         DateTime.tryParse(echeance!)!.isBefore(DateTime.now()));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isRetard ? AppColors.alerteFond
             : isUrgent ? AppColors.fondConsultation
             : AppColors.succesFond,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isRetard ? AppColors.alerte.withValues(alpha: 0.3)
               : isUrgent ? AppColors.or.withValues(alpha: 0.3)
               : AppColors.succes.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isRetard ? '⚠️' : '📅',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${isAuto ? 'Auto ' : ''}$periodeLbl · ${Formatters.dateFormatee(prochaineDate)} · $delai',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: isRetard ? AppColors.alerte
                     : isUrgent ? AppColors.orFonce
                     : AppColors.succes,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
