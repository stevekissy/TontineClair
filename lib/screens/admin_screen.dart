import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final _cleCtrl = TextEditingController();
  bool _connecte = false;
  bool _loading = false;
  String? _erreur;
  List<Map<String, dynamic>> _demandes = [];
  List<Map<String, dynamic>> _tontines = [];
  int _onglet = 0;

  @override
  void dispose() {
    _cleCtrl.dispose();
    super.dispose();
  }

  Future<void> _connecter() async {
    final cle = _cleCtrl.text.trim();
    if (cle.isEmpty) return;
    setState(() {
      _loading = true;
      _erreur = null;
    });

    try {
      final demandes = await SupabaseService.adminListerDemandes(cle);
      final tontines = await SupabaseService.adminListerTontines(cle);

      if (demandes.isEmpty && tontines.isEmpty) {
        // Peut-être clé incorrecte ou aucune donnée
        setState(() {
          _connecte = true;
          _demandes = demandes;
          _tontines = tontines;
        });
      } else {
        setState(() {
          _connecte = true;
          _demandes = demandes;
          _tontines = tontines;
        });
      }
    } catch (e) {
      setState(() => _erreur = 'Clé incorrecte ou erreur réseau.');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _activer(String code) async {
    final cle = _cleCtrl.text.trim();
    final ok = await SupabaseService.adminActiverPremium(
      cle: cle,
      code: code,
      mois: 1,
    );
    if (!mounted) return;
    if (ok) {
      afficherToast(context, 'Premium activé pour $code !');
      await _recharger();
    } else {
      afficherToast(context, 'Erreur lors de l\'activation.', estErreur: true);
    }
  }

  Future<void> _desactiver(String code) async {
    final cle = _cleCtrl.text.trim();
    final ok = await SupabaseService.adminDesactiverPremium(
      cle: cle,
      code: code,
    );
    if (!mounted) return;
    if (ok) {
      afficherToast(context, 'Premium désactivé pour $code.');
      await _recharger();
    } else {
      afficherToast(context, 'Erreur.', estErreur: true);
    }
  }

  Future<void> _recharger() async {
    final cle = _cleCtrl.text.trim();
    final demandes = await SupabaseService.adminListerDemandes(cle);
    final tontines = await SupabaseService.adminListerTontines(cle);
    setState(() {
      _demandes = demandes;
      _tontines = tontines;
    });
  }

  @override
  Widget build(BuildContext context) {
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
              child: _connecte ? _VueAdmin() : _VueConnexion(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _VueConnexion() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Espace administrateur',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 28,
              color: AppColors.encre,
            ),
          ),
          const SizedBox(height: 20),
          CarteTC(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ChampLabel(label: 'Clé administrateur'),
                TextField(
                  controller: _cleCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: 'Clé secrète',
                  ),
                  onSubmitted: (_) => _connecter(),
                ),
                ChampErreur(texte: _erreur),
                const SizedBox(height: 16),
                BtnPrincipal(
                  label: 'Accéder',
                  onTap: _connecter,
                  loading: _loading,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _VueAdmin() {
    return Column(
      children: [
        // Onglets
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _OngletBtn(
                label: 'Demandes (${_demandes.length})',
                selected: _onglet == 0,
                onTap: () => setState(() => _onglet = 0),
              ),
              const SizedBox(width: 10),
              _OngletBtn(
                label: 'Tontines (${_tontines.length})',
                selected: _onglet == 1,
                onTap: () => setState(() => _onglet = 1),
              ),
            ],
          ),
        ),
        Expanded(
          child: _onglet == 0
              ? _ListeDemandes()
              : _ListeTontines(),
        ),
      ],
    );
  }

  Widget _ListeDemandes() {
    if (_demandes.isEmpty) {
      return const Center(
        child: Text(
          'Aucune demande en attente.',
          style: TextStyle(color: AppColors.texteDoux),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _demandes.length,
      itemBuilder: (_, i) {
        final d = _demandes[i];
        final statut = d['statut'] as String? ?? '';
        final quand = DateTime.tryParse(d['quand'] as String? ?? '');

        return CarteTC(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${d['gestionnaire']} · Code ${d['code']}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: AppColors.encre,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: statut == 'activée'
                          ? AppColors.succesFond
                          : AppColors.fondConsultation,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      statut,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: statut == 'activée'
                            ? AppColors.succes
                            : AppColors.orFonce,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Contact : ${d['contact']} · ${Formatters.dateFormatee(quand)}',
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.texteDoux),
              ),
              if (statut == 'en attente') ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: BtnPrincipal(
                        label: 'Activer',
                        onTap: () => _activer(d['code'] as String),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _ListeTontines() {
    if (_tontines.isEmpty) {
      return const Center(
        child: Text(
          'Aucune tontine.',
          style: TextStyle(color: AppColors.texteDoux),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _tontines.length,
      itemBuilder: (_, i) {
        final t = _tontines[i];
        final isPremium = t['plan'] == 'premium';
        final cree = DateTime.tryParse(t['cree'] as String? ?? '');

        return CarteTC(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${t['nom']} · Code ${t['code']}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: AppColors.encre,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${t['membres']} membres · Créé ${Formatters.dateFormatee(cree)}',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.texteDoux),
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  BadgePlan(isPremium: isPremium),
                  const SizedBox(height: 6),
                  if (!isPremium)
                    GestureDetector(
                      onTap: () => _activer(t['code'] as String),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.encre,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Activer',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    )
                  else
                    GestureDetector(
                      onTap: () => _desactiver(t['code'] as String),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.alerte.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Désactiver',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.alerte,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OngletBtn extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _OngletBtn({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.encre : AppColors.fondCode,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: selected ? Colors.white : AppColors.encre,
          ),
        ),
      ),
    );
  }
}
