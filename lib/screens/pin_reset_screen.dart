// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — PinResetScreen v2
// Parcours de réinitialisation du PIN en 3 étapes :
//   1. Saisie du contact (email / téléphone)
//   2. Code de vérification à 6 chiffres  ← Edge Function send-manager-pin
//   3. Nouveau PIN + confirmation
//
// Sécurité :
//   • Code généré côté SQL (SECURITY DEFINER), stocké SHA-256
//   • code_clair retourné UNE SEULE FOIS → envoyé via Edge Function SMTP
//   • SMTP_PASSWORD jamais dans le code Flutter ou GitHub
//   • Anti-énumération : réponse identique si contact inconnu
//   • Max 5 tentatives de saisie du code
//   • Bouton "Renvoyer" bloqué 60 secondes après chaque envoi
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Écran principal — orchestre les 3 étapes
// ─────────────────────────────────────────────────────────────────────────────
class PinResetScreen extends StatefulWidget {
  final String tontineCode;
  final String gestNom;

  const PinResetScreen({
    super.key,
    required this.tontineCode,
    required this.gestNom,
  });

  @override
  State<PinResetScreen> createState() => _PinResetScreenState();
}

class _PinResetScreenState extends State<PinResetScreen> {
  int    _etape   = 0; // 0=contact, 1=code, 2=nouveau PIN
  String _contact = '';
  String _emailGest = ''; // email récupéré depuis la RPC (pour le renvoi)

  void _allerEtape(int etape, {String contact = '', String emailGest = ''}) {
    setState(() {
      _etape = etape;
      if (contact.isNotEmpty)   _contact   = contact;
      if (emailGest.isNotEmpty) _emailGest = emailGest;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              const SizedBox(height: 18),
              // ── Header ─────────────────────────────────────────────────────
              Row(
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
              const SizedBox(height: 24),
              // ── Indicateur d'étape ─────────────────────────────────────────
              _IndicateurEtape(etape: _etape),
              const SizedBox(height: 24),
              // ── Contenu ────────────────────────────────────────────────────
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.05, 0),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: switch (_etape) {
                  0 => _EtapeContact(
                    key: const ValueKey(0),
                    tontineCode: widget.tontineCode,
                    gestNom:     widget.gestNom,
                    onSuivant:   (contact, emailGest) =>
                        _allerEtape(1, contact: contact, emailGest: emailGest),
                  ),
                  1 => _EtapeCode(
                    key: const ValueKey(1),
                    tontineCode: widget.tontineCode,
                    gestNom:     widget.gestNom,
                    contact:     _contact,
                    emailGest:   _emailGest,
                    onSuivant:   () => _allerEtape(2),
                    onRetour:    () => _allerEtape(0),
                  ),
                  _ => _EtapeNouveauPin(
                    key: const ValueKey(2),
                    tontineCode: widget.tontineCode,
                    gestNom:     widget.gestNom,
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Indicateur d'étape (3 cercles numérotés)
// ─────────────────────────────────────────────────────────────────────────────
class _IndicateurEtape extends StatelessWidget {
  final int etape;
  const _IndicateurEtape({required this.etape});

  @override
  Widget build(BuildContext context) {
    final labels = ['Contact', 'Code', 'Nouveau PIN'];
    return Row(
      children: List.generate(labels.length * 2 - 1, (i) {
        if (i.isOdd) {
          return Expanded(
            child: Container(
              height: 2,
              color: i ~/ 2 < etape ? AppColors.or : AppColors.lignes,
            ),
          );
        }
        final idx   = i ~/ 2;
        final actif = idx == etape;
        final fini  = idx <  etape;
        return Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 32, height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fini
                    ? AppColors.succes
                    : actif ? AppColors.encre : AppColors.fondCode,
                border: Border.all(
                  color: actif ? AppColors.encre : AppColors.lignes,
                  width: 1.5,
                ),
              ),
              child: Center(
                child: fini
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : Text(
                        '${idx + 1}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: actif ? Colors.white : AppColors.texteDoux,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              labels[idx],
              style: TextStyle(
                fontSize: 10,
                fontWeight: actif ? FontWeight.w700 : FontWeight.w400,
                color: actif ? AppColors.encre : AppColors.texteDoux,
              ),
            ),
          ],
        );
      }),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Étape 1 — Saisie du contact
// ─────────────────────────────────────────────────────────────────────────────
class _EtapeContact extends StatefulWidget {
  final String tontineCode;
  final String gestNom;
  final void Function(String contact, String emailGest) onSuivant;

  const _EtapeContact({
    super.key,
    required this.tontineCode,
    required this.gestNom,
    required this.onSuivant,
  });

  @override
  State<_EtapeContact> createState() => _EtapeContactState();
}

class _EtapeContactState extends State<_EtapeContact> {
  final _contactCtrl = TextEditingController();
  bool    _loading = false;
  String? _erreur;

  @override
  void dispose() {
    _contactCtrl.dispose();
    super.dispose();
  }

  Future<void> _envoyer() async {
    final contact = _contactCtrl.text.trim().toLowerCase();
    if (contact.isEmpty) {
      setState(() => _erreur = 'Veuillez saisir votre email ou téléphone.');
      return;
    }

    setState(() { _loading = true; _erreur = null; });

    try {
      // ── Étape A : RPC génère le code (stocké hashé) ──────────────────────
      final rpcResult = await SupabaseService.demanderResetPin(
        code:    widget.tontineCode,
        nom:     widget.gestNom,
        contact: contact,
      );

      if (!mounted) return;

      // Anti-énumération : toujours avancer à l'étape 2
      if (rpcResult['ok'] != true) {
        // Seul cas bloquant : rate limit explicite
        final erreur = rpcResult['erreur'] as String? ?? '';
        if (erreur.contains('Trop de tentatives') || erreur.contains('30 minutes')) {
          setState(() { _erreur = erreur; _loading = false; });
          return;
        }
      }

      // ── Étape B : si la RPC a généré un code → appel Edge Function SMTP ──
      final doitEnvoyer  = rpcResult['envoyer'] == true;
      final codeClair    = rpcResult['code_clair'] as String?;
      final emailGest    = rpcResult['email']    as String? ?? '';
      final gestNomReel  = rpcResult['gest_nom'] as String? ?? widget.gestNom;
      final tontineCode  = rpcResult['tontine_code'] as String? ?? widget.tontineCode;

      if (doitEnvoyer && codeClair != null && emailGest.isNotEmpty) {
        // Appel Edge Function — peut prendre quelques secondes (SMTP)
        final smtpResult = await SupabaseService.envoyerCodeResetPin(
          email:       emailGest,
          gestNom:     gestNomReel,
          tontineCode: tontineCode,
          codeClair:   codeClair,
        );

        if (!mounted) return;

        if (smtpResult['success'] != true) {
          // Message générique — détail dans logs Supabase
          setState(() {
            _erreur  = smtpResult['error'] as String?
                ?? "Impossible d'envoyer le code. Réessayez.";
            _loading = false;
          });
          return;
        }
      }

      // ── Toujours avancer (anti-énumération) ───────────────────────────────
      if (mounted) widget.onSuivant(contact, emailGest);

    } catch (e) {
      if (mounted) setState(() => _erreur = 'Erreur réseau. Réessayez.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Center(child: Text('🔑', style: TextStyle(fontSize: 40))),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              'PIN oublié ?',
              style: TextStyle(
                fontWeight: FontWeight.w800, fontSize: 22, color: AppColors.encre),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              'Gestionnaire : ${widget.gestNom}',
              style: const TextStyle(
                fontSize: 13, color: AppColors.texteDoux, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Saisissez votre adresse e-mail ou numéro de téléphone lié à votre profil.',
            style: TextStyle(fontSize: 14, color: AppColors.texte, height: 1.5),
          ),
          const SizedBox(height: 16),
          const ChampLabel(label: 'E-mail ou téléphone'),
          TextField(
            controller:      _contactCtrl,
            keyboardType:    TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText:   'Ex : gestionnaire@email.com ou +225 07 00 00 00',
              prefixIcon: Icon(Icons.alternate_email_rounded,
                  color: AppColors.encreDoux),
            ),
            onSubmitted: (_) => _envoyer(),
          ),
          ChampErreur(texte: _erreur),
          const SizedBox(height: 20),
          BtnPrincipal(
            label:   'Envoyer le code de vérification',
            icone:   Icons.send_rounded,
            onTap:   _envoyer,
            loading: _loading,
          ),
          const SizedBox(height: 12),
          const Center(
            child: Text(
              'Un code à 6 chiffres valable 10 minutes vous sera envoyé par e-mail.',
              style: TextStyle(fontSize: 12, color: AppColors.texteDoux),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Étape 2 — Saisie du code + bouton Renvoyer (cooldown 60 s)
// ─────────────────────────────────────────────────────────────────────────────
class _EtapeCode extends StatefulWidget {
  final String   tontineCode;
  final String   gestNom;
  final String   contact;
  final String   emailGest;   // email réel du gestionnaire (pour le renvoi)
  final VoidCallback onSuivant;
  final VoidCallback onRetour;

  const _EtapeCode({
    super.key,
    required this.tontineCode,
    required this.gestNom,
    required this.contact,
    required this.emailGest,
    required this.onSuivant,
    required this.onRetour,
  });

  @override
  State<_EtapeCode> createState() => _EtapeCodeState();
}

class _EtapeCodeState extends State<_EtapeCode> {
  final _codeCtrl = TextEditingController();
  bool    _loading          = false;
  bool    _renvoyant        = false;
  String? _erreur;
  int     _tentativesRest   = 5;
  // ── Timer "Renvoyer" : cooldown 60 secondes ──────────────────────────────
  int     _secondesRestantes = 0; // 0 = bouton actif
  Timer?  _timer;

  @override
  void initState() {
    super.initState();
    // Le code vient d'être envoyé à l'arrivée sur cet écran
    _demarrerCooldown();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _timer?.cancel();
    super.dispose();
  }

  // ── Démarre le compte à rebours de 60 secondes ────────────────────────────
  void _demarrerCooldown() {
    _timer?.cancel();
    setState(() => _secondesRestantes = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        _secondesRestantes--;
        if (_secondesRestantes <= 0) t.cancel();
      });
    });
  }

  // ── Renvoyer un nouveau code ──────────────────────────────────────────────
  Future<void> _renvoyer() async {
    if (_secondesRestantes > 0 || _renvoyant) return;

    setState(() { _renvoyant = true; _erreur = null; });

    try {
      // 1. Nouvelle RPC → nouveau code hashé
      final rpcResult = await SupabaseService.demanderResetPin(
        code:    widget.tontineCode,
        nom:     widget.gestNom,
        contact: widget.contact,
      );

      if (!mounted) return;

      final doitEnvoyer = rpcResult['envoyer'] == true;
      final codeClair   = rpcResult['code_clair'] as String?;
      final emailGest   = (rpcResult['email'] as String?)
                          ?? widget.emailGest;
      final gestNom     = (rpcResult['gest_nom'] as String?)
                          ?? widget.gestNom;

      if (doitEnvoyer && codeClair != null && emailGest.isNotEmpty) {
        // 2. Edge Function SMTP
        final smtpResult = await SupabaseService.envoyerCodeResetPin(
          email:       emailGest,
          gestNom:     gestNom,
          tontineCode: widget.tontineCode,
          codeClair:   codeClair,
        );

        if (!mounted) return;

        if (smtpResult['success'] != true) {
          setState(() =>
              _erreur = smtpResult['error'] as String?
                  ?? "Impossible d'envoyer le code. Réessayez.");
          return;
        }
      }

      // ✅ Renvoi ok — reset timer + champ
      _codeCtrl.clear();
      _demarrerCooldown();
      if (mounted) {
        afficherToast(context, 'Nouveau code envoyé !');
      }

    } catch (_) {
      if (mounted) {
        setState(() => _erreur = "Impossible d'envoyer le code. Réessayez.");
      }
    } finally {
      if (mounted) setState(() => _renvoyant = false);
    }
  }

  // ── Valider le code saisi ─────────────────────────────────────────────────
  Future<void> _valider() async {
    final code = _codeCtrl.text.trim();
    if (code.length != 6) {
      setState(() => _erreur = 'Le code fait 6 chiffres.');
      return;
    }

    setState(() { _loading = true; _erreur = null; });

    try {
      final result = await SupabaseService.validerCodeResetPin(
        codeTontine: widget.tontineCode,
        nom:         widget.gestNom,
        codeSaisi:   code,
      );

      if (!mounted) return;

      if (result['ok'] == true) {
        widget.onSuivant();
      } else {
        final restantes = result['tentatives_restantes'] as int? ?? 0;
        setState(() {
          _erreur           = result['erreur'] as String? ?? 'Code incorrect.';
          _tentativesRest   = restantes;
        });
        if (restantes <= 0) {
          await Future.delayed(const Duration(seconds: 2));
          if (mounted) widget.onRetour();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _erreur = 'Erreur réseau. Réessayez.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cooldownActif = _secondesRestantes > 0;

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Center(child: Text('📨', style: TextStyle(fontSize: 40))),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              'Vérification',
              style: TextStyle(
                fontWeight: FontWeight.w800, fontSize: 22, color: AppColors.encre),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Un code à 6 chiffres a été envoyé à\n${_masquerContact(widget.contact)}',
              style: const TextStyle(
                fontSize: 13, color: AppColors.texteDoux, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          const ChampLabel(label: 'Code de vérification'),
          TextField(
            controller:       _codeCtrl,
            keyboardType:     TextInputType.number,
            textAlign:        TextAlign.center,
            maxLength:        6,
            autofocus:        true,
            inputFormatters:  [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              hintText:    '• • • • • •',
              counterText: '',
              filled:      true,
              fillColor:   Colors.white,
              border:      OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            style: const TextStyle(
              fontSize:     32,
              fontWeight:   FontWeight.w800,
              letterSpacing: 12,
              color:        AppColors.encre,
            ),
            onSubmitted: (_) => _valider(),
          ),
          // ── Erreur + tentatives ───────────────────────────────────────────
          if (_erreur != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.alerteFond,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                const Icon(Icons.error_outline, size: 16, color: AppColors.alerte),
                const SizedBox(width: 8),
                Expanded(child: Text(_erreur!,
                    style: const TextStyle(fontSize: 13, color: AppColors.alerte))),
              ]),
            ),
            if (_tentativesRest > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '$_tentativesRest tentative(s) restante(s)',
                  style: const TextStyle(fontSize: 12, color: AppColors.texteDoux),
                ),
              ),
          ],
          const SizedBox(height: 20),
          // ── Bouton valider ────────────────────────────────────────────────
          BtnPrincipal(
            label:   'Valider le code',
            icone:   Icons.verified_rounded,
            onTap:   _valider,
            loading: _loading,
          ),
          const SizedBox(height: 16),
          // ── Bouton "Renvoyer le code" avec cooldown 60s ───────────────────
          Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: cooldownActif
                  // Cooldown actif — bouton désactivé avec compte à rebours
                  ? _BoutonRenvoyerDesactive(
                      key: const ValueKey('desactive'),
                      secondes: _secondesRestantes,
                    )
                  // Cooldown terminé — bouton actif
                  : _renvoyant
                      ? const SizedBox(
                          key: ValueKey('loading'),
                          height: 36,
                          child: Center(
                            child: SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2, color: AppColors.encre),
                            ),
                          ),
                        )
                      : TextButton.icon(
                          key: const ValueKey('actif'),
                          onPressed: _renvoyer,
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                          label: const Text(
                            'Renvoyer le code',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.encre,
                          ),
                        ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              '⏱ Ce code expire dans 10 minutes',
              style: TextStyle(fontSize: 12, color: AppColors.texteDoux),
            ),
          ),
        ],
      ),
    );
  }

  String _masquerContact(String contact) {
    if (contact.contains('@')) {
      final parts = contact.split('@');
      final nom = parts[0];
      if (nom.length <= 3) return '$nom@${parts[1]}';
      return '${nom.substring(0, 3)}***@${parts[1]}';
    }
    if (contact.length >= 6) {
      return '${contact.substring(0, 4)}****${contact.substring(contact.length - 2)}';
    }
    return contact;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget : bouton "Renvoyer" désactivé avec compte à rebours
// ─────────────────────────────────────────────────────────────────────────────
class _BoutonRenvoyerDesactive extends StatelessWidget {
  final int secondes;
  const _BoutonRenvoyerDesactive({super.key, required this.secondes});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14, height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            value: secondes / 60,
            color: AppColors.texteDoux,
            backgroundColor: AppColors.lignes,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'Renvoyer dans ${secondes}s',
          style: const TextStyle(
            fontSize: 13,
            color: AppColors.texteDoux,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Étape 3 — Nouveau PIN + confirmation
// ─────────────────────────────────────────────────────────────────────────────
class _EtapeNouveauPin extends StatefulWidget {
  final String tontineCode;
  final String gestNom;

  const _EtapeNouveauPin({
    super.key,
    required this.tontineCode,
    required this.gestNom,
  });

  @override
  State<_EtapeNouveauPin> createState() => _EtapeNouveauPinState();
}

class _EtapeNouveauPinState extends State<_EtapeNouveauPin> {
  final _pinCtrl      = TextEditingController();
  final _confirmCtrl  = TextEditingController();
  bool    _loading    = false;
  String? _erreur;
  bool    _pinVis     = false;
  bool    _confVis    = false;
  bool    _succes     = false;

  static const _pinsInterdits = {
    '0000','1111','2222','3333','4444','5555','6666','7777','8888','9999',
    '1234','4321','1212','0101','1010','0011','1100',
    '123456','654321','112233','000000','111111','999999','123123','321321',
  };

  @override
  void dispose() {
    _pinCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _appliquer() async {
    final pin     = _pinCtrl.text.trim();
    final confirm = _confirmCtrl.text.trim();

    if (pin.length < 4) {
      setState(() => _erreur = 'PIN trop court (4 chiffres minimum).');
      return;
    }
    if (_pinsInterdits.contains(pin)) {
      setState(() => _erreur = 'Ce PIN est trop simple. Choisissez-en un plus sécurisé.');
      return;
    }
    if (pin != confirm) {
      setState(() => _erreur = 'Les deux PIN ne correspondent pas.');
      return;
    }

    setState(() { _loading = true; _erreur = null; });

    try {
      final result = await SupabaseService.reinitialiserPin(
        codeTontine: widget.tontineCode,
        nom:         widget.gestNom,
        nouveauPin:  pin,
      );

      if (!mounted) return;

      if (result['ok'] == true) {
        setState(() => _succes = true);
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) Navigator.of(context).pop();
      } else {
        setState(() => _erreur = result['erreur'] as String? ?? 'Erreur. Réessayez.');
      }
    } catch (_) {
      if (mounted) setState(() => _erreur = 'Erreur réseau. Réessayez.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_succes) {
      return CarteTC(
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 72, height: 72,
              decoration: const BoxDecoration(
                color: AppColors.succesFond, shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  color: AppColors.succes, size: 40),
            ),
            const SizedBox(height: 20),
            const Text(
              'PIN réinitialisé !',
              style: TextStyle(
                fontWeight: FontWeight.w800, fontSize: 22, color: AppColors.succes),
            ),
            const SizedBox(height: 12),
            const Text(
              'Votre nouveau PIN de gestion est actif.\nVous allez être redirigé.',
              style: TextStyle(fontSize: 14, color: AppColors.texteDoux, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    }

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Center(child: Text('🛡️', style: TextStyle(fontSize: 40))),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              'Nouveau PIN',
              style: TextStyle(
                fontWeight: FontWeight.w800, fontSize: 22, color: AppColors.encre),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Définissez un PIN sécurisé et mémorable.',
              style: TextStyle(fontSize: 13, color: AppColors.texteDoux),
            ),
          ),
          const SizedBox(height: 24),
          const ChampLabel(label: 'Nouveau PIN'),
          TextField(
            controller:      _pinCtrl,
            keyboardType:    TextInputType.number,
            obscureText:     !_pinVis,
            maxLength:       6,
            textAlign:       TextAlign.center,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              hintText:    '••••',
              counterText: '',
              suffixIcon:  IconButton(
                icon: Icon(
                  _pinVis ? Icons.visibility_off : Icons.visibility,
                  color: AppColors.encreDoux,
                ),
                onPressed: () => setState(() => _pinVis = !_pinVis),
              ),
            ),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          const ChampLabel(label: 'Confirmer le PIN'),
          TextField(
            controller:      _confirmCtrl,
            keyboardType:    TextInputType.number,
            obscureText:     !_confVis,
            maxLength:       6,
            textAlign:       TextAlign.center,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              hintText:    '••••',
              counterText: '',
              suffixIcon:  IconButton(
                icon: Icon(
                  _confVis ? Icons.visibility_off : Icons.visibility,
                  color: AppColors.encreDoux,
                ),
                onPressed: () => setState(() => _confVis = !_confVis),
              ),
            ),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            onSubmitted: (_) => _appliquer(),
          ),
          ChampErreur(texte: _erreur),
          const SizedBox(height: 12),
          _ReglePIN(),
          const SizedBox(height: 20),
          BtnPrincipal(
            label:   'Enregistrer le nouveau PIN',
            icone:   Icons.lock_reset_rounded,
            onTap:   _appliquer,
            loading: _loading,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget : règles PIN
// ─────────────────────────────────────────────────────────────────────────────
class _ReglePIN extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:  AppColors.fondCode,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.lignes),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Règles du PIN :',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.encre)),
          const SizedBox(height: 6),
          for (final r in [
            '4 à 6 chiffres obligatoires',
            'Pas de suite simple (0000, 1234…)',
            'Jamais le même que l\'ancien PIN',
            'Ne communiquez jamais votre PIN',
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                const Icon(Icons.check_circle_outline_rounded,
                    size: 13, color: AppColors.succes),
                const SizedBox(width: 6),
                Text(r,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.texteDoux)),
              ]),
            ),
        ],
      ),
    );
  }
}
