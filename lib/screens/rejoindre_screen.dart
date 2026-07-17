import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/tontine_provider.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';
import 'detail_screen.dart';
import '../utils/app_localizations.dart';

class RejoindreScreen extends StatefulWidget {
  const RejoindreScreen({super.key});

  @override
  State<RejoindreScreen> createState() => _RejoindreScreenState();
}

class _RejoindreScreenState extends State<RejoindreScreen> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  String? _erreur;
  _TypeErreur? _typeErreur;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _rejoindre() async {
    final code = _ctrl.text.trim().toUpperCase();
    if (code.length != 6) {
      setState(() {
        _erreur = 'Le code doit faire exactement 6 caractères.';
        _typeErreur = _TypeErreur.format;
      });
      return;
    }
    setState(() {
      _loading    = true;
      _erreur     = null;
      _typeErreur = null;
    });

    try {
      final provider = context.read<TontineProvider>();
      final ok = await provider.rejoindre(code);

      if (!mounted) return;
      setState(() => _loading = false);

      if (ok) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => DetailScreen(code: code)),
        );
      } else {
        // rejoindre() a retourné false → lire l'erreur normalisée du provider
        final errProvider = provider.erreur ?? '';
        if (!mounted) return;
        setState(() {
          if (errProvider == 'TONTINE_DELETED' ||
              errProvider.contains('TONTINE_DELETED') ||
              errProvider.contains('supprimée') ||
              errProvider.contains('supprimee')) {
            // Tontine supprimée — message professionnel distinct
            _erreur     = 'Cette tontine a été supprimée par son gestionnaire.\n'
                          'Son code d\'invitation n\'est plus valide.';
            _typeErreur = _TypeErreur.supprimee;
          } else if (errProvider == 'CODE_INTROUVABLE' ||
                     errProvider.contains('CODE_INTROUVABLE')) {
            _erreur     = 'Code invalide ou expiré. Vérifiez le code puis réessayez.';
            _typeErreur = _TypeErreur.introuvable;
          } else if (errProvider.contains('PGRST202') ||
                     errProvider.toLowerCase().contains('introuvable')) {
            _erreur     = 'Base non initialisée.';
            _typeErreur = _TypeErreur.sqlManquant;
          } else {
            _erreur     = errProvider.isNotEmpty
                ? errProvider
                : 'Code invalide ou expiré. Vérifiez le code puis réessayez.';
            _typeErreur = _TypeErreur.introuvable;
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      setState(() {
        _loading = false;
        if (msg.contains('PGRST202') || msg.contains('SQL') ||
            msg.contains('scripts')) {
          _erreur     = 'Base de données non initialisée.';
          _typeErreur = _TypeErreur.sqlManquant;
        } else if (msg.contains('TONTINE_DELETED')) {
          _erreur     = 'Cette tontine a été supprimée par son gestionnaire.\n'
                        'Son code d\'invitation n\'est plus valide.';
          _typeErreur = _TypeErreur.supprimee;
        } else if (msg.contains('CODE_INTROUVABLE')) {
          _erreur     = 'Code invalide ou expiré. Vérifiez le code puis réessayez.';
          _typeErreur = _TypeErreur.introuvable;
        } else if (msg.contains('réseau') || msg.contains('SocketException')) {
          _erreur     = 'Erreur réseau. Vérifiez l\'URL Supabase.';
          _typeErreur = _TypeErreur.autre;
        } else if (msg.contains('401') || msg.contains('Clé anon')) {
          _erreur     = 'Clé anon invalide. Reconfigurez la connexion.';
          _typeErreur = _TypeErreur.cle;
        } else {
          _erreur     = 'Erreur : $msg';
          _typeErreur = _TypeErreur.autre;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 18),
              // En-tête
              Row(
                children: [
                  const LogoTontineClair(),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('Mes tontines'),
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
              const SizedBox(height: 20),
              const Text(
                'Rejoindre une tontine',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 30,
                  color: AppColors.encre,
                  letterSpacing: -0.5,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'Entre le code à 6 caractères transmis par ton gestionnaire.',
                style: TextStyle(fontSize: 15, color: AppColors.texteDoux),
              ),
              SizedBox(height: 20),

              // Champ code
              CarteTC(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ChampLabel(label: context.tr('code_rejoindre')),
                    TextField(
                      controller: _ctrl,
                      maxLength: 6,
                      textCapitalization: TextCapitalization.characters,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 28,
                        color: AppColors.encre,
                        letterSpacing: 0.3,
                      ),
                      decoration: InputDecoration(
                        hintText: 'AB4K9T',
                        hintStyle: TextStyle(
                          color: AppColors.texteDoux.withValues(alpha: 0.5),
                          fontSize: 28,
                        ),
                        counterText: '',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide:
                              const BorderSide(color: AppColors.lignes, width: 1.5),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide:
                              const BorderSide(color: AppColors.lignes, width: 1.5),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide:
                              const BorderSide(color: AppColors.encre, width: 2),
                        ),
                      ),
                      onChanged: (_) => setState(() {
                        _erreur     = null;
                        _typeErreur = null;
                      }),
                      onSubmitted: (_) => _rejoindre(),
                    ),
                  ],
                ),
              ),

              // Zone d'erreur contextuelle
              if (_erreur != null) _construireErreur(),

              SizedBox(height: 16),
              BtnPrincipal(
                label: context.tr('ouvrir_tontine'),
                onTap: _rejoindre,
                loading: _loading,
                icon: Icons.search_rounded,
              ),
              const SizedBox(height: 14),
              const Center(
                child: Text(
                  'Tu pourras tout consulter. Seuls les gestionnaires (avec le PIN) peuvent modifier.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.texteDoux),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Bloc d'erreur contextuel ──────────────────────────────────────────────

  Widget _construireErreur() {
    switch (_typeErreur) {

      // ── Migrations SQL manquantes ──────────────────────────────────────────
      case _TypeErreur.sqlManquant:
        return _CarteErreurSQL(code: _ctrl.text.trim().toUpperCase());

      // ── Tontine absente de CETTE base ─────────────────────────────────────
      case _TypeErreur.mauvaiseBase:
        return _CarteInfo(
          icone: Icons.cloud_off_rounded,
          couleur: AppColors.or,
          titre: 'Tontine absente de cette base',
          corps: 'La tontine "${_ctrl.text.trim().toUpperCase()}" '
              'n\'existe pas dans le projet Supabase actuellement configuré.\n\n'
              '→ Vérifiez que vous utilisez le bon projet Supabase '
              '(celui où la tontine a été créée).\n'
              '→ Si vous venez d\'un autre appareil, recconfigurez '
              'l\'URL + clé du projet d\'origine.',
          action: TextButton.icon(
            onPressed: () => Navigator.of(context)
                .popUntil((route) => route.isFirst),
            icon: const Icon(Icons.settings_rounded, size: 16),
            label: const Text('Reconfigurer Supabase'),
            style: TextButton.styleFrom(foregroundColor: AppColors.encre),
          ),
        );

      // ── Tontine supprimée ──────────────────────────────────────────────────
      case _TypeErreur.supprimee:
        return _CarteInfo(
          icone: Icons.delete_forever_rounded,
          couleur: AppColors.alerte,
          titre: 'Tontine supprimée',
          corps: 'Cette tontine a été supprimée définitivement par son gestionnaire.\n\n'
              '• Son code d\'invitation n\'est plus valide.\n'
              '• Aucune adhésion ni opération n\'est possible.\n'
              '• Si vous pensez qu\'il s\'agit d\'une erreur, contactez '
              'votre gestionnaire ou le support TontineClair.',
        );

      // ── Introuvable / code invalide ────────────────────────────────────────
      case _TypeErreur.introuvable:
        return _CarteInfo(
          icone: Icons.search_off_rounded,
          couleur: AppColors.alerte,
          titre: 'Code invalide ou expiré',
          corps: 'Aucune tontine active ne correspond au code '
              '"${_ctrl.text.trim().toUpperCase()}".\n\n'
              '• Vérifiez que le code est exact (majuscules, pas de zéro/O).\n'
              '• Demandez à votre gestionnaire de vous communiquer le code actuel.',
        );

      // ── Clé invalide ───────────────────────────────────────────────────────
      case _TypeErreur.cle:
        return _CarteInfo(
          icone: Icons.vpn_key_off_rounded,
          couleur: AppColors.alerte,
          titre: 'Clé Supabase invalide',
          corps: 'La clé anon configurée est refusée par Supabase.\n'
              'Recconfigurez la connexion avec la clé correcte.',
          action: TextButton.icon(
            onPressed: () => Navigator.of(context)
                .popUntil((route) => route.isFirst),
            icon: const Icon(Icons.settings_rounded, size: 16),
            label: const Text('Reconfigurer'),
            style: TextButton.styleFrom(foregroundColor: AppColors.encre),
          ),
        );

      // ── Erreur format ──────────────────────────────────────────────────────
      case _TypeErreur.format:
      case _TypeErreur.autre:
      default:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ChampErreur(texte: _erreur),
        );
    }
  }
}

// ─── Types d'erreur ────────────────────────────────────────────────────────
enum _TypeErreur { format, introuvable, supprimee, sqlManquant, mauvaiseBase, cle, autre }

// ─── Carte guide SQL ────────────────────────────────────────────────────────
class _CarteErreurSQL extends StatefulWidget {
  final String code;
  const _CarteErreurSQL({required this.code});

  @override
  State<_CarteErreurSQL> createState() => _CarteErreurSQLState();
}

class _CarteErreurSQLState extends State<_CarteErreurSQL> {
  int _etape = 0; // 0 = intro, 1..5 = chaque script SQL

  final List<_ScriptSQL> _scripts = const [
    _ScriptSQL(nom: 'supabase.sql',    version: 'Base',  desc: 'Crée la table tontines + fonctions de base'),
    _ScriptSQL(nom: 'supabase-v2.sql', version: 'v2',    desc: 'PIN par gestionnaire'),
    _ScriptSQL(nom: 'supabase-v3.sql', version: 'v3',    desc: 'Journal d\'audit'),
    _ScriptSQL(nom: 'supabase-v4.sql', version: 'v4',    desc: 'Vote sécurisé'),
    _ScriptSQL(nom: 'supabase-v5.sql', version: 'v5',    desc: 'Abonnement freemium'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.or.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Titre
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.or.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.build_rounded, color: AppColors.orFonce, size: 18),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Base de données non initialisée',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: AppColors.encre,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          if (_etape == 0) ...[
            const Text(
              'Les scripts SQL n\'ont pas encore été exécutés sur ce projet Supabase. '
              'Suivez ces 5 étapes dans le SQL Editor de Supabase.',
              style: TextStyle(fontSize: 13.5, color: AppColors.texte, height: 1.5),
            ),
            const SizedBox(height: 12),
            // Liste des scripts
            ...List.generate(_scripts.length, (i) => _LigneScript(
              script: _scripts[i],
              numero: i + 1,
            )),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      // Ouvrir Supabase dans le navigateur
                    },
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Ouvrir Supabase'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.encre,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
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

class _ScriptSQL {
  final String nom;
  final String version;
  final String desc;
  const _ScriptSQL({required this.nom, required this.version, required this.desc});
}

class _LigneScript extends StatelessWidget {
  final _ScriptSQL script;
  final int numero;
  const _LigneScript({required this.script, required this.numero});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: AppColors.encre,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Text(
                '$numero',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  script.nom,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.encre,
                    fontFamily: 'monospace',
                  ),
                ),
                Text(
                  script.desc,
                  style: const TextStyle(fontSize: 12, color: AppColors.texteDoux),
                ),
              ],
            ),
          ),
          // Copier le nom du fichier
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 16, color: AppColors.encreDoux),
            tooltip: 'Copier le nom',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: script.nom));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${script.nom} copié'),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 1),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ─── Carte info générique ───────────────────────────────────────────────────
class _CarteInfo extends StatelessWidget {
  final IconData icone;
  final Color couleur;
  final String titre;
  final String corps;
  final Widget? action;

  const _CarteInfo({
    required this.icone,
    required this.couleur,
    required this.titre,
    required this.corps,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: couleur.withValues(alpha: 0.3), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icone, color: couleur, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  titre,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: couleur == AppColors.alerte ? AppColors.alerte : AppColors.encre,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            corps,
            style: const TextStyle(
              fontSize: 13.5,
              color: AppColors.texte,
              height: 1.5,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 8),
            action!,
          ],
        ],
      ),
    );
  }
}
