import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/tontine_provider.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';

class AbonnementScreen extends StatefulWidget {
  final String code;

  const AbonnementScreen({super.key, required this.code});

  @override
  State<AbonnementScreen> createState() => _AbonnementScreenState();
}

class _AbonnementScreenState extends State<AbonnementScreen> {
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;
    if (tontine == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final isPremium = tontine.isPremium;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
              const SizedBox(height: 24),
              const Text(
                'Abonnement',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 30,
                  color: AppColors.encre,
                ),
              ),
              const SizedBox(height: 8),
              if (isPremium)
                _BandeauPremiumActif(tontine: tontine)
              else
                const Text(
                  'Passez au Premium pour débloquer toutes les fonctionnalités : caisse, prêts, votes, exports illimités.',
                  style: TextStyle(fontSize: 15, color: AppColors.texteDoux),
                ),
              const SizedBox(height: 24),
              // Tableau comparatif
              _TableauComparatif(),
              const SizedBox(height: 24),
              // Tarifs
              if (!isPremium) ...[
                const Text(
                  'Choisissez votre formule',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    color: AppColors.encre,
                  ),
                ),
                const SizedBox(height: 12),
                _CarteTarif(
                  label: 'Mensuel',
                  prix: '2 500 FCFA / mois',
                  description: 'Flexible, sans engagement',
                  badge: null,
                  selected: false,
                  onTap: () => _demanderPremium(context, provider),
                ),
                const SizedBox(height: 10),
                _CarteTarif(
                  label: 'Annuel',
                  prix: '25 000 FCFA / an',
                  description: '2 mois offerts vs mensuel',
                  badge: '2 mois offerts',
                  selected: false,
                  onTap: () => _demanderPremium(context, provider),
                ),
                const SizedBox(height: 20),
                const Text(
                  '💡 Le paiement sera bientôt disponible directement dans l\'application. En attendant, contactez votre administrateur pour activer le Premium.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.texteDoux,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 16),
                if (provider.estDebloque)
                  BtnKola(
                    label: '✉️ Demander l\'activation Premium',
                    onTap: () => _demanderPremium(context, provider),
                    loading: _loading,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _demanderPremium(
    BuildContext context,
    TontineProvider provider,
  ) async {
    if (!provider.estDebloque) {
      afficherToast(
        context,
        'Connectez-vous en tant que gestionnaire d\'abord.',
        estErreur: true,
      );
      return;
    }

    final contactCtrl = TextEditingController();

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
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
            const SizedBox(height: 16),
            const Text(
              'Demander le Premium',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 20,
                color: AppColors.encre,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Votre demande sera traitée manuellement. Entrez votre numéro WhatsApp pour être contacté.',
              style: TextStyle(fontSize: 13.5, color: AppColors.texteDoux),
            ),
            const ChampLabel(label: 'Numéro WhatsApp / Contact'),
            TextField(
              controller: contactCtrl,
              keyboardType: TextInputType.phone,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '+225 07 XX XX XX XX',
              ),
            ),
            const SizedBox(height: 16),
            BtnPrincipal(
              label: 'Envoyer la demande',
              onTap: () => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 8),
            BtnSecondaire(
              label: 'Annuler',
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    );

    if (result != true || !context.mounted) return;

    final ok = await afficherModalePin(
      context,
      titre: 'Confirmer la demande',
      sousTitre: 'Votre PIN pour authentifier la demande.',
      onValider: (pin) async {
        setState(() => _loading = true);
        try {
          return await SupabaseService.demanderPremium(
            code: provider.courante!.code,
            nom: provider.gestActifNom!,
            pin: pin,
            contact: contactCtrl.text.trim(),
          );
        } finally {
          setState(() => _loading = false);
        }
      },
    );

    if (!context.mounted) return;
    if (ok == true) {
      afficherToast(
        context,
        'Demande envoyée ! Vous serez contacté sous 24h.',
      );
    } else {
      afficherToast(context, 'PIN incorrect.', estErreur: true);
    }
  }
}

class _BandeauPremiumActif extends StatelessWidget {
  final dynamic tontine;

  const _BandeauPremiumActif({required this.tontine});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.or,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Text('★', style: TextStyle(fontSize: 28, color: Color(0xFF2A1E05))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Abonnement Premium actif',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: Color(0xFF2A1E05),
                  ),
                ),
                if (tontine.planExpire != null)
                  Text(
                    'Expire le ${tontine.planExpire!.day.toString().padLeft(2, '0')}/${tontine.planExpire!.month.toString().padLeft(2, '0')}/${tontine.planExpire!.year}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF4A3500),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TableauComparatif extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return CarteTC(
      child: Column(
        children: [
          const _LigneComparatif(
            fonctionnalite: 'Tontines',
            gratuit: '1',
            premium: 'Illimitées',
          ),
          _sep(),
          const _LigneComparatif(
            fonctionnalite: 'Membres',
            gratuit: '5 max',
            premium: 'Illimités',
          ),
          _sep(),
          const _LigneComparatif(
            fonctionnalite: 'Cotisations & Tirage',
            gratuit: '✓',
            premium: '✓',
          ),
          _sep(),
          const _LigneComparatif(
            fonctionnalite: 'Caisse commune',
            gratuit: '—',
            premium: '✓',
          ),
          _sep(),
          const _LigneComparatif(
            fonctionnalite: 'Prêts internes',
            gratuit: '—',
            premium: '✓',
          ),
          _sep(),
          const _LigneComparatif(
            fonctionnalite: 'Votes sécurisés',
            gratuit: '—',
            premium: '✓',
          ),
          _sep(),
          const _LigneComparatif(
            fonctionnalite: 'Export PDF',
            gratuit: '—',
            premium: '✓',
          ),
          _sep(),
          const _LigneComparatif(
            fonctionnalite: 'Journal illimité',
            gratuit: '—',
            premium: '✓',
          ),
        ],
      ),
    );
  }

  Widget _sep() => const Divider(height: 12, color: AppColors.lignes);
}

class _LigneComparatif extends StatelessWidget {
  final String fonctionnalite;
  final String gratuit;
  final String premium;

  const _LigneComparatif({
    required this.fonctionnalite,
    required this.gratuit,
    required this.premium,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: Text(
            fonctionnalite,
            style: const TextStyle(
              fontSize: 13.5,
              color: AppColors.texte,
            ),
          ),
        ),
        SizedBox(
          width: 60,
          child: Text(
            gratuit,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: gratuit == '—' ? AppColors.texteDoux : AppColors.texte,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        SizedBox(
          width: 60,
          child: Text(
            premium,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: premium == '✓' ? AppColors.succes : AppColors.encre,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

class _CarteTarif extends StatelessWidget {
  final String label;
  final String prix;
  final String description;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;

  const _CarteTarif({
    required this.label,
    required this.prix,
    required this.description,
    this.badge,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: selected ? AppColors.fondCode : AppColors.carte,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppColors.encre : AppColors.lignes,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                      color: AppColors.encre,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    prix,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      color: AppColors.or,
                    ),
                  ),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.texteDoux,
                    ),
                  ),
                ],
              ),
            ),
            if (badge != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.succes,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  badge!,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
