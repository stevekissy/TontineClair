import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/tontine_provider.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

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
                    label: const Text('Retour'),
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
    if (quoi.contains('PAIEMENT')) return Icons.payments_outlined;
    if (quoi.contains('DECAISSEMENT')) return Icons.arrow_outward;
    if (quoi.contains('TIRAGE')) return Icons.shuffle;
    if (quoi.contains('VOTE')) return Icons.how_to_vote_outlined;
    if (quoi.contains('PRET')) return Icons.handshake_outlined;
    if (quoi.contains('CAISSE')) return Icons.account_balance_wallet_outlined;
    if (quoi.contains('PREMIUM')) return Icons.star;
    return Icons.history;
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
            decoration: const BoxDecoration(
              color: AppColors.fondCode,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Icon(_icone(quoi), size: 16, color: AppColors.encre),
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

  String _formaterQuoi(String quoi) {
    // Rendre plus lisible
    return quoi
        .replaceAll('_', ' ')
        .replaceAll('PAIEMENT', 'Paiement')
        .replaceAll('DECAISSEMENT', 'Décaissement')
        .replaceAll('TOUR', 'tour')
        .replaceAll('TIRAGE VERROUILLE', 'Tirage verrouillé')
        .replaceAll('VOTE CREE', 'Vote créé')
        .replaceAll('VOTE CLOS', 'Vote clos')
        .replaceAll('PRET', 'Prêt')
        .replaceAll('REMBOURSEMENT', 'Remboursement')
        .replaceAll('CAISSE', 'Caisse')
        .replaceAll('APPORT', 'Apport')
        .replaceAll('DEPENSE', 'Dépense')
        .replaceAll('PENALITE', 'Pénalité')
        .replaceAll('PREMIUM ACTIVE', 'Premium activé')
        .replaceAll('DEMANDE PREMIUM', 'Demande Premium');
  }
}
