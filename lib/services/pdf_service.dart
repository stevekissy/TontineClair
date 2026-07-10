// ─────────────────────────────────────────────────────────────────────────────
// PdfService — Relevé complet TontineClair
// Spécification : FICHE-MODULE-DASHBOARD-PARTAGE.pdf §2
// 4 sections dans l'ordre : En-tête / Caisse / Tours clôturés / Prêts / Journal
// ─────────────────────────────────────────────────────────────────────────────

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../models/tontine.dart';
import '../utils/formatters.dart';

class PdfService {
  // Couleurs
  static const _or = PdfColor.fromInt(0xFFD99A2B);
  static const _encre = PdfColor.fromInt(0xFF1C2447);
  static const _fondGris = PdfColor.fromInt(0xFFEEEEEE);
  static const _texteDoux = PdfColor.fromInt(0xFF6E6C60);

  /// Génère et partage le PDF du relevé complet.
  static Future<void> exporterReleve({
    required Tontine tontine,
    required String nomGestionnaire,
  }) async {
    final data = tontine.data;
    final doc = pw.Document();

    // Polices par défaut (système)
    final regular = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();

    final theme = pw.ThemeData.withFont(
      base: regular,
      bold: bold,
    );

    doc.addPage(
      pw.MultiPage(
        theme: theme,
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (ctx) => _buildHeader(data, tontine.code, bold, regular),
        footer: (ctx) => _buildFooter(ctx, regular),
        build: (ctx) => [
          _sectionCaisse(data, bold, regular),
          pw.SizedBox(height: 20),
          _sectionTours(data, bold, regular),
          pw.SizedBox(height: 20),
          _sectionPrets(data, bold, regular),
          pw.SizedBox(height: 20),
          _sectionJournal(data, bold, regular),
        ],
      ),
    );

    final bytes = await doc.save();

    await Printing.sharePdf(
      bytes: bytes,
      filename: 'TontineClair_${data.nom.replaceAll(' ', '_')}_${tontine.code}.pdf',
    );
  }

  // ── En-tête de page ─────────────────────────────────────────────────────
  static pw.Widget _buildHeader(
    TontineData data,
    String code,
    pw.Font bold,
    pw.Font regular,
  ) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'TontineClair',
              style: pw.TextStyle(font: bold, fontSize: 18, color: _encre),
            ),
            pw.Text(
              'Relevé généré le ${Formatters.dateHeure(DateTime.now())}',
              style: pw.TextStyle(font: regular, fontSize: 9, color: _texteDoux),
            ),
          ],
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          'Relevé de la tontine « ${data.nom} »',
          style: pw.TextStyle(font: bold, fontSize: 14, color: _encre),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          'Code : $code  ·  ${data.membres.length} membres  ·  ${Formatters.montantFCFA(data.montant)}/pers.  ·  ${Formatters.periodicite(data.periode)}',
          style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
        ),
        pw.Divider(color: _or, thickness: 1.5),
        pw.SizedBox(height: 8),
      ],
    );
  }

  // ── Pied de page ─────────────────────────────────────────────────────────
  static pw.Widget _buildFooter(pw.Context ctx, pw.Font regular) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          'TontineClair — Relevé confidentiel',
          style: pw.TextStyle(font: regular, fontSize: 8, color: _texteDoux),
        ),
        pw.Text(
          'Page ${ctx.pageNumber} / ${ctx.pagesCount}',
          style: pw.TextStyle(font: regular, fontSize: 8, color: _texteDoux),
        ),
      ],
    );
  }

  // ── §2 : Caisse ──────────────────────────────────────────────────────────
  static pw.Widget _sectionCaisse(
    TontineData data,
    pw.Font bold,
    pw.Font regular,
  ) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _titreSousSection('Caisse commune', bold),
        pw.SizedBox(height: 6),
        // Solde actuel en gros
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(
            color: _encre,
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Solde disponible',
                style: pw.TextStyle(font: bold, fontSize: 12, color: PdfColors.white),
              ),
              pw.Text(
                Formatters.montantFCFA(data.soldeCaisse),
                style: pw.TextStyle(font: bold, fontSize: 16, color: _or),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 10),
        if (data.caisse.isEmpty)
          pw.Text(
            'Aucun mouvement enregistré.',
            style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
          )
        else
          pw.TableHelper.fromTextArray(
            headers: ['Date', 'Motif', 'Par qui', 'Montant'],
            headerStyle: pw.TextStyle(font: bold, fontSize: 9, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: _encre),
            cellStyle: pw.TextStyle(font: regular, fontSize: 9),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            columnWidths: {
              0: const pw.FixedColumnWidth(70),
              1: const pw.FlexColumnWidth(2),
              2: const pw.FlexColumnWidth(1.2),
              3: const pw.FixedColumnWidth(80),
            },
            data: data.caisse.map((m) {
              final montantPositif = m.montant >= 0;
              return [
                Formatters.dateHeure(DateTime.tryParse(m.date)),
                m.description.isNotEmpty ? m.description : m.type,
                m.gestionnaire,
                (montantPositif ? '+' : '') + Formatters.montantFCFA(m.montant),
              ];
            }).toList(),
            cellAlignments: {
              3: pw.Alignment.centerRight,
            },
          ),
      ],
    );
  }

  // ── §3 : Tours clôturés ──────────────────────────────────────────────────
  static pw.Widget _sectionTours(
    TontineData data,
    pw.Font bold,
    pw.Font regular,
  ) {
    final historique = data.historique;

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _titreSousSection('Tours clôturés', bold),
        pw.SizedBox(height: 6),
        if (historique.isEmpty)
          pw.Text(
            'Aucun tour clôturé pour l\'instant.',
            style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
          )
        else
          pw.TableHelper.fromTextArray(
            headers: ['Tour', 'Bénéficiaire', 'Cotisations', 'Montant', 'Date'],
            headerStyle: pw.TextStyle(font: bold, fontSize: 9, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: _encre),
            cellStyle: pw.TextStyle(font: regular, fontSize: 9),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            data: historique.asMap().entries.map((e) {
              final h = e.value;
              final tour = (h['tour'] as num?)?.toInt() ?? (e.key + 1);
              final beneficiaire = h['beneficiaire'] as String? ?? h['membre'] as String? ?? '—';
              final recu = (h['totalRecu'] as num?)?.toInt()
                  ?? (h['total'] as num?)?.toInt()
                  ?? 0;
              final total = (h['totalAttendu'] as num?)?.toInt()
                  ?? data.membres.length * data.montant;
              // BUG FIX : h['date'] et h['closLe'] peuvent être des int (timestamp ms)
              // → ne jamais caster directement en String? (TypeError si int)
              DateTime? dateD;
              final dateRaw = h['date'] ?? h['closLe'];
              if (dateRaw is int) {
                dateD = DateTime.fromMillisecondsSinceEpoch(dateRaw);
              } else if (dateRaw is String && dateRaw.isNotEmpty) {
                dateD = DateTime.tryParse(dateRaw);
              }

              return [
                'Tour $tour',
                beneficiaire,
                '${(h['nbPayes'] as num?)?.toInt() ?? '?'}/${data.membres.length}',
                Formatters.montantFCFA(recu > 0 ? recu : total),
                dateD != null ? Formatters.dateFormatee(dateD) : '—',
              ];
            }).toList(),
          ),
      ],
    );
  }

  // ── §4 : Prêts ───────────────────────────────────────────────────────────
  static pw.Widget _sectionPrets(
    TontineData data,
    pw.Font bold,
    pw.Font regular,
  ) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _titreSousSection('Prêts', bold),
        pw.SizedBox(height: 6),
        if (data.prets.isEmpty)
          pw.Text(
            'Aucun prêt enregistré.',
            style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
          )
        else
          ...data.prets.map((p) {
            // Résoudre le nom de l'emprunteur
            final membreNom = p.emprunteurNom.isNotEmpty
                ? p.emprunteurNom
                : data.membres
                    .where((m) => m.id == p.emprunteurId)
                    .map((m) => m.nom)
                    .firstOrNull ?? p.emprunteurId;

            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  color: _fondGris,
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        '$membreNom — ${Formatters.montantFCFA(p.montant)} à ${p.taux}% sur ${p.dureesMois} mois',
                        style: pw.TextStyle(font: bold, fontSize: 9),
                      ),
                      pw.Text(
                        'Statut : ${p.statut}  |  Restant : ${Formatters.montantFCFA(p.resteADu)}',
                        style: pw.TextStyle(font: regular, fontSize: 9, color: _texteDoux),
                      ),
                    ],
                  ),
                ),
                if (p.remboursements.isNotEmpty) ...[
                  pw.SizedBox(height: 3),
                  pw.TableHelper.fromTextArray(
                    headers: ['Date', 'Méthode', 'Réf.', 'Montant'],
                    headerStyle: pw.TextStyle(font: bold, fontSize: 8, color: PdfColors.white),
                    headerDecoration: const pw.BoxDecoration(color: _encre),
                    cellStyle: pw.TextStyle(font: regular, fontSize: 8),
                    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                    data: p.remboursements.map((r) => [
                      Formatters.dateFormatee(DateTime.tryParse(r.date)),
                      r.methode,
                      r.reference,
                      Formatters.montantFCFA(r.montant),
                    ]).toList(),
                  ),
                ],
                pw.SizedBox(height: 8),
              ],
            );
          }),
      ],
    );
  }

  // ── §5 : Journal ─────────────────────────────────────────────────────────
  static pw.Widget _sectionJournal(
    TontineData data,
    pw.Font bold,
    pw.Font regular,
  ) {
    final entries = data.journal.take(200).toList();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _titreSousSection("Journal d'activité (${entries.length} actions)", bold),
        pw.SizedBox(height: 6),
        if (entries.isEmpty)
          pw.Text(
            'Aucune action dans le journal.',
            style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
          )
        else
          pw.TableHelper.fromTextArray(
            headers: ['Date/heure', 'Action', 'Auteur'],
            headerStyle: pw.TextStyle(font: bold, fontSize: 9, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: _encre),
            cellStyle: pw.TextStyle(font: regular, fontSize: 8),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            columnWidths: {
              0: const pw.FixedColumnWidth(80),
              1: const pw.FlexColumnWidth(3),
              2: const pw.FlexColumnWidth(1.5),
            },
            data: entries.map((j) => [
              Formatters.dateHeure(DateTime.tryParse(j.quand)),
              j.quoi,
              j.gestionnaire,
            ]).toList(),
          ),
      ],
    );
  }

  // ── Titre de section avec soulignement or ──────────────────────────────
  static pw.Widget _titreSousSection(String titre, pw.Font bold) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          titre,
          style: pw.TextStyle(font: bold, fontSize: 13, color: _encre),
        ),
        pw.Container(height: 2, color: _or, width: 80),
        pw.SizedBox(height: 4),
      ],
    );
  }
}
