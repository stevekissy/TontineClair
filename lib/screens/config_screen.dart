import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/storage_service.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';

class ConfigScreen extends StatefulWidget {
  final VoidCallback onConfigured;

  const ConfigScreen({super.key, required this.onConfigured});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loading     = false;
  bool _showKey     = false;   // afficher/masquer la clé
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _preRemplir();
  }

  /// Si une config existe déjà, la pré-remplir pour modification facile.
  Future<void> _preRemplir() async {
    final url = await StorageService.getProjectUrl();
    final key = await StorageService.getAnonKey();
    if (!mounted) return;
    if (url != null && url.isNotEmpty) _urlCtrl.text = url;
    if (key != null && key.isNotEmpty) _keyCtrl.text = key;
  }

  /// Normalise l'ID projet ou l'URL complète → URL Supabase propre.
  String _normaliserUrl(String input) {
    input = input.trim();
    // Si c'est juste un ID de projet (ex: "ubrqtcxbxcmvmxleiglh")
    if (!input.contains('.') && !input.startsWith('http')) {
      return 'https://$input.supabase.co';
    }
    // Si c'est déjà une URL mais sans schéma
    if (!input.startsWith('http')) {
      input = 'https://$input';
    }
    // Supprimer le slash final
    return input.endsWith('/') ? input.substring(0, input.length - 1) : input;
  }

  Future<void> _valider() async {
    setState(() => _erreur = null);
    if (!_formKey.currentState!.validate()) return;

    final urlBrut = _urlCtrl.text.trim();
    final key     = _keyCtrl.text.trim();
    final url     = _normaliserUrl(urlBrut);

    // Vérification minimale de la clé : doit être un JWT (commence par eyJ)
    if (!key.startsWith('eyJ')) {
      setState(() => _erreur =
          'La clé anon doit commencer par "eyJ…". '
          'Copiez-la depuis Supabase → Settings → API → anon public.');
      return;
    }

    setState(() => _loading = true);

    try {
      // Injecter temporairement pour tester
      SupabaseService.supabaseUrl     = url;
      SupabaseService.supabaseAnonKey = key;

      // Test de connexion : appel d'une fonction RPC qui existe toujours
      // On attend soit un résultat soit une erreur métier (tontine inconnue)
      // Dans les deux cas, la connexion est valide.
      await SupabaseService.rpc('lire_plan', {'p_code': 'TEST00'});

      // Si on arrive ici sans exception = connexion OK
      await StorageService.sauvegarderConfig(projectUrl: url, anonKey: key);
      if (mounted) widget.onConfigured();

    } catch (e) {
      final msg = e.toString();

      // Ces messages signifient que la connexion a fonctionné
      // mais la tontine TEST00 n'existe pas — c'est normal
      if (msg.contains('introuvable') ||
          msg.contains('not found')   ||
          msg.contains('PGRST202')    ||   // fonction non trouvée = schéma pas encore exécuté
          msg.contains('PGRST301')    ||   // tontine inconnue
          msg.contains('42883')) {
        await StorageService.sauvegarderConfig(projectUrl: url, anonKey: key);
        if (mounted) widget.onConfigured();
        return;
      }

      // Erreur d'authentification (clé incorrecte)
      if (msg.contains('401') ||
          msg.contains('Invalid API key') ||
          msg.contains('JWT')) {
        setState(() {
          _loading = false;
          _erreur  = 'Clé anon invalide. Vérifiez dans Supabase → Settings → API.';
        });
        return;
      }

      // Erreur réseau ou URL incorrecte
      if (msg.contains('SocketException') ||
          msg.contains('HandshakeException') ||
          msg.contains('Connection refused') ||
          msg.contains('host lookup')) {
        setState(() {
          _loading = false;
          _erreur  = 'Impossible de joindre "$url". '
              'Vérifiez l\'URL du projet (ex: https://xxxx.supabase.co).';
        });
        return;
      }

      // Autre erreur imprévue
      setState(() {
        _loading = false;
        _erreur  = 'Erreur : $msg';
      });
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),

                // ── En-tête ──────────────────────────────────────────
                Row(
                  children: [
                    const LogoTontineClair(fontSize: 24),
                    const Spacer(),
                    Image.asset(
                      'assets/icons/icone-192.png',
                      width: 38,
                      height: 38,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ],
                ),
                const SizedBox(height: 28),

                const Text(
                  'Connexion Supabase',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 26,
                    color: AppColors.encre,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Renseignez les identifiants de votre projet Supabase pour démarrer.',
                  style: TextStyle(fontSize: 14.5, color: AppColors.texteDoux, height: 1.5),
                ),

                const SizedBox(height: 20),

                // ── Étapes ───────────────────────────────────────────
                CarteTC(
                  child: Column(
                    children: [
                      _Etape(
                        num: '1',
                        texte: 'Créez un projet sur supabase.com et exécutez les fichiers SQL fournis (supabase.sql → v2 → v3 → v4 → v5).',
                      ),
                      const Divider(height: 24, color: AppColors.lignes),
                      _Etape(
                        num: '2',
                        texte: 'Dans Settings → API, copiez l\'URL du projet (ex: https://xxxx.supabase.co).',
                      ),
                      const Divider(height: 24, color: AppColors.lignes),
                      _Etape(
                        num: '3',
                        texte: 'Copiez la clé anon (public) — elle commence par "eyJhbGci…".',
                      ),
                    ],
                  ),
                ),

                // ── Champ URL du projet ───────────────────────────────
                const ChampLabel(label: 'URL du projet Supabase'),
                TextFormField(
                  controller: _urlCtrl,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'https://xxxx.supabase.co  ou  xxxx',
                    filled: true,
                    fillColor: Colors.white,
                    prefixIcon: const Icon(Icons.link_rounded, color: AppColors.encreDoux, size: 20),
                    suffixIcon: _urlCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18, color: AppColors.texteDoux),
                            onPressed: () => setState(() => _urlCtrl.clear()),
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.lignes, width: 1.5),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.lignes, width: 1.5),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.encre, width: 2),
                    ),
                    errorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.alerte, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Champ obligatoire';
                    return null;
                  },
                ),
                const ChampAide(texte: 'Vous pouvez coller juste l\'ID du projet (ex: ubrqtcxbxcmvmxleiglh) — l\'URL sera construite automatiquement.'),

                // ── Champ Clé anon ────────────────────────────────────
                const ChampLabel(label: 'Clé anon (public)'),
                TextFormField(
                  controller: _keyCtrl,
                  obscureText: !_showKey,
                  maxLines: _showKey ? 3 : 1,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    hintText: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9…',
                    filled: true,
                    fillColor: Colors.white,
                    prefixIcon: const Icon(Icons.vpn_key_rounded, color: AppColors.encreDoux, size: 20),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Bouton coller
                        IconButton(
                          icon: const Icon(Icons.content_paste_rounded, size: 18, color: AppColors.encreDoux),
                          tooltip: 'Coller',
                          onPressed: () async {
                            final data = await Clipboard.getData('text/plain');
                            if (data?.text != null) {
                              setState(() => _keyCtrl.text = data!.text!.trim());
                            }
                          },
                        ),
                        // Afficher/masquer
                        IconButton(
                          icon: Icon(
                            _showKey ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                            size: 18,
                            color: AppColors.encreDoux,
                          ),
                          tooltip: _showKey ? 'Masquer' : 'Afficher',
                          onPressed: () => setState(() => _showKey = !_showKey),
                        ),
                      ],
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.lignes, width: 1.5),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.lignes, width: 1.5),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.encre, width: 2),
                    ),
                    errorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.alerte, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Champ obligatoire';
                    if (v.trim().length < 40) return 'La clé anon semble trop courte';
                    return null;
                  },
                ),
                const ChampAide(
                  texte: 'Supabase → Settings → API → "anon public". '
                      'Cette clé commence toujours par "eyJhbGci…". '
                      'Elle est conçue pour être embarquée dans les apps mobiles.',
                ),

                // ── Erreur globale ────────────────────────────────────
                if (_erreur != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.alerteFond,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.alerte.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            color: AppColors.alerte, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _erreur!,
                            style: const TextStyle(
                              fontSize: 13.5,
                              color: AppColors.alerte,
                              fontWeight: FontWeight.w600,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                // ── Bouton de validation ──────────────────────────────
                BtnPrincipal(
                  label: 'Confirmer la connexion',
                  onTap: _valider,
                  loading: _loading,
                  icon: Icons.check_circle_outline_rounded,
                ),

                const SizedBox(height: 12),

                // Lien vers la doc Supabase
                Center(
                  child: TextButton.icon(
                    onPressed: () {
                      // url_launcher vers la doc Supabase (optionnel)
                    },
                    icon: const Icon(Icons.open_in_new_rounded, size: 15, color: AppColors.encreDoux),
                    label: const Text(
                      'supabase.com → Documentation',
                      style: TextStyle(fontSize: 13, color: AppColors.encreDoux),
                    ),
                  ),
                ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Widget étape numérotée ──────────────────────────────────────

class _Etape extends StatelessWidget {
  final String num;
  final String texte;

  const _Etape({required this.num, required this.texte});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: AppColors.encre,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              num,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            texte,
            style: const TextStyle(
              fontSize: 13.5,
              color: AppColors.texte,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}
