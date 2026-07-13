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
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

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
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.encre),
              SizedBox(height: 12),
              Text(
                'Chargement des cotisations…',
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
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                  children: [
                    const Text(
                      'Cotisations',
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
                    const SizedBox(height: 8),
                    _BandeauEcheance(
                      echeance: data.echeance,
                      periode: data.periode,
                    ),
                    const SizedBox(height: 16),

                    // Bug #6 fix : afficher un message si liste vide
                    if (membresOrdre.isEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Aucun membre à afficher.\nTirez vers le bas pour recharger.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.texteDoux),
                          ),
                        ),
                      )
                    else
                      // Liste dans l'ordre de passage (ordre[]) — badge BÉNÉF. indépendant de paye
                      ...membresOrdre.asMap().entries.map(
                        (e) => _CarteMembre(
                          membre: e.value,
                          rang: e.key + 1,
                          montant: data.montant,
                          estGest: estGest,
                          echeance: data.echeance,
                          tontine: tontine,
                          // Badge BÉNÉFICIAIRE : indépendant du statut paye
                          isBeneficiaire: !data.cycleTermine && e.value.id == benefId,
                          onToggle: estGest && !data.cycleTermine
                              ? () => _togglePaiement(
                                    context,
                                    provider,
                                    tontine,
                                    e.value,
                                  )
                              : null,
                          onEnvoyerRecu: () => _envoyerRecu(context, tontine, e.value),
                          onRelancer: () => _relancer(context, tontine, e.value),
                          onGenererPdf: estGest && e.value.paye
                              ? () => _genererRecuPdf(context, tontine, e.value)
                              : null,
                        ),
                      ),
                    const SizedBox(height: 16),
                    // Partage récap WhatsApp (accessible à tous)
                    _BoutonRecapWhatsApp(tontine: tontine),
                    if (estGest) ...[
                      const SizedBox(height: 10),
                      BtnWhatsApp(
                        label: 'Relancer tous les retardataires',
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

  Future<void> _togglePaiement(
    BuildContext context,
    TontineProvider provider,
    dynamic tontine,
    Membre membre,
  ) async {
    if (!provider.estDebloque) return;

    final data = tontine.data;
    final nowStr = DateTime.now().toIso8601String();
    final ref = Formatters.genererReference();

    if (!membre.paye) {
      // Marquer payé — choisir méthode (filtrée selon la devise de la tontine)
      final methode = await _choisirMethode(context, devise: data.devise);
      if (methode == null || !context.mounted) return;

      final ok = await afficherModalePin(
        context,
        titre: 'Confirmer le paiement',
        sousTitre: 'Vérifie les détails avant de confirmer avec ton PIN.',
        recap: [
          (label: 'Membre', valeur: membre.nom),
          (label: 'Montant', valeur: Formatters.montant(data.montant, devise: data.devise)),
          (label: 'Méthode', valeur: Formatters.methodePaiement(methode)),
          (label: 'Tour', valeur: 'N° ${data.numerTour}'),
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
          };
          newData['paiements'] = paiements;

          // ── Caisse : ajouter l'apport ─────────────────────────────────────
          final caisseMap = newData['caisse'];
          final caisse = List<Map<String, dynamic>>.from(
            caisseMap is Map<String, dynamic>
                ? ((caisseMap['mouvements'] as List<dynamic>?)
                        ?.cast<Map<String, dynamic>>() ?? [])
                : caisseMap is List
                    ? (caisseMap as List<dynamic>).cast<Map<String, dynamic>>()
                    : [],
          );
          caisse.add({
            'id': '${ref}C',
            'type': 'apport',
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

      if (ok == true && context.mounted) {
        afficherToast(context, 'Paiement de ${membre.nom} enregistré !');

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
      final ok = await afficherModalePin(
        context,
        titre: 'Annuler le paiement',
        sousTitre: 'Cette action supprime le paiement enregistré.',
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
                    ? (caisseMap as List<dynamic>).cast<Map<String, dynamic>>()
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

      if (ok == true && context.mounted) {
        afficherToast(context, 'Paiement annulé et journal mis à jour.');
      }
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
        title: const Text(
          '📲 Envoyer le reçu ?',
          style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre),
        ),
        content: Text(
          'Paiement de ${membre.nom} enregistré (${Formatters.montant(data.montant, devise: data.devise)}).\n\nComment souhaitez-vous partager le reçu ?',
          style: const TextStyle(color: AppColors.texte),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Ignorer'),
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
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.lignes,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Méthode de paiement',
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
    for (final m in payes) buf.writeln('  ✓ ${m.nom}');
    if (nonPayes.isNotEmpty) {
      buf.writeln('');
      buf.writeln('⏳ En attente (${nonPayes.length}/${membres.length})');
      for (final m in nonPayes) buf.writeln('  · ${m.nom}');
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
            afficherToast(context, '📋 Message copié ! Collez-le dans WhatsApp.');
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
  /// Badge BÉNÉFICIAIRE — totalement indépendant du statut paye
  final bool isBeneficiaire;
  final VoidCallback? onToggle;
  final VoidCallback? onEnvoyerRecu;
  final VoidCallback? onRelancer;
  final VoidCallback? onGenererPdf;

  const _CarteMembre({
    required this.membre,
    required this.rang,
    required this.montant,
    required this.estGest,
    this.echeance,
    required this.tontine,
    this.isBeneficiaire = false,
    this.onToggle,
    this.onEnvoyerRecu,
    this.onRelancer,
    this.onGenererPdf,
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
                      Text(
                        '${Formatters.methodePaiement(membre.methodePaiement ?? '')} · ${Formatters.dateHeure(DateTime.tryParse(membre.datePaiement!))}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.texteDoux,
                        ),
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
              if (estGest)
                GestureDetector(
                  onTap: onToggle,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: membre.paye
                          ? AppColors.succesFond
                          : AppColors.encre,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      membre.paye ? '✓ Payé' : 'Approuver',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: membre.paye ? AppColors.succes : Colors.white,
                      ),
                    ),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: membre.paye
                        ? AppColors.succesFond
                        : AppColors.alerteFond,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    membre.paye ? '✓ Payé' : 'En attente',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color:
                          membre.paye ? AppColors.succes : AppColors.alerte,
                    ),
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
