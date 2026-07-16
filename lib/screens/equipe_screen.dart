import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';
import '../utils/formatters.dart';

// =============================================================================
// ÉCRAN ÉQUIPE ADMIN — Gestion des membres et rôles
// Accessible uniquement au super_admin
// =============================================================================

class EquipeScreen extends StatefulWidget {
  final String cle;
  final String roleActuel;   // 'super_admin' | 'comptable' | 'conformite'

  const EquipeScreen({super.key, required this.cle, required this.roleActuel});

  @override
  State<EquipeScreen> createState() => _EquipeScreenState();
}

class _EquipeScreenState extends State<EquipeScreen> {
  List<Map<String, dynamic>> _membres = [];
  bool _loading = true;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() { _loading = true; _erreur = null; });
    try {
      final m = await SupabaseService.adminListerMembres(widget.cle);
      setState(() => _membres = m);
    } catch (e) {
      setState(() => _erreur = 'Erreur de chargement');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _ajouterMembre() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _DialogNouveauMembre(),
    );
    if (result == null) return;

    final res = await SupabaseService.adminCreerMembre(
      cle:      widget.cle,
      nom:      result['nom']!,
      pseudo:   result['pseudo']!,
      clePerso: result['cle']!,
      role:     result['role']!,
      creePar:  'super_admin',
    );

    if (!mounted) return;
    if (res['ok'] == true || res['pseudo'] != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Membre ajouté avec succès'), backgroundColor: AppColors.succes),
      );
      _charger();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur: ${res['erreur'] ?? 'Inconnue'}'), backgroundColor: AppColors.alerte),
      );
    }
  }

  Future<void> _toggleActif(Map<String, dynamic> m) async {
    final actifActuel = m['actif'] as bool? ?? true;
    final res = await SupabaseService.adminModifierMembre(
      cle:   widget.cle,
      id:    m['id'] as int,
      actif: !actifActuel,
    );
    if (!mounted) return;
    if (res['ok'] == true) _charger();
  }

  Future<void> _changerRole(Map<String, dynamic> m) async {
    final roles = ['super_admin', 'comptable', 'conformite'];
    final role = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Changer le rôle de ${m['nom']}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.encre)),
        children: roles.map((r) => SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, r),
          child: _BadgeRole(role: r),
        )).toList(),
      ),
    );
    if (role == null) return;
    await SupabaseService.adminModifierMembre(cle: widget.cle, id: m['id'] as int, role: role);
    if (mounted) _charger();
  }

  @override
  Widget build(BuildContext context) {
    final isSuperAdmin = widget.roleActuel == 'super_admin';

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: const Text('Équipe Admin',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.encre)),
        iconTheme: const IconThemeData(color: AppColors.encre),
        actions: [
          if (isSuperAdmin)
            IconButton(
              icon: const Icon(Icons.person_add_outlined, color: AppColors.encre),
              tooltip: 'Ajouter un membre',
              onPressed: _ajouterMembre,
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: AppColors.encre),
            onPressed: _charger,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _erreur != null
              ? Center(child: Text(_erreur!, style: const TextStyle(color: AppColors.alerte)))
              : _membres.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.group_off_outlined, size: 48, color: AppColors.texteDoux),
                          SizedBox(height: 12),
                          Text('Aucun membre d\'équipe', style: TextStyle(color: AppColors.texteDoux)),
                        ],
                      ),
                    )
                  : Column(
                      children: [
                        // ── Résumé rôles ──────────────────────────────────────────
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          child: Row(
                            children: [
                              _PillRole(label: 'Super Admin',
                                  n: _membres.where((m) => m['role'] == 'super_admin').length,
                                  couleur: AppColors.encre),
                              const SizedBox(width: 8),
                              _PillRole(label: 'Comptable',
                                  n: _membres.where((m) => m['role'] == 'comptable').length,
                                  couleur: AppColors.or),
                              const SizedBox(width: 8),
                              _PillRole(label: 'Conformité',
                                  n: _membres.where((m) => m['role'] == 'conformite').length,
                                  couleur: AppColors.succes),
                            ],
                          ),
                        ),
                        const Divider(height: 1, color: AppColors.lignes),
                        // ── Liste membres ─────────────────────────────────────────
                        Expanded(
                          child: ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            itemCount: _membres.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final m   = _membres[i];
                              final actif = m['actif'] as bool? ?? true;
                              final dernCo = m['derniere_connexion'] != null
                                  ? DateTime.tryParse(m['derniere_connexion'] as String)
                                  : null;

                              return CarteTC(
                                child: Row(
                                  children: [
                                    // Avatar
                                    Container(
                                      width: 44, height: 44,
                                      decoration: BoxDecoration(
                                        color: actif
                                            ? _couleurRole(m['role'] as String? ?? '').withValues(alpha: .15)
                                            : AppColors.fondCode,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Icon(
                                        _iconeRole(m['role'] as String? ?? ''),
                                        color: actif
                                            ? _couleurRole(m['role'] as String? ?? '')
                                            : AppColors.texteDoux,
                                        size: 22,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    // Infos
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Text(m['nom'] as String? ?? '',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 14,
                                                    color: actif ? AppColors.encre : AppColors.texteDoux,
                                                    decoration: actif ? null : TextDecoration.lineThrough,
                                                  )),
                                              const SizedBox(width: 8),
                                              _BadgeRole(role: m['role'] as String? ?? ''),
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Text('@${m['pseudo']}',
                                              style: const TextStyle(
                                                  fontSize: 12, color: AppColors.encreDoux,
                                                  fontFamily: 'monospace')),
                                          if (dernCo != null)
                                            Text(
                                              'Dernière co.: ${Formatters.dateFormatee(dernCo)}',
                                              style: const TextStyle(fontSize: 11, color: AppColors.texteDoux),
                                            ),
                                        ],
                                      ),
                                    ),
                                    // Actions (super_admin uniquement)
                                    if (isSuperAdmin)
                                      PopupMenuButton<String>(
                                        icon: const Icon(Icons.more_vert_rounded, color: AppColors.texteDoux),
                                        color: AppColors.fondPapier,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        onSelected: (v) {
                                          if (v == 'role')   _changerRole(m);
                                          if (v == 'toggle') _toggleActif(m);
                                        },
                                        itemBuilder: (_) => [
                                          const PopupMenuItem(value: 'role',
                                              child: Row(children: [
                                                Icon(Icons.swap_horiz_rounded, size: 18, color: AppColors.encre),
                                                SizedBox(width: 8),
                                                Text('Changer le rôle'),
                                              ])),
                                          PopupMenuItem(value: 'toggle',
                                              child: Row(children: [
                                                Icon(
                                                  actif ? Icons.block_rounded : Icons.check_circle_outline_rounded,
                                                  size: 18,
                                                  color: actif ? AppColors.alerte : AppColors.succes,
                                                ),
                                                const SizedBox(width: 8),
                                                Text(actif ? 'Désactiver' : 'Réactiver'),
                                              ])),
                                        ],
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
    );
  }

  Color _couleurRole(String role) {
    switch (role) {
      case 'super_admin': return AppColors.encre;
      case 'comptable':   return AppColors.or;
      case 'conformite':  return AppColors.succes;
      default:            return AppColors.texteDoux;
    }
  }

  IconData _iconeRole(String role) {
    switch (role) {
      case 'super_admin': return Icons.admin_panel_settings_rounded;
      case 'comptable':   return Icons.account_balance_wallet_outlined;
      case 'conformite':  return Icons.verified_user_outlined;
      default:            return Icons.person_outline_rounded;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dialogue d'ajout d'un nouveau membre
// ─────────────────────────────────────────────────────────────────────────────
class _DialogNouveauMembre extends StatefulWidget {
  const _DialogNouveauMembre();

  @override
  State<_DialogNouveauMembre> createState() => _DialogNouveauMembreState();
}

class _DialogNouveauMembreState extends State<_DialogNouveauMembre> {
  final _nomCtrl   = TextEditingController();
  final _pseudoCtrl= TextEditingController();
  final _cleCtrl   = TextEditingController();
  String _role     = 'comptable';
  bool   _obscure  = true;
  String? _erreur;

  @override
  void dispose() {
    _nomCtrl.dispose(); _pseudoCtrl.dispose(); _cleCtrl.dispose();
    super.dispose();
  }

  void _valider() {
    final nom    = _nomCtrl.text.trim();
    final pseudo = _pseudoCtrl.text.trim();
    final cle    = _cleCtrl.text.trim();
    if (nom.isEmpty || pseudo.isEmpty || cle.length < 6) {
      setState(() => _erreur = 'Remplir tous les champs (clé ≥ 6 caractères)');
      return;
    }
    Navigator.pop(context, {'nom': nom, 'pseudo': pseudo, 'cle': cle, 'role': _role});
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.fondPapier,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(
        children: [
          Icon(Icons.person_add_outlined, color: AppColors.encre, size: 22),
          SizedBox(width: 10),
          Text('Nouveau membre', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: AppColors.encre)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Nom complet', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.texteDoux)),
            const SizedBox(height: 4),
            TextField(controller: _nomCtrl, decoration: const InputDecoration(hintText: 'Ex: Jean Konan')),
            const SizedBox(height: 12),
            const Text('Pseudo de connexion', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.texteDoux)),
            const SizedBox(height: 4),
            TextField(controller: _pseudoCtrl, decoration: const InputDecoration(hintText: 'Ex: jean_konan')),
            const SizedBox(height: 12),
            const Text('Clé personnelle (≥ 6 caractères)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.texteDoux)),
            const SizedBox(height: 4),
            TextField(
              controller: _cleCtrl,
              obscureText: _obscure,
              decoration: InputDecoration(
                hintText: '••••••••',
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Rôle', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.texteDoux)),
            const SizedBox(height: 6),
            Row(
              children: [
                _ChipRole(label: 'Comptable',  role: 'comptable',  selectionne: _role == 'comptable',  onTap: () => setState(() => _role = 'comptable')),
                const SizedBox(width: 8),
                _ChipRole(label: 'Conformité', role: 'conformite', selectionne: _role == 'conformite', onTap: () => setState(() => _role = 'conformite')),
                const SizedBox(width: 8),
                _ChipRole(label: 'Super',      role: 'super_admin',selectionne: _role == 'super_admin',onTap: () => setState(() => _role = 'super_admin')),
              ],
            ),
            if (_erreur != null) ...[
              const SizedBox(height: 10),
              Text(_erreur!, style: const TextStyle(fontSize: 12, color: AppColors.alerte)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler', style: TextStyle(color: AppColors.texteDoux)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.encre, foregroundColor: Colors.white),
          onPressed: _valider,
          child: const Text('Créer'),
        ),
      ],
    );
  }
}

// ── Widgets locaux ────────────────────────────────────────────────────────────

class _BadgeRole extends StatelessWidget {
  final String role;
  const _BadgeRole({required this.role});

  @override
  Widget build(BuildContext context) {
    final (label, couleur) = switch (role) {
      'super_admin' => ('Super Admin', AppColors.encre),
      'comptable'   => ('Comptable',   AppColors.orFonce),
      'conformite'  => ('Conformité',  AppColors.succes),
      _             => (role,          AppColors.texteDoux),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: couleur.withValues(alpha: .3)),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: couleur)),
    );
  }
}

class _PillRole extends StatelessWidget {
  final String label;
  final int n;
  final Color couleur;
  const _PillRole({required this.label, required this.n, required this.couleur});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('$n $label', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: couleur)),
    );
  }
}

class _ChipRole extends StatelessWidget {
  final String label, role;
  final bool selectionne;
  final VoidCallback onTap;
  const _ChipRole({required this.label, required this.role, required this.selectionne, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final couleur = switch (role) {
      'super_admin' => AppColors.encre,
      'comptable'   => AppColors.orFonce,
      'conformite'  => AppColors.succes,
      _             => AppColors.texteDoux,
    };
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selectionne ? couleur : AppColors.fondCode,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700,
              color: selectionne ? Colors.white : AppColors.encre,
            )),
      ),
    );
  }
}
