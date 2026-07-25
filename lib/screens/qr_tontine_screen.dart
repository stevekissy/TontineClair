// ═══════════════════════════════════════════════════════════════════════════════
// QrTontineScreen  —  TontineClair Phase 4 / Option Z
//
// Génère un QR code de vérification blockchain pour une tontine.
// Encode l'URL publique de vérification → partageable sur WhatsApp, SMS, etc.
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../utils/app_colors.dart';
import '../services/blockchain_service.dart';

class QrTontineScreen extends StatefulWidget {
  final String codeTontine;
  final String nomTontine;

  const QrTontineScreen({
    super.key,
    required this.codeTontine,
    required this.nomTontine,
  });

  @override
  State<QrTontineScreen> createState() => _QrTontineScreenState();
}

class _QrTontineScreenState extends State<QrTontineScreen> {
  final GlobalKey _qrKey = GlobalKey();
  int _totalOps = 0;
  int _onChain  = 0;
  int _phase    = 1;
  bool _loading = true;
  bool _sharing = false;

  // Contenu encodé dans le QR :
  // - Phase 2 on-chain : lien PolygonScan vers le smart contract (page réelle)
  // - Phase 1 SHA-256  : lien Google Play / texte de vérification manuelle
  String get _urlVerification {
    if (_phase == 2) {
      // TontineVault.sol sur Polygon Mainnet — page réelle et vérifiable
      const contrat = '0xbADbBb485159775c5733c5E0F506b7942ee77872';
      return 'https://polygonscan.com/address/$contrat';
    }
    // Phase 1 : URL PlayStore avec param utm pour identifier la source
    return 'https://play.google.com/store/apps/details?id=com.tontineclair.app&utm_source=qr&utm_content=${widget.codeTontine}';
  }

  // Texte WhatsApp — dynamique selon la phase réelle
  String get _messageWhatsapp {
    final securite = _phase == 2
        ? 'Ancre on-chain Polygon Mainnet — $_onChain TX verifiables sur PolygonScan'
        : 'Securise par TontineClair (journal SHA-256 interne)';
    final lien = _phase == 2
        ? 'Voir le contrat : $_urlVerification'
        : 'Ouvrez TontineClair > Verifier blockchain > Code : ${widget.codeTontine}';
    return '*Verifiez la tontine "${widget.nomTontine}" sur la blockchain*\n\n'
        'Code : *${widget.codeTontine}*\n'
        '$_totalOps operation${_totalOps > 1 ? "s" : ""} enregistree${_totalOps > 1 ? "s" : ""} dans le journal\n'
        '$securite\n\n'
        'Scannez le QR code ci-joint ou :\n'
        '$lien';
  }

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    try {
      final results = await Future.wait([
        BlockchainService.lireJournal(tontineCode: widget.codeTontine, limit: 200),
        BlockchainService.contractInfo(),
      ]);
      final toutesEntrees = results[0] as List<BlockchainEntry>;
      final contrat = results[1] as Map<String, dynamic>;
      if (!mounted) return;
      // Garde client : seules les entrées de CETTE tontine sont comptées
      final codeCible = widget.codeTontine.trim().toUpperCase();
      final entrees = toutesEntrees
          .where((e) => e.tontineCode.trim().toUpperCase() == codeCible)
          .toList();
      final phaseRecu = (contrat['phase'] as num?)?.toInt() ?? 1;
      setState(() {
        _phase    = phaseRecu;
        _totalOps = entrees.length;
        // Phase 1 : tx_hash = proof SHA-256 local, PAS un vrai TX Polygon
        // Phase 2 : vrais TX Ethereum v\u00e9rifiables sur Polygon
        _onChain  = phaseRecu == 2
            ? entrees.where((e) => e.txHash != null && e.txHash!.length == 66).length
            : 0;
        _loading  = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Capturer le QR en image ────────────────────────────────────────────────
  Future<Uint8List?> _capturerQr() async {
    try {
      final boundary = _qrKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  // ── Partager QR + message ──────────────────────────────────────────────────
  Future<void> _partager() async {
    setState(() => _sharing = true);
    try {
      final bytes = await _capturerQr();
      if (bytes == null) {
        // Fallback : partager juste le texte
        await Share.share(_messageWhatsapp,
            subject: 'Vérification blockchain ${widget.nomTontine}');
        return;
      }

      final dir  = await getTemporaryDirectory();
      final file = File('${dir.path}/qr_${widget.codeTontine}.png');
      await file.writeAsBytes(bytes);

      await Share.shareXFiles(
        [XFile(file.path)],
        text: _messageWhatsapp,
        subject: 'Vérification blockchain — ${widget.nomTontine}',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Erreur partage: $e'),
          backgroundColor: AppColors.alerte,
        ),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  // ── Copier lien ────────────────────────────────────────────────────────────
  void _copierLien() {
    Clipboard.setData(ClipboardData(text: _urlVerification));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Lien copié !'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
        backgroundColor: AppColors.succes,
      ),
    );
  }

  // ── Copier message WhatsApp ────────────────────────────────────────────────
  void _copierMessage() {
    Clipboard.setData(ClipboardData(text: _messageWhatsapp));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Message WhatsApp copié !'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
        backgroundColor: AppColors.succes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.encre,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('QR Code Blockchain',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            Text(widget.nomTontine,
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _sharing ? null : _partager,
            tooltip: 'Partager',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── QR Code principal ──────────────────────────────────────────────
          Center(
            child: RepaintBoundary(
              key: _qrKey,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.encre.withValues(alpha: 0.15),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // En-tête QR
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.verified_outlined,
                            size: 16, color: AppColors.encre),
                        const SizedBox(width: 6),
                        const Text(
                          'TontineClair · Vérification Blockchain',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.encre,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // QR Code
                    QrImageView(
                      data: _urlVerification,
                      version: QrVersions.auto,
                      size: 220,
                      backgroundColor: Colors.white,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: AppColors.encre,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: AppColors.encre,
                      ),
                      errorCorrectionLevel: QrErrorCorrectLevel.H,
                    ),

                    const SizedBox(height: 12),

                    // Code tontine sous le QR
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.fondCode,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        widget.codeTontine,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: AppColors.encre,
                          letterSpacing: 4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _loading
                          ? 'Chargement...'
                          : '$_totalOps operation${_totalOps > 1 ? "s" : ""} · '
                              '${_phase == 2 ? "$_onChain on-chain" : "SHA-256"}',
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.texteDoux),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 24),

          // ── Stats ──────────────────────────────────────────────────────────
          if (!_loading)
            Row(
              children: [
                _StatChip(
                    label: 'Opérations',
                    valeur: '$_totalOps',
                    icone: Icons.list_alt,
                    couleur: AppColors.encre),
                const SizedBox(width: 8),
                _StatChip(
                    label: _phase == 2 ? 'On-chain' : 'SHA-256',
                    valeur: _phase == 2 ? '$_onChain' : '$_totalOps',
                    icone: _phase == 2 ? Icons.bolt : Icons.lock_outline,
                    couleur: _phase == 2
                        ? const Color(0xFF00C853)
                        : AppColors.or),
                const SizedBox(width: 8),
                _StatChip(
                    label: 'Phase',
                    valeur: '$_phase',
                    icone: Icons.layers_outlined,
                    couleur: _phase == 2
                        ? const Color(0xFF00C853)
                        : AppColors.or),
              ],
            ),

          const SizedBox(height: 20),

          // ── Message WhatsApp ───────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppColors.whatsapp.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.chat_outlined,
                        size: 18, color: AppColors.whatsapp),
                    const SizedBox(width: 8),
                    const Text(
                      'Message WhatsApp prêt',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.whatsapp,
                        fontSize: 14,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _copierMessage,
                      child: const Icon(Icons.copy,
                          size: 18, color: AppColors.whatsapp),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  _messageWhatsapp,
                  style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.texte,
                      height: 1.5),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── URL de vérification ────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.carte,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.lignes),
            ),
            child: Row(
              children: [
                const Icon(Icons.link, size: 18, color: AppColors.encre),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _urlVerification,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.encre,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: _copierLien,
                  child: const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.copy,
                        size: 18, color: AppColors.texteDoux),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ── Boutons ────────────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _sharing ? null : _partager,
              icon: _sharing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.share),
              label: Text(_sharing
                  ? 'Partage en cours…'
                  : 'Partager QR + Message'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.whatsapp,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              onPressed: _copierLien,
              icon: const Icon(Icons.link),
              label: const Text('Copier le lien'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.encre,
                side: const BorderSide(color: AppColors.encre),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// ── Chip statistique ───────────────────────────────────────────────────────────
class _StatChip extends StatelessWidget {
  final String label;
  final String valeur;
  final IconData icone;
  final Color couleur;

  const _StatChip({
    required this.label,
    required this.valeur,
    required this.icone,
    required this.couleur,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: couleur.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: couleur.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Icon(icone, size: 20, color: couleur),
            const SizedBox(height: 4),
            Text(valeur,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: couleur)),
            Text(label,
                style: const TextStyle(
                    fontSize: 10, color: AppColors.texteDoux)),
          ],
        ),
      ),
    );
  }
}
