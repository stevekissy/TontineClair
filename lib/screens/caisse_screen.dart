import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/devise_service.dart';
import '../services/supabase_service.dart';
import '../services/blockchain_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';
import '../services/locale_service.dart';
import '../services/email_service.dart' as email_svc;

// ─── Widget animé pour le solde caisse ────────────────────────────────────────
/// Affiche le solde avec une animation de compteur fun quand la valeur change.
class _SoldeAnime extends StatefulWidget {
  final int solde;
  final String devise;

  const _SoldeAnime({required this.solde, required this.devise});

  @override
  State<_SoldeAnime> createState() => _SoldeAnimeState();
}

class _SoldeAnimeState extends State<_SoldeAnime>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  int _ancienSolde = 0;

  @override
  void initState() {
    super.initState();
    _ancienSolde = widget.solde;
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  }

  @override
  void didUpdateWidget(_SoldeAnime oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.solde != widget.solde) {
      _ancienSolde = oldWidget.solde;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        final valeurAffichee = (_ancienSolde +
                (_anim.value * (widget.solde - _ancienSolde)))
            .round();
        return Text(
          Formatters.montant(valeurAffichee, devise: widget.devise),
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 34,
            color: Colors.white,
          ),
        );
      },
    );
  }
}

// ─── Opérateurs Mobile Money disponibles ──────────────────────────────────────
const _operateursMobileMoney = ['orange', 'moov', 'mtn', 'wave'];

class CaisseScreen extends StatefulWidget {
  final String code;

  const CaisseScreen({super.key, required this.code});

  @override
  State<CaisseScreen> createState() => _CaisseScreenState();
}

class _CaisseScreenState extends State<CaisseScreen> {

  Future<void> _recharger() async {
    if (!mounted) return;
    await context.read<TontineProvider>().chargerTontine(widget.code);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;
    if (tontine == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final data = tontine.data;
    final estGest = provider.estDebloque;

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
                    style: TextButton.styleFrom(foregroundColor: AppColors.encre),
                  ),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _recharger,
                child: ListView(
                padding: EdgeInsets.all(16),
                children: [
                  Text(
                    context.tr('caisse_commune'),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 28,
                      color: AppColors.encre,
                    ),
                  ),
                  SizedBox(height: 16),
                  // Solde
                  Container(
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.encre,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      children: [
                        Text(
                          context.tr('solde_disponible'),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.14,
                            color: AppColors.or,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _SoldeAnime(
                          solde: data.soldeCaisse,
                          devise: data.devise,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 16),
                  // Actions gestionnaire
                  if (estGest) ...[
                    Row(
                      children: [
                        Expanded(
                          child: _BtnAction(
                            icon: Icons.add,
                            label: context.tr('apport'),
                            couleur: AppColors.succes,
                            onTap: () => _mouvement(context, provider, data, 'apport'),
                          ),
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: _BtnAction(
                            icon: Icons.remove,
                            label: context.tr('depense'),
                            couleur: AppColors.alerte,
                            onTap: () => _mouvement(context, provider, data, 'depense'),
                          ),
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: _BtnAction(
                            icon: Icons.warning_amber,
                            label: context.tr('penalite'),
                            couleur: AppColors.orFonce,
                            onTap: () => _mouvement(context, provider, data, 'penalite'),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                  ],
                  // Historique
                  Text(
                    context.tr('mouvements'),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                      color: AppColors.encre,
                    ),
                  ),
                  SizedBox(height: 10),
                  if (data.caisse.isEmpty)
                    Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          context.tr('aucun_mouvement'),
                          style: TextStyle(color: AppColors.texteDoux),
                        ),
                      ),
                    )
                  else ...() {
                    // Calcul du solde AVANT chaque mouvement (style releve bancaire)
                    // data.caisse est chronologique (ancien -> nouveau)
                    // soldesAvant[i] = solde de la caisse juste AVANT le mouvement i
                    //
                    // Le solde d'ouverture (avant le 1er mouvement) = soldeCaisse actuel
                    // moins la somme de tous les mouvements déjà enregistrés.
                    // Ainsi chaque "Solde avant" reflète le vrai solde absolu
                    // à l'instant précédant l'opération.
                    final mouvements = data.caisse.toList();
                    final soldesAvant = <int>[];

                    // Montant signé : les sorties soustraient, les entrées ajoutent.
                    // m.montant est TOUJOURS stocké en valeur absolue positive ;
                    // c'est le type qui détermine le signe réel dans la caisse.
                    const sorties = {
                      'depense', 'decaissement', 'decaissement_cagnotte', 'pret', 'retrait',
                    };
                    // Retourne le montant avec le bon signe selon le type
                    int signe(m) => sorties.contains(m.type)
                        ? -m.montant.abs()
                        :  m.montant.abs();

                    final totalSigne = mouvements.fold<int>(
                      0, (s, m) => s + signe(m),
                    );
                    int cumul = data.soldeCaisse - totalSigne;
                    for (final m in mouvements) {
                      soldesAvant.add(cumul); // solde AVANT ce mouvement
                      cumul += signe(m);      // applique le bon signe
                    }
                    // Affichage du plus recent au plus ancien
                    return List.generate(mouvements.length, (i) {
                      final idx = mouvements.length - 1 - i;
                      return _LigneMouvement(
                        mouvement: mouvements[idx],
                        devise: data.devise,
                        soldeAvant: soldesAvant[idx],
                      );
                    });
                  }(),

                ],
              ),
              ), // RefreshIndicator
            ),
          ],
        ),
      ),
    );
  }

  // ── Notifie tous les gestionnaires ayant un email d'un mouvement caisse ────
  // Appelé de manière non-bloquante (fire-and-forget) après chaque mouvement.
  //
  // Stratégie double-source pour les emails :
  //   1. Appel REST direct sur Supabase (colonne gestionnaires) — source principale
  //   2. Fallback depuis data.gestionnaires (modèle local) si REST retourne []
  //
  // Le paramètre [gestionnairesFallback] doit être passé depuis l'appelant
  // (toujours disponible via data.gestionnaires dans le contexte Pro).
  static Future<void> _envoyerEmailsMouvement({
    required String      codeTontine,
    required TontineData data,
    required String      typeLibelle, // 'Apport', 'Dépense', 'Pénalité'
    required int         montant,
    required String      gestActif,
    required String      devise,
    String?              description,
    String?              membreNom,
    List<Gestionnaire>?  gestionnairesFallback, // fallback local si REST retourne []
  }) async {
    if (kDebugMode) {
      debugPrint('[CaisseEmail] ► Début envoi — type=$typeLibelle, tontine=$codeTontine');
    }

    // ── Source 1 : REST Supabase (colonne gestionnaires) ─────────────────
    List<Map<String, String>> destinataires =
        await SupabaseService.lireEmailsGestionnaires(codeTontine);

    if (kDebugMode) {
      debugPrint('[CaisseEmail] REST → ${destinataires.length} destinataire(s) trouvé(s)');
      for (final d in destinataires) {
        debugPrint('[CaisseEmail]   • ${d['nom']} → ${d['email']}');
      }
    }

    // ── Source 2 : Fallback depuis le modèle local ────────────────────────
    if (destinataires.isEmpty) {
      if (kDebugMode) {
        debugPrint('[CaisseEmail] REST vide → tentative fallback depuis data.gestionnaires');
      }
      final fallback = gestionnairesFallback ?? data.gestionnaires;
      for (final g in fallback) {
        final email = g.email.trim();
        final nom   = g.nom.trim();
        if (email.isNotEmpty && nom.isNotEmpty) {
          destinataires.add({'nom': nom, 'email': email});
        }
      }
      if (kDebugMode) {
        debugPrint('[CaisseEmail] Fallback → ${destinataires.length} destinataire(s)');
        for (final d in destinataires) {
          debugPrint('[CaisseEmail]   • ${d['nom']} → ${d['email']}');
        }
      }
    }

    // ── Aucun email disponible ────────────────────────────────────────────
    if (destinataires.isEmpty) {
      if (kDebugMode) {
        debugPrint('[CaisseEmail] ✗ Aucun gestionnaire avec email '
            '(REST + fallback vides). Envoi annulé pour $codeTontine');
      }
      return;
    }

    final montantStr = Formatters.montant(montant, devise: devise);
    final desc       = description?.isNotEmpty == true ? description! : '';
    final tontineNom = data.nom;

    final String motifHtml = desc.isNotEmpty
        ? '<p style="font-size:13px;color:#6B7280;margin-top:10px">📝 Motif : <strong>$desc</strong></p>'
        : '';

    final String detailAction;
    final String icone;
    switch (typeLibelle) {
      case 'Apport':
        detailAction = 'Un apport de <strong>$montantStr</strong> a été enregistré dans la caisse commune.$motifHtml';
        icone = '💰';
      case 'Dépense':
        detailAction = 'Une dépense de <strong>$montantStr</strong> a été effectuée depuis la caisse commune.$motifHtml';
        icone = '💸';
      case 'Pénalité':
        final membreStr = membreNom?.isNotEmpty == true ? ' sur <strong>$membreNom</strong>' : '';
        detailAction = 'Une pénalité de <strong>$montantStr</strong>$membreStr a été appliquée.$motifHtml';
        icone = '⚠️';
      default:
        detailAction = 'Un mouvement de <strong>$montantStr</strong> a été enregistré.$motifHtml';
        icone = '📋';
    }

    if (kDebugMode) {
      debugPrint('[CaisseEmail] ► Envoi à ${destinataires.length} gestionnaire(s)…');
    }

    // ── Envoi en parallèle aux gestionnaires ──────────────────────────────
    for (final gest in destinataires) {
      final adresse = gest['email']!;
      final nomGest = gest['nom']!;
      if (kDebugMode) debugPrint('[CaisseEmail]   → Gestionnaire: $nomGest <$adresse>');
      email_svc.EmailService.envoyer(
        type:         email_svc.TypeEmail.alerteSecurite,
        destinataire: adresse,
        variables: {
          'nom':        nomGest,
          'action':     '$icone $typeLibelle caisse${desc.isNotEmpty ? ' — $desc' : ''} — $tontineNom',
          'message':    detailAction,
          'tontine':    tontineNom,
          'date':       DateTime.now().toLocal().toString().substring(0, 16),
          'gest_actif': gestActif,
        },
      ).then((result) {
        if (kDebugMode) {
          if (result.ok) {
            debugPrint('[CaisseEmail]   ✓ Gestionnaire $adresse (id=${result.emailId})');
          } else {
            debugPrint('[CaisseEmail]   ✗ Gestionnaire $adresse : ${result.erreur}');
          }
        }
      }).catchError((Object e) {
        if (kDebugMode) debugPrint('[CaisseEmail]   ✗ Exception gestionnaire $adresse : $e');
      });
    }

    // ── Envoi aux membres Premium (e-mails renseignés à la création) ──────
    // Récupère les membres avec email depuis Supabase (data.membres[].email)
    // Non-bloquant : fire-and-forget, jamais en Premium Gratuite
    if (data.tier == 'premium' || data.tier == 'pro') {
      final emailsMembres =
          await SupabaseService.lireEmailsMembres(codeTontine);

      if (kDebugMode) {
        debugPrint('[CaisseEmail] Membres Premium : ${emailsMembres.length} email(s) trouvé(s)');
      }

      for (final m in emailsMembres) {
        final adresse  = m['email']!;
        final nomMembre = m['nom']!;

        // Éviter les doublons si un membre a le même email qu'un gestionnaire
        final dejaEnvoye = destinataires.any((d) => d['email'] == adresse);
        if (dejaEnvoye) continue;

        if (kDebugMode) debugPrint('[CaisseEmail]   → Membre: $nomMembre <$adresse>');

        email_svc.EmailService.envoyer(
          type:         email_svc.TypeEmail.alerteSecurite,
          destinataire: adresse,
          variables: {
            'nom':        nomMembre,
            'action':     '$icone $typeLibelle — $tontineNom',
            'message':    detailAction,
            'tontine':    tontineNom,
            'date':       DateTime.now().toLocal().toString().substring(0, 16),
            'gest_actif': gestActif,
          },
        ).then((result) {
          if (kDebugMode) {
            if (result.ok) {
              debugPrint('[CaisseEmail]   ✓ Membre $adresse (id=${result.emailId})');
            } else {
              debugPrint('[CaisseEmail]   ✗ Membre $adresse : ${result.erreur}');
            }
          }
        }).catchError((Object e) {
          if (kDebugMode) debugPrint('[CaisseEmail]   ✗ Exception membre $adresse : $e');
        });
      }
    }
  }
  Future<void> _mouvement(
    BuildContext context,
    TontineProvider provider,
    TontineData data,
    String type,
  ) async {
    final montantCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    String methode = 'especes';

    // Pour les pénalités : menu de sélection du membre pénalisé
    // SOURCE UNIQUE DE MEMBRES : membresActifs avec double fallback
    final membresOrdre = data.membresActifs;
    String? membrePenaliteId =
        (type == 'penalite' && membresOrdre.isNotEmpty) ? membresOrdre.first.id : null;

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.lignes,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  type == 'apport'
                      ? context.tr('apport_caisse')
                      : type == 'depense'
                          ? 'Dépense de caisse'
                          : 'Appliquer une pénalité',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    color: AppColors.encre,
                  ),
                ),
                // Membre pénalisé (pénalité uniquement)
                if (type == 'penalite' && membresOrdre.isNotEmpty) ...[
                  ChampLabel(label: context.tr('membre_penalise')),
                  DropdownButtonFormField<String>(
                    initialValue: membrePenaliteId,
                    isExpanded: true,
                    decoration: const InputDecoration(),
                    items: membresOrdre
                        .map((m) => DropdownMenuItem(
                              value: m.id,
                              child: Text(m.nom, overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (v) => setS(() => membrePenaliteId = v),
                  ),
                ],
                ChampLabel(label: 'Montant (${DeviseService.parCode(data.devise).symbole})'),
                TextField(
                  controller: montantCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(hintText: '5 000'),
                  autofocus: true,
                ),
                ChampLabel(label: context.tr('description_motif')),
                TextField(
                  controller: descCtrl,
                  maxLength: 100,
                  decoration: InputDecoration(
                    hintText: type == 'penalite'
                        ? 'Ex : Retard de cotisation'
                        : 'Ex : Frais de local',
                    counterText: '',
                  ),
                ),
                if (type != 'penalite') ...[
                  ChampLabel(label: context.tr('mode_paiement_label')),
                  DropdownButtonFormField<String>(
                    initialValue: methode,
                    decoration: InputDecoration(),
                    items: ['especes', 'orange', 'mtn', 'moov', 'wave']
                        .map((m) => DropdownMenuItem(
                              value: m,
                              child: Text(Formatters.methodePaiement(m)),
                            ))
                        .toList(),
                    onChanged: (v) => setS(() => methode = v!),
                  ),
                ],
                SizedBox(height: 16),
                BtnPrincipal(
                  label: context.tr('enregistrer'),
                  onTap: () => Navigator.pop(ctx, true),
                ),
                const SizedBox(height: 8),
                BtnSecondaire(
                  label: 'Annuler',
                  onTap: () => Navigator.pop(ctx, false),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );

    if (result != true || !context.mounted) return;

    final montant = int.tryParse(montantCtrl.text.trim());
    if (montant == null || montant <= 0) {
      afficherToast(context, 'Montant invalide', estErreur: true);
      return;
    }
    // Vérification solde pour les dépenses
    if (type == 'depense' && montant > data.soldeCaisse) {
      afficherToast(context,
          'Solde insuffisant (${Formatters.montant(data.soldeCaisse, devise: data.devise)} disponibles)',
          estErreur: true);
      return;
    }

    final nomMembre = (type == 'penalite' && membrePenaliteId != null)
        ? (membresOrdre.where((m) => m.id == membrePenaliteId).firstOrNull?.nom ?? '')
        : '';
    final descFinale = descCtrl.text.trim().isNotEmpty
        ? descCtrl.text.trim()
        : (type == 'penalite' && nomMembre.isNotEmpty ? 'Pénalité — $nomMembre' : '');

    final libelleType = type == 'apport'
        ? 'Apport'
        : type == 'depense'
            ? 'Dépense'
            : 'Pénalité';

    // ref généré ici pour être accessible à la fois dans onValider ET dans le bloc blockchain
    final ref = Formatters.genererReference();

    final ok = await afficherModalePin(
      context,
      titre: 'Confirmer le mouvement',
      sousTitre: 'Vérifie les détails avant de confirmer avec ton PIN.',
      recap: [
        (label: 'Type', valeur: libelleType),
        (label: 'Montant', valeur: Formatters.montant(montant, devise: data.devise)),
        if (descFinale.isNotEmpty) (label: 'Description', valeur: descFinale),
        (label: 'Solde actuel', valeur: Formatters.montant(data.soldeCaisse, devise: data.devise)),
      ],
      onValider: (pin) async {
        final now = DateTime.now().toIso8601String();
        final newData = data.toJson();
        // ── Correction : caisse est stockée comme {mouvements:[...]} ─────────
        // toJson() produit {'mouvements':[...]}, on lit donc dans cette Map.
        final caisseMap = newData['caisse'];
        final caisse = List<Map<String, dynamic>>.from(
          caisseMap is Map<String, dynamic>
              ? ((caisseMap['mouvements'] as List<dynamic>?)
                      ?.cast<Map<String, dynamic>>() ??
                  [])
              : caisseMap is List
                  ? caisseMap.cast<Map<String, dynamic>>()
                  : [],
        );
        final entree = {
          'id': ref,
          'type': type,
          'montant': montant,
          'description': descFinale,
          'gestionnaire': provider.gestActifNom ?? '',
          'date': now,
          'reference': ref,
        };
        if (type == 'penalite' && membrePenaliteId != null) {
          entree['membreId'] = membrePenaliteId!;
          entree['membreNom'] = nomMembre;
        }
        caisse.add(entree);
        // Toujours écrire dans le format attendu par TontineData.fromJson()
        newData['caisse'] = {'mouvements': caisse};

        // Pénalité : incrémenter compteur + baisser score de confiance du membre
        if (type == 'penalite' && membrePenaliteId != null) {
          final membres = List<Map<String, dynamic>>.from(
            (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
          );
          final idx = membres.indexWhere((m) => m['id'] == membrePenaliteId);
          if (idx >= 0) {
            membres[idx]['penalites'] = ((membres[idx]['penalites'] as int?) ?? 0) + 1;
            membres[idx]['score'] = (((membres[idx]['score'] as int?) ?? 50) - 5).clamp(0, 100);
          }
          newData['membres'] = membres;
        }

        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        journal.insert(0, {
          'quoi': type == 'penalite'
              ? 'PÉNALITÉ \u2014 $nomMembre \u2014 ${Formatters.montant(montant, devise: data.devise)}'
              : '${type == 'apport' ? 'APPORT' : 'DÉPENSE'} CAISSE \u2014 ${Formatters.montant(montant, devise: data.devise)}${descFinale.isNotEmpty ? ' \u2014 $descFinale' : ''}',
          'gestionnaire': provider.gestActifNom ?? '',
          'quand': now,
          'reference': ref,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    // ── BLOCKCHAIN : pénalité / dépense / apport caisse (non-bloquant) ──
    if (ok == true) {
      if (type == 'penalite' && membrePenaliteId != null) {
        BlockchainService.enregistrerPenalite(
          tontineCode: widget.code,
          membreId   : membrePenaliteId!,
          membreNom  : nomMembre,
          montantXof : montant,
          devise     : data.devise,
          refInterne : ref,
        ).catchError((e) {
          if (kDebugMode) debugPrint('[Blockchain] penalite erreur: $e');
          return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
        });
      } else if (type == 'depense') {
        BlockchainService.enregistrerDepenseCaisse(
          tontineCode : widget.code,
          montantXof  : montant,
          devise      : data.devise,
          description : descFinale.isNotEmpty ? descFinale : 'Dépense caisse',
          gestionnaire: provider.gestActifNom,
          refInterne  : ref,
        ).catchError((e) {
          if (kDebugMode) debugPrint('[Blockchain] depense_caisse erreur: $e');
          return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
        });
      } else if (type == 'apport') {
        // Apport caisse manuel (espèces / Mobile Money hors CoinPayments)
        BlockchainService.enregistrerApport(
          tontineCode: widget.code,
          membreId   : provider.gestActifNom ?? 'gest',
          membreNom  : provider.gestActifNom ?? '',
          montantXof : montant,
          devise     : data.devise,
          refInterne : ref,
        ).catchError((e) {
          if (kDebugMode) debugPrint('[Blockchain] apport_caisse erreur: $e');
          return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
        });
      }
    }
    // ────────────────────────────────────────────────────────────────────

    if (ok == true && context.mounted) {
      afficherToast(context,
          type == 'penalite' ? 'Pénalité appliquée !' : 'Mouvement enregistré !');
      // ── Email à tous les gestionnaires (mouvement manuel caisse gratuite) ──
      _envoyerEmailsMouvement(
        codeTontine: widget.code,
        data:        data,
        typeLibelle: type == 'apport' ? 'Apport'
                   : type == 'depense' ? 'Dépense'
                   : 'Pénalité',
        montant:     montant,
        gestActif:   provider.gestActifNom ?? '',
        devise:      data.devise,
        description: descFinale,
        membreNom:   type == 'penalite' ? nomMembre : null,
      );
      final lang = Provider.of<LocaleService>(context, listen: false).langue.code;
      final typeNotif = type == 'penalite' ? 'penalite' : 'caisse';
      final montantStr = Formatters.montant(montant, devise: data.devise);
      final desc = descFinale.isNotEmpty ? ' — $descFinale' : '';
      final t = SupabaseService.notifTexte(typeNotif, lang, vars: {
        'nom': nomMembre,
        'montant': montantStr,
        'libelle': libelleType,
        'desc': desc,
      });
      SupabaseService.envoyerNotification(
        code: widget.code,
        type: typeNotif,
        titre: t['titre']!,
        message: t['message']!,
      );
    }
  }
}

class _BtnAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color couleur;
  final VoidCallback onTap;

  const _BtnAction({
    required this.icon,
    required this.label,
    required this.couleur,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: couleur.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: couleur.withValues(alpha: 0.3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: couleur, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: couleur,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LigneMouvement extends StatelessWidget {
  final MouvementCaisse mouvement;
  final String devise;
  /// Solde de la caisse après application de ce mouvement.
  /// Affiché en petit sous le montant pour tracer l'évolution du solde.
  /// Solde AVANT ce mouvement — affiché sous le montant
  final int? soldeAvant;

  const _LigneMouvement({
    required this.mouvement,
    this.devise = 'XOF',
    this.soldeAvant,
  });

  bool get _isEntree =>
      mouvement.type == 'apport' ||
      mouvement.type == 'cotisation' ||
      mouvement.type == 'penalite' ||
      mouvement.type == 'remboursement';
  // Note: 'decaissement', 'decaissement_cagnotte', 'depense', 'pret', 'retrait' = sorties

  /// Libellé lisible du type de mouvement (jamais de chaîne technique)
  String get _typeLabel {
    switch (mouvement.type) {
      case 'apport':         return 'Apport';
      case 'depense':        return 'Dépense';
      case 'penalite':       return 'Pénalité';
      case 'cotisation':     return 'Cotisation';
      case 'remboursement':  return 'Remboursement';
      case 'pret':           return 'Prêt';
      case 'correction':     return 'Correction';
      case 'decaissement':          return 'Décaissement';
      case 'decaissement_cagnotte': return '💸 Cagnotte versée';
      default:               return Formatters.capitaliser(mouvement.type);
    }
  }

  /// Motif saisi par l'utilisateur — extrait le motif des chaînes techniques
  /// Ex: "Apport Caisse via CoinPayments — 700 XOF — location"
  ///      → retourne "location"
  /// Ex: "TontineClair - APPORT — location" → retourne "location"
  /// Ex: "location" (texte pur) → retourne "location"
  /// Ex: "Cotisation Yvan — Tour 2 — par Arnaud" (ancien format)
  ///      → retourne "Yvan — Tour 2 — par Arnaud" (évite le doublon "Cotisation — Cotisation Yvan")
  String get _motif {
    final d = mouvement.description.trim();
    if (d.isEmpty) return '';
    final lower = d.toLowerCase();

    // ── Rétrocompatibilité : ancien format de cotisation gestionnaire ─────────
    // Les cotisations enregistrées avant le fix stockaient "Cotisation Nom — Tour N — par Gest".
    // L'UI affiche déjà "_typeLabel — motif" (ex: "Cotisation — …"),
    // donc on retire le préfixe "Cotisation " pour éviter "Cotisation — Cotisation Yvan".
    if (mouvement.type == 'cotisation' &&
        lower.startsWith('cotisation ') &&
        lower.contains(' — tour ')) {
      // Supprimer le préfixe "Cotisation " (11 caractères) pour retourner "Yvan — Tour 2 — …"
      return d.substring('Cotisation '.length).trim();
    }

    // ── Chaînes techniques : tenter d'extraire le motif après le dernier " — "
    final estTechnique = lower.startsWith('tontineclair') ||
        lower.contains('coinpayments') ||
        lower.contains('apport en caisse') ||
        lower.contains('apport caisse') ||
        lower.contains('dépense caisse') ||
        lower.contains('depense caisse') ||
        lower.contains('pénalité caisse') ||
        lower.contains('penalite caisse') ||
        lower.contains('cotisation caisse');

    if (estTechnique) {
      // Chercher le motif après le dernier " — " (séparateur tiret cadratin)
      final lastDash = d.lastIndexOf(' — ');
      if (lastDash != -1) {
        final candidat = d.substring(lastDash + 3).trim();
        // Vérifier que ce n'est pas une donnée technique (montant, code devise…)
        final candidatLower = candidat.toLowerCase();
        final estDonnee = RegExp(r'^\d').hasMatch(candidat) || // commence par chiffre (montant)
            candidatLower == 'xof' ||
            candidatLower == 'eur' ||
            candidatLower == 'usd' ||
            candidatLower.contains('coinpayments') ||
            candidatLower.contains('tontineclair') ||
            candidat.isEmpty;
        if (!estDonnee) return candidat;
      }
      // Aussi tenter avec " - " (tiret simple, format "TontineClair - APPORT — location")
      final segments = d.split(' — ');
      if (segments.length >= 2) {
        final last = segments.last.trim();
        final lastL = last.toLowerCase();
        if (last.isNotEmpty &&
            !RegExp(r'^\d').hasMatch(last) &&
            !lastL.contains('xof') &&
            !lastL.contains('coinpayments') &&
            !lastL.contains('apport') &&
            !lastL.contains('caisse')) {
          return last;
        }
      }
      return ''; // Pas de motif extractible
    }

    return d;
  }

  @override
  Widget build(BuildContext context) {
    final date   = DateTime.tryParse(mouvement.date);
    final motif  = _motif;
    final modePaiement = Formatters.decrypterPaiement(
      par: mouvement.gestionnaire,
      description: mouvement.description,
      reference: mouvement.reference,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.lignes),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _isEntree ? AppColors.succesFond : AppColors.alerteFond,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isEntree ? Icons.add : Icons.remove,
              size: 18,
              color: _isEntree ? AppColors.succes : AppColors.alerte,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Ligne 1 : Type + motif ─────────────────────────────────
                // Affiche toujours le type lisible (Apport, Dépense, Pénalité)
                // suivi du motif s'il existe : "Apport — location"
                Text(
                  motif.isNotEmpty ? '$_typeLabel — $motif' : _typeLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: AppColors.texte,
                  ),
                ),
                // ── Ligne 2 : Mode de paiement · date ─────────────────────
                Text(
                  '$modePaiement · ${Formatters.dateFormatee(date)}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.texteDoux,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${_isEntree ? '+' : '-'}${Formatters.montant(mouvement.montant.abs(), devise: devise)}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: _isEntree ? AppColors.succes : AppColors.alerte,
                ),
              ),
              if (soldeAvant != null) ...
                [
                  const SizedBox(height: 2),
                  Text(
                    'Solde avant : ${Formatters.montant(soldeAvant!, devise: devise)}',
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: AppColors.texteDoux,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
            ],
          ),
        ],
      ),
    );
  }
}

