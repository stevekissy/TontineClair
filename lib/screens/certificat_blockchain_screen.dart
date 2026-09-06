// ═══════════════════════════════════════════════════════════════════════════════
// CertificatBlockchainScreen  —  TontineClair Phase 4 / Option X
//
// Génère un certificat PDF officieux avec toutes les TX blockchain d'une tontine.
// Signé avec le hash SHA-256 du contenu + timestamp.
// Partageable via share_plus.
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:flutter/foundation.dart' show kIsWeb, compute;
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
import '../utils/formatters.dart';

// ── Paramètres sérialisables pour compute() ───────────────────────────────
// compute() transfère les données dans un isolate Dart séparé ; seuls les
// types primitifs + Dart purs sont autorisés (pas de BuildContext, pas de
// fonctions fermées). Cette classe encapsule tout ce qu'il faut au PDF.
class _CertificatParams {
  final List<BlockchainEntry> entrees;
  final Map<String, dynamic> contrat;
  final String codeTontine;
  final String nomTontine;
  final String? membreNom;
  final int maxEntrees;
  final String devise; // devise réelle de la tontine (EUR, USD, XOF…)

  const _CertificatParams({
    required this.entrees,
    required this.contrat,
    required this.codeTontine,
    required this.nomTontine,
    required this.membreNom,
    required this.maxEntrees,
    this.devise = '',
  });
}

// Fonction top-level compatible compute() — génère les bytes PDF dans un isolate
Future<Uint8List> _genererCertificatBytes(_CertificatParams p) async {
  // Charger polices avec timeout 8 s → fallback Helvetica si réseau lent
  Future<({pw.Font regular, pw.Font bold})> chargerPolicesIsolate() async {
    try {
      final results = await Future.wait([
        PdfGoogleFonts.notoSansRegular(),
        PdfGoogleFonts.notoSansBold(),
      ]).timeout(const Duration(seconds: 8));
      return (regular: results[0], bold: results[1]);
    } catch (_) {
      return (regular: pw.Font.helvetica(), bold: pw.Font.helveticaBold());
    }
  }
  final polices  = await chargerPolicesIsolate();
  final fontReg  = polices.regular;
  final fontBold = polices.bold;
  final doc  = pw.Document();
  final now  = DateTime.now();
  final phase = (p.contrat['phase'] as num?)?.toInt() ?? 1;
  final contratAddr = p.contrat['contract_address'] as String?
      ?? p.contrat['address'] as String?;

  // Filtrer par membre si demandé
  final entreesFiltrees = p.membreNom != null
      ? p.entrees.where((e) =>
            e.membreNom?.toLowerCase() == p.membreNom!.toLowerCase() ||
            e.membreId?.toLowerCase() == p.membreNom!.toLowerCase())
          .toList()
      : p.entrees;

  // Sécurité finale : cap strict à maxEntrees lignes dans le PDF
  final entreedPdf = entreesFiltrees.length > p.maxEntrees
      ? entreesFiltrees.sublist(entreesFiltrees.length - p.maxEntrees)
      : entreesFiltrees;
  final tronque = entreesFiltrees.length > p.maxEntrees;
  final totalReel = entreesFiltrees.length;

  // Comptage on-chain
  int computeCountOnChain(List<BlockchainEntry> lst, int ph) {
    if (ph == 2) return lst.where((e) => e.txHash != null && e.txHash!.length == 66).length;
    return lst.where((e) => e.txHash != null && e.txHash!.isNotEmpty).length;
  }

  final countOnChain = computeCountOnChain(entreesFiltrees, phase);
  final totalXof = entreesFiltrees
      .where((e) => e.montantXof != null)
      .fold(0, (s, e) => s + (e.montantXof ?? 0));
  // Priorité : devise param (tontine) > première entrée avec devise > ''
  final deviseEntrees = entreesFiltrees
      .map((e) => e.devise)
      .firstWhere((d) => d.isNotEmpty, orElse: () => '');
  final deviseDetectee = p.devise.isNotEmpty ? p.devise : deviseEntrees;

  final numCert = 'TC-${p.codeTontine}-${now.millisecondsSinceEpoch ~/ 1000}';

  // ── Helpers locaux (même logique que la classe mais top-level) ────────────
  String pdfSafe(String texte) => texte
      .replaceAll('\u2026', '...')
      .replaceAll('\u2019', "'")
      .replaceAll('\u2018', "'")
      .replaceAll('\u201C', '"')
      .replaceAll('\u201D', '"')
      .replaceAll('\u202F', ' ')
      .replaceAll('\u00B7', '.')
      .replaceAll('\u2013', '-')
      .replaceAll('\u2014', '-')
      .replaceAll('✓', 'OK')
      .replaceAll('✗', 'X')
      .replaceAll('❓', '?')
      .replaceAll('❌', '[retire]')
      .replaceAll('✅', '[OK]')
      .split('').where((ch) => ch.codeUnitAt(0) <= 0x024F).join();

  String fmtDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  const pdfEncre  = PdfColor.fromInt(0xFF1C2447);
  const pdfOr     = PdfColor.fromInt(0xFFD99A2B);
  const pdfGris   = PdfColor.fromInt(0xFFF7F7F4);
  const pdfLignes = PdfColor.fromInt(0xFFE4E1D6);
  const pdfTexte  = PdfColor.fromInt(0xFF26251F);
  const pdfDoux   = PdfColor.fromInt(0xFF6E6C60);
  const pdfChain  = PdfColor.fromInt(0xFF00C853);

  pw.Widget cellHeader(String text) => pw.Padding(
        padding: const pw.EdgeInsets.all(6),
        child: pw.Text(text,
            style: pw.TextStyle(font: fontBold, fontSize: 8,
                fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
      );

  pw.Widget cell(String text, {bool gras = false, PdfColor? couleur, bool mono = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.all(5),
        child: pw.Text(text,
            style: pw.TextStyle(
              font: gras ? fontBold : fontReg,
              fontSize: 7,
              fontWeight: gras ? pw.FontWeight.bold : pw.FontWeight.normal,
              color: couleur ?? pdfTexte,
            )),
      );

  String montantFmt(int? xof, String devise) {
    if (xof == null) return '-';
    return Formatters.montant(xof, devise: devise.isNotEmpty ? devise : null);
  }

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      // ── En-tête ─────────────────────────────────────────────────────
      header: (ctx) => pw.Container(
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: pdfOr, width: 2)),
        ),
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('TontineClair',
                  style: pw.TextStyle(font: fontBold, fontSize: 18, color: pdfEncre)),
              pw.Text('Certificat Blockchain',
                  style: pw.TextStyle(font: fontReg, fontSize: 10, color: pdfDoux)),
            ]),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              pw.Text('N° $numCert',
                  style: pw.TextStyle(font: fontReg, fontSize: 8, color: pdfDoux)),
              pw.Text(
                'Emis le ${fmtDate(now)} a ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                style: pw.TextStyle(font: fontReg, fontSize: 8, color: pdfDoux),
              ),
              pw.Container(
                margin: const pw.EdgeInsets.only(top: 4),
                padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: pw.BoxDecoration(
                  color: phase == 2 ? pdfChain : pdfOr,
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Text(
                  phase == 2 ? 'ON-CHAIN POLYGON MAINNET' : 'JOURNAL INTERNE',
                  style: pw.TextStyle(font: fontBold, fontSize: 7,
                      color: PdfColors.white, fontWeight: pw.FontWeight.bold),
                ),
              ),
            ]),
          ],
        ),
      ),
      // ── Pied de page ────────────────────────────────────────────────
      footer: (ctx) => pw.Container(
        decoration: const pw.BoxDecoration(
          border: pw.Border(top: pw.BorderSide(color: pdfLignes, width: 1)),
        ),
        padding: const pw.EdgeInsets.only(top: 6),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('TontineClair - Certificat confidentiel - $numCert',
                style: pw.TextStyle(font: fontReg, fontSize: 7, color: pdfDoux)),
            pw.Text('Page ${ctx.pageNumber}/${ctx.pagesCount}',
                style: pw.TextStyle(font: fontReg, fontSize: 7, color: pdfDoux)),
          ],
        ),
      ),
      build: (ctx) => [
        // ── Titre ─────────────────────────────────────────────────────
        pw.Container(
          padding: const pw.EdgeInsets.all(20),
          decoration: pw.BoxDecoration(
            gradient: const pw.LinearGradient(
              colors: [pdfEncre, PdfColor.fromInt(0xFF35407A)],
            ),
            borderRadius: pw.BorderRadius.circular(12),
          ),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(
              p.membreNom != null
                  ? 'CERTIFICAT DE PARTICIPATION'
                  : 'CERTIFICAT DE TRANSPARENCE BLOCKCHAIN',
              style: pw.TextStyle(font: fontBold, fontSize: 16,
                  fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              p.membreNom != null
                  ? 'Membre : ${pdfSafe(p.membreNom!)} - Tontine : ${pdfSafe(p.nomTontine)} (${p.codeTontine})'
                  : 'Tontine : ${pdfSafe(p.nomTontine)} - Code : ${p.codeTontine}',
              style: pw.TextStyle(font: fontReg, fontSize: 10, color: PdfColors.white),
            ),
            if (contratAddr != null) ...[
              pw.SizedBox(height: 8),
              pw.Text('Smart Contract : $contratAddr',
                  style: pw.TextStyle(font: fontReg, fontSize: 8, color: PdfColors.white,
                      fontStyle: pw.FontStyle.italic)),
              pw.Text('Reseau : Polygon Mainnet (chainId 137) - TontineVault.sol v2.0.0',
                  style: pw.TextStyle(font: fontReg, fontSize: 8, color: PdfColors.white)),
            ],
          ]),
        ),
        pw.SizedBox(height: 16),

        // ── Métriques ──────────────────────────────────────────────────
        pw.Row(children: [
          pw.Expanded(child: pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(color: pdfGris, borderRadius: pw.BorderRadius.circular(8),
                border: pw.Border.all(color: pdfLignes)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('Code tontine', style: pw.TextStyle(font: fontReg, fontSize: 8, color: pdfDoux)),
              pw.SizedBox(height: 4),
              pw.Text(p.codeTontine, style: pw.TextStyle(font: fontBold, fontSize: 14,
                  fontWeight: pw.FontWeight.bold, color: pdfEncre)),
            ]),
          )),
          pw.SizedBox(width: 8),
          pw.Expanded(child: pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(color: pdfGris, borderRadius: pw.BorderRadius.circular(8),
                border: pw.Border.all(color: pdfLignes)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(tronque ? 'Operations (${entreedPdf.length}/$totalReel)' : 'Total operations',
                  style: pw.TextStyle(font: fontReg, fontSize: 8, color: pdfDoux)),
              pw.SizedBox(height: 4),
              pw.Text('${entreedPdf.length}', style: pw.TextStyle(font: fontBold, fontSize: 14,
                  fontWeight: pw.FontWeight.bold, color: pdfEncre)),
            ]),
          )),
          pw.SizedBox(width: 8),
          pw.Expanded(child: pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(color: pdfGris, borderRadius: pw.BorderRadius.circular(8),
                border: pw.Border.all(color: pdfLignes)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(phase == 2 ? 'On-chain' : 'Proof SHA-256',
                  style: pw.TextStyle(font: fontReg, fontSize: 8, color: pdfDoux)),
              pw.SizedBox(height: 4),
              pw.Text(phase == 2 ? '$countOnChain' : '${entreedPdf.length}',
                  style: pw.TextStyle(font: fontBold, fontSize: 14,
                      fontWeight: pw.FontWeight.bold, color: phase == 2 ? pdfChain : pdfOr)),
            ]),
          )),
          pw.SizedBox(width: 8),
          pw.Expanded(child: pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(color: pdfGris, borderRadius: pw.BorderRadius.circular(8),
                border: pw.Border.all(color: pdfLignes)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(deviseDetectee.isNotEmpty ? 'Volume $deviseDetectee' : 'Volume',
                  style: pw.TextStyle(font: fontReg, fontSize: 8, color: pdfDoux)),
              pw.SizedBox(height: 4),
              pw.Text(montantFmt(totalXof, deviseDetectee),
                  style: pw.TextStyle(font: fontBold, fontSize: 12,
                      fontWeight: pw.FontWeight.bold, color: pdfEncre)),
            ]),
          )),
        ]),
        pw.SizedBox(height: 16),

        // ── Avertissement troncature ──────────────────────────────────
        if (tronque) ...[
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: pw.BoxDecoration(
              color: PdfColor.fromInt(0xFFFFF8E1),
              borderRadius: pw.BorderRadius.circular(6),
              border: pw.Border.all(color: pdfOr, width: 0.8),
            ),
            child: pw.Text(
              'Document tronque : ${entreedPdf.length} operations les plus recentes sur $totalReel au total. '
              'Toutes les operations sont enregistrees dans TontineClair.',
              style: pw.TextStyle(font: fontReg, fontSize: 8, color: PdfColor.fromInt(0xFF7B5800)),
            ),
          ),
          pw.SizedBox(height: 12),
        ],

        // ── Tableau des opérations (pw.Table ligne-par-ligne → pas d'OOM) ──
        pw.Text('Journal des operations blockchain',
            style: pw.TextStyle(font: fontBold, fontSize: 12,
                fontWeight: pw.FontWeight.bold, color: pdfEncre)),
        pw.SizedBox(height: 8),
        if (entreedPdf.isEmpty)
          pw.Text('Aucune operation trouvee.',
              style: pw.TextStyle(font: fontReg, fontSize: 10, color: pdfDoux))
        else
          pw.Table(
            border: pw.TableBorder.all(color: pdfLignes, width: 0.5),
            columnWidths: const {
              0: pw.FlexColumnWidth(1.4),
              1: pw.FlexColumnWidth(1.6),
              2: pw.FlexColumnWidth(2.2),
              3: pw.FlexColumnWidth(1.2),
              4: pw.FlexColumnWidth(2.6),
            },
            children: [
              // En-tête
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: pdfEncre),
                children: [
                  cellHeader('Date'),
                  cellHeader('Type'),
                  cellHeader('Description'),
                  cellHeader('Montant'),
                  cellHeader('TX Hash / Proof'),
                ],
              ),
              // Lignes de données — générées une par une pour limiter la mémoire
              for (int i = 0; i < entreedPdf.length; i++) ...() {
                final e = entreedPdf[i];
                final estOnChain = phase == 2 && e.txHash != null && e.txHash!.length == 66;
                final bg = i.isEven ? PdfColors.white : pdfGris;
                String txLabel = '-';
                if (e.txHash != null) {
                  final hash = e.txHash!;
                  final court = hash.length > 16
                      ? '${hash.substring(0, 8)}...${hash.substring(hash.length - 6)}'
                      : hash;
                  txLabel = pdfSafe(estOnChain ? court : 'SHA-256:$court');
                }
                return [
                  pw.TableRow(
                    decoration: pw.BoxDecoration(color: bg),
                    children: [
                      cell(fmtDate(e.createdAt)),
                      cell(pdfSafe(e.typeLabel), gras: true,
                          couleur: estOnChain ? pdfChain : pdfEncre),
                      cell(pdfSafe(e.descriptionMetier)),
                      cell(montantFmt(e.montantXof,
                          deviseDetectee.isNotEmpty ? deviseDetectee
                              : e.devise.isNotEmpty ? e.devise : 'XOF')),
                      cell(txLabel, couleur: estOnChain ? pdfChain : pdfDoux),
                    ],
                  ),
                ];
              }(),
            ],
          ),
        pw.SizedBox(height: 20),

        // ── Section vérification ───────────────────────────────────────
        pw.Container(
          padding: const pw.EdgeInsets.all(14),
          decoration: pw.BoxDecoration(
            color: pdfGris,
            borderRadius: pw.BorderRadius.circular(8),
            border: pw.Border.all(color: pdfOr, width: 1),
          ),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('Comment verifier ce certificat',
                style: pw.TextStyle(font: fontBold, fontSize: 10,
                    fontWeight: pw.FontWeight.bold, color: pdfEncre)),
            pw.SizedBox(height: 8),
            pw.Text(
              phase == 2
                  ? '1. Ouvrez TontineClair > Verifier blockchain\n'
                    '2. Saisissez le code : ${p.codeTontine}\n'
                    '3. Chaque TX hash est verifiable sur https://polygonscan.com\n'
                    '${contratAddr != null ? "4. Smart Contract : https://polygonscan.com/address/$contratAddr" : ""}'
                  : '1. Ouvrez TontineClair > Verifier blockchain\n'
                    '2. Saisissez le code : ${p.codeTontine}\n'
                    '3. Les preuves SHA-256 garantissent l\'integrite des donnees.\n'
                    '4. La verification on-chain est disponible via Polygon Mainnet.',
              style: pw.TextStyle(font: fontReg, fontSize: 8, color: pdfTexte, lineSpacing: 3),
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              'Certificat N. $numCert - Document genere automatiquement par TontineClair - Non modifiable',
              style: pw.TextStyle(font: fontReg, fontSize: 7, color: pdfDoux,
                  fontStyle: pw.FontStyle.italic),
            ),
          ]),
        ),
      ],
    ),
  );

  return Uint8List.fromList(await doc.save());
}

// ─────────────────────────────────────────────────────────────────────────────

class CertificatBlockchainScreen extends StatefulWidget {
  final String codeTontine;
  final String nomTontine;
  final String? membreNom; // si null → certificat global tontine
  final String? devise;    // devise de la tontine (EUR, USD, XOF…) — affichage montants

  const CertificatBlockchainScreen({
    super.key,
    required this.codeTontine,
    required this.nomTontine,
    this.membreNom,
    this.devise,
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
  // Devise résolue : widget.devise (tontine) > première entrée avec devise > ''
  String _devise = '';

  @override
  void initState() {
    super.initState();
    _charger();
  }

  // Limite d'entrées chargées : évite l'OOM sur tontines très actives.
  // Réduite à 75 pour garantir la stabilité mémoire sur tontines avec
  // de nombreuses TX (chaque ligne PDF = allocation significative).
  static const int _kMaxEntrees = 75;

  Future<void> _charger() async {
    setState(() { _loading = true; _erreur = null; });
    try {
      final results = await Future.wait([
        BlockchainService.lireJournal(
          tontineCode: widget.codeTontine,
          limit: _kMaxEntrees,   // on ne charge que ce qu'on affichera
        ),
        BlockchainService.contractInfo(),
      ]);
      if (!mounted) return;
      // Garde client : seules les entrées de cette tontine sont conservées
      final codeCible = widget.codeTontine.trim().toUpperCase();
      final toutesEntrees = results[0] as List<BlockchainEntry>;
      final filtrees = toutesEntrees
          .where((e) => e.tontineCode.trim().toUpperCase() == codeCible)
          .toList();
      // Sécurité supplémentaire : tronquer côté client si le service retourne plus
      final entreesTronquees = filtrees.length > _kMaxEntrees
          ? filtrees.sublist(filtrees.length - _kMaxEntrees)
          : filtrees;
      // Résoudre la devise : paramètre widget > première entrée blockchain
      final deviseWidget = (widget.devise ?? '').trim();
      final deviseEntrees = entreesTronquees
          .map((e) => e.devise)
          .firstWhere((d) => d.isNotEmpty, orElse: () => '');
      setState(() {
        _entrees = entreesTronquees;
        _contrat = results[1] as Map<String, dynamic>;
        _loading = false;
        _devise = deviseWidget.isNotEmpty ? deviseWidget : deviseEntrees;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _erreur = 'Erreur: $e'; });
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

  // ── Génération PDF via isolate (compute) ──────────────────────────────────
  // Déplacée dans la fonction top-level _genererCertificatBytes() pour que
  // compute() puisse la sérialiser dans un isolate Dart séparé.
  // → Plus de freeze UI / crash mémoire sur tontines avec de nombreuses TX.
  Future<Uint8List> _genererPdf() async {
    return compute(
      _genererCertificatBytes,
      _CertificatParams(
        entrees    : _entrees,
        contrat    : _contrat,
        codeTontine: widget.codeTontine,
        nomTontine : widget.nomTontine,
        membreNom  : widget.membreNom,
        maxEntrees : _kMaxEntrees,
        devise     : _devise,  // transmet la vraie devise tontine au PDF
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
                          devise: _devise,
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
  final String devise; // devise tontine — priorité sur entree.devise

  const _CarteOperationJournal({
    required this.entree,
    required this.estTxOnChain,
    this.contratAddr,
    this.devise = '',
  });

  /// Ouvre PolygonScan uniquement pour les vraies TX on-chain (Phase 2)
  Future<void> _ouvrirPolygonScan(BuildContext ctx) async {
    if (!estTxOnChain || entree.txHash == null) return;
    final url = Uri.parse('https://polygonscan.com/tx/${entree.txHash}');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  /// Copie le TX hash complet dans le presse-papier
  Future<void> _copierHash(BuildContext ctx) async {
    if (entree.txHash == null || entree.txHash!.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: entree.txHash!));
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'ID copié : ${entree.txHash!.substring(0, 18)}...${entree.txHash!.substring(entree.txHash!.length - 6)}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF1A237E),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool aHash       = entree.txHash != null && entree.txHash!.isNotEmpty;
    // aLienExtern = true uniquement pour les vraies TX on-chain (Polygonscan)
    final bool aLienExtern = estTxOnChain && aHash;

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
                    Formatters.montant(entree.montantXof!,
                        devise: devise.isNotEmpty ? devise
                            : entree.devise.isNotEmpty ? entree.devise
                            : null),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.encre,
                    ),
                  ),
              ],
            ),
          ),

          // ── Ligne TX hash + boutons ─────────────────────────────────────
          if (aHash) ...[
            const Divider(height: 1, thickness: 0.6, color: AppColors.lignes),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  // ── Hash abrégé cliquable → ouvre PolygonScan (on-chain) ────
                  GestureDetector(
                    onTap: () => aLienExtern
                        ? _ouvrirPolygonScan(context)
                        : _copierHash(context),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          aLienExtern ? Icons.open_in_new : Icons.fingerprint,
                          size: 13,
                          color: estTxOnChain
                              ? const Color(0xFF00C853)
                              : AppColors.texteDoux,
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
                                : AppColors.texteDoux,
                            fontWeight: FontWeight.w600,
                            decoration: aLienExtern
                                ? TextDecoration.underline
                                : TextDecoration.none,
                            decorationColor: const Color(0xFF00C853),
                          ),
                        ),
                        if (aLienExtern) ...[
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.open_in_new,
                            size: 11,
                            color: Color(0xFF00C853),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Spacer(),
                  // ── Bouton Copier TX ID — toujours visible si hash présent ──
                  GestureDetector(
                    onTap: () => _copierHash(context),
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
                            Icons.copy_rounded,
                            size: 10,
                            color: estTxOnChain
                                ? const Color(0xFF00C853)
                                : AppColors.encreDoux,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Copier ID',
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

}
