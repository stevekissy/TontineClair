import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

class CotisationsScreen extends StatelessWidget {
  final String code;

  const CotisationsScreen({super.key, required this.code});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;
    if (tontine == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final data = tontine.data;
    final estGest = provider.estDebloque;
    final membres = data.membres;

    // Membres affichés dans l'ordre de passage (ordre[]) — spec FICHE-REGLE-BENEFICIAIRE
    final membreParId = {for (final m in membres) m.id: m};
    final membresOrdre = data.ordre.isNotEmpty
        ? data.ordre.map((id) => membreParId[id]).whereType<Membre>().toList()
        : membres;
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
                        : 'Tour ${data.numerTour} · ${Formatters.montantFCFA(data.montant)} par membre · ${data.nbPayes}/${membres.length} payés',
                    style: const TextStyle(fontSize: 14, color: AppColors.texteDoux),
                  ),
                  if (data.echeance != null) ...[
                    const SizedBox(height: 8),
                    _BandeauEcheance(echeance: data.echeance!),
                  ],
                  const SizedBox(height: 16),
                  // Liste dans l'ordre de passage (ordre[]) — badge BÉNÉF. indépendant de paye
                  ...membresOrdre.asMap().entries.map(
                    (e) => _CarteMembre(
                      membre: e.value,
                      rang: e.key + 1,
                      montant: data.montant,
                      estGest: estGest,
                      echeance: data.echeance,
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
      // Marquer payé — choisir méthode
      final methode = await _choisirMethode(context);
      if (methode == null || !context.mounted) return;

      final ok = await afficherModalePin(
        context,
        titre: 'Confirmer le paiement',
        sousTitre: 'Vérifie les détails avant de confirmer avec ton PIN.',
        recap: [
          (label: 'Membre', valeur: membre.nom),
          (label: 'Montant', valeur: Formatters.montantFCFA(data.montant)),
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
      }
    } else {
      // Annuler le paiement
      final ok = await afficherModalePin(
        context,
        titre: 'Annuler le paiement',
        sousTitre: 'Cette action supprime le paiement enregistré.',
        recap: [
          (label: 'Membre', valeur: membre.nom),
          (label: 'Montant', valeur: Formatters.montantFCFA(data.montant)),
        ],
        onValider: (pin) async {
          final newData = data.toJson();
          final membres = List<Map<String, dynamic>>.from(
            (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
          );
          final idx = membres.indexWhere((m) => m['id'] == membre.id);
          if (idx >= 0) {
            membres[idx]['paye'] = false;
            membres[idx].remove('datePaiement');
            membres[idx].remove('methodePaiement');
            membres[idx].remove('referencePaiement');
          }
          newData['membres'] = membres;
          return provider.ecrire(newData, pin);
        },
      );

      if (ok == true && context.mounted) {
        afficherToast(context, 'Paiement annulé.');
      }
    }
  }

  Future<String?> _choisirMethode(BuildContext context) async {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Méthode de paiement',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: AppColors.encre,
              ),
            ),
            const SizedBox(height: 16),
            ...['especes', 'orange', 'mtn', 'moov', 'wave'].map(
              (m) => ListTile(
                title: Text(Formatters.methodePaiement(m)),
                leading: const Icon(Icons.payment, color: AppColors.encre),
                onTap: () => Navigator.pop(ctx, m),
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
      'Montant : ${Formatters.montantFCFA(data.montant)}\n'
      'Tour : ${data.numerTour}\n'
      'Date : ${Formatters.dateHeure(membre.datePaiement != null ? DateTime.tryParse(membre.datePaiement!) : null)}\n'
      'Méthode : ${Formatters.methodePaiement(membre.methodePaiement ?? '')}\n'
      'Réf. : ${membre.referencePaiement ?? ''}\n'
      'Code tontine : ${tontine.code}',
    );
    launchUrl(
      Uri.parse('https://wa.me/?text=$msg'),
      mode: LaunchMode.externalApplication,
    );
  }

  void _relancer(BuildContext context, dynamic tontine, Membre membre) {
    if (membre.paye) return;
    final data = tontine.data;
    final msg = Uri.encodeComponent(
      '⏰ Rappel de cotisation — TontineClair\n'
      'Bonjour ${membre.nom},\n'
      'Ta cotisation de ${Formatters.montantFCFA(data.montant)} pour la tontine "${data.nom}" (tour ${data.numerTour}) est en attente.\n'
      '${data.echeance != null ? 'Échéance : ${Formatters.dateFormatee(DateTime.tryParse(data.echeance!))}\n' : ''}'
      'Code tontine : ${tontine.code}',
    );
    launchUrl(
      Uri.parse('https://wa.me/?text=$msg'),
      mode: LaunchMode.externalApplication,
    );
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
      'Montant : ${Formatters.montantFCFA(data.montant)}\n'
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
        // BUG FIX : h['date'] peut être un int (timestamp ms) ou une String ISO
        final dateRaw = h['date'];
        DateTime? dateD;
        if (dateRaw is int) {
          dateD = DateTime.fromMillisecondsSinceEpoch(dateRaw);
        } else if (dateRaw is String && dateRaw.isNotEmpty) {
          dateD = DateTime.tryParse(dateRaw);
        }
        buf.writeln('• Tour $tour → $benef — ${Formatters.montantFCFA(montant)}'
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
    buf.writeln('Tour ${data.numerTour}/${membres.length} · ${Formatters.montantFCFA(data.montant)} par membre');
    if (data.echeance != null) {
      // BUG FIX : data.echeance est déjà une String nullable — pas besoin de cast
      final echD = DateTime.tryParse(data.echeance!);
      if (echD != null) buf.writeln('📅 Échéance : ${Formatters.dateFormatee(echD)}');
    }
    buf.writeln('🏆 Bénéficiaire du tour : ${beneficiaire?.nom ?? '—'} — reçoit ${Formatters.montantFCFA(montantTotal)}');
    buf.writeln('');
    buf.writeln('✅ Ont cotisé (${payes.length}/${membres.length})');
    for (final m in payes) buf.writeln('  ✓ ${m.nom}');
    if (nonPayes.isNotEmpty) {
      buf.writeln('');
      buf.writeln('⏳ En attente (${nonPayes.length}/${membres.length})');
      for (final m in nonPayes) buf.writeln('  · ${m.nom}');
    }
    buf.writeln('');
    buf.writeln('💰 Cagnotte : ${Formatters.montantFCFA(montantTotal)} / ${Formatters.montantFCFA(totalAttendu)}');
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
          final url = Uri.parse('https://wa.me/?text=$msg');
          if (await canLaunchUrl(url)) {
            await launchUrl(url, mode: LaunchMode.externalApplication);
          } else {
            if (context.mounted) {
              afficherToast(context, 'Impossible d\'ouvrir WhatsApp.', estErreur: true);
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

class _CarteMembre extends StatelessWidget {
  final Membre membre;
  final int rang;
  final int montant;
  final bool estGest;
  final String? echeance;
  /// Badge BÉNÉFICIAIRE — totalement indépendant du statut paye
  final bool isBeneficiaire;
  final VoidCallback? onToggle;
  final VoidCallback? onEnvoyerRecu;
  final VoidCallback? onRelancer;

  const _CarteMembre({
    required this.membre,
    required this.rang,
    required this.montant,
    required this.estGest,
    this.echeance,
    this.isBeneficiaire = false,
    this.onToggle,
    this.onEnvoyerRecu,
    this.onRelancer,
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
                decoration: BoxDecoration(
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
                      membre.paye ? '✓ Payé' : 'Marquer payé',
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
          if (membre.referencePaiement != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Réf. ${membre.referencePaiement}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.texteDoux,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                if (membre.paye) ...[
                  TextButton(
                    onPressed: onEnvoyerRecu,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                    ),
                    child: const Text(
                      'Envoyer reçu',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.whatsapp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
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
  final String echeance;

  const _BandeauEcheance({required this.echeance});

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(echeance);
    if (date == null) return const SizedBox.shrink();
    final estRetard = date.isBefore(DateTime.now());
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: estRetard ? AppColors.alerteFond : AppColors.succesFond,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '📅 Échéance : ${Formatters.dateFormatee(date)} · ${Formatters.joursRestants(date)}',
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: estRetard ? AppColors.alerte : AppColors.succes,
        ),
      ),
    );
  }
}
