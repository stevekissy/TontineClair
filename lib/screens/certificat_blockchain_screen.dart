// ═══════════════════════════════════════════════════════════════════════════════
// CertificatBlockchainScreen  —  TontineClair Phase 4 / Option X
//
// Génère un certificat PDF officieux avec toutes les TX blockchain d'une tontine.
// Signé avec le hash SHA-256 du contenu + timestamp.
// Partageable via share_plus.
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
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
      setState(() {
        _entrees = results[0] as List<BlockchainEntry>;
        _contrat = results[1] as Map<String, dynamic>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _erreur = 'Erreur: $e'; });
    }
  }

  // ── Génération PDF ─────────────────────────────────────────────────────────
  Future<Uint8List> _genererPdf() async {
    final doc = pw.Document();
    final now = DateTime.now();
    final phase = (_contrat['phase'] as num?)?.toInt() ?? 1;
    final contratAddr = _contrat['contract'] as String?;

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

    // Phase 1 : tx_hash est un proof SHA-256 local, PAS un vrai TX Polygon
    // Phase 2 : tx_hash est un vrai hash Ethereum (66 chars) vérifiable sur-chain
    final countOnChain = phase == 2
        ? entreesFiltrees.where((e) => e.txHash != null && e.txHash!.length == 66).length
        : 0; // en Phase 1, aucune TX réelle sur Polygon
    final totalXof = entreesFiltrees
        .where((e) => e.montantXof != null)
        .fold(0, (s, e) => s + (e.montantXof ?? 0));

    // Numéro de certificat basé sur timestamp
    final numCert = 'TC-${widget.codeTontine}-${now.millisecondsSinceEpoch ~/ 1000}';

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (ctx) => _buildHeader(ctx, now, numCert, phase),
        footer: (ctx) => _buildFooter(ctx, numCert, contratAddr),
        build: (ctx) => [
          // Titre certificat
          _buildTitre(phase, contratAddr),
          pw.SizedBox(height: 16),

          // Infos tontine
          _buildInfosTontine(now, phase, countOnChain, entreesFiltrees.length, totalXof),
          pw.SizedBox(height: 16),

          // Stats blockchain
          _buildStatsBlockchain(entreesFiltrees, countOnChain, phase),
          pw.SizedBox(height: 20),

          // Tableau des opérations
          _buildTableauOperations(entreesFiltrees, phase),
          pw.SizedBox(height: 20),

          // Section vérification
          _buildSectionVerification(numCert, contratAddr, phase),
        ],
      ),
    );

    return doc.save();
  }

  // ── Widgets PDF ────────────────────────────────────────────────────────────

  pw.Widget _buildHeader(pw.Context ctx, DateTime now, String numCert, int phase) {
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
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                      color: _pdfEncre)),
              pw.Text('Certificat Blockchain',
                  style: pw.TextStyle(fontSize: 10, color: _pdfDoux)),
            ],
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('N° $numCert',
                  style: pw.TextStyle(fontSize: 8, color: _pdfDoux)),
              pw.Text(
                'Émis le ${_fmtDate(now)} à ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                style: pw.TextStyle(fontSize: 8, color: _pdfDoux),
              ),
              pw.Container(
                margin: const pw.EdgeInsets.only(top: 4),
                padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: pw.BoxDecoration(
                  color: phase == 2 ? _pdfChain : _pdfOr,
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Text(
                  phase == 2 ? 'PHASE 2 — ON-CHAIN' : 'PHASE 1 — PROOF',
                  style: pw.TextStyle(
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

  pw.Widget _buildFooter(pw.Context ctx, String numCert, String? contratAddr) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _pdfLignes, width: 1)),
      ),
      padding: const pw.EdgeInsets.only(top: 6),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'TontineClair — Certificat confidentiel · $numCert',
            style: pw.TextStyle(fontSize: 7, color: _pdfDoux),
          ),
          pw.Text(
            'Page ${ctx.pageNumber}/${ctx.pagesCount}',
            style: pw.TextStyle(fontSize: 7, color: _pdfDoux),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildTitre(int phase, String? contratAddr) {
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
              fontSize: 16,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            widget.membreNom != null
                ? 'Membre : ${widget.membreNom} · Tontine : ${widget.nomTontine} (${widget.codeTontine})'
                : 'Tontine : ${widget.nomTontine} · Code : ${widget.codeTontine}',
            style: pw.TextStyle(fontSize: 10, color: PdfColors.white),
          ),
          if (contratAddr != null) ...[
            pw.SizedBox(height: 8),
            pw.Text(
              'Smart Contract : $contratAddr',
              style: pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.white,
                  fontStyle: pw.FontStyle.italic),
            ),
            pw.Text(
              'Réseau : Polygon Amoy (chainId 80002) · TontineVault.sol v2.0.0',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.white),
            ),
          ],
        ],
      ),
    );
  }

  pw.Widget _buildInfosTontine(DateTime now, int phase, int onChain, int total, int xof) {
    return pw.Row(
      children: [
        _metriqueBox('Code tontine', widget.codeTontine),
        pw.SizedBox(width: 8),
        _metriqueBox('Total opérations', '$total'),
        pw.SizedBox(width: 8),
        _metriqueBox(
          phase == 2 ? 'On-chain ⚡' : 'Proof SHA-256',
          phase == 2 ? '$onChain' : '$total',
          couleur: phase == 2 ? _pdfChain : _pdfOr,
        ),
        pw.SizedBox(width: 8),
        _metriqueBox('Volume XOF', _formatXof(xof)),
      ],
    );
  }

  pw.Widget _metriqueBox(String label, String valeur, {PdfColor? couleur}) {
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
                style: pw.TextStyle(fontSize: 8, color: _pdfDoux)),
            pw.SizedBox(height: 4),
            pw.Text(valeur,
                style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: couleur ?? _pdfEncre)),
          ],
        ),
      ),
    );
  }

  pw.Widget _buildStatsBlockchain(
      List<BlockchainEntry> entrees, int onChain, int phase) {
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
                ? '✅ Opérations ancrées on-chain · vérifiables sur Polygon Amoy'
                : '🔒 Opérations sécurisées par preuve cryptographique SHA-256 (journal interne TontineClair)',
            style: pw.TextStyle(
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
                  '${e.key} : ${e.value}',
                  style: pw.TextStyle(fontSize: 8, color: _pdfTexte),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildTableauOperations(List<BlockchainEntry> entrees, int phase) {
    if (entrees.isEmpty) {
      return pw.Text('Aucune opération trouvée.',
          style: pw.TextStyle(fontSize: 10, color: _pdfDoux));
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Journal des opérations blockchain',
          style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color: _pdfEncre),
        ),
        pw.SizedBox(height: 8),
        pw.Table(
          border: pw.TableBorder.all(color: _pdfLignes, width: 0.5),
          columnWidths: {
            0: const pw.FlexColumnWidth(1.5),
            1: const pw.FlexColumnWidth(2),
            2: const pw.FlexColumnWidth(1.5),
            3: const pw.FlexColumnWidth(1.2),
            4: const pw.FlexColumnWidth(3),
          },
          children: [
            // En-tête
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: _pdfEncre),
              children: [
                _cellHeader('Date'),
                _cellHeader('Type'),
                _cellHeader('Membre'),
                _cellHeader('Montant XOF'),
                _cellHeader('TX Hash / Proof'),
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
                  _cell(_fmtDate(e.createdAt)),
                  _cell(e.typeLabel,
                      gras: true,
                      couleur: estOnChain ? _pdfChain : _pdfEncre),
                  _cell(e.membreNom ?? e.membreId ?? '—'),
                  _cell(e.montantXof != null
                      ? '${_formatXof(e.montantXof!)} F'
                      : '—'),
                  _cell(
                    e.txHash != null
                        ? (estOnChain ? e.txHashCourt : 'SHA-256:${e.txHashCourt}')
                        : '—',
                    mono: true,
                    couleur: estOnChain ? _pdfChain : _pdfDoux,
                    suffix: estOnChain ? ' ⚡' : '',
                  ),
                ],
              );
            }),
          ],
        ),
      ],
    );
  }

  pw.Widget _cellHeader(String text) => pw.Padding(
        padding: const pw.EdgeInsets.all(6),
        child: pw.Text(text,
            style: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white)),
      );

  pw.Widget _cell(String text,
      {bool gras = false,
      PdfColor? couleur,
      bool mono = false,
      String suffix = ''}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.all(5),
        child: pw.Text(
          text + suffix,
          style: pw.TextStyle(
            fontSize: 7,
            fontWeight: gras ? pw.FontWeight.bold : pw.FontWeight.normal,
            color: couleur ?? _pdfTexte,
          ),
        ),
      );

  pw.Widget _buildSectionVerification(
      String numCert, String? contratAddr, int phase) {
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
            'Comment vérifier ce certificat',
            style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
                color: _pdfEncre),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            phase == 2
                ? '1. Ouvrez TontineClair → Vérifier blockchain\n'
                  '2. Saisissez le code : ${widget.codeTontine}\n'
                  '3. Chaque TX hash ⚡ est vérifiable sur https://amoy.polygonscan.com\n'
                  '${contratAddr != null ? "4. Smart Contract : https://amoy.polygonscan.com/address/$contratAddr" : ""}'
                : '1. Ouvrez TontineClair → Vérifier blockchain\n'
                  '2. Saisissez le code : ${widget.codeTontine}\n'
                  '3. Les preuves SHA-256 sont des empreintes cryptographiques internes.\n'
                  '   Elles garantissent l\'intégrité des données mais ne sont pas des transactions Polygon.\n'
                  '4. La vérification on-chain (Phase 2) sera disponible ultérieurement.',
            style: pw.TextStyle(fontSize: 8, color: _pdfTexte, lineSpacing: 3),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'Certificat N° $numCert · Document généré automatiquement par TontineClair · Non modifiable',
            style:
                pw.TextStyle(fontSize: 7, color: _pdfDoux, fontStyle: pw.FontStyle.italic),
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
            'Vérifiable sur Polygon Amoy ⚡',
      );
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
                    final dir  = await getTemporaryDirectory();
                    final file = File(
                        '${dir.path}/certificat_blockchain_${widget.codeTontine}.pdf');
                    await file.writeAsBytes(bytes);
                    await Share.shareXFiles([XFile(file.path)]);
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
    // Phase 1 : aucun vrai TX on-chain — les hashes sont des preuves SHA-256 locales
    final countOnChain = phase == 2
        ? _entrees.where((e) => e.txHash != null && e.txHash!.length == 66).length
        : 0;

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
            Text(phase == 2 ? 'PDF · Polygon Amoy On-Chain' : 'PDF · Preuves SHA-256',
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
                                  phase == 2 ? '⚡ Phase 2' : '🔒 Phase 1',
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
                                  phase == 2 ? 'On-chain ⚡' : 'SHA-256',
                                  phase == 2 ? '$countOnChain' : '${_entrees.length}',
                                  phase == 2 ? Icons.bolt : Icons.lock_outline,
                                  couleur: phase == 2
                                      ? const Color(0xFF00C853)
                                      : AppColors.or),
                              const SizedBox(width: 8),
                              _metriqueFlutter(
                                  'Réseau', 'Polygon\nAmoy', Icons.hub),
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
