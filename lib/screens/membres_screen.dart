// ─────────────────────────────────────────────────────────────────────────────
// Module Membres — TontineClair
// Spécification : FICHE-MODULE-MEMBRES.pdf + index.html (ongletMembres,
//                 scoreConfiance, definirPinMembre, changerMonPin)
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/score_service.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import 'score_membre_screen.dart';
import 'classement_screen.dart';
import '../utils/app_localizations.dart';
import '../services/locale_service.dart';

// ─── Constantes couleurs score ────────────────────────────────────────────────
const _scoreExcellent = Color(0xFF2E7D5B); // ≥80
const _scoreBon = Color(0xFF35407A);        // ≥65
const _scoreMoyen = Color(0xFFD99A2B);      // ≥50
const _scoreRisque = Color(0xFFE07A2F);     // ≥35
const _scoreTresRisque = Color(0xFFC4453C); // <35

Color _couleurScore(int score) {
  if (score >= 80) return _scoreExcellent;
  if (score >= 65) return _scoreBon;
  if (score >= 50) return _scoreMoyen;
  if (score >= 35) return _scoreRisque;
  return _scoreTresRisque;
}

String _labelScore(int score, BuildContext context) {
  if (score >= 80) return context.tr('tres_fiable');
  if (score >= 65) return context.tr('fiable');
  if (score >= 50) return context.tr('a_surveiller');
  if (score >= 35) return context.tr('risque');
  return context.tr('tres_risque');
}

// ─── Score via ScoreService (SOURCE UNIQUE de calcul) ────────────────────────
// Les voix du membre sont passées depuis _voixParMembre chargé via Supabase.
// Cela garantit que la liste des membres affiche exactement le même score
// que la fiche détaillée et le classement.

// ─── Écran principal ──────────────────────────────────────────────────────────
class MembresScreen extends StatefulWidget {
  final String code;

  const MembresScreen({super.key, required this.code});

  @override
  State<MembresScreen> createState() => _MembresScreenState();
}

class _MembresScreenState extends State<MembresScreen> {
  // PIN des membres ayant défini leur PIN (IDs)
  Set<String> _membresAvecPin = {};
  // Voix par membre : {membreId: [{vote_id, choix, quand, ...}]}
  Map<String, List<Map<String, dynamic>>> _voixParMembre = {};
  bool _chargement = true;
  String? _erreurChargement;

  // PIN provisoire généré par le gestionnaire (en mémoire uniquement)
  // {membreId: pinProvisoire}
  final Map<String, String> _pinsProvisoires = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _charger());
  }

  Future<void> _charger() async {
    setState(() {
      _chargement = true;
      _erreurChargement = null;
    });
    try {
      final avecPin = await SupabaseService.membresAvecPin(widget.code);
      final voixBrutes = await SupabaseService.lireVoix(widget.code);

      // Indexer les voix par membre
      final voixMap = <String, List<Map<String, dynamic>>>{};
      for (final v in voixBrutes) {
        final mid = v['membre_id'] as String? ?? '';
        voixMap.putIfAbsent(mid, () => []).add(v);
      }

      if (!mounted) return;
      setState(() {
        _membresAvecPin = avecPin.toSet();
        _voixParMembre = voixMap;
        _chargement = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erreurChargement = 'Erreur de chargement : $e';
        _chargement = false;
      });
    }
  }

  // _attribuerPin : délégué à _afficherModalAttribuer (non utilisé directement)

  // ── Ouvrir WhatsApp avec le message PIN ──────────────────────────────────
  Future<void> _envoyerWhatsApp(
    BuildContext ctx,
    Membre membre,
    String pin,
    TontineData data,
  ) async {
    final lang = Provider.of<LocaleService>(ctx, listen: false).langue.code;
    const _pinMsgs = {
      'fr': '🔑 *TON PIN DE VOTE*\n'
          'Bonjour {nom}, voici ton PIN de vote personnel : *{pin}*\n'
          'Tontine : {tontine}\n'
          'Change-le dès maintenant (2 minutes) :\n'
          '1. Ouvre TontineClair et entre le code : {code}\n'
          '2. Va dans l\'onglet Membres, tout en bas : « 🔑 Changer mon PIN de vote »\n'
          '3. Choisis ton nom, entre ce PIN provisoire puis ton nouveau PIN secret\n'
          'Après ça, toi seul connais ton PIN. Personne d\'autre ne peut voter à ta place. 🔒',
      'en': '🔑 *YOUR VOTING PIN*\n'
          'Hello {nom}, here is your personal voting PIN: *{pin}*\n'
          'Tontine: {tontine}\n'
          'Change it now (2 minutes):\n'
          '1. Open TontineClair and enter the code: {code}\n'
          '2. Go to the Members tab, at the bottom: « 🔑 Change my voting PIN »\n'
          '3. Choose your name, enter this temporary PIN then your new secret PIN\n'
          'After that, only you know your PIN. No one else can vote in your place. 🔒',
      'es': '🔑 *TU PIN DE VOTACIÓN*\n'
          'Hola {nom}, aquí está tu PIN de votación personal: *{pin}*\n'
          'Tontina: {tontine}\n'
          'Cámbialo ahora (2 minutos):\n'
          '1. Abre TontineClair e introduce el código: {code}\n'
          '2. Ve a la pestaña Miembros, al final: « 🔑 Cambiar mi PIN de votación »\n'
          '3. Elige tu nombre, introduce este PIN provisional y luego tu nuevo PIN secreto\n'
          'Después, solo tú conoces tu PIN. Nadie más puede votar en tu lugar. 🔒',
      'pt': '🔑 *O SEU PIN DE VOTAÇÃO*\n'
          'Olá {nom}, aqui está o seu PIN de votação pessoal: *{pin}*\n'
          'Tontina: {tontine}\n'
          'Altere-o agora (2 minutos):\n'
          '1. Abra o TontineClair e insira o código: {code}\n'
          '2. Vá ao separador Membros, no final: « 🔑 Alterar o meu PIN de votação »\n'
          '3. Escolha o seu nome, insira este PIN provisório e depois o seu novo PIN secreto\n'
          'Depois disso, só você conhece o seu PIN. Mais ninguém pode votar em seu lugar. 🔒',
      'ar': '🔑 *رمز التصويت الخاص بك*\n'
          'مرحباً {nom}، إليك رمز التصويت الشخصي الخاص بك: *{pin}*\n'
          'التنتين: {tontine}\n'
          'قم بتغييره الآن (دقيقتان):\n'
          '1. افتح TontineClair وأدخل الرمز: {code}\n'
          '2. انتقل إلى تبويب الأعضاء، في الأسفل: « 🔑 تغيير رمز التصويت »\n'
          '3. اختر اسمك، أدخل هذا الرمز المؤقت ثم رمزك السري الجديد\n'
          'بعد ذلك، أنت وحدك تعرف رمزك. لا يمكن لأحد آخر التصويت بدلاً عنك. 🔒',
    };
    final msg = (_pinMsgs[lang] ?? _pinMsgs['fr']!)
        .replaceAll('{nom}', membre.nom)
        .replaceAll('{pin}', pin)
        .replaceAll('{tontine}', data.nom)
        .replaceAll('{code}', widget.code);
    final encoded = Uri.encodeComponent(msg);

    // Utiliser le numéro si disponible (message privé direct), sinon sélecteur de contact
    final tel = (membre.tel ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
    final url = tel.isNotEmpty
        ? Uri.parse('https://wa.me/$tel?text=$encoded')
        : Uri.parse('https://wa.me/?text=$encoded');

    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  // ── Modal : attribuer PIN (gestionnaire) ─────────────────────────────────
  void _afficherModalAttribuer(BuildContext ctx, Membre membre, TontineData data) {
    final pinCtrl = TextEditingController();
    String? erreur;
    bool loading = false;

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(builder: (sCtx, setSt) {
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(sCtx).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
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
                const SizedBox(height: 20),
                Text(
                  _membresAvecPin.contains(membre.id)
                      ? '🔄 Réinitialiser le PIN de ${membre.nom}'
                      : '🔑 Attribuer un PIN à ${membre.nom}',
                  style: GoogleFonts.bricolageGrotesque(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: AppColors.encre,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Entre ton PIN gestionnaire pour confirmer.',
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
                    color: AppColors.texteDoux,
                  ),
                ),
                SizedBox(height: 16),
                TextField(
                  controller: pinCtrl,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: context.tr('pin_gestionnaire'),
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
                          const BorderSide(color: AppColors.encre, width: 1.5),
                    ),
                  ),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.texte,
                  ),
                ),
                if (erreur != null)
                  Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      erreur!,
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.alerte,
                      ),
                    ),
                  ),
                SizedBox(height: 16),
                BtnPrincipal(
                  label: _membresAvecPin.contains(membre.id)
                      ? context.tr('reinitialiser_pin')
                      : context.tr('generer_pin'),
                  loading: loading,
                  onTap: () async {
                    if (pinCtrl.text.length < 4) {
                      setSt(() => erreur = context.tr('pin_trop_court'));
                      return;
                    }
                    setSt(() {
                      loading = true;
                      erreur = null;
                    });
                    final pin = (1000 + math.Random().nextInt(8999)).toString();
                    final ok = await SupabaseService.definirPinMembre(
                      code: widget.code,
                      gestNom: data.gestionnaires.firstOrNull?.nom ?? '',
                      gestPin: pinCtrl.text.trim(),
                      membreId: membre.id,
                      nouveauPin: pin,
                    );
                    if (!sCtx.mounted) return;
                    setSt(() => loading = false);
                    if (ok) {
                      setState(() {
                        _membresAvecPin.add(membre.id);
                        _pinsProvisoires[membre.id] = pin;
                      });
                      Navigator.of(sCtx).pop();
                      // Afficher PIN provisoire + WhatsApp
                      _afficherPinProvisoire(ctx, membre, pin, data);
                    } else {
                      setSt(
                          () => erreur = 'PIN gestionnaire incorrect. Réessayez.');
                    }
                  },
                ),
                SizedBox(height: 8),
                BtnSecondaire(
                  label: context.tr('annuler'),
                  onTap: () => Navigator.of(sCtx).pop(),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  // ── Modal : afficher PIN provisoire + bouton WhatsApp ────────────────────
  void _afficherPinProvisoire(
    BuildContext ctx,
    Membre membre,
    String pin,
    TontineData data,
  ) {
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              SizedBox(height: 20),
              Text('✅', style: TextStyle(fontSize: 36)),
              SizedBox(height: 12),
              Text(
                "${context.tr('pin_attribue')} — ${membre.nom}",
                style: GoogleFonts.bricolageGrotesque(
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                  color: AppColors.encre,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.fondCode,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.encreDoux.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    Text(
                      context.tr('pin_provisoire'),
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        color: AppColors.texteDoux,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      pin,
                      style: GoogleFonts.bricolageGrotesque(
                        fontWeight: FontWeight.w800,
                        fontSize: 36,
                        color: AppColors.encre,
                        letterSpacing: 8,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      context.tr('communication_pin'),
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: AppColors.texteDoux,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16),
              // Bug #5 fix : bouton WhatsApp toujours visible (fallback wa.me/?text= si pas de tel)
              BtnWhatsApp(
                label: context.tr('envoyer_pin_whatsapp'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _envoyerWhatsApp(ctx, membre, pin, data);
                },
              ),
              SizedBox(height: 8),
              BtnSecondaire(
                label: context.tr('fermer'),
                onTap: () => Navigator.of(sheetCtx).pop(),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Modal : Changer mon PIN (membre) ──────────────────────────────────────
  void _afficherChangerPin(BuildContext ctx, TontineData data) {
    String? membreSelectionne;
    final ancienCtrl = TextEditingController();
    final nouveauCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? erreur;
    bool loading = false;

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(builder: (sCtx, setSt) {
          return SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(sCtx).viewInsets.bottom + 24,
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
                SizedBox(height: 20),
                Text(
                  '🔑 Changer mon PIN de vote',
                  style: GoogleFonts.bricolageGrotesque(
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    color: AppColors.encre,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  context.tr('ancien_pin'),
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
                    color: AppColors.texteDoux,
                  ),
                ),
                const SizedBox(height: 18),

                // Sélection du membre
                Text(
                  'Mon nom',
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    color: AppColors.encre,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.lignes, width: 1.5),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: ButtonTheme(
                      alignedDropdown: true,
                      child: DropdownButton<String>(
                        value: membreSelectionne,
                        hint: Text(
                          'Choisir mon nom',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            color: AppColors.texteDoux,
                          ),
                        ),
                        isExpanded: true,
                        icon: const Icon(Icons.keyboard_arrow_down,
                            color: AppColors.encre),
                        items: data.membres
                            .where((m) => _membresAvecPin.contains(m.id))
                            .map((m) => DropdownMenuItem(
                                  value: m.id,
                                  child: Text(
                                    m.nom,
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.texte,
                                    ),
                                  ),
                                ))
                            .toList(),
                        onChanged: (v) => setSt(() {
                          membreSelectionne = v;
                          erreur = null;
                        }),
                      ),
                    ),
                  ),
                ),

                SizedBox(height: 14),
                _ChampPin(
                  label: context.tr('ancien_pin'),
                  ctrl: ancienCtrl,
                  placeholder: 'PIN reçu par le gestionnaire',
                ),
                const SizedBox(height: 14),
                _ChampPin(
                  label: 'Nouveau PIN secret',
                  ctrl: nouveauCtrl,
                  placeholder: '4 à 6 chiffres',
                ),
                const SizedBox(height: 14),
                _ChampPin(
                  label: 'Confirmer le nouveau PIN',
                  ctrl: confirmCtrl,
                  placeholder: 'Répéter le nouveau PIN',
                ),

                if (erreur != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      erreur!,
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.alerte,
                      ),
                    ),
                  ),

                const SizedBox(height: 20),
                BtnPrincipal(
                  label: 'Changer mon PIN',
                  loading: loading,
                  onTap: () async {
                    if (membreSelectionne == null) {
                      setSt(() => erreur = 'Choisis ton nom dans la liste.');
                      return;
                    }
                    if (ancienCtrl.text.length < 4) {
                      setSt(() => erreur = 'Ancien PIN trop court.');
                      return;
                    }
                    if (nouveauCtrl.text.length < 4) {
                      setSt(() => erreur = 'Nouveau PIN trop court (4 chiffres min.).');
                      return;
                    }
                    if (nouveauCtrl.text != confirmCtrl.text) {
                      setSt(() => erreur = 'Les deux nouveaux PINs ne correspondent pas.');
                      return;
                    }
                    setSt(() {
                      loading = true;
                      erreur = null;
                    });
                    final ok = await SupabaseService.changerPinMembre(
                      code: widget.code,
                      membreId: membreSelectionne!,
                      ancienPin: ancienCtrl.text.trim(),
                      nouveauPin: nouveauCtrl.text.trim(),
                    ); // signature : {code, membreId, ancienPin, nouveauPin}
                    if (!sCtx.mounted) return;
                    setSt(() => loading = false);
                    if (ok) {
                      // Supprimer le PIN provisoire en mémoire
                      setState(() => _pinsProvisoires.remove(membreSelectionne));
                      Navigator.of(sCtx).pop();
                      afficherToast(ctx, '🔑 PIN changé avec succès !');
                    } else {
                      setSt(() => erreur =
                          'Ancien PIN incorrect ou opération refusée. Réessayez.');
                    }
                  },
                ),
                const SizedBox(height: 8),
                BtnSecondaire(
                  label: 'Annuler',
                  onTap: () => Navigator.of(sCtx).pop(),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;
    if (tontine == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final data = tontine.data;
    final estGest = provider.estDebloque;
    final membres = data.membres;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Column(
          children: [
            // ── En-tête ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: Row(
                children: [
                  const LogoTontineClair(),
                  const Spacer(),
                  if (estGest)
                    TextButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ClassementScreen(
                            code: widget.code,
                            estGestionnaire: true,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.leaderboard_rounded, size: 16),
                      label: const Text('Classement'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.encreDoux,
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
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

            // ── Corps ──
            Expanded(
              child: _chargement
                  ? const Center(child: CircularProgressIndicator())
                  : _erreurChargement != null
                      ? _EtatErreur(
                          message: _erreurChargement!,
                          onRetry: _charger,
                        )
                      : RefreshIndicator(
                          onRefresh: _charger,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                            children: [
                              // Titre section
                              Padding(
                                padding: const EdgeInsets.only(top: 8, bottom: 4),
                                child: Row(
                                  children: [
                                    Text(
                                      'Membres',
                                      style: GoogleFonts.bricolageGrotesque(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 24,
                                        color: AppColors.encre,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${membres.length} pers.',
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        color: AppColors.texteDoux,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                data.nom,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  color: AppColors.texteDoux,
                                ),
                              ),
                              const SizedBox(height: 16),

                              // ── Cartes membres ──
                              ...membres.asMap().entries.map((e) {
                                final idx = e.key;
                                final m = e.value;
                                final voixM = _voixParMembre[m.id] ?? [];
                                final scoreCalc = ScoreService.calculerScore(data, m.id, voixM);
                                final score = scoreCalc.score;
                                final aPin = _membresAvecPin.contains(m.id);
                                final pinProvisoire = _pinsProvisoires[m.id];

                                return _CarteMembre(
                                  membre: m,
                                  rang: idx + 1,
                                  score: score,
                                  aPin: aPin,
                                  pinProvisoire: pinProvisoire,
                                  voixMembre: voixM,
                                  data: data,
                                  estGest: estGest,
                                  code: widget.code,
                                  onAttribuerPin: estGest
                                      ? () => _afficherModalAttribuer(
                                            context,
                                            m,
                                            data,
                                          )
                                      : null,
                                  onEnvoyerWhatsApp: (estGest &&
                                          pinProvisoire != null)
                                      ? () => _envoyerWhatsApp(
                                            context,
                                            m,
                                            pinProvisoire,
                                            data,
                                          )
                                      : null,
                                  onVoirScore: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ScoreMembreScreen(
                                        code: widget.code,
                                        membre: m,
                                        estGestionnaire: estGest,
                                      ),
                                    ),
                                  ),
                                );
                              }),

                              // ── Séparateur + section "Changer mon PIN" ──
                              const SizedBox(height: 24),
                              Container(
                                padding: const EdgeInsets.all(18),
                                decoration: BoxDecoration(
                                  color: AppColors.fondCode,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: AppColors.encreDoux
                                        .withValues(alpha: 0.25),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '🔑 Changer mon PIN de vote',
                                      style: GoogleFonts.bricolageGrotesque(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 16,
                                        color: AppColors.encre,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Si tu as reçu un PIN provisoire, change-le ici pour le rendre secret.',
                                      style: GoogleFonts.inter(
                                        fontSize: 13,
                                        color: AppColors.texteDoux,
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    _membresAvecPin.isEmpty
                                        ? Text(
                                            'Aucun membre n\'a encore reçu de PIN.',
                                            style: GoogleFonts.inter(
                                              fontSize: 13,
                                              color: AppColors.texteDoux,
                                            ),
                                          )
                                        : BtnPrincipal(
                                            label: 'Changer mon PIN',
                                            icon: Icons.lock_reset,
                                            onTap: () =>
                                                _afficherChangerPin(context, data),
                                          ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Carte d'un membre ────────────────────────────────────────────────────────
class _CarteMembre extends StatefulWidget {
  final Membre membre;
  final int rang;
  final int score;
  final bool aPin;
  final String? pinProvisoire;
  final List<Map<String, dynamic>> voixMembre;
  final TontineData data;
  final bool estGest;
  final String code;
  final VoidCallback? onAttribuerPin;
  final VoidCallback? onEnvoyerWhatsApp;
  final VoidCallback? onVoirScore;

  const _CarteMembre({
    required this.membre,
    required this.rang,
    required this.score,
    required this.aPin,
    this.pinProvisoire,
    required this.voixMembre,
    required this.data,
    required this.estGest,
    required this.code,
    this.onAttribuerPin,
    this.onEnvoyerWhatsApp,
    this.onVoirScore,
  });

  @override
  State<_CarteMembre> createState() => _CarteMembreState();
}

class _CarteMembreState extends State<_CarteMembre> {
  bool _etendu = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.membre;
    final score = widget.score;
    final couleur = _couleurScore(score);
    final label = _labelScore(score, context);

    // Stats depuis data.stats
    final statsRaw = widget.data.stats[m.id];
    int toursTotal = 0, toursPayes = 0, retards = 0, penalites = 0,
        pretsRembourses = 0;
    if (statsRaw is Map) {
      toursTotal = (statsRaw['toursTotal'] as num?)?.toInt() ?? 0;
      toursPayes = (statsRaw['toursPayes'] as num?)?.toInt() ?? 0;
      retards = (statsRaw['retards'] as num?)?.toInt() ?? 0;
      penalites = (statsRaw['penalites'] as num?)?.toInt() ?? 0;
      pretsRembourses = (statsRaw['pretsRembourses'] as num?)?.toInt() ?? 0;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.lignes),
        boxShadow: [
          BoxShadow(
            color: AppColors.encre.withValues(alpha: 0.04),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        children: [
          // ── Ligne principale (toujours visible) ──
          InkWell(
            onTap: () => setState(() => _etendu = !_etendu),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Rang + nom + badge score
                  Row(
                    children: [
                      // Rang
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: AppColors.fondCode,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            '${widget.rang}',
                            style: GoogleFonts.bricolageGrotesque(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: AppColors.encre,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Nom
                      Expanded(
                        child: Text(
                          m.nom,
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: AppColors.texte,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // Badge score
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: couleur.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '$score/100 · $label',
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            color: couleur,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        _etendu
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 20,
                        color: AppColors.texteDoux,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Barre de progression colorée
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: score / 100,
                      backgroundColor: AppColors.lignes,
                      valueColor: AlwaysStoppedAnimation<Color>(couleur),
                      minHeight: 5,
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Ligne de statistiques
                  Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    children: [
                      _StatPuce(
                        label: 'Cotisations : $toursPayes/$toursTotal tours',
                        couleur: AppColors.texteDoux,
                      ),
                      if (retards > 0)
                        _StatPuce(
                          label: '$retards retard${retards > 1 ? 's' : ''}',
                          couleur: AppColors.alerte,
                        ),
                      if (penalites > 0)
                        _StatPuce(
                          label: '$penalites pénalité${penalites > 1 ? 's' : ''}',
                          couleur: AppColors.alerte,
                        ),
                      if (pretsRembourses > 0)
                        _StatPuce(
                          label:
                              '$pretsRembourses prêt${pretsRembourses > 1 ? 's' : ''} soldé${pretsRembourses > 1 ? 's' : ''}',
                          couleur: AppColors.succes,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Statut PIN de vote (+ badge provisoire si applicable)
                  Row(
                    children: [
                      Icon(
                        widget.aPin ? Icons.lock : Icons.lock_open,
                        size: 14,
                        color: widget.aPin
                            ? AppColors.succes
                            : AppColors.alerte,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        widget.aPin ? 'PIN défini ✓' : 'PIN non défini',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                          color: widget.aPin
                              ? AppColors.succes
                              : AppColors.alerte,
                        ),
                      ),
                      // Bug #5 : badge "PIN provisoire" si en attente de changement
                      if (widget.pinProvisoire != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.or.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.or.withValues(alpha: 0.4)),
                          ),
                          child: Text(
                            '⏳ Provisoire',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.or,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ── Section étendue ──
          if (_etendu)
            Column(
              children: [
                const Divider(height: 1, color: AppColors.lignes),

                // Historique des votes
                if (widget.voixMembre.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Historique des votes',
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: AppColors.encre,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...widget.voixMembre
                            .take(5)
                            .map((v) => _LigneVote(voix: v)),
                        if (widget.voixMembre.length > 5)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '+ ${widget.voixMembre.length - 5} autre(s) vote(s)',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: AppColors.texteDoux,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (widget.voixMembre.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                    child: Text(
                      'Aucun vote enregistré pour ce membre.',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: AppColors.texteDoux,
                      ),
                    ),
                  ),

                // Bouton Score IA (visible pour tous : membres + gestionnaires)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: widget.onVoirScore,
                      icon: const Icon(
                        Icons.auto_awesome_rounded,
                        size: 15,
                        color: AppColors.encreDoux,
                      ),
                      label: Text(
                        'Voir le score de confiance IA',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: AppColors.encreDoux,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.encreDoux,
                        side: BorderSide(
                            color: AppColors.encreDoux.withValues(alpha: 0.4)),
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ),

                // Section gestionnaire
                if (widget.estGest) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppColors.lignes),
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Actions gestionnaire',
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: AppColors.encre,
                          ),
                        ),
                        const SizedBox(height: 10),
                        // Bouton attribuer / réinitialiser PIN
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: widget.onAttribuerPin,
                            icon: Icon(
                              widget.aPin ? Icons.refresh : Icons.key,
                              size: 16,
                            ),
                            label: Text(
                              widget.aPin
                                  ? 'Réinitialiser le PIN'
                                  : 'Attribuer un PIN',
                              style: GoogleFonts.inter(
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.encre,
                              side: const BorderSide(color: AppColors.encreDoux),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                        // Bug #5 fix : bouton WhatsApp visible dès qu'un PIN provisoire existe
                        if (widget.pinProvisoire != null) ...[
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: widget.onEnvoyerWhatsApp,
                              icon:
                                  const Icon(Icons.chat, size: 16, color: Colors.white),
                              label: Text(
                                '📲 Envoyer le PIN par WhatsApp',
                                style: GoogleFonts.inter(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                  color: Colors.white,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.whatsapp,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                        ],
                        // ── Mobile Money (Premium) ──────────────────────────
                        const SizedBox(height: 12),
                        const Divider(height: 1, color: AppColors.lignes),
                        const SizedBox(height: 12),
                        _SectionMobileMoney(
                          membre: m,
                          code: widget.code,
                        ),
                      ],
                    ),
                  ),
                ] else
                  const SizedBox(height: 14),
              ],
            ),
        ],
      ),
    );
  }
}

// ─── Ligne d'une voix (historique) ───────────────────────────────────────────
class _LigneVote extends StatelessWidget {
  final Map<String, dynamic> voix;

  const _LigneVote({required this.voix});

  @override
  Widget build(BuildContext context) {
    final choix = voix['choix'] as String? ?? '—';
    final methode = voix['methode'] as String? ?? '';
    final quand = voix['quand'];
    String dateStr = '—';
    if (quand is int) {
      dateStr = Formatters.dateHeure(
          DateTime.fromMillisecondsSinceEpoch(quand));
    } else if (quand is String) {
      dateStr = Formatters.dateHeure(DateTime.tryParse(quand));
    }

    Color choixCouleur;
    switch (choix.toLowerCase()) {
      case 'pour':
        choixCouleur = AppColors.succes;
        break;
      case 'contre':
        choixCouleur = AppColors.alerte;
        break;
      default:
        choixCouleur = AppColors.or;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: choixCouleur.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              choix,
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: choixCouleur,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (methode.isNotEmpty) ...[
            Text(
              '· $methode',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: AppColors.texteDoux,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              dateStr,
              style: GoogleFonts.inter(
                fontSize: 11.5,
                color: AppColors.texteDoux,
              ),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Petite puce de stat ──────────────────────────────────────────────────────
class _StatPuce extends StatelessWidget {
  final String label;
  final Color couleur;

  const _StatPuce({required this.label, required this.couleur});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: couleur,
      ),
    );
  }
}

// ─── Champ PIN réutilisable ───────────────────────────────────────────────────
class _ChampPin extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final String placeholder;

  const _ChampPin({
    required this.label,
    required this.ctrl,
    required this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 13.5,
            color: AppColors.encre,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 6,
          decoration: InputDecoration(
            hintText: placeholder,
            counterText: '',
            filled: true,
            fillColor: Colors.white,
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
              borderSide: const BorderSide(color: AppColors.encre, width: 1.5),
            ),
          ),
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.texte,
          ),
        ),
      ],
    );
  }
}

// ─── Section Mobile Money \u2014 coordonn\u00e9es de d\u00e9caissement d'un membre ─────────────
const _operateurs = ['orange', 'moov', 'mtn', 'wave'];

class _SectionMobileMoney extends StatefulWidget {
  final Membre membre;
  final String code;

  const _SectionMobileMoney({required this.membre, required this.code});

  @override
  State<_SectionMobileMoney> createState() => _SectionMobileMoneyState();
}

class _SectionMobileMoneyState extends State<_SectionMobileMoney> {
  bool _enEdition = false;
  bool _saving = false;
  late String? _operateur;
  late String  _numero;
  final _numCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _operateur = widget.membre.operateur;
    _numero    = widget.membre.numeroBenef ?? '';
    _numCtrl.text = _numero;
  }

  @override
  void dispose() {
    _numCtrl.dispose();
    super.dispose();
  }

  Future<void> _sauvegarder() async {
    final num = _numCtrl.text.trim();
    if (_operateur == null || num.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choisissez un opérateur et saisissez le numéro.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final provider = context.read<TontineProvider>();
      final data     = provider.courante!.data;

      // Mettre à jour le membre dans la liste
      final newMembres = data.membres.map((m) {
        if (m.id != widget.membre.id) return m;
        return Membre(
          id:               m.id,
          nom:              m.nom,
          tel:              m.tel,
          role:             m.role,
          paye:             m.paye,
          score:            m.score,
          pinVote:          m.pinVote,
          scoreOverride:    m.scoreOverride,
          motifOverride:    m.motifOverride,
          dateOverride:     m.dateOverride,
          adminOverride:    m.adminOverride,
          operateur:        _operateur,
          numeroBenef:      num,
        );
      }).toList();

      final newData = data.toJson();
      newData['membres'] = newMembres.map((m) => m.toJson()).toList();

      // Écrire sans PIN (modification non-financière — coordonnées MM uniquement)
      await SupabaseService.ecrireTontineSansPIN(code: widget.code, data: newData);
      await provider.chargerTontine(widget.code, silencieux: true);

      if (mounted) {
        setState(() { _enEdition = false; _numero = num; });
        afficherToast(context, '✅ Coordonnées Mobile Money sauvegardées !');
      }
    } catch (e) {
      if (mounted) afficherToast(context, 'Erreur : $e', estErreur: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final aCoords = (_operateur != null && _numero.isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.phone_android_rounded, size: 14, color: AppColors.encreDoux),
            const SizedBox(width: 6),
            Text(
              'Mobile Money (décaissement)',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: AppColors.encre,
              ),
            ),
            const Spacer(),
            if (!_enEdition)
              GestureDetector(
                onTap: () => setState(() => _enEdition = true),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.fondCode,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.lignes),
                  ),
                  child: Text(
                    aCoords ? 'Modifier' : 'Ajouter',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.encreDoux,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),

        if (!_enEdition) ...[
          // Affichage lecture
          if (aCoords)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.succesFond,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.succes.withValues(alpha: 0.25)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline, size: 15, color: AppColors.succes),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_operateur![0].toUpperCase()}${_operateur!.substring(1)} · $_numero',
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.succes,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.fondConsultation,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.orFonce.withValues(alpha: 0.25)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 15, color: AppColors.orFonce),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Aucune coordonnée Mobile Money — requises pour les décaissements Premium.',
                      style: GoogleFonts.inter(fontSize: 12, color: AppColors.orFonce),
                    ),
                  ),
                ],
              ),
            ),
        ] else ...[
          // Formulaire édition
          // Opérateur
          Text(
            'Opérateur',
            style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.texteDoux),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: _operateurs.map((op) {
              final sel = _operateur == op;
              return GestureDetector(
                onTap: () => setState(() => _operateur = op),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: sel ? AppColors.encre : AppColors.fondCode,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: sel ? AppColors.encre : AppColors.lignes,
                    ),
                  ),
                  child: Text(
                    op[0].toUpperCase() + op.substring(1),
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: sel ? Colors.white : AppColors.encre,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          // Numéro
          Text(
            'Numéro Mobile Money',
            style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.texteDoux),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _numCtrl,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              hintText: 'Ex : +225 07 00 00 00',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.lignes),
              ),
              prefixIcon: const Icon(Icons.phone_outlined, size: 18),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: BtnPrincipal(
                  label: 'Sauvegarder',
                  icone: Icons.save_rounded,
                  loading: _saving,
                  onTap: _sauvegarder,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: BtnSecondaire(
                  label: 'Annuler',
                  onTap: () {
                    setState(() {
                      _enEdition = false;
                      _operateur = widget.membre.operateur;
                      _numCtrl.text = widget.membre.numeroBenef ?? '';
                    });
                  },
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ─── État d'erreur ────────────────────────────────────────────────────────────
class _EtatErreur extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _EtatErreur({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.alerte),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(color: AppColors.alerte),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            BtnPrincipal(label: 'Réessayer', onTap: onRetry),
          ],
        ),
      ),
    );
  }
}
