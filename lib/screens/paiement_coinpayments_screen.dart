import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/coinpayments_service.dart';
import '../services/supabase_service.dart';
import '../services/locale_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import 'paiement_crypto_wallet_screen.dart';

/// Écran de paiement CoinPayments (crypto) pour les membres Premium.
///
/// Workflow :
///   1. Sélection de la cryptomonnaie (USDT TRC20 par défaut)
///   2. creerTransaction → obtient checkout_url + txid CoinPayments
///   3. Ouverture du checkout_url dans le navigateur
///   4. Polling toutes les 10s (max 15 min) pour détecter la confirmation
///   5. Dès statut 100 → confirmerEtCrediter → crédit Supabase
///   6. Affichage "Paiement confirmé"
///
/// Garanties de sécurité (même niveau que SycaPay v5) :
///   • Clés CoinPayments uniquement côté Edge Function
///   • Crédit uniquement via confirmerEtCrediter (RPC sécurisée)
///   • Double-click protégé par _enTraitement
class PaiementCoinPaymentsScreen extends StatefulWidget {
  final String  code;
  final String  typeFlux;     // 'cotisation' | 'caisse' | 'penalite' | 'remboursement_pret' | ...
  final Membre? membre;
  final int?    montant;      // obligatoire si typeFlux != 'cotisation'
  final String  description;
  final String? membreId;
  final String? membreNom;
  final String? pretId;
  final int?    taux;
  final int?    dureesMois;
  final int?    numeroTour;

  const PaiementCoinPaymentsScreen({
    super.key,
    required this.code,
    required this.typeFlux,
    this.membre,
    this.montant,
    this.description = 'Paiement',
    this.membreId,
    this.membreNom,
    this.pretId,
    this.taux,
    this.dureesMois,
    this.numeroTour,
  });

  @override
  State<PaiementCoinPaymentsScreen> createState() =>
      _PaiementCoinPaymentsScreenState();
}

class _PaiementCoinPaymentsScreenState
    extends State<PaiementCoinPaymentsScreen>
    with WidgetsBindingObserver {

  static const _couleurCrypto = Color(0xFFF7931A);   // orange Bitcoin
  static const _couleurFond   = Color(0xFFFFF8EE);

  // Cryptos supportées : (code, label, couleur)
  static const _cryptos = [
    ('USDT.TRC20', 'USDT (TRC20)', Color(0xFF26A17B)),
    ('USDT.ERC20', 'USDT (ERC20)', Color(0xFF3C9BFF)),
    ('BTC',        'Bitcoin',      Color(0xFFF7931A)),
    ('ETH',        'Ethereum',     Color(0xFF627EEA)),
    ('LTC',        'Litecoin',     Color(0xFF9DA2A6)),
  ];

  String  _crypto            = 'USDT.TRC20';
  _EtapeCrypto _etape        = _EtapeCrypto.saisie;
  String? _txid;
  String? _checkoutUrl;
  String? _numCommande;
  String? _messageErreur;
  String? _messageInfo;
  bool    _enTraitement      = false;
  bool    _checkoutOuvert    = false;
  bool    _peutVerifier      = false;
  Timer?  _watchdog;
  Timer?  _pollTimer;
  int     _pollCount         = 0;
  static const int _maxPolls = 90;  // 90 × 10s = 15 min

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Retour foreground après checkout → vérification immédiate
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && _checkoutOuvert) {
      _checkoutOuvert = false;
      if (_etape == _EtapeCrypto.attenteCheckout && _txid != null) {
        if (kDebugMode) debugPrint('[CoinPayments] Retour foreground → poll immédiat');
        _verifierStatutImmediatement();
      }
    }
  }

  // ── Montant à payer ───────────────────────────────────────────────────────

  int get _montant {
    if (widget.typeFlux == 'cotisation') {
      final provider = context.read<TontineProvider>();
      return provider.courante?.data.montant ?? widget.montant ?? 0;
    }
    return widget.montant ?? 0;
  }

  String get _membreId   => widget.membreId  ?? widget.membre?.id  ?? '';
  String get _membreNom  => widget.membreNom ?? widget.membre?.nom ?? '';
  String get _titreEcran {
    switch (widget.typeFlux) {
      case 'cotisation':        return 'Cotisation — Crypto';
      case 'caisse':            return 'Apport caisse — Crypto';
      case 'penalite':          return 'Pénalité — Crypto';
      case 'remboursement_pret': return 'Remboursement — Crypto';
      default:                  return 'Paiement Crypto';
    }
  }

  // ── Créer la transaction ──────────────────────────────────────────────────

  Future<void> _creerTransaction() async {
    if (_enTraitement) return;
    _enTraitement = true;

    final montant = _montant;
    final numCmd  = CoinPaymentsService.genererNumCommande(
        widget.code, _membreId.isNotEmpty ? _membreId : 'user');
    _numCommande = numCmd;

    setState(() {
      _etape         = _EtapeCrypto.creation;
      _messageErreur = null;
      _messageInfo   = null;
      _peutVerifier  = false;
    });

    try {
      if (kDebugMode) debugPrint('[CoinPayments] creerTransaction $numCmd crypto=$_crypto');

      final resultat = await CoinPaymentsService.creerTransaction(
        montantXof:    montant,
        numCommande:   numCmd,
        tontineCode:   widget.code,
        typeOperation: widget.typeFlux,
        membreId:      _membreId.isNotEmpty ? _membreId : null,
        membreNom:     _membreNom.isNotEmpty ? _membreNom : null,
        pretId:        widget.pretId,
        currency2:     _crypto,
      );

      _enTraitement = false;
      if (!mounted) return;

      if (kDebugMode) debugPrint('[CoinPayments] creerTransaction → $resultat');

      if (resultat.erreur || !resultat.aCheckoutUrl) {
        setState(() {
          _etape         = _EtapeCrypto.saisie;
          _messageErreur = resultat.erreur
              ? resultat.message
              : 'Impossible de créer la transaction. Réessayez.';
        });
        return;
      }

      _txid        = resultat.txid;
      _checkoutUrl = resultat.checkoutUrl;

      // ── Navigation vers l'écran in-app (plus de redirection navigateur) ──
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => PaiementCryptoWalletScreen(
            txid:          resultat.txid!,
            checkoutUrl:   resultat.checkoutUrl!,
            currency2:     _crypto,
            numCommande:   numCmd,
            montantXof:    montant,
            tontineCode:   widget.code,
            typeOperation: widget.typeFlux,
            membreId:      _membreId.isNotEmpty ? _membreId : null,
            membreNom:     _membreNom.isNotEmpty ? _membreNom : null,
            pretId:        widget.pretId,
          ),
        ),
      );
      if (!mounted) return;
      if (ok == true) {
        // Paiement confirmé — on remonte au parent avec succès
        Navigator.of(context).pop(true);
      } else {
        // Retour sans paiement — reset l'écran saisie
        setState(() {
          _etape         = _EtapeCrypto.saisie;
          _messageErreur = null;
          _messageInfo   = 'Paiement annulé ou en attente.';
        });
      }

    } catch (e) {
      _enTraitement = false;
      if (!mounted) return;
      if (kDebugMode) debugPrint('[CoinPayments] creerTransaction EXCEPTION: $e');
      // Affiche le vrai message d'erreur (pas un générique qui cache le problème)
      final errMsg = e.toString().replaceAll('Exception: ', '').replaceAll('ClientException: ', '');
      setState(() {
        _etape         = _EtapeCrypto.saisie;
        _messageErreur = '⚠️ $errMsg';
      });
    }
  }

  // ── Ouvrir le checkout CoinPayments ──────────────────────────────────────

  Future<void> _ouvrirCheckout() async {
    if (_checkoutUrl == null) return;
    final uri = Uri.tryParse(_checkoutUrl!);
    if (uri == null) return;

    setState(() => _checkoutOuvert = true);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) setState(() => _checkoutOuvert = false);
    }
  }

  // ── Polling : vérifier toutes les 10s ────────────────────────────────────

  void _lancerPolling(int montant, String numCmd) {
    _pollCount = 0;
    _pollTimer?.cancel();

    _watchdog = Timer(const Duration(minutes: 16), () {
      if (!mounted || _etape != _EtapeCrypto.attenteCheckout) return;
      _pollTimer?.cancel();
      setState(() {
        _etape        = _EtapeCrypto.saisie;
        _peutVerifier = true;
        _messageErreur = '⏱ Délai dépassé (15 min).\nRéf. : $numCmd';
        _messageInfo   = 'Si vous avez payé, utilisez "Vérifier" pour finaliser.';
      });
    });

    _pollTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (!mounted || _etape != _EtapeCrypto.attenteCheckout) {
        timer.cancel(); return;
      }
      _pollCount++;
      if (_pollCount > _maxPolls) {
        timer.cancel(); return;
      }

      if (_txid == null) return;

      try {
        final statut = await CoinPaymentsService.verifierStatut(
          txid:        _txid!,
          numCommande: numCmd,
          tontineCode: widget.code,
        );

        if (!mounted) { timer.cancel(); return; }
        if (kDebugMode) debugPrint('[CoinPayments] poll #$_pollCount → ${statut.statusNorm} (code=${statut.statusCode})');

        if (statut.estConfirme) {
          timer.cancel();
          _watchdog?.cancel();
          setState(() => _etape = _EtapeCrypto.confirmation);
          await _confirmerEtCrediter(montant, numCmd);
        } else if (statut.estEchec) {
          timer.cancel();
          _watchdog?.cancel();
          setState(() {
            _etape         = _EtapeCrypto.saisie;
            _messageErreur = statut.messageFr;
          });
        }
        // pending / processing → continuer le polling
      } catch (_) {
        // Erreur réseau silencieuse → polling continue
      }
    });
  }

  // ── Vérification immédiate (retour foreground ou bouton manuel) ───────────

  Future<void> _verifierStatutImmediatement() async {
    if (_txid == null || _numCommande == null) return;
    if (_enTraitement) return;
    _enTraitement = true;

    final montant = _montant;

    setState(() {
      _etape         = _EtapeCrypto.verification;
      _messageErreur = null;
    });

    try {
      final statut = await CoinPaymentsService.verifierStatut(
        txid:        _txid!,
        numCommande: _numCommande!,
        tontineCode: widget.code,
      );

      _enTraitement = false;
      if (!mounted) return;

      if (kDebugMode) debugPrint('[CoinPayments] verif immédiate → ${statut.statusNorm}');

      if (statut.estConfirme) {
        _pollTimer?.cancel();
        _watchdog?.cancel();
        setState(() => _etape = _EtapeCrypto.confirmation);
        await _confirmerEtCrediter(montant, _numCommande!);
      } else if (statut.estEnAttente) {
        setState(() {
          _etape       = _EtapeCrypto.attenteCheckout;
          _messageInfo = '⏳ Paiement en cours de confirmation blockchain. Patientez…';
        });
      } else {
        setState(() {
          _etape         = _EtapeCrypto.saisie;
          _messageErreur = statut.messageFr;
          _peutVerifier  = true;
        });
      }
    } catch (e) {
      _enTraitement = false;
      if (!mounted) return;
      setState(() {
        _etape         = _EtapeCrypto.attenteCheckout;
        _messageErreur = 'Vérification échouée : $e';
        _peutVerifier  = true;
      });
    }
  }

  // ── Confirmer et créditer (sécurisé côté serveur) ────────────────────────

  Future<void> _confirmerEtCrediter(int montant, String numCmd) async {
    try {
      if (kDebugMode) debugPrint('[CoinPayments] confirmerEtCrediter → $numCmd');

      final confirmation = await CoinPaymentsService.confirmerEtCrediter(
        txid:          _txid!,
        numCommande:   numCmd,
        tontineCode:   widget.code,
        typeOperation: widget.typeFlux,
        montantXof:    montant,
        membreId:      _membreId.isNotEmpty ? _membreId : null,
        membreNom:     _membreNom.isNotEmpty ? _membreNom : null,
        pretId:        widget.pretId,
      );

      if (!mounted) return;

      if (kDebugMode) debugPrint('[CoinPayments] confirmerEtCrediter → $confirmation');

      if (confirmation.ok) {
        setState(() => _etape = _EtapeCrypto.enregistrement);
        await _rechargerEtSucces(montant);
      } else if (confirmation.estEnAttente) {
        setState(() {
          _etape        = _EtapeCrypto.saisie;
          _peutVerifier = true;
          _messageErreur = '⏳ Confirmation blockchain en attente.\nRéf. : $numCmd';
          _messageInfo   = 'Utilisez "Vérifier" quand la transaction est confirmée.';
        });
      } else {
        setState(() {
          _etape         = _EtapeCrypto.saisie;
          _messageErreur = confirmation.message.isNotEmpty
              ? confirmation.message
              : 'Paiement non confirmé. Vérifiez votre wallet et réessayez.';
          _peutVerifier  = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _etape        = _EtapeCrypto.saisie;
        _peutVerifier = true;
        _messageErreur = '⚠️ Erreur de connexion.\nRéf. : ${_numCommande ?? "—"}';
        _messageInfo   = 'Si vous avez payé, utilisez "Vérifier" pour finaliser.';
      });
    }
  }

  // ── Recharger et succès ───────────────────────────────────────────────────

  Future<void> _rechargerEtSucces(int montant) async {
    final provider = context.read<TontineProvider>();
    try {
      await provider.chargerTontine(widget.code).timeout(const Duration(seconds: 15));
    } catch (_) {}
    if (!mounted) return;

    // Notification push
    try {
      final data   = provider.courante?.data;
      final devise = data?.devise ?? 'XOF';
      final lang   = Provider.of<LocaleService>(context, listen: false).langue.code; // ignore: use_build_context_synchronously
      final t      = SupabaseService.notifTexte(widget.typeFlux, lang, vars: {
        'montant': Formatters.montant(montant, devise: devise),
        'nom':     _membreNom,
        'libelle': 'CoinPayments Crypto',
        'desc':    '',
      });
      SupabaseService.envoyerNotification(
        code:    widget.code,
        type:    'cotisation_crypto_confirmee',
        titre:   t['titre'] ?? 'Paiement confirmé',
        message: t['message'] ?? 'Paiement CoinPayments confirmé.',
        donneesExtra: {
          'membre': _membreNom,
          'txid':   _txid ?? '',
          'crypto': _crypto,
        },
      );
    } catch (_) {}

    if (!mounted) return;
    setState(() => _etape = _EtapeCrypto.succes);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<TontineProvider>(context);
    final data     = provider.courante?.data;
    final montant  = widget.typeFlux == 'cotisation'
        ? (data?.montant ?? widget.montant ?? 0)
        : (widget.montant ?? 0);
    final devise   = data?.devise ?? 'XOF';

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: Text(
          _titreEcran,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color:      AppColors.encre,
            fontSize:   16,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.encre),
      ),
      body: switch (_etape) {
        _EtapeCrypto.saisie         => _vueSaisie(montant, devise),
        _EtapeCrypto.creation       => _vueChargement('Création de la transaction…'),
        _EtapeCrypto.attenteCheckout => _vueAttenteCheckout(montant, devise),
        _EtapeCrypto.verification   => _vueChargement('Vérification du paiement…'),
        _EtapeCrypto.confirmation   => _vueChargement('Confirmation en cours…'),
        _EtapeCrypto.enregistrement => _vueEnregistrement(),
        _EtapeCrypto.succes         => _vueSucces(montant, devise),
      },
    );
  }

  // ── Vue saisie ────────────────────────────────────────────────────────────

  Widget _vueSaisie(int montant, String devise) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Carte montant
          _CarteMontantCrypto(montant: montant, devise: devise),
          const SizedBox(height: 24),

          // Sélecteur crypto
          const Text(
            'Cryptomonnaie de paiement',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize:   14,
              color:      AppColors.encre,
            ),
          ),
          const SizedBox(height: 10),
          _SelecteurCrypto(
            selected: _crypto,
            onChanged: (v) => setState(() => _crypto = v),
          ),
          const SizedBox(height: 16),

          // Info USDT recommandé
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color:        const Color(0xFFFFF8EE),
              borderRadius: BorderRadius.circular(10),
              border:       Border.all(color: _couleurCrypto.withValues(alpha: 0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 16, color: _couleurCrypto),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'USDT TRC20 recommandé : frais minimaux, confirmation rapide (1-5 min).',
                    style: TextStyle(
                        fontSize: 12,
                        color:    AppColors.texte,
                        height:   1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Message erreur / info
          if (_messageErreur != null || _messageInfo != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _messageErreur != null
                    ? AppColors.alerteFond
                    : const Color(0xFFF3FBF6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_messageErreur != null)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            color: AppColors.alerte, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _messageErreur!,
                            style: const TextStyle(
                                color: AppColors.alerte, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  if (_messageInfo != null) ...[
                    if (_messageErreur != null) const SizedBox(height: 6),
                    Text(
                      _messageInfo!,
                      style: TextStyle(
                        fontSize:   12,
                        color:      _messageErreur != null
                            ? AppColors.alerte
                            : AppColors.succes,
                        fontStyle:  FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Bouton principal
          FilledButton.icon(
            onPressed: _enTraitement ? null : _creerTransaction,
            icon:  const Icon(Icons.currency_bitcoin_rounded),
            label: Text(
              'Payer ${Formatters.montant(montant, devise: devise)} en crypto',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            style: FilledButton.styleFrom(
              backgroundColor:         _couleurCrypto,
              disabledBackgroundColor: AppColors.encre.withValues(alpha: 0.2),
              padding:                 const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),

          // Bouton vérifier (si transaction déjà créée)
          if (_peutVerifier && _txid != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _enTraitement ? null : _verifierStatutImmediatement,
              icon: const Icon(Icons.search_rounded,
                  color: _couleurCrypto),
              label: const Text('Vérifier mon paiement',
                  style: TextStyle(
                      color: _couleurCrypto,
                      fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                side:    const BorderSide(color: _couleurCrypto),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape:   RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
            if (_numCommande != null) ...[
              const SizedBox(height: 4),
              Text(
                'Réf. : $_numCommande',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 10, color: AppColors.texteDoux),
              ),
            ],
          ],
        ],
      ),
    );
  }

  // ── Vue attente checkout ──────────────────────────────────────────────────

  Widget _vueAttenteCheckout(int montant, String devise) {
    final cryptoLabel = _cryptos
        .firstWhere((c) => c.$1 == _crypto, orElse: () => _cryptos.first)
        .$2;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 8),

          // En-tête crypto
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color:        _couleurFond,
              borderRadius: BorderRadius.circular(16),
              border:       Border.all(
                  color: _couleurCrypto.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.currency_bitcoin_rounded,
                    color: _couleurCrypto, size: 28),
                const SizedBox(width: 10),
                Text(
                  'Paiement $cryptoLabel',
                  style: const TextStyle(
                    fontSize:   18,
                    fontWeight: FontWeight.w700,
                    color:      _couleurCrypto,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          Text(
            'Montant à régler',
            style: const TextStyle(
                fontSize: 13, color: AppColors.texteDoux),
          ),
          const SizedBox(height: 4),
          Text(
            Formatters.montant(montant, devise: devise),
            style: const TextStyle(
              fontSize:   26,
              fontWeight: FontWeight.w800,
              color:      AppColors.encre,
            ),
          ),
          const SizedBox(height: 20),

          const Text(
            'La page de paiement CoinPayments a été ouverte dans votre navigateur.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 15, color: AppColors.encre, height: 1.5),
          ),
          const SizedBox(height: 8),
          const Text(
            'Scannez l\'adresse avec votre wallet crypto\n'
            'et revenez ici après paiement.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12, color: AppColors.texteDoux, height: 1.5),
          ),
          const SizedBox(height: 24),

          // Bouton ouvrir checkout
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _ouvrirCheckout,
              icon:  const Icon(Icons.open_in_browser_rounded, size: 20),
              label: const Text(
                'Ouvrir la page de paiement',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _couleurCrypto,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Indicateur polling
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: _couleurCrypto),
              ),
              SizedBox(width: 10),
              Text(
                'Détection automatique en cours…',
                style: TextStyle(fontSize: 12, color: AppColors.texteDoux),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Ne relancez PAS un nouveau paiement.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize:  11,
              color:     AppColors.alerte,
              fontStyle: FontStyle.italic,
            ),
          ),

          if (_messageInfo != null) ...[
            const SizedBox(height: 12),
            Text(
              _messageInfo!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12,
                  color:    AppColors.succes,
                  fontStyle: FontStyle.italic),
            ),
          ],

          if (_numCommande != null) ...[
            const SizedBox(height: 12),
            Text(
              'Réf. : $_numCommande',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 10, color: AppColors.texteDoux),
            ),
          ],

          const SizedBox(height: 24),
          // Bouton vérification manuelle
          OutlinedButton.icon(
            onPressed: _verifierStatutImmediatement,
            icon: const Icon(Icons.search_rounded,
                color: _couleurCrypto, size: 18),
            label: const Text(
              'Vérifier manuellement',
              style: TextStyle(
                  color: _couleurCrypto,
                  fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              side:    const BorderSide(color: _couleurCrypto),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              shape:   RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Vue chargement générique ───────────────────────────────────────────────

  Widget _vueChargement(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: _couleurCrypto),
            const SizedBox(height: 24),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: AppColors.texte),
            ),
            const SizedBox(height: 8),
            const Text(
              'Ne fermez pas l\'application.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: AppColors.texteDoux),
            ),
          ],
        ),
      ),
    );
  }

  // ── Vue enregistrement ────────────────────────────────────────────────────

  Widget _vueEnregistrement() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72, height: 72,
              decoration: const BoxDecoration(
                color: Color(0xFFFFF8EE),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_outline_rounded,
                  size: 44, color: _couleurCrypto),
            ),
            const SizedBox(height: 20),
            const Text(
              'Paiement crypto confirmé !',
              style: TextStyle(
                fontSize:   20,
                fontWeight: FontWeight.w800,
                color:      AppColors.encre,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Enregistrement en cours…',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: AppColors.texteDoux),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 28, height: 28,
              child: CircularProgressIndicator(
                  strokeWidth: 3, color: _couleurCrypto),
            ),
          ],
        ),
      ),
    );
  }

  // ── Vue succès ────────────────────────────────────────────────────────────

  Widget _vueSucces(int montant, String devise) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80, height: 80,
              decoration: const BoxDecoration(
                color: Color(0xFFFFF8EE),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  size: 50, color: _couleurCrypto),
            ),
            const SizedBox(height: 24),
            const Text(
              'Paiement reçu avec succès.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize:   22,
                fontWeight: FontWeight.w800,
                color:      AppColors.encre,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${_membreNom.isNotEmpty ? "$_membreNom — " : ""}'
              '${Formatters.montant(montant, devise: devise)}\n'
              'Payé en $_crypto via CoinPayments.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 15, color: AppColors.texte, height: 1.5),
            ),
            if (_txid != null) ...[
              const SizedBox(height: 8),
              Text(
                'Réf. tx : $_txid',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.texteDoux),
              ),
            ],
            const SizedBox(height: 40),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: _couleurCrypto,
                padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text(
                'Retour',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Enum étapes ───────────────────────────────────────────────────────────────

enum _EtapeCrypto {
  saisie,
  creation,
  attenteCheckout,
  verification,
  confirmation,
  enregistrement,
  succes,
}

// ── Widget carte montant ──────────────────────────────────────────────────────

class _CarteMontantCrypto extends StatelessWidget {
  final int    montant;
  final String devise;
  const _CarteMontantCrypto({required this.montant, required this.devise});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color:        const Color(0xFFFFF8EE),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: const Color(0xFFF7931A).withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          const Text(
            'Montant à payer',
            style: TextStyle(fontSize: 13, color: AppColors.texteDoux),
          ),
          const SizedBox(height: 6),
          Text(
            Formatters.montant(montant, devise: devise),
            style: const TextStyle(
              fontSize:   28,
              fontWeight: FontWeight.w800,
              color:      Color(0xFFF7931A),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Paiement crypto sécurisé — CoinPayments',
            style: TextStyle(fontSize: 11, color: AppColors.texteDoux),
          ),
        ],
      ),
    );
  }
}

// ── Sélecteur de crypto ───────────────────────────────────────────────────────

class _SelecteurCrypto extends StatelessWidget {
  final String               selected;
  final ValueChanged<String> onChanged;

  static const _items = [
    ('USDT.TRC20', 'USDT TRC20', Color(0xFF26A17B)),
    ('USDT.ERC20', 'USDT ERC20', Color(0xFF3C9BFF)),
    ('BTC',        'Bitcoin',    Color(0xFFF7931A)),
    ('ETH',        'Ethereum',   Color(0xFF627EEA)),
    ('LTC',        'Litecoin',   Color(0xFF9DA2A6)),
  ];

  const _SelecteurCrypto({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _items.map((item) {
        final (code, label, color) = item;
        final sel = selected == code;
        return GestureDetector(
          onTap: () => onChanged(code),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: sel
                  ? color.withValues(alpha: 0.12)
                  : AppColors.fondSecondaire,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: sel
                    ? color.withValues(alpha: 0.6)
                    : AppColors.lignes,
                width: sel ? 1.5 : 1.0,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize:   13,
                fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
                color:      sel ? color : AppColors.texte,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
