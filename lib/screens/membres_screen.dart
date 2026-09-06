// ─────────────────────────────────────────────────────────────────────────────
// Module Membres — TontineClair
// Spécification : FICHE-MODULE-MEMBRES.pdf + index.html (ongletMembres,
//                 scoreConfiance, definirPinMembre, changerMonPin)
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/score_service.dart';
import '../services/supabase_service.dart';
import '../services/paiement_methodes_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import 'score_membre_screen.dart';
import 'classement_screen.dart';
import '../utils/app_localizations.dart';
import '../services/locale_service.dart';
import '../services/email_service.dart' as email_svc;

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
    const pinMsgs = {
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
    final msg = (pinMsgs[lang] ?? pinMsgs['fr']!)
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

  // ── Modal : Modifier l'e-mail d'un membre (gestionnaire uniquement) ────────
  // Valide le PIN gestionnaire, met à jour data.membres[].email via
  // ecrireTontineSansPIN, puis envoie un e-mail de confirmation au nouvel email.
  void _afficherModalEmailMembre(
    BuildContext ctx,
    Membre membre,
    TontineData data,
    String code,
  ) {
    final emailCtrl = TextEditingController(
      text: membre.email ?? '',
    );
    final pinCtrl = TextEditingController();
    String? erreur;
    bool saving = false;

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (bCtx) => StatefulBuilder(
        builder: (bCtx, setSt) {
          Future<void> sauvegarder() async {
            final nouvelEmail = emailCtrl.text.trim().toLowerCase();
            final pin         = pinCtrl.text.trim();
            final emailReg    = RegExp(r'^[\w.+\-]+@[\w\-]+\.[\w.]+$');

            // ── Validations locales ──────────────────────────────────────
            if (nouvelEmail.isEmpty) {
              setSt(() => erreur = 'Saisissez un e-mail valide.');
              return;
            }
            if (!emailReg.hasMatch(nouvelEmail)) {
              setSt(() => erreur = 'Format invalide (ex: awa@gmail.com).');
              return;
            }
            if (pin.length < 4) {
              setSt(() => erreur = 'PIN gestionnaire requis (4 chiffres min.).');
              return;
            }

            setSt(() { saving = true; erreur = null; });

            try {
              // ── Vérifier le PIN gestionnaire via Supabase RPC ────────────
              // ⚠️ data.gestionnaires[].pin est toujours vide côté client
              // (jamais retourné par lire_tontine pour raisons de sécurité).
              // Il FAUT appeler verifierGestionnaire() qui hash-compare côté serveur.
              final provider = ctx.read<TontineProvider>();
              final gestNom  = provider.gestActifNom ?? '';
              final pinOk    = await SupabaseService.verifierGestionnaire(
                code: code,
                nom:  gestNom,
                pin:  pin,
              );
              if (!pinOk) {
                setSt(() {
                  saving = false;
                  erreur = 'PIN gestionnaire incorrect.';
                });
                return;
              }

              // ── Mettre à jour data.membres[] en mémoire ──────────────────
              final ancienEmail = membre.email ?? '';
              final newMembres = data.membres.map((m) {
                if (m.id == membre.id) {
                  return Membre(
                    id:                    m.id,
                    nom:                   m.nom,
                    tel:                   m.tel,
                    role:                  m.role,
                    email:                 nouvelEmail.isNotEmpty ? nouvelEmail : null,
                    paye:                  m.paye,
                    datePaiement:          m.datePaiement,
                    methodePaiement:       m.methodePaiement,
                    referencePaiement:     m.referencePaiement,
                    score:                 m.score,
                    pinVote:               m.pinVote,
                    scoreOverride:         m.scoreOverride,
                    motifOverride:         m.motifOverride,
                    dateOverride:          m.dateOverride,
                    adminOverride:         m.adminOverride,
                    moyenPaiementCode:     m.moyenPaiementCode,
                    coordonneesPaiement:   m.coordonneesPaiement,
                    operateur:             m.operateur,
                    numeroBenef:           m.numeroBenef,
                    validePar:             m.validePar,
                    paiementStatut:        m.paiementStatut,
                    paiementDeclareParGest: m.paiementDeclareParGest,
                    photoPreuveBase64:     m.photoPreuveBase64,
                  );
                }
                return m;
              }).toList();

              final newData = data.toJson();
              newData['membres'] = newMembres.map((m) => m.toJson()).toList();

              // ── Écrire dans Supabase ──────────────────────────────────────
              await SupabaseService.ecrireTontineSansPIN(
                code: code,
                data: newData,
              );

              // ── Recharger les données locales ────────────────────────────
              await provider.chargerTontine(code, silencieux: true);

              // ── Fermer le modal ──────────────────────────────────────────
              if (bCtx.mounted) Navigator.of(bCtx).pop();

              // ── Toast de confirmation ─────────────────────────────────────
              if (ctx.mounted) {
                afficherToast(ctx, '✅ E-mail de ${membre.nom} mis à jour !');
              }

              // ── Envoyer e-mail de confirmation au NOUVEL email ─────────
              // Non-bloquant (fire-and-forget)
              final d = DateTime.now();
              final dateStr =
                  '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}'
                  ' à ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

              final msgHtml = ancienEmail.isNotEmpty
                  ? 'Votre adresse e-mail dans la tontine <strong>${data.nom}</strong> '
                    'a été mise à jour le $dateStr.<br><br>'
                    'Ancien e-mail : <strong>$ancienEmail</strong><br>'
                    'Nouvel e-mail : <strong>$nouvelEmail</strong><br><br>'
                    'Vous recevrez désormais toutes les notifications de mouvement '
                    'à cette adresse.'
                  : 'Votre adresse e-mail a été enregistrée dans la tontine '
                    '<strong>${data.nom}</strong> le $dateStr.<br><br>'
                    'E-mail : <strong>$nouvelEmail</strong><br><br>'
                    'Vous recevrez désormais toutes les notifications de mouvement '
                    'à cette adresse.';

              email_svc.EmailService.envoyerAlerteSecurite(
                destinataire: nouvelEmail,
                nom:          membre.nom,
                action:       '✅ Votre e-mail TontineClair a été enregistré',
                message:      msgHtml,
                tontine:      data.nom,
                tontineCode:  code,
                gestNom:      gestNom,
              ).then((r) {
                if (r.ok) {
                  if (kDebugMode) debugPrint('[EmailMembre] ✓ Confirmation envoyée à $nouvelEmail');
                } else {
                  if (kDebugMode) debugPrint('[EmailMembre] ✗ Échec : ${r.erreur}');
                }
              }).catchError((Object e) {
                if (kDebugMode) debugPrint('[EmailMembre] ✗ Exception : $e');
              });

            } catch (e) {
              setSt(() {
                saving = false;
                erreur = 'Erreur : $e';
              });
            }
          }

          return Padding(
            padding: EdgeInsets.only(
              left: 20, right: 20, top: 20,
              bottom: MediaQuery.of(bCtx).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── En-tête ──────────────────────────────────────────────
                Row(
                  children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C2447).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(
                        child: Text('📧', style: TextStyle(fontSize: 18)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'E-mail de ${membre.nom}',
                            style: GoogleFonts.inter(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: AppColors.encre,
                            ),
                          ),
                          Text(
                            'Notifications en temps réel',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: AppColors.texteDoux,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // ── Champ e-mail ──────────────────────────────────────────
                Text(
                  'Adresse e-mail du membre',
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: AppColors.encre,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'ex : awa@gmail.com',
                    prefixIcon: const Icon(
                      Icons.email_outlined,
                      size: 18,
                      color: AppColors.texteDoux,
                    ),
                    errorText: erreur != null &&
                            !erreur!.contains('PIN')
                        ? erreur
                        : null,
                  ),
                  onChanged: (_) => setSt(() => erreur = null),
                ),
                const SizedBox(height: 4),
                Text(
                  '📬 Ce membre recevra un e-mail de confirmation après la mise à jour.',
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: AppColors.texteDoux,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 16),

                // ── PIN gestionnaire ──────────────────────────────────────
                Text(
                  'PIN gestionnaire (confirmation)',
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: AppColors.encre,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: pinCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: InputDecoration(
                    hintText: 'PIN gestionnaire',
                    counterText: '',
                    prefixIcon: const Icon(
                      Icons.lock_outline,
                      size: 18,
                      color: AppColors.texteDoux,
                    ),
                    errorText: erreur != null &&
                            erreur!.contains('PIN')
                        ? erreur
                        : null,
                  ),
                  onChanged: (_) => setSt(() => erreur = null),
                ),
                const SizedBox(height: 20),

                // ── Bouton sauvegarder ────────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: saving ? null : sauvegarder,
                    icon: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_outlined,
                            size: 16, color: Colors.white),
                    label: Text(
                      saving ? 'Enregistrement…' : 'Enregistrer l\'e-mail',
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: Colors.white,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.encre,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
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
                                  onModifierEmail: estGest
                                      ? () => _afficherModalEmailMembre(
                                            context,
                                            m,
                                            data,
                                            widget.code,
                                          )
                                      : null,
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
  final VoidCallback? onModifierEmail; // gestionnaire uniquement

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
    this.onModifierEmail,
  });

  @override
  State<_CarteMembre> createState() => _CarteMembreState();
}

class _CarteMembreState extends State<_CarteMembre> {
  bool _etendu        = false;
  bool _preuvesOuvertes = false; // contrôle le pli/dépli du bloc "Preuves"

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
          // NB: on utilise GestureDetector au lieu d'InkWell pour que le
          // InkWell enfant du badge "Preuves" puisse intercepter ses propres taps.
          GestureDetector(
            onTap: () => setState(() => _etendu = !_etendu),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Ligne 1 : rang + nom + chevron ──────────────────────
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
                      // Nom — a tout l'espace disponible
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
                      // Chevron principal (déplie la fiche complète)
                      Icon(
                        _etendu
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 20,
                        color: AppColors.texteDoux,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  // ── Ligne 2 : badge score + badge preuves ────────────────
                  Row(
                    children: [
                      const SizedBox(width: 40), // aligne sous le nom (rang=30 + gap=10)
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
                      // Badge "Preuves" — InkWell indépendant du GestureDetector parent
                      if (_SectionPreuvesCategories.aDesPreuves(m, widget.data)) ...[
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => setState(
                              () => _preuvesOuvertes = !_preuvesOuvertes),
                          borderRadius: BorderRadius.circular(8),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: _preuvesOuvertes
                                  ? AppColors.encreDoux.withValues(alpha: 0.20)
                                  : AppColors.encreDoux.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: _preuvesOuvertes
                                      ? AppColors.encreDoux.withValues(alpha: 0.60)
                                      : AppColors.encreDoux.withValues(alpha: 0.30)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.receipt_long_rounded,
                                    size: 12,
                                    color: AppColors.encreDoux),
                                const SizedBox(width: 4),
                                Text(
                                  'Preuves',
                                  style: GoogleFonts.inter(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.encreDoux,
                                  ),
                                ),
                                const SizedBox(width: 3),
                                AnimatedRotation(
                                  turns: _preuvesOuvertes ? 0.5 : 0.0,
                                  duration: const Duration(milliseconds: 200),
                                  child: Icon(
                                    Icons.keyboard_arrow_down,
                                    size: 13,
                                    color: AppColors.encreDoux,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
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

          // ── Section preuves catégorisées — pliable via badge "Preuves" ──────
          if (_SectionPreuvesCategories.aDesPreuves(widget.membre, widget.data))
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 250),
              crossFadeState: _preuvesOuvertes
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: Column(
                children: [
                  const Divider(height: 1, color: AppColors.lignes),
                  _SectionPreuvesCategories(
                    membre: widget.membre,
                    data:   widget.data,
                  ),
                ],
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
                        // ── E-mail membre (Premium) ─────────────────────────
                        const SizedBox(height: 10),
                        const Divider(height: 1, color: AppColors.lignes),
                        const SizedBox(height: 10),
                        // Affichage de l'email actuel
                        Row(
                          children: [
                            const Icon(
                              Icons.email_outlined,
                              size: 14,
                              color: AppColors.texteDoux,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                m.email != null && m.email!.isNotEmpty
                                    ? m.email!
                                    : 'Aucun e-mail enregistré',
                                style: GoogleFonts.inter(
                                  fontSize: 12.5,
                                  color: m.email != null && m.email!.isNotEmpty
                                      ? AppColors.encre
                                      : AppColors.texteDoux,
                                  fontStyle: m.email == null || m.email!.isEmpty
                                      ? FontStyle.italic
                                      : FontStyle.normal,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: widget.onModifierEmail,
                            icon: const Icon(
                              Icons.edit_outlined,
                              size: 15,
                            ),
                            label: Text(
                              m.email != null && m.email!.isNotEmpty
                                  ? 'Modifier l\'e-mail'
                                  : 'Ajouter un e-mail',
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
                        // ── Coordonnées de décaissement (Premium) ──────────
                        const SizedBox(height: 12),
                        const Divider(height: 1, color: AppColors.lignes),
                        const SizedBox(height: 12),
                        _SectionCoordonneesPaiement(
                          membre: m,
                          code: widget.code,
                          devise: widget.data.devise,
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

// ─── Section preuves catégorisées par type ───────────────────────────────────
// Affiche 3 catégories : Cotisation (photo tour courant), Remboursements, Prêts.
// S'affiche uniquement si au moins une catégorie a des données.
class _SectionPreuvesCategories extends StatelessWidget {
  final Membre     membre;
  final TontineData data;

  const _SectionPreuvesCategories({
    required this.membre,
    required this.data,
  });

  /// Prêts dont ce membre est l'emprunteur
  List<Pret> get _pretsduMembre =>
      data.prets.where((p) => p.emprunteurId == membre.id).toList();

  /// Tous les remboursements du membre (toutes les tranches)
  List<({Pret pret, Remboursement remb})> get _remboursementsDuMembre {
    final result = <({Pret pret, Remboursement remb})>[];
    for (final p in _pretsduMembre) {
      for (final r in p.remboursements) {
        result.add((pret: p, remb: r));
      }
    }
    // Tri anti-chronologique
    result.sort((a, b) {
      final da = DateTime.tryParse(a.remb.date) ?? DateTime(0);
      final db = DateTime.tryParse(b.remb.date) ?? DateTime(0);
      return db.compareTo(da);
    });
    return result;
  }

  /// true si au moins une catégorie a des données à afficher
  static bool aDesPreuves(Membre m, TontineData data) {
    final aPhoto    = m.photoPreuveBase64 != null && m.photoPreuveBase64!.isNotEmpty;
    final aPrets    = data.prets.any((p) => p.emprunteurId == m.id);
    final aRembours = data.prets.any(
        (p) => p.emprunteurId == m.id && p.remboursements.isNotEmpty);
    return aPhoto || aPrets || aRembours;
  }

  @override
  Widget build(BuildContext context) {
    final devise        = data.devise;
    final aPhoto        = membre.photoPreuveBase64 != null &&
                          membre.photoPreuveBase64!.isNotEmpty;
    final prets         = _pretsduMembre;
    final remboursements = _remboursementsDuMembre;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── En-tête section ──
          Row(
            children: [
              const Icon(Icons.receipt_long_rounded,
                  size: 15, color: AppColors.encreDoux),
              const SizedBox(width: 6),
              Text(
                'Preuves de paiement',
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: AppColors.encre,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Catégorie 1 : Cotisation ──────────────────────────────────────
          if (aPhoto) ...[
            _EnteteCategoriePreuve(
              couleur: const Color(0xFF2E7D5B),
              icone: Icons.savings_rounded,
              label: 'Preuve de cotisation',
              badgeStatut: membre.paiementStatut,
            ),
            const SizedBox(height: 8),
            // Infos paiement (méthode / réf / gestionnaire / date)
            _MetasPaiement(
              methode:      membre.methodePaiement,
              reference:    membre.referencePaiement,
              validePar:    membre.validePar ?? membre.paiementDeclareParGest,
              date:         membre.datePaiement,
              montant:      data.montant,
              devise:       devise,
            ),
            const SizedBox(height: 8),
            // Thumbnail photo
            _MiniaturePhotoPreuve(
              base64Data: membre.photoPreuveBase64!,
              titre:      'Cotisation — ${membre.nom}',
            ),
          ],

          // ── Catégorie 2 : Remboursements ──────────────────────────────────
          if (remboursements.isNotEmpty) ...[
            if (aPhoto) const SizedBox(height: 14),
            _EnteteCategoriePreuve(
              couleur: const Color(0xFF1565C0),
              icone: Icons.currency_exchange_rounded,
              label: 'Preuves de remboursement',
              badgeStatut: null,
            ),
            const SizedBox(height: 8),
            ...remboursements.take(5).map((entry) =>
              _LigneRemboursement(
                pret:    entry.pret,
                remb:    entry.remb,
                devise:  devise,
              ),
            ),
            if (remboursements.length > 5) ...[
              const SizedBox(height: 4),
              Text(
                '+ ${remboursements.length - 5} autre(s) remboursement(s)',
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  color: AppColors.texteDoux,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],

          // ── Catégorie 3 : Prêts ───────────────────────────────────────────
          if (prets.isNotEmpty) ...[
            if (aPhoto || remboursements.isNotEmpty) const SizedBox(height: 14),
            _EnteteCategoriePreuve(
              couleur: const Color(0xFFE07A2F),
              icone: Icons.account_balance_rounded,
              label: 'Prêts en cours',
              badgeStatut: null,
            ),
            const SizedBox(height: 8),
            ...prets.map((p) => _LignePret(pret: p, devise: devise)),
          ],
        ],
      ),
    );
  }
}

// ─── En-tête de catégorie avec pill colorée ───────────────────────────────────
class _EnteteCategoriePreuve extends StatelessWidget {
  final Color   couleur;
  final IconData icone;
  final String  label;
  final String? badgeStatut; // null | 'en_attente' | 'approuve'

  const _EnteteCategoriePreuve({
    required this.couleur,
    required this.icone,
    required this.label,
    this.badgeStatut,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: couleur.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(icone, size: 13, color: couleur),
        ),
        const SizedBox(width: 7),
        Text(
          label,
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 12,
            color: couleur,
          ),
        ),
        const Spacer(),
        if (badgeStatut != null) _BadgeStatutPaiement(statut: badgeStatut!),
      ],
    );
  }
}

// ─── Badge statut paiement ────────────────────────────────────────────────────
class _BadgeStatutPaiement extends StatelessWidget {
  final String statut;
  const _BadgeStatutPaiement({required this.statut});

  @override
  Widget build(BuildContext context) {
    final bool estApprouve = statut == 'approuve';
    final Color c = estApprouve ? const Color(0xFF2E7D5B) : const Color(0xFFD99A2B);
    final String label = estApprouve ? '✓ Approuvé' : '⏳ En attente';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: c,
        ),
      ),
    );
  }
}

// ─── Métas d'un paiement (méthode / réf / gest / date / montant) ─────────────
class _MetasPaiement extends StatelessWidget {
  final String? methode;
  final String? reference;
  final String? validePar;
  final String? date;
  final int?    montant;
  final String  devise;

  const _MetasPaiement({
    this.methode,
    this.reference,
    this.validePar,
    this.date,
    this.montant,
    required this.devise,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr = _parseDate(date);
    final lignes  = <(IconData, String)>[
      if (montant != null && montant! > 0)
        (Icons.payments_rounded, Formatters.montant(montant!, devise: devise)),
      if (methode != null && methode!.isNotEmpty)
        (Icons.credit_card_rounded, methode!),
      if (reference != null && reference!.isNotEmpty)
        (Icons.tag_rounded, 'Réf : $reference'),
      if (validePar != null && validePar!.isNotEmpty)
        (Icons.person_outline_rounded, validePar!),
      if (dateStr.isNotEmpty)
        (Icons.access_time_rounded, dateStr),
    ];

    if (lignes.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.fondSecondaire,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lignes.map((l) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(l.$1, size: 12, color: AppColors.texteDoux),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l.$2,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: AppColors.texte,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        )).toList(),
      ),
    );
  }

  static String _parseDate(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final dt = DateTime.tryParse(raw);
    if (dt != null) return Formatters.dateHeure(dt);
    final ms = int.tryParse(raw);
    if (ms != null && ms > 0) {
      return Formatters.dateHeure(DateTime.fromMillisecondsSinceEpoch(ms));
    }
    return raw;
  }
}

// ─── Miniature photo avec tap → plein écran ───────────────────────────────────
class _MiniaturePhotoPreuve extends StatelessWidget {
  final String base64Data;
  final String titre;

  const _MiniaturePhotoPreuve({
    required this.base64Data,
    required this.titre,
  });

  void _voirEnPleinEcran(BuildContext context) {
    final bytes = base64Decode(base64Data);
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            InteractiveViewer(
              child: Center(
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
            // Bouton fermer
            Positioned(
              top: 16, right: 16,
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded,
                      color: Colors.white, size: 22),
                ),
              ),
            ),
            // Titre
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.75),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Text(
                  titre,
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = base64Decode(base64Data);
    return GestureDetector(
      onTap: () => _voirEnPleinEcran(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            Image.memory(
              bytes,
              height: 160,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.fondSecondaire,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: Text('Image non disponible',
                      style: TextStyle(color: AppColors.texteDoux)),
                ),
              ),
            ),
            Positioned(
              bottom: 8, right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.zoom_in_rounded, size: 13, color: Colors.white),
                    SizedBox(width: 4),
                    Text('Agrandir',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.w600)),
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

// ─── Ligne d'un remboursement de prêt ────────────────────────────────────────
class _LigneRemboursement extends StatelessWidget {
  final Pret          pret;
  final Remboursement remb;
  final String        devise;

  const _LigneRemboursement({
    required this.pret,
    required this.remb,
    required this.devise,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr  = _parseDate(remb.date);
    final montantFmt = Formatters.montant(remb.montant, devise: devise);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1565C0).withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFF1565C0).withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        children: [
          // Icône montant
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFF1565C0).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.currency_exchange_rounded,
                size: 16, color: Color(0xFF1565C0)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Prêt initial : ${Formatters.montant(pret.montant, devise: devise)}',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: AppColors.texteDoux,
                  ),
                ),
                if (remb.methode.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    remb.methode,
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.encre,
                    ),
                  ),
                ],
                if (remb.reference.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Row(
                    children: [
                      const Icon(Icons.tag_rounded,
                          size: 10, color: AppColors.texteDoux),
                      const SizedBox(width: 3),
                      Text(
                        remb.reference,
                        style: GoogleFonts.inter(
                          fontSize: 10.5, color: AppColors.texteDoux),
                      ),
                    ],
                  ),
                ],
                if (dateStr.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Icon(Icons.access_time_rounded,
                          size: 10, color: AppColors.texteDoux),
                      const SizedBox(width: 3),
                      Text(
                        dateStr,
                        style: GoogleFonts.inter(
                          fontSize: 10.5, color: AppColors.texteDoux),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // Montant remboursé
          Text(
            montantFmt,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF1565C0),
            ),
          ),
        ],
      ),
    );
  }

  static String _parseDate(String raw) {
    if (raw.isEmpty) return '';
    final dt = DateTime.tryParse(raw);
    if (dt != null) return Formatters.dateHeure(dt);
    final ms = int.tryParse(raw);
    if (ms != null && ms > 0) {
      return Formatters.dateHeure(DateTime.fromMillisecondsSinceEpoch(ms));
    }
    return raw;
  }
}

// ─── Ligne d'un prêt ──────────────────────────────────────────────────────────
class _LignePret extends StatelessWidget {
  final Pret   pret;
  final String devise;

  const _LignePret({required this.pret, required this.devise});

  @override
  Widget build(BuildContext context) {
    final statutCalc = pret.statutCalcule;
    final Color couleurStatut;
    final String labelStatut;
    switch (statutCalc) {
      case 'solde':
        couleurStatut = const Color(0xFF2E7D5B);
        labelStatut   = 'Soldé';
      case 'retard':
        couleurStatut = const Color(0xFFCC3333);
        labelStatut   = 'En retard';
      case 'partiel':
        couleurStatut = const Color(0xFFD99A2B);
        labelStatut   = 'Partiel';
      default:
        couleurStatut = const Color(0xFFE07A2F);
        labelStatut   = 'En cours';
    }

    final resteADu = pret.resteADu;
    final totalDu  = pret.totalDu;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFE07A2F).withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFFE07A2F).withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFFE07A2F).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.account_balance_rounded,
                size: 16, color: Color(0xFFE07A2F)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Prêt de ${Formatters.montant(pret.montant, devise: devise)}',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.encre,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Reste dû : ${Formatters.montant(resteADu, devise: devise)} / ${Formatters.montant(totalDu, devise: devise)}',
                  style: GoogleFonts.inter(
                    fontSize: 11, color: AppColors.texteDoux),
                ),
                const SizedBox(height: 4),
                // Barre de progression remboursement
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: totalDu > 0
                        ? (pret.totalRembourse / totalDu).clamp(0.0, 1.0)
                        : 0.0,
                    minHeight: 4,
                    backgroundColor: AppColors.lignes,
                    valueColor: AlwaysStoppedAnimation<Color>(couleurStatut),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Badge statut
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: couleurStatut.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: couleurStatut.withValues(alpha: 0.30)),
            ),
            child: Text(
              labelStatut,
              style: GoogleFonts.inter(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: couleurStatut,
              ),
            ),
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

  /// Tente de parser une date depuis plusieurs champs possibles du JSON vote.
  /// Supporte : int (ms epoch), String ISO8601, String timestamp PostgreSQL.
  static String _extraireDate(Map<String, dynamic> voix) {
    // Priorité : quand > created_at > date > voted_at > ts
    for (final key in ['quand', 'created_at', 'date', 'voted_at', 'ts']) {
      final raw = voix[key];
      if (raw == null) continue;
      DateTime? dt;
      if (raw is int && raw > 0) {
        // Milliseconds epoch
        dt = DateTime.fromMillisecondsSinceEpoch(raw);
      } else if (raw is String && raw.isNotEmpty) {
        // ISO 8601 ou timestamp PostgreSQL (ex: "2024-12-01T14:23:00.000Z")
        dt = DateTime.tryParse(raw);
        // Tentative avec timestamp numérique sous forme string
        if (dt == null) {
          final ms = int.tryParse(raw);
          if (ms != null && ms > 0) dt = DateTime.fromMillisecondsSinceEpoch(ms);
        }
      }
      if (dt != null) return Formatters.dateHeure(dt);
    }
    return ''; // Pas de date disponible — on n'affiche rien plutôt que "—"
  }

  @override
  Widget build(BuildContext context) {
    final choix   = voix['choix']   as String? ?? '—';
    final methode = voix['methode'] as String? ?? '';
    final dateStr = _extraireDate(voix);

    // Libellé lisible du choix
    final String choixLabel;
    switch (choix.toLowerCase()) {
      case 'pour':   choixLabel = 'Oui';  break;
      case 'contre': choixLabel = 'Non';  break;
      default:       choixLabel = choix;
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
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Badge choix
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: choixCouleur.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              choixLabel,
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: choixCouleur,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Méthode + Date
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (methode.isNotEmpty)
                  Text(
                    '· $methode',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: AppColors.texteDoux,
                    ),
                  ),
                if (dateStr.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Icon(Icons.access_time_rounded,
                          size: 11, color: AppColors.texteDoux),
                      const SizedBox(width: 3),
                      Text(
                        dateStr,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: AppColors.texteDoux,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
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

// ─── Section Coordonnées de décaissement ─────────────────────────────────────
// Remplace _SectionMobileMoney — supporte tous les moyens de paiement
// selon la devise de la tontine (détection automatique via PaiementMethodesService).
class _SectionCoordonneesPaiement extends StatefulWidget {
  final Membre  membre;
  final String  code;
  final String? devise;

  const _SectionCoordonneesPaiement({
    required this.membre,
    required this.code,
    this.devise,
  });

  @override
  State<_SectionCoordonneesPaiement> createState() => _SectionCoordonneesPaiementState();
}

class _SectionCoordonneesPaiementState extends State<_SectionCoordonneesPaiement> {
  bool    _enEdition = false;
  bool    _saving    = false;
  String? _moyenCode;   // code sélectionné
  final   _coordCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Initialiser depuis v2, puis fallback v1
    _moyenCode = widget.membre.moyenPaiementEffectif;
    _coordCtrl.text = widget.membre.coordonneesEffectives ?? '';
  }

  @override
  void dispose() {
    _coordCtrl.dispose();
    super.dispose();
  }

  List<PaiementMethode> get _methodes =>
      PaiementMethodesService.methodesParDevise(widget.devise);

  PaiementMethode? get _moyenSelectionne =>
      _moyenCode != null ? PaiementMethodesService.parCode(_moyenCode) : null;

  Future<void> _sauvegarder() async {
    final coord = _coordCtrl.text.trim();
    if (_moyenCode == null || coord.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choisissez un moyen de paiement et saisissez les coordonnées.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final provider = context.read<TontineProvider>();
      final data     = provider.courante!.data;

      final newMembres = data.membres.map((m) {
        if (m.id != widget.membre.id) return m;
        return Membre(
          id:                   m.id,
          nom:                  m.nom,
          tel:                  m.tel,
          role:                 m.role,
          paye:                 m.paye,
          score:                m.score,
          pinVote:              m.pinVote,
          scoreOverride:        m.scoreOverride,
          motifOverride:        m.motifOverride,
          dateOverride:         m.dateOverride,
          adminOverride:        m.adminOverride,
          moyenPaiementCode:    _moyenCode,
          coordonneesPaiement:  coord,
          // conserver v1 si préexistant, mais le nouveau prend la priorité (getters)
          operateur:            m.operateur,
          numeroBenef:          m.numeroBenef,
          validePar:            provider.gestActifNom,
        );
      }).toList();

      final newData = data.toJson();
      newData['membres'] = newMembres.map((m) => m.toJson()).toList();

      await SupabaseService.ecrireTontineSansPIN(code: widget.code, data: newData);
      await provider.chargerTontine(widget.code, silencieux: true);

      if (mounted) {
        setState(() { _enEdition = false; });
        afficherToast(context, '✅ Coordonnées de décaissement sauvegardées !');
      }
    } catch (e) {
      if (mounted) afficherToast(context, 'Erreur : $e', estErreur: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final aCoords = widget.membre.aCoordonneesDecaissement;
    final moyen   = _moyenSelectionne;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── En-tête ──────────────────────────────────────────────────────────
        Row(
          children: [
            const Icon(Icons.account_balance_wallet_rounded, size: 14, color: AppColors.encreDoux),
            const SizedBox(width: 6),
            Text(
              'Coordonnées de décaissement',
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

        if (!_enEdition) ...[ // ── Vue lecture ─────────────────────────────
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
                  Text(
                    PaiementMethodesService.icone(widget.membre.moyenPaiementEffectif),
                    style: const TextStyle(fontSize: 18),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          PaiementMethodesService.label(widget.membre.moyenPaiementEffectif),
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            color: AppColors.succes,
                          ),
                        ),
                        Text(
                          widget.membre.coordonneesEffectives ?? '',
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: AppColors.succes,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.check_circle_outline, size: 15, color: AppColors.succes),
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
                      'Aucune coordonnée — requises pour les décaissements.',
                      style: GoogleFonts.inter(fontSize: 12, color: AppColors.orFonce),
                    ),
                  ),
                ],
              ),
            ),

        ] else ...[ // ── Formulaire édition ──────────────────────────────────
          Text(
            'Moyen de paiement',
            style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.texteDoux),
          ),
          const SizedBox(height: 8),

          // ── Grille des moyens disponibles pour cette devise ─────────────
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _methodes.map((m) {
              final sel = _moyenCode == m.code;
              return GestureDetector(
                onTap: () {
                  setState(() {
                    _moyenCode = m.code;
                    // Vider le champ quand on change de moyen
                    if (_moyenCode != widget.membre.moyenPaiementEffectif) {
                      _coordCtrl.clear();
                    } else {
                      _coordCtrl.text = widget.membre.coordonneesEffectives ?? '';
                    }
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: sel ? AppColors.encre : AppColors.fondCode,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: sel ? AppColors.encre : AppColors.lignes),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(m.icone, style: const TextStyle(fontSize: 14)),
                      const SizedBox(width: 6),
                      Text(
                        m.label,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: sel ? Colors.white : AppColors.encre,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),

          const SizedBox(height: 14),

          // ── Champ de saisie adaptatif selon le moyen sélectionné ────────
          if (moyen != null) ...[ 
            Text(
              moyen.labelChamp,
              style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.texteDoux),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _coordCtrl,
              keyboardType: moyen.typeChamp == TypeChampPaiement.phone
                  ? TextInputType.phone
                  : moyen.typeChamp == TypeChampPaiement.email
                      ? TextInputType.emailAddress
                      : TextInputType.text,
              textCapitalization: moyen.typeChamp == TypeChampPaiement.iban
                  ? TextCapitalization.characters
                  : TextCapitalization.none,
              decoration: InputDecoration(
                hintText: moyen.hintTexte,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.lignes),
                ),
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(moyen.icone, style: const TextStyle(fontSize: 18)),
                ),
              ),
            ),
            const SizedBox(height: 6),
            // Hint contextuel
            Text(
              'Ex : ${moyen.hintTexte}',
              style: GoogleFonts.inter(fontSize: 11, color: AppColors.texteDoux),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.fondCode,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.lignes),
              ),
              child: Text(
                'Sélectionnez un moyen de paiement ci-dessus.',
                style: GoogleFonts.inter(fontSize: 12, color: AppColors.texteDoux),
              ),
            ),
          ],

          const SizedBox(height: 14),
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
                      _moyenCode = widget.membre.moyenPaiementEffectif;
                      _coordCtrl.text = widget.membre.coordonneesEffectives ?? '';
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
