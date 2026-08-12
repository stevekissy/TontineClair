import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/tontine_provider.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';

class JournalScreen extends StatelessWidget {
  final String code;

  const JournalScreen({super.key, required this.code});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;
    if (tontine == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final journal = tontine.data.journal;

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
                    label: Text(context.tr('retour')),
                    style: TextButton.styleFrom(foregroundColor: AppColors.encre),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    'Journal d\'audit',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 28,
                      color: AppColors.encre,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${journal.length} entrée${journal.length > 1 ? 's' : ''} · Horodatées',
                    style: const TextStyle(fontSize: 14, color: AppColors.texteDoux),
                  ),
                  const SizedBox(height: 16),
                  if (journal.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Aucune action enregistrée.',
                          style: TextStyle(color: AppColors.texteDoux),
                        ),
                      ),
                    )
                  else
                    ...journal.asMap().entries.map(
                      (e) => _LigneJournal(entry: e.value, index: e.key),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LigneJournal extends StatelessWidget {
  final dynamic entry;
  final int index;

  const _LigneJournal({required this.entry, required this.index});

  IconData _icone(String quoi) {
    if (quoi.contains('PAIEMENT'))    return Icons.payments_outlined;
    if (quoi.contains('DECAISSEMENT')) return Icons.arrow_outward;
    if (quoi.contains('TIRAGE'))      return Icons.shuffle;
    if (quoi.contains('CLOS_ADOPTE') || quoi.contains('ADOPTE'))
                                       return Icons.check_circle_outline;
    if (quoi.contains('CLOS_REJETE') || quoi.contains('REJETE'))
                                       return Icons.cancel_outlined;
    if (quoi.contains('VOTE_CREE') || quoi.contains('RETRAIT_CREE'))
                                       return Icons.ballot_outlined;
    if (quoi.contains('VOTE') || quoi.contains('RETRAIT_CLOS'))
                                       return Icons.how_to_vote_outlined;
    if (quoi.contains('PRET'))         return Icons.handshake_outlined;
    if (quoi.contains('CAISSE'))       return Icons.account_balance_wallet_outlined;
    if (quoi.contains('PREMIUM'))      return Icons.star;
    if (quoi.contains('APPORT'))       return Icons.add_box_outlined;
    if (quoi.contains('PENALITE'))     return Icons.warning_amber_outlined;
    if (quoi.contains('REMBOURSEMENT')) return Icons.price_check_outlined;
    return Icons.history;
  }

  Color _couleurIcone(String quoi) {
    if (quoi.contains('ADOPTE'))    return const Color(0xFF2E7D5B);
    if (quoi.contains('REJETE'))    return const Color(0xFFE53935);
    if (quoi.contains('VOTE_CREE') || quoi.contains('RETRAIT_CREE'))
                                    return const Color(0xFF00ACC1);
    if (quoi.contains('VOTE'))      return const Color(0xFF00838F);
    if (quoi.contains('PAIEMENT') || quoi.contains('DECAISSEMENT'))
                                    return const Color(0xFFE53935);
    if (quoi.contains('APPORT'))    return const Color(0xFF1976D2);
    if (quoi.contains('PRET'))      return const Color(0xFFF57C00);
    if (quoi.contains('PENALITE'))  return const Color(0xFFFF8F00);
    if (quoi.contains('PREMIUM'))   return const Color(0xFFD4AC0D);
    return AppColors.encre;
  }

  @override
  Widget build(BuildContext context) {
    final quoi = entry.quoi as String? ?? '';
    final gest = entry.gestionnaire as String? ?? '';
    final quand = entry.quand as String? ?? '';
    final ref = entry.reference as String?;

    final date = DateTime.tryParse(quand);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.lignes),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _couleurIcone(quoi).withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Icon(_icone(quoi), size: 16, color: _couleurIcone(quoi)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formaterQuoi(quoi),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    color: AppColors.texte,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${gest.isEmpty ? 'Système' : gest} · ${Formatters.dateHeure(date)}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.texteDoux,
                  ),
                ),
                if (ref != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Réf. $ref',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.texteDoux,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Transforme le champ `quoi` brut en texte lisible pour un novice.
  /// Gère les anciens formats concaténés (ex: VOTE_CLOS_ADOPTE_TC123:oui=3:non=1:…)
  /// ET les nouveaux formats structurés.
  String _formaterQuoi(String quoi) {
    // ── Cas : VOTE_CLOS (format historique concaténé) ──────────────────────
    // Exemples :
    //   VOTE_CLOS_ADOPTE_TC80294701:oui=0:non=0:abs=0:participation=0/5
    //   RETRAIT_CLOS_REJETE_TC12345:oui=1:non=2:abs=0:participation=3/5
    final regexVoteClos = RegExp(
      r'^(VOTE|RETRAIT)_CLOS_(ADOPTE|REJETE)_([A-Z0-9]+):oui=(\d+):non=(\d+):abs=(\d+):participation=(\d+)/(\d+)',
    );
    final mVC = regexVoteClos.firstMatch(quoi);
    if (mVC != null) {
      final typeLabel  = mVC.group(1) == 'RETRAIT' ? 'Retrait' : 'Vote';
      final statut     = mVC.group(2) == 'ADOPTE' ? 'adopté ✅' : 'rejeté ❌';
      final oui        = mVC.group(4);
      final non        = mVC.group(5);
      final abs        = mVC.group(6);
      final particip   = mVC.group(7);
      final total      = mVC.group(8);
      return '$typeLabel $statut — $oui oui · $non non · $abs abs. · $particip/$total participants';
    }

    // ── Cas : VOTE_CREE_type ───────────────────────────────────────────────
    // Exemples : VOTE_CREE_libre, VOTE_CREE_admission, VOTE_CREE_retrait
    final regexVoteCree = RegExp(r'^(VOTE|RETRAIT)_CREE_?(\w+)?$');
    final mCree = regexVoteCree.firstMatch(quoi);
    if (mCree != null) {
      final typeVote = _labelTypeVote(mCree.group(2));
      return 'Vote ouvert — $typeVote';
    }

    // ── Cas : VOTE_CLOS sans stats (ancienne version très courte) ──────────
    if (quoi.startsWith('VOTE_CLOS_ADOPTE')) return 'Vote adopté ✅';
    if (quoi.startsWith('VOTE_CLOS_REJETE')) return 'Vote rejeté ❌';
    if (quoi.startsWith('RETRAIT_CLOS_ADOPTE')) return 'Vote retrait adopté ✅';
    if (quoi.startsWith('RETRAIT_CLOS_REJETE')) return 'Vote retrait rejeté ❌';

    // ── Fallback : nettoyage générique ─────────────────────────────────────
    return quoi
        .replaceAll('_', ' ')
        .replaceAll('PAIEMENT', 'Paiement')
        .replaceAll('DECAISSEMENT', 'Décaissement')
        .replaceAll('TIRAGE VERROUILLE', 'Tirage verrouillé')
        .replaceAll('VOTE CREE', 'Vote ouvert')
        .replaceAll('VOTE CLOS ADOPTE', 'Vote adopté ✅')
        .replaceAll('VOTE CLOS REJETE', 'Vote rejeté ❌')
        .replaceAll('VOTE CLOS', 'Vote clôturé')
        .replaceAll('PRET', 'Prêt')
        .replaceAll('REMBOURSEMENT', 'Remboursement')
        .replaceAll('CAISSE', 'Caisse')
        .replaceAll('APPORT', 'Apport')
        .replaceAll('DEPENSE', 'Dépense')
        .replaceAll('PENALITE', 'Pénalité')
        .replaceAll('PREMIUM ACTIVE', 'Premium activé')
        .replaceAll('DEMANDE PREMIUM', 'Demande Premium')
        .replaceAll('TOUR', 'Tour')
        .trim();
  }

  /// Traduit le type de vote en label humain.
  String _labelTypeVote(String? type) {
    switch ((type ?? '').toLowerCase()) {
      case 'libre':      return 'libre';
      case 'admission':  return 'admission nouveau membre';
      case 'retrait':    return 'exclusion membre';
      case 'pret':       return 'accord de prêt';
      case 'depense':    return 'dépense caisse';
      default:           return type?.isNotEmpty == true ? type! : 'général';
    }
  }
}
