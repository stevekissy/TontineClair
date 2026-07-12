// ─────────────────────────────────────────────────────────────────────────────
// PdfService — Relevé complet TontineClair
// Spécification : FICHE-MODULE-DASHBOARD-PARTAGE.pdf §2
// 4 sections dans l'ordre : En-tête / Caisse / Tours clôturés / Prêts / Journal
//
// Bug #4 fix : Printing.sharePdf() ne déclenche pas de téléchargement sur Flutter
// Web. Utilisation de Printing.layoutPdf() → Uint8List → download via <a href>
// ─────────────────────────────────────────────────────────────────────────────

// Import conditionnel : web_download_web.dart sur Flutter Web, stub sur mobile
// Ceci évite l'erreur "dart:html not available" lors de la compilation Android
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../models/tontine.dart';
import '../utils/formatters.dart';
import '../utils/web_download_stub.dart'
    if (dart.library.html) '../utils/web_download_web.dart';

class PdfService {
  // Couleurs
  static const _or = PdfColor.fromInt(0xFFD99A2B);
  static const _encre = PdfColor.fromInt(0xFF1C2447);
  static const _fondGris = PdfColor.fromInt(0xFFEEEEEE);
  static const _texteDoux = PdfColor.fromInt(0xFF6E6C60);

  // ── Bug #4 : téléchargement PDF unifié Web + Mobile ─────────────────────
  // Web  → downloadPdfBytes() depuis web_download_web.dart (dart:html Blob)
  // Mobile → Printing.sharePdf() sélecteur natif
  static Future<void> _telechargerPdf(
    pw.Document doc,
    String filename,
  ) async {
    final bytes = await doc.save();
    if (kIsWeb) {
      // Web : import conditionnel → web_download_web.dart → dart:html Blob
      downloadPdfBytes(bytes, filename);
    } else {
      // Mobile : sélecteur de partage natif
      await Printing.sharePdf(bytes: bytes, filename: filename);
    }
  }

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

    await _telechargerPdf(
      doc,
      'TontineClair_${data.nom.replaceAll(' ', '_')}_${tontine.code}.pdf',
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
          'Code : $code  ·  ${data.membres.length} membres  ·  ${Formatters.montant(data.montant, devise: data.devise)}/pers.  ·  ${Formatters.periodicite(data.periode)}',
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
                Formatters.montant(data.soldeCaisse, devise: data.devise),
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
                (montantPositif ? '+' : '') + Formatters.montant(m.montant, devise: data.devise),
              ];
            }).toList(),
            cellAlignments: {
              3: pw.Alignment.centerRight,
            },
          ),
      ],
    );
  }

  // ── §3 : Tours ───────────────────────────────────────────────────────────
  static pw.Widget _sectionTours(
    TontineData data,
    pw.Font bold,
    pw.Font regular,
  ) {
    final historique = data.historique;
    final nbTours = data.nbTours;

    // Construire la liste des widgets de la section
    final List<pw.Widget> contenu = [
      _titreSousSection('Tours du cycle (Tour ${data.numerTour} sur $nbTours)', bold),
      pw.SizedBox(height: 6),
    ];

    // ── Tour en cours ────────────────────────────────────────────────────────
    if (!data.cycleTermine && !data.cycleEnAttente) {
      contenu.add(
        pw.Container(
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            color: _encre,
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'Tour ${data.numerTour} / $nbTours — EN COURS',
                    style: pw.TextStyle(font: bold, fontSize: 10, color: PdfColors.white),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    'Bénéficiaire : ${data.beneficiaireNomOuFallback}',
                    style: pw.TextStyle(font: regular, fontSize: 9, color: _or),
                  ),
                ],
              ),
              pw.Text(
                '${data.nbPayes}/${data.membres.length} cotisations',
                style: pw.TextStyle(font: bold, fontSize: 9, color: PdfColors.white),
              ),
            ],
          ),
        ),
      );
      contenu.add(pw.SizedBox(height: 8));
    } else if (data.cycleEnAttente) {
      contenu.add(
        pw.Container(
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            color: _fondGris,
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
          ),
          child: pw.Text(
            'Tontine en attente de démarrage — aucun tour commencé.',
            style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
          ),
        ),
      );
      contenu.add(pw.SizedBox(height: 8));
    }

    // ── Tours clôturés ──────────────────────────────────────────────────────
    if (historique.isEmpty) {
      contenu.add(
        pw.Text(
          'Aucun tour clôturé pour l\'instant.',
          style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
        ),
      );
    } else {
      contenu.add(
        pw.TableHelper.fromTextArray(
          headers: ['Tour', 'Bénéficiaire', 'Cotisations', 'Montant', 'Date'],
          headerStyle: pw.TextStyle(font: bold, fontSize: 9, color: PdfColors.white),
          headerDecoration: const pw.BoxDecoration(color: _encre),
          cellStyle: pw.TextStyle(font: regular, fontSize: 9),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          data: historique.asMap().entries.map((e) {
            final h = e.value;
            final numTour = (h['tour'] as num?)?.toInt() ?? (e.key + 1);
            // Résoudre le bénéficiaire : historique → beneficiaireId → 'non désigné'
            String benef = h['beneficiaire'] as String?
                ?? h['membre'] as String?
                ?? h['beneficiaireNom'] as String?
                ?? '';
            if (benef.isEmpty) {
              final benefId = h['beneficiaireId'] as String?
                  ?? h['ordreId'] as String?;
              if (benefId != null) {
                benef = data.membres
                    .where((m) => m.id == benefId)
                    .map((m) => m.nom)
                    .firstOrNull ?? 'Bénéficiaire non encore désigné';
              } else {
                benef = 'Bénéficiaire non encore désigné';
              }
            }
            final recu = (h['totalRecu'] as num?)?.toInt()
                ?? (h['total'] as num?)?.toInt()
                ?? 0;
            final total = (h['totalAttendu'] as num?)?.toInt()
                ?? data.membres.length * data.montant;
            DateTime? dateD;
            final dateRaw = h['date'] ?? h['closLe'];
            if (dateRaw is int) {
              dateD = DateTime.fromMillisecondsSinceEpoch(dateRaw);
            } else if (dateRaw is String && dateRaw.isNotEmpty) {
              dateD = DateTime.tryParse(dateRaw);
            }

            return [
              'Tour $numTour',
              benef,
              '${(h['nbPayes'] as num?)?.toInt() ?? '?'}/$nbTours',
              Formatters.montant(recu > 0 ? recu : total, devise: data.devise),
              dateD != null ? Formatters.dateFormatee(dateD) : '—',
            ];
          }).toList(),
        ),
      );
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: contenu,
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
                        '$membreNom — ${Formatters.montant(p.montant, devise: data.devise)} à ${p.taux}% sur ${p.dureesMois} mois',
                        style: pw.TextStyle(font: bold, fontSize: 9),
                      ),
                      pw.Text(
                        'Statut : ${p.statutCalcule}  |  Restant : ${Formatters.montant(p.resteADu, devise: data.devise)}',
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
                      Formatters.montant(r.montant, devise: data.devise),
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

  // ── §PV : Procès-verbal de vote nominatif ───────────────────────────────
  /// Génère et partage le PDF du PV d'un vote.
  static Future<void> exporterPvVote({
    required Tontine tontine,
    required Vote vote,
    required List<Map<String, dynamic>> voixDetaillees,
    required String nomGestionnaire,
  }) async {
    final data = tontine.data;
    final doc = pw.Document();

    final regular = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();
    final theme = pw.ThemeData.withFont(base: regular, bold: bold);

    // Décompte — Bug #1 fix : utiliser membre_id (clé snake_case de Supabase)
    final oui = voixDetaillees.where((v) => v['choix'] == 'oui').length;
    final non = voixDetaillees.where((v) => v['choix'] == 'non').length;
    final abstention = voixDetaillees.where((v) => v['choix'] == 'abstention').length;
    final adopte = vote.adopte;
    final totalVotants = voixDetaillees.length;
    final totalMembres = data.membres.length;

    // Bug #1 fix : utiliser membre_id (snake_case) comme dans lire_voix_tontine RPC
    final ayantVoteIds = voixDetaillees
        .map((v) => v['membre_id'] as String? ?? v['membreId'] as String? ?? '')
        .toSet();
    final nonVotants = data.membres.where((m) => !ayantVoteIds.contains(m.id)).toList();

    doc.addPage(
      pw.MultiPage(
        theme: theme,
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (_) => _buildPvHeader(data, tontine.code, vote, bold, regular),
        footer: (ctx) => _buildFooter(ctx, regular),
        build: (_) => [
          // ── Bloc résumé ───────────────────────────────────────────────────
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              color: _encre,
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      adopte == true
                          ? 'ADOPTE'
                          : adopte == false
                              ? 'REJETE'
                              : 'SANS DECISION',
                      style: pw.TextStyle(font: bold, fontSize: 14, color: _or),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      'Participation : $totalVotants / $totalMembres membres',
                      style: pw.TextStyle(font: regular, fontSize: 9,
                          color: PdfColors.white),
                    ),
                  ],
                ),
                pw.Row(
                  children: [
                    _compteurVote('Oui', oui, bold, regular),
                    pw.SizedBox(width: 16),
                    _compteurVote('Non', non, bold, regular),
                    pw.SizedBox(width: 16),
                    _compteurVote('Abst.', abstention, bold, regular),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 16),

          // ── Tableau nominatif des votes ───────────────────────────────────
          _titreSousSection('Depouillement nominatif', bold),
          pw.SizedBox(height: 6),
          if (voixDetaillees.isEmpty)
            pw.Text(
              'Aucune voix enregistrée.',
              style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
            )
          else
            pw.TableHelper.fromTextArray(
              headers: ['#', 'Membre', 'Vote', 'Horodatage'],
              headerStyle: pw.TextStyle(font: bold, fontSize: 9, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: _encre),
              cellStyle: pw.TextStyle(font: regular, fontSize: 9),
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              columnWidths: {
                0: const pw.FixedColumnWidth(24),
                1: const pw.FlexColumnWidth(2),
                2: const pw.FixedColumnWidth(60),
                3: const pw.FixedColumnWidth(90),
              },
              data: voixDetaillees.asMap().entries.map((e) {
                final i = e.key + 1;
                final v = e.value;
                // Bug #1 fix : prioriser membre_id (clé snake_case de Supabase)
                final membreId = v['membre_id'] as String? ?? v['membreId'] as String? ?? '';
                final membreNom = v['membre_nom'] as String?
                    ?? v['membreNom'] as String?
                    ?? data.membres
                        .where((m) => m.id == membreId)
                        .map((m) => m.nom)
                        .firstOrNull
                    ?? '—';
                final choix = v['choix'] as String? ?? '—';
                final choixLabel = choix == 'oui'
                    ? 'Oui'
                    : choix == 'non'
                        ? 'Non'
                        : 'Abst.';

                // Timestamp du vote — Bug fix : gérer les deux formats
                DateTime? ts;
                final leRaw = v['le'] ?? v['date'] ?? v['horodatage'];
                if (leRaw is int) {
                  ts = DateTime.fromMillisecondsSinceEpoch(leRaw);
                } else if (leRaw is String && leRaw.isNotEmpty) {
                  ts = DateTime.tryParse(leRaw);
                }

                return [
                  '$i',
                  membreNom,
                  choixLabel,
                  ts != null ? Formatters.dateHeure(ts) : '—',
                ];
              }).toList(),
            ),
          pw.SizedBox(height: 16),

          // ── Non-votants ──────────────────────────────────────────────────
          if (nonVotants.isNotEmpty) ...[
            _titreSousSection('Membres n\'ayant pas vote (${nonVotants.length})', bold),
            pw.SizedBox(height: 6),
            pw.Wrap(
              spacing: 8,
              runSpacing: 4,
              children: nonVotants.map((m) => pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: pw.BoxDecoration(
                  color: _fondGris,
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                ),
                child: pw.Text(m.nom, style: pw.TextStyle(font: regular, fontSize: 9)),
              )).toList(),
            ),
            pw.SizedBox(height: 16),
          ],

          // ── Signature du gestionnaire ────────────────────────────────────
          pw.SizedBox(height: 24),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('Gestionnaire :',
                      style: pw.TextStyle(font: regular, fontSize: 9, color: _texteDoux)),
                  pw.SizedBox(height: 2),
                  pw.Text(nomGestionnaire,
                      style: pw.TextStyle(font: bold, fontSize: 10, color: _encre)),
                  pw.SizedBox(height: 24),
                  pw.Container(width: 120, height: 1, color: _encre),
                  pw.Text('Signature',
                      style: pw.TextStyle(font: regular, fontSize: 8, color: _texteDoux)),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('Clos le :',
                      style: pw.TextStyle(font: regular, fontSize: 9, color: _texteDoux)),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    vote.dateCloture != null
                        ? Formatters.dateHeure(DateTime.tryParse(vote.dateCloture!))
                        : Formatters.dateHeure(DateTime.now()),
                    style: pw.TextStyle(font: bold, fontSize: 10, color: _encre),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );

    await _telechargerPdf(
      doc,
      'TontineClair_PV_Vote_${data.nom.replaceAll(' ', '_')}'
          '_${vote.id.substring(0, 6).toUpperCase()}.pdf',
    );
  }

  // ── §Reçu : Reçu de cotisation nominatif ─────────────────────────────────
  /// Bug #6 : génère un PDF reçu pour un paiement de cotisation.
  static Future<void> exporterRecuCotisation({
    required dynamic tontine,
    required Membre membre,
    required String ref,
    required String methode,
    required String dateStr,
  }) async {
    final data = tontine.data;
    final doc = pw.Document();

    final regular = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();
    final theme = pw.ThemeData.withFont(base: regular, bold: bold);

    final datePaiement = DateTime.tryParse(dateStr);

    doc.addPage(
      pw.Page(
        theme: theme,
        pageFormat: PdfPageFormat.a5,
        margin: const pw.EdgeInsets.all(24),
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            // En-tête
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('TontineClair',
                    style: pw.TextStyle(font: bold, fontSize: 20, color: _encre)),
                pw.Text(
                  'Généré le ${Formatters.dateHeure(DateTime.now())}',
                  style: pw.TextStyle(font: regular, fontSize: 8, color: _texteDoux),
                ),
              ],
            ),
            pw.Divider(color: _or, thickness: 1.5),
            pw.SizedBox(height: 12),
            pw.Text(
              'RECU DE COTISATION',
              style: pw.TextStyle(font: bold, fontSize: 16, color: _encre),
            ),
            pw.SizedBox(height: 16),
            // Bloc principal
            pw.Container(
              padding: const pw.EdgeInsets.all(14),
              decoration: pw.BoxDecoration(
                color: _encre,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text('Montant',
                          style: pw.TextStyle(font: regular, fontSize: 10, color: PdfColors.white)),
                      pw.Text(
                        Formatters.montant(data.montant, devise: data.devise),
                        style: pw.TextStyle(font: bold, fontSize: 18, color: _or),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 14),
            // Détails
            _ligneRecu('Tontine', data.nom, bold, regular),
            _ligneRecu('Membre', membre.nom, bold, regular),
            _ligneRecu('Tour N°', 'Tour ${data.numerTour} sur ${data.nbTours}', bold, regular),
            _ligneRecu('Bénéficiaire', data.beneficiaireNomOuFallback, bold, regular),
            _ligneRecu('Méthode', Formatters.methodePaiement(methode), bold, regular),
            _ligneRecu('Date', Formatters.dateHeure(datePaiement), bold, regular),
            _ligneRecu('Référence', ref, bold, regular),
            _ligneRecu('Code tontine', tontine.code as String, bold, regular),
            pw.SizedBox(height: 20),
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: const PdfColor.fromInt(0xFFE8F5E9),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
              ),
              child: pw.Text(
                'Paiement enregistre et valide par TontineClair',
                style: pw.TextStyle(font: bold, fontSize: 10, color: const PdfColor.fromInt(0xFF2E7D5B)),
              ),
            ),
          ],
        ),
      ),
    );

    await _telechargerPdf(
      doc,
      'TontineClair_Recu_${membre.nom.replaceAll(' ', '_')}_Tour${data.numerTour}_$ref.pdf',
    );
  }

  // ── Helper : ligne reçu ──────────────────────────────────────────────────
  static pw.Widget _ligneRecu(
    String label,
    String valeur,
    pw.Font bold,
    pw.Font regular,
  ) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label,
              style: pw.TextStyle(font: regular, fontSize: 9, color: _texteDoux)),
          pw.Text(valeur,
              style: pw.TextStyle(font: bold, fontSize: 9, color: _encre)),
        ],
      ),
    );
  }

  // En-tête spécifique PV vote
  static pw.Widget _buildPvHeader(
    TontineData data,
    String code,
    Vote vote,
    pw.Font bold,
    pw.Font regular,
  ) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('TontineClair',
                style: pw.TextStyle(font: bold, fontSize: 18, color: _encre)),
            pw.Text(
              'PV genere le ${Formatters.dateHeure(DateTime.now())}',
              style: pw.TextStyle(font: regular, fontSize: 9, color: _texteDoux),
            ),
          ],
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          'Proces-verbal de vote — ${data.nom}',
          style: pw.TextStyle(font: bold, fontSize: 14, color: _encre),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          'Code tontine : $code  ·  Vote ref. : ${vote.id.substring(0, 8).toUpperCase()}',
          style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
        ),
        pw.SizedBox(height: 4),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: pw.BoxDecoration(
            color: _fondGris,
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
          ),
          child: pw.Text(
            'Question : ${vote.question}',
            style: pw.TextStyle(font: bold, fontSize: 11, color: _encre),
          ),
        ),
        pw.Divider(color: _or, thickness: 1.5),
        pw.SizedBox(height: 8),
      ],
    );
  }

  // Compteur de vote pour le bloc résumé
  static pw.Widget _compteurVote(
    String label,
    int count,
    pw.Font bold,
    pw.Font regular,
  ) {
    return pw.Column(
      children: [
        pw.Text('$count',
            style: pw.TextStyle(font: bold, fontSize: 16, color: PdfColors.white)),
        pw.Text(label,
            style: pw.TextStyle(font: regular, fontSize: 8, color: PdfColors.grey400)),
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
