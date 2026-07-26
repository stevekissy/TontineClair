import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/coinpayments_service.dart';


/// Écran de paiement crypto 100% in-app — aucune redirection externe.
///
/// Affiche directement dans TontineClair :
///   • QR code de l'adresse wallet
///   • Adresse copiable
///   • Montant exact en crypto
///   • Timer de expiration
///   • Détection automatique du paiement (polling)
///
/// CoinPayments reste totalement invisible pour l'utilisateur.
class PaiementCryptoWalletScreen extends StatefulWidget {
  final String  txid;
  final String  checkoutUrl;
  final String  currency2;       // 'USDT.TRC20' | 'BTC' | 'ETH' | 'LTC' | 'USDT.ERC20'
  final String  numCommande;
  final int     montantXof;
  final String  tontineCode;
  final String  typeOperation;
  final String? membreId;
  final String? membreNom;
  final String? pretId;

  const PaiementCryptoWalletScreen({
    super.key,
    required this.txid,
    required this.checkoutUrl,
    required this.currency2,
    required this.numCommande,
    required this.montantXof,
    required this.tontineCode,
    required this.typeOperation,
    this.membreId,
    this.membreNom,
    this.pretId,
  });

  @override
  State<PaiementCryptoWalletScreen> createState() =>
      _PaiementCryptoWalletScreenState();
}

class _PaiementCryptoWalletScreenState
    extends State<PaiementCryptoWalletScreen>
    with WidgetsBindingObserver {

  // ── Palette TontineClair ──────────────────────────────────────────────────
  static const _orange   = Color(0xFFF7931A);
  static const _vert     = Color(0xFF2ECC71);
  static const _rouge    = Color(0xFFE74C3C);
  static const _bleuFond = Color(0xFFF0F4FF);

  // ── State ─────────────────────────────────────────────────────────────────
  String? _address;
  double  _amountCrypto = 0;
  int     _timeoutSecs  = 7200;   // 2h par défaut
  bool    _loadingWallet = true;
  String? _walletError;

  // Timer countdown
  Timer?  _countdownTimer;
  int     _secondsLeft = 7200;

  // Polling statut
  Timer?  _pollTimer;
  int     _pollCount  = 0;
  static const int _maxPolls = 90; // 90 × 10s = 15 min
  bool    _paiementDetecte = false;
  bool    _enConfirmation  = false;
  String? _erreurConfirm;

  // Copie adresse
  bool    _adresseCopie = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _chargerWallet();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Retour foreground (ex : l'utilisateur vient de payer sur son wallet)
  /// → vérification immédiate sans attendre le prochain tick de polling (10s).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed
        && !_paiementDetecte
        && !_enConfirmation
        && _address != null) {
      if (kDebugMode) debugPrint('[CryptoWallet] Retour foreground → vérification immédiate');
      _verifierStatut();
    }
  }

  // ── Chargement adresse wallet ──────────────────────────────────────────────

  Future<void> _chargerWallet() async {
    setState(() { _loadingWallet = true; _walletError = null; });
    try {
      final info = await CoinPaymentsService.infoWallet(
        txid:        widget.txid,
        checkoutUrl: widget.checkoutUrl,
        currency2:   widget.currency2,
        numCommande: widget.numCommande,
      );
      if (!mounted) return;
      if (info['erreur'] == true) {
        setState(() {
          _walletError  = info['message'] as String? ?? 'Erreur récupération wallet';
          _loadingWallet = false;
        });
        return;
      }
      final address = (info['address'] as String?) ?? '';
      final amountf = (info['amountf'] as num?)?.toDouble() ?? 0.0;
      final timeout = (info['timeout'] as num?)?.toInt() ?? 7200;

      if (address.isEmpty) {
        setState(() {
          _walletError  = 'Adresse wallet non disponible. Réessayez.';
          _loadingWallet = false;
        });
        return;
      }

      setState(() {
        _address      = address;
        _amountCrypto = amountf;
        _timeoutSecs  = timeout;
        _secondsLeft  = timeout;
        _loadingWallet = false;
      });

      _demarrerCountdown();
      _demarrerPolling();

    } catch (e) {
      if (!mounted) return;
      setState(() {
        _walletError  = 'Erreur: ${e.toString().replaceAll('Exception: ', '')}';
        _loadingWallet = false;
      });
    }
  }

  // ── Countdown timer ────────────────────────────────────────────────────────

  void _demarrerCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        if (_secondsLeft > 0) {
          _secondsLeft--;
        } else {
          t.cancel();
        }
      });
    });
  }

  String get _tempsFormate {
    final h = _secondsLeft ~/ 3600;
    final m = (_secondsLeft % 3600) ~/ 60;
    final s = _secondsLeft % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  bool get _expire => _secondsLeft <= 0;

  // ── Polling détection paiement ─────────────────────────────────────────────

  void _demarrerPolling() {
    _pollTimer?.cancel();
    _pollCount = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted || _paiementDetecte) return;
      _pollCount++;
      if (_pollCount > _maxPolls) { _pollTimer?.cancel(); return; }
      _verifierStatut();
    });
  }

  Future<void> _verifierStatut() async {
    try {
      final statut = await CoinPaymentsService.verifierStatut(
        txid:        widget.txid,
        numCommande: widget.numCommande,
        tontineCode: widget.tontineCode,
      );
      if (!mounted) return;

      // CAS 1 : Déjà crédité en DB (IPN a tout traité avant notre polling)
      // → L'Edge Function retourne ok:true + fromCache:true → succès immédiat, pas besoin de re-créditer
      if (statut.ok && !_paiementDetecte) {
        _pollTimer?.cancel();
        _countdownTimer?.cancel();
        setState(() { _paiementDetecte = true; _enConfirmation = false; });
        _afficherSucces();
        return;
      }

      // CAS 2 : needsCredit=true → IPN reçu mais crédit en attente (polling Flutter)
      // → L'Edge Function a détecté processing+IPN reçu → il faut appeler confirmerEtCrediter
      if (statut.needsCredit && !_enConfirmation && !_paiementDetecte) {
        _pollTimer?.cancel();
        _confirmerEtCrediter();
        return;
      }

      // CAS 3 : statusCode == 100 ou statusNorm == 'confirmed' sans ok:true
      // → CoinPayments confirme le paiement → déclencher crédit côté serveur
      // CoinPayments : 1 = fonds reçus non confirmés, 2 = en cours, 100 = CONFIRMÉ
      final estConfirme = statut.statusCode == 100
          || statut.statusNorm == 'confirmed';

      if (estConfirme && !_enConfirmation && !_paiementDetecte) {
        _pollTimer?.cancel();
        _confirmerEtCrediter();
      }
      // statut 1, 2, etc. → on continue à poller, rien à faire
    } catch (_) {}
  }

  Future<void> _confirmerEtCrediter() async {
    if (_enConfirmation || _paiementDetecte) return;
    setState(() { _enConfirmation = true; _erreurConfirm = null; });

    try {
      final result = await CoinPaymentsService.confirmerEtCrediter(
        txid:          widget.txid,
        numCommande:   widget.numCommande,
        tontineCode:   widget.tontineCode,
        typeOperation: widget.typeOperation,
        montantXof:    widget.montantXof,
        membreId:      widget.membreId,
        membreNom:     widget.membreNom,
        pretId:        widget.pretId,
      );
      if (!mounted) return;

      if (result.ok) {
        _countdownTimer?.cancel();
        setState(() { _paiementDetecte = true; _enConfirmation = false; });
        _afficherSucces();
      } else {
        setState(() {
          _enConfirmation = false;
          _erreurConfirm  = result.message;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _enConfirmation = false;
        _erreurConfirm  = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  void _afficherSucces() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: _vert, size: 72),
            const SizedBox(height: 16),
            const Text(
              'Paiement confirmé !',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Votre ${_labelType(widget.typeOperation)} a été enregistrée avec succès.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 8),
            Text(
              'Réf. : ${widget.numCommande}',
              style: const TextStyle(fontSize: 11, color: Colors.black38),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();       // ferme dialog
              Navigator.of(context).pop(true);   // retour avec succès
            },
            child: const Text('Retour', style: TextStyle(color: _orange)),
          ),
        ],
      ),
    );
  }

  String _labelType(String t) {
    const map = {
      'cotisation':         'cotisation',
      'caisse':             'apport caisse',
      'penalite':           'pénalité',
      'remboursement_pret': 'remboursement',
      'pret_octroye':       'prêt',
    };
    return map[t] ?? t;
  }

  // ── Copier adresse ─────────────────────────────────────────────────────────

  Future<void> _copierAdresse() async {
    if (_address == null) return;
    await Clipboard.setData(ClipboardData(text: _address!));
    setState(() => _adresseCopie = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _adresseCopie = false);
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Adresse copiée !'),
          backgroundColor: _vert,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _copierMontant() async {
    await Clipboard.setData(ClipboardData(text: _amountCrypto.toStringAsFixed(8)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Montant copié !'),
          backgroundColor: _vert,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // ── Labels crypto ──────────────────────────────────────────────────────────

  String get _cryptoLabel {
    const map = {
      'USDT.TRC20': 'USDT TRC20',
      'USDT.BEP20': 'USDT BEP20',
      'USDT.ERC20': 'USDT ERC20',
      'BNB.BSC':    'BNB (BSC)',
      'BTC':        'Bitcoin',
      'ETH':        'Ethereum',
      'LTC':        'Litecoin',
    };
    return map[widget.currency2] ?? widget.currency2;
  }

  // Libellé du réseau pour les avertissements
  String get _networkLabel {
    const map = {
      'USDT.TRC20': 'TRC20 (Tron)',
      'USDT.BEP20': 'BEP20 (BSC)',
      'USDT.ERC20': 'ERC20 (Ethereum)',
      'BNB.BSC':    'BSC (BNB Smart Chain)',
      'BTC':        'Bitcoin',
      'ETH':        'Ethereum',
      'LTC':        'Litecoin',
    };
    return map[widget.currency2] ?? widget.currency2;
  }

  Color get _cryptoColor {
    if (widget.currency2 == 'BNB.BSC')     return const Color(0xFFF0B90B);
    if (widget.currency2 == 'USDT.BEP20')  return const Color(0xFFF0B90B);
    if (widget.currency2.contains('USDT')) return const Color(0xFF26A17B);
    if (widget.currency2 == 'BTC')         return _orange;
    if (widget.currency2 == 'ETH')         return const Color(0xFF627EEA);
    if (widget.currency2 == 'LTC')         return const Color(0xFF9DA2A6);
    return _orange;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bleuFond,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        centerTitle: true,
        title: Column(
          children: [
            Text(
              'Paiement $_cryptoLabel',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const Text(
              'Sécurisé par TontineClair',
              style: TextStyle(fontSize: 11, color: Colors.black38),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: SafeArea(
        child: _loadingWallet
            ? _buildChargement()
            : _walletError != null
                ? _buildErreur()
                : _paiementDetecte
                    ? _buildSucces()
                    : _expire
                        ? _buildExpire()
                        : _buildPaiement(),
      ),
    );
  }

  // ── États ──────────────────────────────────────────────────────────────────

  Widget _buildChargement() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: _orange),
          SizedBox(height: 20),
          Text('Préparation du paiement…', style: TextStyle(color: Colors.black54)),
        ],
      ),
    );
  }

  Widget _buildErreur() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: _rouge, size: 56),
            const SizedBox(height: 16),
            Text(
              _walletError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _chargerWallet,
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
              style: ElevatedButton.styleFrom(backgroundColor: _orange),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpire() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.timer_off, color: _rouge, size: 56),
            const SizedBox(height: 16),
            const Text(
              'Transaction expirée',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Le délai de paiement (2h) est dépassé.\nCreez une nouvelle transaction.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => Navigator.of(context).pop(false),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Retour'),
              style: ElevatedButton.styleFrom(backgroundColor: _orange),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSucces() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, color: _vert, size: 80),
            const SizedBox(height: 20),
            const Text('Paiement confirmé !',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              _labelType(widget.typeOperation).toUpperCase(),
              style: TextStyle(color: _cryptoColor, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.home),
              label: const Text('Retour à la tontine'),
              style: ElevatedButton.styleFrom(backgroundColor: _vert),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaiement() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          // ── Header montant ────────────────────────────────────────────────
          _buildCardMontant(),
          const SizedBox(height: 12),

          // ── QR Code ───────────────────────────────────────────────────────
          _buildCardQR(),
          const SizedBox(height: 12),

          // ── Adresse wallet ────────────────────────────────────────────────
          _buildCardAdresse(),
          const SizedBox(height: 12),

          // ── Montant exact ──────────────────────────────────────────────────
          _buildCardMontantCrypto(),
          const SizedBox(height: 12),

          // ── Timer + status ────────────────────────────────────────────────
          _buildCardTimer(),
          const SizedBox(height: 12),

          // ── Warning ───────────────────────────────────────────────────────
          _buildWarning(),
          const SizedBox(height: 16),

          // ── Bouton vérification manuelle ──────────────────────────────────
          _buildBoutonVerifier(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildBoutonVerifier() {
    return Column(
      children: [
        if (_enConfirmation)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: _orange)),
                SizedBox(width: 10),
                Text('Vérification en cours…',
                    style: TextStyle(color: _orange, fontSize: 13)),
              ],
            ),
          )
        else
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _enConfirmation ? null : _verifierStatut,
              icon: const Icon(Icons.check_circle_outline, color: _orange),
              label: const Text(
                'J\'ai payé — Vérifier maintenant',
                style: TextStyle(
                  color: _orange,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: _orange, width: 2),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        if (_erreurConfirm != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _rouge.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _erreurConfirm!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _rouge, fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }

  // ── Widgets cards ──────────────────────────────────────────────────────────

  Widget _buildCardMontant() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_cryptoColor.withValues(alpha: 0.9), _cryptoColor],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            _cryptoLabel,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '${_formaterXof(widget.montantXof)} FCFA',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Envoyez exactement le montant ci-dessous',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildCardQR() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.qr_code_2, color: _cryptoColor, size: 20),
              const SizedBox(width: 6),
              const Text(
                'Scannez avec votre wallet crypto',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _cryptoColor.withValues(alpha: 0.4), width: 3),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(10),
            child: QrImageView(
              data: _address!,
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
              // M = 15% de correction d'erreur — bon compromis lisibilité/densité
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              eyeStyle: QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: _cryptoColor,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Colors.black87,
              ),
              // ⚠️ PAS de embeddedImage — le logo détruisait la lisibilité du QR
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Ouvrez votre application wallet et scannez',
            style: TextStyle(fontSize: 12, color: Colors.black.withValues(alpha: 0.4)),
          ),
        ],
      ),
    );
  }

  Widget _buildCardAdresse() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.account_balance_wallet, color: _cryptoColor, size: 18),
              const SizedBox(width: 6),
              Text(
                'Adresse $_cryptoLabel',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Text(
              _address!,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                letterSpacing: 0.5,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _copierAdresse,
              icon: Icon(_adresseCopie ? Icons.check : Icons.copy, size: 18),
              label: Text(_adresseCopie ? 'Adresse copiée !' : 'Copier l\'adresse'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _adresseCopie ? _vert : _cryptoColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardMontantCrypto() {
    final montantStr = _amountCrypto > 0
        ? _amountCrypto.toStringAsFixed(widget.currency2 == 'BTC' ? 8 : 5)
        : '…';
    final unite = widget.currency2.contains('USDT') ? 'USDT'
        : (widget.currency2 == 'BNB.BSC' ? 'BNB' : widget.currency2);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.payments_outlined, color: _cryptoColor, size: 18),
              const SizedBox(width: 6),
              const Text(
                'Montant exact à envoyer',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _cryptoColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$montantStr $unite',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: _cryptoColor,
                      fontFamily: 'monospace',
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _copierMontant,
                icon: const Icon(Icons.copy, size: 20),
                tooltip: 'Copier le montant',
                style: IconButton.styleFrom(
                  backgroundColor: Colors.grey.shade100,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '⚠️ Envoyez EXACTEMENT ce montant, ni plus ni moins.',
            style: TextStyle(fontSize: 11, color: Colors.deepOrange),
          ),
        ],
      ),
    );
  }

  Widget _buildCardTimer() {
    final timerColor = _secondsLeft < 300 ? _rouge : _orange;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.timer_outlined, color: timerColor, size: 18),
                  const SizedBox(width: 6),
                  const Text('Temps restant', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: timerColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _tempsFormate,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: timerColor,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Barre progression
          LinearProgressIndicator(
            value: _timeoutSecs > 0 ? _secondsLeft / _timeoutSecs : 0,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation<Color>(timerColor),
            borderRadius: BorderRadius.circular(4),
            minHeight: 6,
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_enConfirmation) ...[
                const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _orange)),
                const SizedBox(width: 8),
                const Text('Vérification en cours…',
                    style: TextStyle(fontSize: 12, color: _orange)),
              ] else ...[
                const Icon(Icons.radar, color: Colors.black38, size: 14),
                const SizedBox(width: 6),
                const Text('Détection automatique active',
                    style: TextStyle(fontSize: 12, color: Colors.black38)),
              ],
            ],
          ),
          if (_erreurConfirm != null) ...[
            const SizedBox(height: 8),
            Text(
              _erreurConfirm!,
              style: const TextStyle(fontSize: 11, color: _rouge),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWarning() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline, color: Colors.amber, size: 18),
              const SizedBox(width: 6),
              Text(
                'Instructions importantes',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: Colors.amber.shade800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _warningItem('Réseau obligatoire : $_networkLabel'),
          _warningItem('Tout envoi sur le mauvais réseau sera perdu définitivement'),
          if (widget.currency2 == 'USDT.BEP20' || widget.currency2 == 'BNB.BSC')
            _warningItem('BSC = BNB Smart Chain (anciennement Binance Smart Chain)'),
          _warningItem('Envoyez EXACTEMENT le montant indiqué'),
          _warningItem('Ne fermez pas cet écran avant confirmation'),
          _warningItem('Le paiement est détecté automatiquement (1-5 min)'),
        ],
      ),
    );
  }

  Widget _warningItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.arrow_right, size: 16, color: Colors.amber.shade700),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: Colors.amber.shade900),
            ),
          ),
        ],
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _formaterXof(int v) {
    final s = v.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
