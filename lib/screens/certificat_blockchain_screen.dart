// ═══════════════════════════════════════════════════════════════════════════════
// CertificatBlockchainScreen  —  TontineClair Phase 4 / Option X
//
// Génère un certificat PDF officieux avec toutes les TX blockchain d'une tontine.
// Signé avec le hash SHA-256 du contenu + timestamp.
// Partageable via share_plus.
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io' if (dart.library.html) 'dart:io';
import '../services/blockchain_service.dart';
import '../utils/app_colors.dart';

class CertificatBlockchainScreen extends StatefulWidget {
  final String codeTontine;
  final String nomTontine;
  final String? membreNom; // si null → certificat global tontine

  const CertificatBlockchainScreen({
    super.key,
    required this.codeTontine,
    required this.nomTontine,
    this.membreNom,
  });

  @override
  State<CertificatBlockchainScreen> createState() =>
      _CertificatBlockchainScreenState();
}

class _CertificatBlockchainScreenState
    extends State<CertificatBlockchainScreen> {
  List<BlockchainEntry> _entrees = [];
  Map<String, dynamic> _contrat = {};
  bool _loading = true;
  bool _generating = false;
  String? _erreur;

  // Couleurs PDF
  static const _pdfEncre    = PdfColor.fromInt(0xFF1C2447);
  static const _pdfOr       = PdfColor.fromInt(0xFFD99A2B);
  static const _pdfGris     = PdfColor.fromInt(0xFFF7F7F4);
  static const _pdfLignes   = PdfColor.fromInt(0xFFE4E1D6);
  static const _pdfTexte    = PdfColor.fromInt(0xFF26251F);
  static const _pdfDoux     = PdfColor.fromInt(0xFF6E6C60);
  static const _pdfChain    = PdfColor.fromInt(0xFF00C853);

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() { _loading = true; _erreur = null; });
    try {
      final results = await Future.wait([
        BlockchainService.lireJournal(
          tontineCode: widget.codeTontine,
          limit: 200,
        ),
        BlockchainService.contractInfo(),
      ]);
      if (!mounted) return;
      // Garde client : seules les entrées de cette tontine sont conservées
      final codeCible = widget.codeTontine.trim().toUpperCase();
      final toutesEntrees = results[0] as List<BlockchainEntry>;
      setState(() {
        _entrees = toutesEntrees
            .where((e) => e.tontineCode.trim().toUpperCase() == codeCible)
            .toList();
        _contrat = results[1] as Map<String, dynamic>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _erreur = 'Erreur: $e'; });
    }
  }

  // ── Chargement polices PDF (NotoSans → Helvetica en fallback) ────────────
  static Future<({pw.Font regular, pw.Font bold})> _chargerPolices() async {
    try {
      final regular = await PdfGoogleFonts.notoSansRegular();
      final bold    = await PdfGoogleFonts.notoSansBold();
      return (regular: regular, bold: bold);
    } catch (_) {
      return (regular: pw.Font.helvetica(), bold: pw.Font.helveticaBold());
    }
  }

  // ── Calcul countOnChain unifié ─────────────────────────────────────────────
  /// Logique Phase-aware partagée entre le build Flutter et le PDF.
  /// Phase 1 : preuve SHA-256 locale  → hash non-vide
  /// Phase 2 : TX Ethereum on-chain   → hash de 66 caractères (0x…)
  static int _computeCountOnChain(List<BlockchainEntry> entrees, int phase) {
    if (phase == 2) {
      return entrees
          .where((e) => e.txHash != null && e.txHash!.length == 66)
          .length;
    } else {
      return entrees
          .where((e) => e.txHash != null && e.txHash!.isNotEmpty)
          .length;
    }
  }

  // ── Génération PDF ─────────────────────────────────────────────────────────
  Future<Uint8List> _genererPdf() async {
    // Charger les polices AVANT de construire le document
    // (Helvetica intégrée ne supporte pas les accents UTF-8 → crash)
    final polices  = await _chargerPolices();
    final fontReg  = polices.regular;
    final fontBold = polices.bold;

    final doc = pw.Document();
    final now = DateTime.now();
    final phase = (_contrat['phase'] as num?)?.toInt() ?? 1;
    final contratAddr = _contrat['contract_address'] as String?
        ?? _contrat['address'] as String?;

    // Filtrer par membre si demandé
    final entreesFiltrees = widget.membreNom != null
        ? _entrees
            .where((e) =>
                e.membreNom?.toLowerCase() ==
                    widget.membreNom!.toLowerCase() ||
                e.membreId?.toLowerCase() ==
                    widget.membreNom!.toLowerCase())
            .toList()
        : _entrees;

    // Comptage unifié Phase-aware (même logique que le build Flutter)
    final countOnChain = _computeCountOnChain(entreesFiltrees, phase);
    final totalXof = entreesFiltrees
        .where((e) => e.montantXof != null)
        .fold(0, (s, e) => s + (e.montantXof ?? 0));

    // Numéro de certificat basé sur timestamp
    final numCert = 'TC-${widget.codeTontine}-${now.millisecondsSinceEpoch ~/ 1000}';

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (ctx) => _buildHeader(ctx, now, numCert, phase, fontReg, fontBold),
        footer: (ctx) => _buildFooter(ctx, numCert, contratAddr, fontReg),
        build: (ctx) => [
          // Titre certificat
          _buildTitre(phase, contratAddr, fontReg, fontBold),
          pw.SizedBox(height: 16),

          // Infos tontine
          _buildInfosTontine(now, phase, countOnChain, entreesFiltrees.length, totalXof, fontReg, fontBold),
          pw.SizedBox(height: 16),

          // Stats blockchain
          _buildStatsBlockchain(entreesFiltrees, countOnChain, phase, fontReg, fontBold),
          pw.SizedBox(height: 20),

          // Tableau des opérations
          _buildTableauOperations(entreesFiltrees, phase, fontReg, fontBold),
          pw.SizedBox(height: 20),

          // Section vérification
          _buildSectionVerification(numCert, contratAddr, phase, fontReg, fontBold),
        ],
      ),
    );

    return doc.save();
  }

  // ── Widgets PDF ────────────────────────────────────────────────────────────

  pw.Widget _buildHeader(pw.Context ctx, DateTime now, String numCert, int phase, pw.Font fontReg, pw.Font fontBold) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _pdfOr, width: 2)),
      ),
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('TontineClair',
                  style: pw.TextStyle(
                      font: fontBold,
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                      color: _pdfEncre)),
              pw.Text('Certificat Blockchain',
                  style: pw.TextStyle(font: fontReg, fontSize: 10, color: _pdfDoux)),
            ],
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('N° $numCert',
                  style: pw.TextStyle(font: fontReg, fontSize: 8, color: _pdfDoux)),
              pw.Text(
                'Emis le ${_fmtDate(now)} a ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                style: pw.TextStyle(font: fontReg, fontSize: 8, color: _pdfDoux),
              ),
              pw.Container(
                margin: const pw.EdgeInsets.only(top: 4),
                padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: pw.BoxDecoration(
                  color: phase == 2 ? _pdfChain : _pdfOr,
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Text(
                  phase == 2 ? 'ON-CHAIN POLYGON MAINNET' : 'JOURNAL INTERNE',
                  style: pw.TextStyle(
                      font: fontBold,
                      fontSize: 7,
                      color: PdfColors.white,
                      fontWeight: pw.FontWeight.bold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget _buildFooter(pw.Context ctx, String numCert, String? contratAddr, pw.Font fontReg) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _pdfLignes, width: 1)),
      ),
      padding: const pw.EdgeInsets.only(top: 6),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'TontineClair - Certificat confidentiel - $numCert',
            style: pw.TextStyle(font: fontReg, fontSize: 7, color: _pdfDoux),
          ),
          pw.Text(
            'Page ${ctx.pageNumber}/${ctx.pagesCount}',
            style: pw.TextStyle(font: fontReg, fontSize: 7, color: _pdfDoux),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildTitre(int phase, String? contratAddr, pw.Font fontReg, pw.Font fontBold) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(20),
      decoration: pw.BoxDecoration(
        gradient: const pw.LinearGradient(
          colors: [_pdfEncre, PdfColor.fromInt(0xFF35407A)],
        ),
        borderRadius: pw.BorderRadius.circular(12),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            widget.membreNom != null
                ? 'CERTIFICAT DE PARTICIPATION'
                : 'CERTIFICAT DE TRANSPARENCE BLOCKCHAIN',
            style: pw.TextStyle(
              font: fontBold,
              fontSize: 16,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            widget.membreNom != null
                ? 'Membre : ${_pdfSafe(widget.membreNom!)} - Tontine : ${_pdfSafe(widget.nomTontine)} (${widget.codeTontine})'
                : 'Tontine : ${_pdfSafe(widget.nomTontine)} - Code : ${widget.codeTontine}',
            style: pw.TextStyle(font: fontReg, fontSize: 10, color: PdfColors.white),
          ),
          if (contratAddr != null) ...[
            pw.SizedBox(height: 8),
            pw.Text(
              'Smart Contract : $contratAddr',
              style: pw.TextStyle(
                  font: fontReg,
                  fontSize: 8,
                  color: PdfColors.white,
                  fontStyle: pw.FontStyle.italic),
            ),
            pw.Text(
              'Reseau : Polygon Mainnet (chainId 137) - TontineVault.sol v2.0.0',
              style: pw.TextStyle(font: fontReg, fontSize: 8, color: PdfColors.white),
            ),
          ],
        ],
      ),
    );
  }

  pw.Widget _buildInfosTontine(DateTime now, int phase, int onChain, int total, int xof, pw.Font fontReg, pw.Font fontBold) {
    return pw.Row(
      children: [
        _metriqueBox('Code tontine', widget.codeTontine, fontReg, fontBold),
        pw.SizedBox(width: 8),
        _metriqueBox('Total operations', '$total', fontReg, fontBold),
        pw.SizedBox(width: 8),
        _metriqueBox(
          phase == 2 ? 'On-chain' : 'Proof SHA-256',
          phase == 2 ? '$onChain' : '$total',
          fontReg, fontBold,
          couleur: phase == 2 ? _pdfChain : _pdfOr,
        ),
        pw.SizedBox(width: 8),
        _metriqueBox('Volume XOF', _formatXof(xof), fontReg, fontBold),
      ],
    );
  }

  pw.Widget _metriqueBox(String label, String valeur, pw.Font fontReg, pw.Font fontBold, {PdfColor? couleur}) {
    return pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          color: _pdfGris,
          borderRadius: pw.BorderRadius.circular(8),
          border: pw.Border.all(color: _pdfLignes),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(label,
                style: pw.TextStyle(font: fontReg, fontSize: 8, color: _pdfDoux)),
            pw.SizedBox(height: 4),
            pw.Text(valeur,
                style: pw.TextStyle(
                    font: fontBold,
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: couleur ?? _pdfEncre)),
          ],
        ),
      ),
    );
  }

  pw.Widget _buildStatsBlockchain(
      List<BlockchainEntry> entrees, int onChain, int phase, pw.Font fontReg, pw.Font fontBold) {
    final byType = <String, int>{};
    for (final e in entrees) {
      byType[e.typeLabel] = (byType[e.typeLabel] ?? 0) + 1;
    }

    return pw.Container(
      padding: const pw.EdgeInsets.all(14),
      decoration: pw.BoxDecoration(
        color: phase == 2
            ? PdfColor.fromInt(0xFFE8FAF0)
            : PdfColor.fromInt(0xFFEEF1FB),
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(
            color: phase == 2 ? _pdfChain : _pdfEncre, width: 0.5),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            phase == 2
                ? 'Operations ancrees on-chain - verifiables sur Polygon Mainnet'
                : 'Operations securisees par preuve cryptographique SHA-256 (journal interne TontineClair)',
            style: pw.TextStyle(
                font: fontBold,
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
                color: phase == 2 ? _pdfChain : _pdfEncre),
          ),
          pw.SizedBox(height: 8),
          pw.Wrap(
            spacing: 8,
            runSpacing: 6,
            children: byType.entries.map((e) {
              return pw.Container(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: pw.BoxDecoration(
                  color: PdfColors.white,
                  borderRadius: pw.BorderRadius.circular(12),
                  border: pw.Border.all(color: _pdfLignes),
                ),
                child: pw.Text(
                  '${_pdfSafe(e.key)} : ${e.value}',
                  style: pw.TextStyle(font: fontReg, fontSize: 8, color: _pdfTexte),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildTableauOperations(List<BlockchainEntry> entrees, int phase, pw.Font fontReg, pw.Font fontBold) {
    if (entrees.isEmpty) {
      return pw.Text('Aucune operation trouvee.',
          style: pw.TextStyle(font: fontReg, fontSize: 10, color: _pdfDoux));
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Journal des operations blockchain',
          style: pw.TextStyle(
              font: fontBold,
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color: _pdfEncre),
        ),
        pw.SizedBox(height: 8),
        pw.Table(
          border: pw.TableBorder.all(color: _pdfLignes, width: 0.5),
          columnWidths: {
            0: const pw.FlexColumnWidth(1.4),  // Date
            1: const pw.FlexColumnWidth(1.6),  // Type
            2: const pw.FlexColumnWidth(2.2),  // Description
            3: const pw.FlexColumnWidth(1.2),  // Montant
            4: const pw.FlexColumnWidth(2.6),  // TX Hash
          },
          children: [
            // En-tête
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: _pdfEncre),
              children: [
                _cellHeader('Date', fontBold),
                _cellHeader('Type', fontBold),
                _cellHeader('Description', fontBold),
                _cellHeader('Montant XOF', fontBold),
                _cellHeader('TX Hash / Proof', fontBold),
              ],
            ),
            // Lignes
            ...entrees.asMap().entries.map((entry) {
              final i = entry.key;
              final e = entry.value;
              // En Phase 1, le txHash est un proof SHA-256 local — pas un TX Polygon
              final estOnChain = phase == 2 && e.txHash != null && e.txHash!.length == 66;
              final bg = i.isEven ? PdfColors.white : _pdfGris;
              return pw.TableRow(
                decoration: pw.BoxDecoration(color: bg),
                children: [
                  _cell(_fmtDate(e.createdAt), fontReg, fontBold),
                  _cell(_pdfSafe(e.typeLabel), fontReg, fontBold,
                      gras: true,
                      couleur: estOnChain ? _pdfChain : _pdfEncre),
                  _cell(_pdfSafe(e.descriptionMetier), fontReg, fontBold),
                  _cell(e.montantXof != null
                      ? '${_formatXof(e.montantXof!)} F'
                      : '-', fontReg, fontBold),
                  _cell(
                    e.txHash != null
                        ? _pdfSafe(estOnChain
                            ? e.txHashCourt
                            : 'SHA-256:${e.txHashCourt}')
                        : '-',
                    fontReg, fontBold,
                    mono: true,
                    couleur: estOnChain ? _pdfChain : _pdfDoux,
                    suffix: '',
                  ),
                ],
              );
            }),
          ],
        ),
      ],
    );
  }

  pw.Widget _cellHeader(String text, pw.Font fontBold) => pw.Padding(
        padding: const pw.EdgeInsets.all(6),
        child: pw.Text(text,
            style: pw.TextStyle(
                font: fontBold,
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white)),
      );

  pw.Widget _cell(String text, pw.Font fontReg, pw.Font fontBold,
      {bool gras = false,
      PdfColor? couleur,
      bool mono = false,
      String suffix = ''}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.all(5),
        child: pw.Text(
          text + suffix,
          style: pw.TextStyle(
            font: gras ? fontBold : fontReg,
            fontSize: 7,
            fontWeight: gras ? pw.FontWeight.bold : pw.FontWeight.normal,
            color: couleur ?? _pdfTexte,
          ),
        ),
      );

  pw.Widget _buildSectionVerification(
      String numCert, String? contratAddr, int phase, pw.Font fontReg, pw.Font fontBold) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(14),
      decoration: pw.BoxDecoration(
        color: _pdfGris,
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: _pdfOr, width: 1),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'Comment verifier ce certificat',
            style: pw.TextStyle(
                font: fontBold,
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
                color: _pdfEncre),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            phase == 2
                ? '1. Ouvrez TontineClair > Verifier blockchain\n'
                  '2. Saisissez le code : ${widget.codeTontine}\n'
                  '3. Chaque TX hash est verifiable sur https://polygonscan.com\n'
                  '${contratAddr != null ? "4. Smart Contract : https://polygonscan.com/address/$contratAddr" : ""}'
                : '1. Ouvrez TontineClair > Verifier blockchain\n'
                  '2. Saisissez le code : ${widget.codeTontine}\n'
                  '3. Les preuves SHA-256 sont des empreintes cryptographiques internes.\n'
                  '   Elles garantissent l\'integrite des donnees mais ne sont pas des transactions Polygon.\n'
                  '4. La verification on-chain est disponible via Polygon Mainnet.',
            style: pw.TextStyle(font: fontReg, fontSize: 8, color: _pdfTexte, lineSpacing: 3),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'Certificat N. $numCert - Document genere automatiquement par TontineClair - Non modifiable',
            style: pw.TextStyle(font: fontReg, fontSize: 7, color: _pdfDoux, fontStyle: pw.FontStyle.italic),
          ),
        ],
      ),
    );
  }

  // ── Partage PDF ────────────────────────────────────────────────────────────
  Future<void> _partager() async {
    setState(() => _generating = true);
    try {
      final bytes = await _genererPdf();

      if (kIsWeb) {
        // Web : téléchargement direct via Printing
        await Printing.sharePdf(
          bytes: bytes,
          filename: 'certificat_blockchain_${widget.codeTontine}.pdf',
        );
      } else {
        // Mobile : partage via share_plus
        final dir  = await getTemporaryDirectory();
        final file = File('${dir.path}/certificat_blockchain_${widget.codeTontine}.pdf');
        await file.writeAsBytes(bytes);
        await Share.shareXFiles(
          [XFile(file.path)],
          subject:
              'Certificat Blockchain — ${widget.nomTontine} (${widget.codeTontine})',
          text:
              'Certificat de transparence blockchain TontineClair\n'
              'Tontine : ${widget.nomTontine}\n'
              'Code : ${widget.codeTontine}\n'
              'Verifiable sur Polygon Mainnet',
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur: $e'), backgroundColor: AppColors.alerte),
      );
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  // ── Prévisualisation ───────────────────────────────────────────────────────
  Future<void> _previsualiser() async {
    setState(() => _generating = true);
    try {
      final bytes = await _genererPdf();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(
              title: const Text('Certificat Blockchain'),
              backgroundColor: AppColors.encre,
              foregroundColor: Colors.white,
              actions: [
                IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: () async {
                    try {
                      if (kIsWeb) {
                        await Printing.sharePdf(
                          bytes: bytes,
                          filename: 'certificat_blockchain_${widget.codeTontine}.pdf',
                        );
                      } else {
                        final dir  = await getTemporaryDirectory();
                        final file = File(
                            '${dir.path}/certificat_blockchain_${widget.codeTontine}.pdf');
                        await file.writeAsBytes(bytes);
                        await Share.shareXFiles([XFile(file.path)]);
                      }
                    } catch (e) {
                      // Erreur silencieuse — l'utilisateur peut réessayer
                    }
                  },
                ),
              ],
            ),
            body: PdfPreview(
              build: (_) => bytes,
              allowPrinting: true,
              allowSharing: true,
              canChangePageFormat: false,
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur PDF: $e'), backgroundColor: AppColors.alerte),
      );
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Rend un texte "PDF-safe" : supprime les emojis et caractères Unicode
  /// non supportés par le renderer PDF Flutter (police Helvetica intégrée).
  /// Conserve le Latin étendu (accents : é è à ç ù ô î, etc.).
  static String _pdfSafe(String texte) {
    return texte
        .replaceAll('\u2026', '...')  // ellipse → ...
        .replaceAll('\u2019', "'")    // apostrophe typographique
        .replaceAll('\u2018', "'")    // guillemet ouvert
        .replaceAll('\u201C', '"')    // guillemet double ouvert
        .replaceAll('\u201D', '"')    // guillemet double fermé
        .replaceAll('\u202F', ' ')    // espace fine insécable
        .replaceAll('\u00B7', '.')    // point médian
        .replaceAll('\u2013', '-')    // tiret demi-cadratin
        .replaceAll('\u2014', '-')    // tiret cadratin
        .replaceAll('✓', 'OK')
        .replaceAll('✗', 'X')
        .replaceAll('❓', '?')
        .replaceAll('❌', '[retire]')
        .replaceAll('✅', '[OK]')
        // Filtre général : garde ASCII + Latin-1 + Latin Extended-A/B (≤ U+024F)
        // Supprime tout emoji, symbole CJK, dingbat > U+024F
        .split('')
        .where((ch) => ch.codeUnitAt(0) <= 0x024F)
        .join();
  }

  String _fmtDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  String _formatXof(int xof) {
    if (xof >= 1000000) return '${(xof / 1000000).toStringAsFixed(1)}M';
    if (xof >= 1000) return '${(xof / 1000).toStringAsFixed(0)}k';
    return '$xof';
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final phase = (_contrat['phase'] as num?)?.toInt() ?? 1;
    // Comptage unifi\u00e9 via _computeCountOnChain (m\u00eame logique que le PDF)
    final countOnChain = _computeCountOnChain(_entrees, phase);

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.encre,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Certificat Blockchain',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            Text(phase == 2 ? 'PDF · Polygon Mainnet On-Chain' : 'PDF · Preuves Blockchain',
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
      ),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: AppColors.encre),
                  SizedBox(height: 16),
                  Text('Chargement du journal blockchain…',
                      style: TextStyle(color: AppColors.texteDoux)),
                ],
              ),
            )
          : _erreur != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 48, color: AppColors.alerte),
                      const SizedBox(height: 16),
                      Text(_erreur!,
                          style:
                              const TextStyle(color: AppColors.texteDoux)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                          onPressed: _charger,
                          child: const Text('Réessayer')),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    // Aperçu certificat
                    Container(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.encre, AppColors.encreDoux],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.encre.withValues(alpha: 0.3),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.workspace_premium,
                                  color: AppColors.or, size: 28),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'CERTIFICAT BLOCKCHAIN',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                        letterSpacing: 1,
                                      ),
                                    ),
                                    Text(
                                      widget.nomTontine,
                                      style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: phase == 2
                                      ? const Color(0xFF00C853)
                                      : AppColors.or,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  'On-chain ⚡',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          // Métriques
                          Row(
                            children: [
                              _metriqueFlutter('Opérations',
                                  '${_entrees.length}', Icons.list_alt),
                              const SizedBox(width: 8),
                              _metriqueFlutter(
                                  'On-chain ⚡',
                                  '$countOnChain',
                                  Icons.bolt,
                                  couleur: const Color(0xFF00C853)),
                              const SizedBox(width: 8),
                              _metriqueFlutter(
                                  'Réseau', 'Polygon\nMainnet', Icons.hub),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Code tontine : ${widget.codeTontine}',
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 12),
                          ),
                          if (widget.membreNom != null)
                            Text(
                              'Membre : ${widget.membreNom}',
                              style: const TextStyle(
                                  color: Colors.white60, fontSize: 12),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Description
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.carte,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.lignes),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Ce certificat contient :',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.encre)),
                          SizedBox(height: 10),
                          _InfoLigne(
                              icone: Icons.table_chart_outlined,
                              texte:
                                  'Tableau complet de toutes les opérations blockchain'),
                          _InfoLigne(
                              icone: Icons.link,
                              texte:
                                  'TX hash vérifiable sur PolygonScan pour chaque opération'),
                          _InfoLigne(
                              icone: Icons.verified_outlined,
                              texte:
                                  'Adresse du smart contract TontineVault.sol'),
                          _InfoLigne(
                              icone: Icons.qr_code,
                              texte:
                                  'Instructions de vérification indépendante'),
                          _InfoLigne(
                              icone: Icons.numbers_outlined,
                              texte:
                                  'Numéro de certificat unique horodaté'),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // ── Journal des opérations avec boutons PolygonScan ──────
                    if (_entrees.isNotEmpty) ...[
                      Row(
                        children: [
                          const Icon(Icons.format_list_bulleted,
                              size: 16, color: AppColors.encre),
                          const SizedBox(width: 8),
                          Text(
                            'Journal des opérations (${_entrees.length})',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.encre,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ...(_entrees.map((e) {
                        final estTxOnChain = e.txHash != null && e.txHash!.length == 66;
                        final contratAddr  = _contrat['contract_address'] as String?
                            ?? _contrat['address'] as String?;
                        return _CarteOperationJournal(
                          entree: e,
                          estTxOnChain: estTxOnChain,
                          contratAddr: contratAddr,
                        );
                      }).toList()),
                      const SizedBox(height: 24),
                    ],

                    // Boutons
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: _generating ? null : _previsualiser,
                        icon: _generating
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white))
                            : const Icon(Icons.visibility_outlined),
                        label: Text(_generating
                            ? 'Génération…'
                            : 'Prévisualiser le certificat'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.encre,
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
                        onPressed: _generating ? null : _partager,
                        icon: const Icon(Icons.share_outlined),
                        label: const Text('Partager le PDF'),
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

  Widget _metriqueFlutter(String label, String valeur, IconData icone,
      {Color couleur = Colors.white}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icone, size: 16, color: couleur),
            const SizedBox(height: 4),
            Text(valeur,
                style: TextStyle(
                    color: couleur,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    height: 1.2)),
            Text(label,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// ── Widget ligne info ──────────────────────────────────────────────────────────
class _InfoLigne extends StatelessWidget {
  final IconData icone;
  final String texte;
  const _InfoLigne({required this.icone, required this.texte});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icone, size: 16, color: AppColors.encre),
          const SizedBox(width: 10),
          Expanded(
            child: Text(texte,
                style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.texte,
                    height: 1.4)),
          ),
        ],
      ),
    );
  }
}

// ── Carte opération journal avec bouton PolygonScan ────────────────────────────
class _CarteOperationJournal extends StatelessWidget {
  final BlockchainEntry entree;
  final bool estTxOnChain;
  final String? contratAddr;

  const _CarteOperationJournal({
    required this.entree,
    required this.estTxOnChain,
    this.contratAddr,
  });

  Future<void> _ouvrirPolygonScan(BuildContext ctx) async {
    final String urlStr;
    if (estTxOnChain && entree.txHash != null) {
      // Phase 2 : TX Ethereum directe → ouvrir la transaction
      urlStr = 'https://polygonscan.com/tx/${entree.txHash}';
    } else if (contratAddr != null) {
      // Phase 1 avec contrat connu → ouvrir l'adresse du contrat
      urlStr = 'https://polygonscan.com/address/$contratAddr';
    } else if (entree.txHash != null && entree.txHash!.isNotEmpty) {
      // Phase 1 sans contrat : hash SHA-256 local → copier dans le presse-papier
      await _copierHash(ctx);
      return;
    } else {
      return;
    }
    final url = Uri.parse(urlStr);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _copierHash(BuildContext ctx) async {
    if (entree.txHash == null) return;
    await Clipboard.setData(ClipboardData(text: entree.txHash!));
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
          content: Text('Hash copié dans le presse-papier'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool aHash       = entree.txHash != null && entree.txHash!.isNotEmpty;
    // aLienExtern = true si on peut ouvrir une URL externe OU copier un hash
    final bool aLienExtern = estTxOnChain || contratAddr != null || aHash;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: estTxOnChain
              ? const Color(0xFF00C853).withValues(alpha: 0.35)
              : AppColors.lignes,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── En-tête opération ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                // Icône type
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: estTxOnChain
                        ? const Color(0xFF00C853).withValues(alpha: 0.12)
                        : AppColors.fondCode,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      entree.iconeMetier,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Type + description
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entree.typeLabel,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: estTxOnChain
                              ? const Color(0xFF00C853)
                              : AppColors.encre,
                        ),
                      ),
                      Text(
                        entree.descriptionMetier,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.texteDoux),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Montant
                if (entree.montantXof != null)
                  Text(
                    '${_formatMontant(entree.montantXof!)} F',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.encre,
                    ),
                  ),
              ],
            ),
          ),

          // ── Ligne TX hash + bouton PolygonScan ─────────────────────────────
          if (aHash) ...[
            const Divider(height: 1, thickness: 0.6, color: AppColors.lignes),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  // Hash cliquable (copie si pas de lien)
                  GestureDetector(
                    onTap: () => aLienExtern
                        ? _ouvrirPolygonScan(context)
                        : _copierHash(context),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          estTxOnChain
                              ? Icons.open_in_new
                              : (contratAddr != null ? Icons.link : Icons.fingerprint),
                          size: 13,
                          color: estTxOnChain
                              ? const Color(0xFF00C853)
                              : (contratAddr != null
                                  ? AppColors.encreDoux
                                  : AppColors.texteDoux),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          estTxOnChain
                              ? 'TX: ${entree.txHashCourt}'
                              : 'Proof: ${entree.txHashCourt}',
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: estTxOnChain
                                ? const Color(0xFF00C853)
                                : (contratAddr != null
                                    ? AppColors.encreDoux
                                    : AppColors.texteDoux),
                            fontWeight: FontWeight.w600,
                            decoration: aLienExtern
                                ? TextDecoration.underline
                                : TextDecoration.none,
                            decorationColor: estTxOnChain
                                ? const Color(0xFF00C853)
                                : AppColors.encreDoux,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          aLienExtern ? Icons.open_in_new : Icons.copy,
                          size: 11,
                          color: estTxOnChain
                              ? const Color(0xFF00C853)
                              : AppColors.texteDoux,
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // ── Bouton PolygonScan ──────────────────────────────────────
                  if (aLienExtern)
                    GestureDetector(
                      onTap: () => _ouvrirPolygonScan(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: estTxOnChain
                              ? const Color(0xFF00C853).withValues(alpha: 0.12)
                              : AppColors.encreDoux.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: estTxOnChain
                                ? const Color(0xFF00C853).withValues(alpha: 0.35)
                                : AppColors.encreDoux.withValues(alpha: 0.25),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              estTxOnChain
                                  ? Icons.open_in_new
                                  : (contratAddr != null
                                      ? Icons.open_in_new
                                      : Icons.copy_rounded),
                              size: 10,
                              color: estTxOnChain
                                  ? const Color(0xFF00C853)
                                  : AppColors.encreDoux,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              estTxOnChain
                                  ? 'PolygonScan'
                                  : (contratAddr != null ? 'Contrat' : 'Copier'),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: estTxOnChain
                                    ? const Color(0xFF00C853)
                                    : AppColors.encreDoux,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _formatMontant(int xof) {
    if (xof >= 1000000) return '${(xof / 1000000).toStringAsFixed(1)}M';
    if (xof >= 1000) {
      final k = xof / 1000;
      return k == k.roundToDouble() ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
    }
    // Formattage avec espace mille
    final s = xof.toString();
    if (s.length <= 3) return s;
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
