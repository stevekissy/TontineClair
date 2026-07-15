import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/tontine_provider.dart';
import '../services/supabase_service.dart';
import '../services/storage_service.dart';
import '../services/locale_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';
import 'creation_screen.dart';
import 'rejoindre_screen.dart';
import 'detail_screen.dart';
import 'admin_screen.dart';
import 'config_screen.dart';
import 'langue_screen.dart';
import '../utils/app_localizations.dart';

class AccueilScreen extends StatelessWidget {
  const AccueilScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Column(
          children: [
            // ── En-tête ───────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
              child: Row(
                children: [
                  // Logo : appui long (5 s) → accès développeur masqué
                  GestureDetector(
                    onLongPress: () => _afficherMenuDev(context),
                    child: const LogoTontineClair(),
                  ),
                  Spacer(),
                  // ── Bouton langue ──────────────────────────────────────
                  _BoutonLangue(),
                ],
              ),
            ),
            // ── Contenu ───────────────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 130),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr('mes_tontines'),
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 30,
                        color: AppColors.encre,
                        letterSpacing: -0.5,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      context.tr('slogan_accueil'),
                      style: TextStyle(fontSize: 15, color: AppColors.texteDoux),
                    ),
                    const SizedBox(height: 16),
                    if (provider.mesTontines.isEmpty)
                      _EtatVideAccueil()
                    else
                      ...provider.mesTontines.map(
                        (t) => _CarteTontine(
                          code: t.code,
                          nom: t.nom,
                          onTap: () => _ouvrirTontine(context, t.code),
                          onRetirer: () => _retirerTontine(context, t.code, t.nom, provider),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      // ── Barre fixe du bas ─────────────────────────────────────────────
      bottomSheet: _BarreActions(
        onRejoindre: () => _aller(context, const RejoindreScreen()),
        onCreer:     () => _aller(context, const CreationScreen()),
        onAdmin:     () => _aller(context, const AdminScreen()),
      ),
    );
  }

  // ─── Navigation ───────────────────────────────────────────────────────────

  void _ouvrirTontine(BuildContext context, String code) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailScreen(code: code)),
    );
  }

  void _aller(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  void _reconfigurer(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConfigScreen(
          onConfigured: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  // ─── Menu développeur (accès caché — appui long sur le logo) ─────────────
  void _afficherMenuDev(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.fondPapier,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr('outils_dev'),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: AppColors.encre,
              ),
            ),
            SizedBox(height: 4),
            Text(
              context.tr('acces_reserve'),
              style: TextStyle(fontSize: 12, color: AppColors.texteDoux),
            ),
            SizedBox(height: 16),
            ListTile(
              leading: Icon(Icons.wifi_find_rounded, color: AppColors.encre),
              title: Text(context.tr('tester_connexion')),
              onTap: () {
                Navigator.pop(context);
                _afficherDiagnostic(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.settings_rounded, color: AppColors.encre),
              title: Text(context.tr('reconfigurer')),
              onTap: () {
                Navigator.pop(context);
                _reconfigurer(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ─── Retirer une tontine de la liste locale ────────────────────────────────

  void _retirerTontine(
    BuildContext context,
    String code,
    String nom,
    TontineProvider provider,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          context.tr('retirer_tontine_titre'),
          style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre),
        ),
        content: Text(
          'Voulez-vous retirer "$nom" de votre liste locale ?\n'
          'La tontine reste accessible avec son code.',
          style: TextStyle(color: AppColors.texte),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.tr('annuler'),
                style: TextStyle(color: AppColors.encreDoux)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              provider.retirer(code);
            },
            child: Text(context.tr('retirer'),
                style: const TextStyle(color: AppColors.alerte,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  // ─── Diagnostic connexion Supabase ────────────────────────────────────────

  void _afficherDiagnostic(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.fondPapier,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _ModaleDiagnostic(),
    );
  }
}

// ─── Modale de diagnostic Supabase ───────────────────────────────────────────

class _ModaleDiagnostic extends StatefulWidget {
  const _ModaleDiagnostic();

  @override
  State<_ModaleDiagnostic> createState() => _ModaleDiagnosticState();
}

class _ModaleDiagnosticState extends State<_ModaleDiagnostic> {
  bool _enCours = true;
  DiagnosticResult? _resultat;

  // Test code direct
  final _codeCtrl = TextEditingController(text: 'D4CQZZ');
  bool _testEnCours = false;
  String? _reponseRaw;
  String? _testErreur;

  @override
  void initState() {
    super.initState();
    _lancer();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _lancer() async {
    setState(() { _enCours = true; _resultat = null; });
    final r = await SupabaseService.diagnostiquer();
    if (mounted) setState(() { _enCours = false; _resultat = r; });
  }

  // Teste directement un code et affiche la réponse HTTP brute
  Future<void> _testerCode() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.length != 6) return;
    setState(() { _testEnCours = true; _reponseRaw = null; _testErreur = null; });

    try {
      final url = SupabaseService.supabaseUrl;
      final key = SupabaseService.supabaseAnonKey;
      final uri = Uri.parse('$url/rest/v1/rpc/lire_tontine');
      final resp = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'apikey': key,
          'Authorization': 'Bearer $key',
        },
        body: jsonEncode({'p_code': code}),
      ).timeout(const Duration(seconds: 10));

      final raw = resp.body;
      if (mounted) {
        setState(() {
          _testEnCours = false;
          _reponseRaw = 'HTTP ${resp.statusCode}\n\n$raw';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testEnCours = false;
          _testErreur = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollCtrl) => SingleChildScrollView(
        controller: scrollCtrl,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          // Poignée
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppColors.lignes,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Diagnostic connexion',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, color: AppColors.encre),
          ),
          const SizedBox(height: 4),

          // URL configurée
          FutureBuilder<String?>(
            future: StorageService.getProjectUrl(),
            builder: (_, snap) => Text(
              snap.data ?? SupabaseService.supabaseUrl,
              style: const TextStyle(fontSize: 12.5, color: AppColors.texteDoux, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 20),

          if (_enCours)
            const Center(
              child: Column(
                children: [
                  CircularProgressIndicator(color: AppColors.encre, strokeWidth: 2.5),
                  SizedBox(height: 12),
                  Text('Test en cours…', style: TextStyle(color: AppColors.texteDoux)),
                ],
              ),
            )
          else if (_resultat != null) ...[
            _LigneDiag(
              ok: _resultat!.connecte,
              label: 'Connexion Supabase',
              detail: _resultat!.connecte
                  ? 'URL et clé anon valides'
                  : 'Impossible de joindre Supabase',
            ),
            const SizedBox(height: 10),
            _LigneDiag(
              ok: _resultat!.sqlInitialise,
              label: 'Scripts SQL exécutés',
              detail: _resultat!.sqlInitialise
                  ? 'Fonctions RPC disponibles'
                  : 'Scripts SQL manquants',
            ),
            const SizedBox(height: 16),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: (_resultat!.connecte && _resultat!.sqlInitialise)
                    ? AppColors.succesFond
                    : AppColors.alerteFond,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _resultat!.message,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: (_resultat!.connecte && _resultat!.sqlInitialise)
                      ? AppColors.succes
                      : AppColors.alerte,
                ),
              ),
            ),

            // ── Test direct d'un code ──────────────────────────────────
            if (_resultat!.connecte && _resultat!.sqlInitialise) ...[
              const SizedBox(height: 24),
              const Text(
                'Tester un code directement',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: AppColors.encre),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _codeCtrl,
                      maxLength: 6,
                      textCapitalization: TextCapitalization.characters,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                        letterSpacing: 2,
                        color: AppColors.encre,
                      ),
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: 'D4CQZZ',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.lignes),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.lignes),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.encre, width: 2),
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    onPressed: _testEnCours ? null : _testerCode,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.encre,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    ),
                    child: _testEnCours
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Tester'),
                  ),
                ],
              ),
              if (_reponseRaw != null) ...[
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: _reponseRaw!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Réponse copiée'), duration: Duration(seconds: 1)),
                    );
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C2447),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Réponse brute Supabase (appuyez pour copier)',
                            style: TextStyle(fontSize: 11, color: Colors.white54)),
                        const SizedBox(height: 6),
                        Text(
                          _reponseRaw!.length > 800
                              ? '${_reponseRaw!.substring(0, 800)}…'
                              : _reponseRaw!,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Colors.greenAccent,
                            fontFamily: 'monospace',
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (_testErreur != null)
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.alerteFond,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(_testErreur!,
                      style: TextStyle(color: AppColors.alerte, fontSize: 13)),
                ),
            ],
          ],

          SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _lancer,
                  icon: Icon(Icons.refresh_rounded, size: 16),
                  label: Text(context.tr('retester')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.encre,
                    side: const BorderSide(color: AppColors.lignes),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ConfigScreen(
                          onConfigured: () => Navigator.of(context).pop(),
                        ),
                      ),
                    );
                  },
                  icon: Icon(Icons.settings_rounded, size: 16),
                  label: Text(context.tr('reconfigurer')),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.encre,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
        ),
      ),
    );
  }
}
class _LigneDiag extends StatelessWidget {
  final bool ok;
  final String label;
  final String detail;
  const _LigneDiag({required this.ok, required this.label, required this.detail});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: ok ? AppColors.succesFond : AppColors.alerteFond,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Icon(
              ok ? Icons.check_rounded : Icons.close_rounded,
              size: 16,
              color: ok ? AppColors.succes : AppColors.alerte,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre)),
              Text(detail,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.texteDoux, height: 1.4)),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Carte tontine ─────────────────────────────────────────────────────────

class _CarteTontine extends StatelessWidget {
  final String code;
  final String nom;
  final VoidCallback onTap;
  final VoidCallback onRetirer;

  const _CarteTontine({
    required this.code,
    required this.nom,
    required this.onTap,
    required this.onRetirer,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
        decoration: BoxDecoration(
          color: AppColors.carte,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.lignes, width: 1),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1C2447).withValues(alpha: 0.05),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          children: [
            // Icône tontine
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: AppColors.encre,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Icon(Icons.groups_rounded, color: AppColors.or, size: 22),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          nom,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            color: AppColors.encre,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // BadgeMandat : affiché si la tontine courante = ce code et mode mandat
                      Builder(builder: (ctx) {
                        final courante = ctx.watch<TontineProvider>().courante;
                        if (courante != null &&
                            courante.code == code &&
                            courante.estSousMandat) {
                          return const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: BadgeMandat(),
                          );
                        }
                        return const SizedBox.shrink();
                      }),
                    ],
                  ),
                  SizedBox(height: 5),
                  Row(
                    children: [
                      Text(
                        context.tr('code_label'),
                        style: const TextStyle(fontSize: 13, color: AppColors.texteDoux),
                      ),
                      CodePuce(code: code),
                    ],
                  ),
                ],
              ),
            ),
            // Menu contextuel
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, color: AppColors.texteDoux),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              color: Colors.white,
              onSelected: (val) {
                if (val == 'retirer') onRetirer();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'retirer',
                  child: Row(
                    children: [
                      Icon(Icons.remove_circle_outline_rounded,
                          color: AppColors.alerte, size: 18),
                      SizedBox(width: 10),
                      Text(context.tr('retirer_liste'),
                          style: const TextStyle(color: AppColors.alerte, fontSize: 14)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── État vide ───────────────────────────────────────────────────────────────

class _EtatVideAccueil extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: 40),
      child: EtatVide(
        emoji: 'T',
        titre: context.tr('tontine_sans_dispute'),
        sousTitre: context.tr('tontine_description'),
      ),
    );
  }
}

// ─── Barre d'actions du bas ──────────────────────────────────────────────────

// ─── Bouton langue (globe) dans le header ─────────────────────────────────────

class _BoutonLangue extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ls = context.watch<LocaleService>();

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const LangueScreen()),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.encre.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.encre.withValues(alpha: 0.10),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ls.langue.drapeau,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(width: 5),
            Text(
              ls.langue.code.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.encre,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: AppColors.encre,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _BarreActions extends StatelessWidget {
  final VoidCallback onRejoindre;
  final VoidCallback onCreer;
  final VoidCallback onAdmin;

  const _BarreActions({
    required this.onRejoindre,
    required this.onCreer,
    required this.onAdmin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            AppColors.fondPapier,
            AppColors.fondPapier.withValues(alpha: 0),
          ],
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, 14, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: BtnSecondaire(
                  label: context.tr('rejoindre'),
                  onTap: onRejoindre,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: BtnKola(
                  label: '+ Créer',
                  onTap: onCreer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Bouton Admin discret : lien textuel sans fond ni bordure
          GestureDetector(
            onTap: onAdmin,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 12,
                    color: AppColors.encre.withValues(alpha: 0.30),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'Espace administrateur',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w400,
                      color: AppColors.encre.withValues(alpha: 0.35),
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
