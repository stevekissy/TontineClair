// ─────────────────────────────────────────────────────────────────────────────
// PdfService — Relevé complet TontineClair
// Spécification : FICHE-MODULE-DASHBOARD-PARTAGE.pdf §2
// 4 sections dans l'ordre : En-tête / Caisse / Tours clôturés / Prêts / Journal
//
// Bug #4 fix : Printing.sharePdf() ne déclenche pas de téléchargement sur Flutter
// Web. Utilisation de Printing.layoutPdf() → Uint8List → download via <a href>
//
// Bug #PDF-FONT fix : Helvetica ne supporte pas les caractères UTF-8 non-ASCII
// (accents français, tirets em, etc.) → crash silencieux. Solution : charger
// NotoSans via PdfGoogleFonts (supporte Latin étendu, accentués, tirets em).
// Fallback sur Helvetica si réseau indisponible.
// ─────────────────────────────────────────────────────────────────────────────

// Import conditionnel : web_download_web.dart sur Flutter Web, stub sur mobile
// Ceci évite l'erreur "dart:html not available" lors de la compilation Android
import 'dart:typed_data' show Uint8List;
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode, compute;
import 'package:flutter/material.dart' show debugPrint;
import 'package:intl/date_symbol_data_local.dart';
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

  // ── Bug #PDF-FONT : nettoyeur de texte pour Helvetica (fallback) ──────────
  // Remplace les caractères non-ASCII par des équivalents ASCII sûrs.
  // Utilisé UNIQUEMENT si NotoSans est indisponible (fallback Helvetica).
  static String _sanitize(String s) {
    return s
        .replaceAll('—', '-')
        .replaceAll('–', '-')
        .replaceAll('\u2019', "'")   // apostrophe typographique '
        .replaceAll('\u2018', "'")   // guillemet '
        .replaceAll('\u201C', '"')   // guillemet "
        .replaceAll('\u201D', '"')   // guillemet "
        .replaceAll('«', '"')
        .replaceAll('»', '"')
        .replaceAll('à', 'a').replaceAll('â', 'a').replaceAll('ä', 'a')
        .replaceAll('é', 'e').replaceAll('è', 'e').replaceAll('ê', 'e').replaceAll('ë', 'e')
        .replaceAll('î', 'i').replaceAll('ï', 'i')
        .replaceAll('ô', 'o').replaceAll('ö', 'o')
        .replaceAll('ù', 'u').replaceAll('û', 'u').replaceAll('ü', 'u')
        .replaceAll('ç', 'c')
        .replaceAll('À', 'A').replaceAll('Â', 'A').replaceAll('Ä', 'A')
        .replaceAll('É', 'E').replaceAll('È', 'E').replaceAll('Ê', 'E').replaceAll('Ë', 'E')
        .replaceAll('Î', 'I').replaceAll('Ï', 'I')
        .replaceAll('Ô', 'O').replaceAll('Ö', 'O')
        .replaceAll('Ù', 'U').replaceAll('Û', 'U').replaceAll('Ü', 'U')
        .replaceAll('Ç', 'C')
        .replaceAll('ñ', 'n').replaceAll('Ñ', 'N')
        .replaceAll('ã', 'a').replaceAll('Ã', 'A')
        .replaceAll('õ', 'o').replaceAll('Õ', 'O')
        // Supprimer les emojis et caractères hors Latin-1 restants
        .replaceAll(RegExp(r'[^\x00-\xFF]'), '?');
  }

  // ── Chargement des polices avec fallback ──────────────────────────────────
  // Tente de charger NotoSans (UTF-8 complet). Si échec (réseau, timeout),
  // retombe sur Helvetica avec _sanitize() appliqué à toutes les chaînes.
  static Future<({pw.Font regular, pw.Font bold, bool usesSanitizer})>
      _chargerPolices() async {
    try {
      final regular = await PdfGoogleFonts.notoSansRegular();
      final bold    = await PdfGoogleFonts.notoSansBold();
      return (regular: regular, bold: bold, usesSanitizer: false);
    } catch (e) {
      if (kDebugMode) debugPrint('[PdfService] NotoSans indisponible, fallback Helvetica: $e');
      return (
        regular: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
        usesSanitizer: true,
      );
    }
  }

  // ── Applique _sanitize si usesSanitizer=true, sinon retourne tel quel ─────
  static String _tx(String s, bool sanitize) => sanitize ? _sanitize(s) : s;

  // ── Traductions PDF (labels statiques dans les documents) ────────────────
  // Seuls les labels fixes du document sont traduits ici.
  // Les données (noms, montants, dates) ne sont JAMAIS traduits.
  static String _t(String key, String langueCode) {
    const Map<String, Map<String, String>> pdf = {
      'releve_titre':          {'fr': 'Relevé de la tontine', 'en': 'Tontine statement', 'es': 'Estado de la tontina', 'pt': 'Extrato da tontina', 'ar': 'كشف التونتين'},
      'releve_genere':         {'fr': 'Relevé généré le', 'en': 'Statement generated on', 'es': 'Estado generado el', 'pt': 'Extrato gerado em', 'ar': 'تم إنشاء الكشف في'},
      'membres':               {'fr': 'membres', 'en': 'members', 'es': 'miembros', 'pt': 'membros', 'ar': 'أعضاء'},
      'par_pers':              {'fr': '/pers.', 'en': '/person', 'es': '/pers.', 'pt': '/pessoa', 'ar': '/شخص'},
      'code':                  {'fr': 'Code', 'en': 'Code', 'es': 'Código', 'pt': 'Código', 'ar': 'الرمز'},
      'confidentiel':          {'fr': 'TontineClair — Relevé confidentiel', 'en': 'TontineClair — Confidential statement', 'es': 'TontineClair — Estado confidencial', 'pt': 'TontineClair — Extrato confidencial', 'ar': 'TontineClair — كشف سري'},
      'page':                  {'fr': 'Page', 'en': 'Page', 'es': 'Página', 'pt': 'Página', 'ar': 'صفحة'},
      'sur':                   {'fr': 'sur', 'en': 'of', 'es': 'de', 'pt': 'de', 'ar': 'من'},
      'caisse_titre':          {'fr': 'Caisse commune', 'en': 'Common treasury', 'es': 'Caja común', 'pt': 'Caixa comum', 'ar': 'الصندوق المشترك'},
      'solde_dispo':           {'fr': 'Solde disponible', 'en': 'Available balance', 'es': 'Saldo disponible', 'pt': 'Saldo disponível', 'ar': 'الرصيد المتاح'},
      'aucun_mouvement':       {'fr': 'Aucun mouvement enregistré.', 'en': 'No transactions recorded.', 'es': 'Sin movimientos registrados.', 'pt': 'Nenhum movimento registrado.', 'ar': 'لا توجد حركات مسجلة.'},
      'col_date':              {'fr': 'Date', 'en': 'Date', 'es': 'Fecha', 'pt': 'Data', 'ar': 'التاريخ'},
      'col_motif':             {'fr': 'Motif', 'en': 'Reason', 'es': 'Motivo', 'pt': 'Motivo', 'ar': 'السبب'},
      'col_par_qui':           {'fr': 'Par qui', 'en': 'By whom', 'es': 'Por quién', 'pt': 'Por quem', 'ar': 'من'},
      'col_montant':           {'fr': 'Montant', 'en': 'Amount', 'es': 'Monto', 'pt': 'Valor', 'ar': 'المبلغ'},
      'tours_titre':           {'fr': 'Tours du cycle', 'en': 'Cycle rounds', 'es': 'Rondas del ciclo', 'pt': 'Rodadas do ciclo', 'ar': 'جولات الدورة'},
      'tour_sur':              {'fr': 'Tour', 'en': 'Round', 'es': 'Ronda', 'pt': 'Rodada', 'ar': 'الجولة'},
      'en_cours':              {'fr': 'EN COURS', 'en': 'IN PROGRESS', 'es': 'EN CURSO', 'pt': 'EM ANDAMENTO', 'ar': 'جارٍ'},
      'beneficiaire':          {'fr': 'Bénéficiaire', 'en': 'Beneficiary', 'es': 'Beneficiario', 'pt': 'Beneficiário', 'ar': 'المستفيد'},
      'cotisations':           {'fr': 'cotisations', 'en': 'contributions', 'es': 'cuotas', 'pt': 'contribuições', 'ar': 'اشتراكات'},
      'en_attente':            {'fr': 'Tontine en attente de démarrage — aucun tour commencé.', 'en': 'Tontine waiting to start — no round begun.', 'es': 'Tontina en espera de inicio — ninguna ronda comenzada.', 'pt': 'Tontina aguardando início — nenhuma rodada iniciada.', 'ar': 'التونتين في انتظار البدء — لم تبدأ أي جولة.'},
      'aucun_tour':            {'fr': "Aucun tour clôturé pour l'instant.", 'en': 'No closed rounds yet.', 'es': 'Ninguna ronda cerrada por ahora.', 'pt': 'Nenhuma rodada encerrada ainda.', 'ar': 'لا توجد جولات مغلقة حتى الآن.'},
      'col_tour':              {'fr': 'Tour', 'en': 'Round', 'es': 'Ronda', 'pt': 'Rodada', 'ar': 'الجولة'},
      'col_beneficiaire':      {'fr': 'Bénéficiaire', 'en': 'Beneficiary', 'es': 'Beneficiario', 'pt': 'Beneficiário', 'ar': 'المستفيد'},
      'benef_non_designe':     {'fr': 'Bénéficiaire non encore désigné', 'en': 'Beneficiary not yet designated', 'es': 'Beneficiario aún no designado', 'pt': 'Beneficiário ainda não designado', 'ar': 'المستفيد لم يُحدَّد بعد'},
      'prets_titre':           {'fr': 'Prêts', 'en': 'Loans', 'es': 'Préstamos', 'pt': 'Empréstimos', 'ar': 'القروض'},
      'aucun_pret':            {'fr': 'Aucun prêt enregistré.', 'en': 'No loans recorded.', 'es': 'Sin préstamos registrados.', 'pt': 'Nenhum empréstimo registrado.', 'ar': 'لا توجد قروض مسجلة.'},
      'statut':                {'fr': 'Statut', 'en': 'Status', 'es': 'Estado', 'pt': 'Status', 'ar': 'الحالة'},
      'restant':               {'fr': 'Restant', 'en': 'Remaining', 'es': 'Restante', 'pt': 'Restante', 'ar': 'المتبقي'},
      'col_methode':           {'fr': 'Méthode', 'en': 'Method', 'es': 'Método', 'pt': 'Método', 'ar': 'الطريقة'},
      'col_ref':               {'fr': 'Réf.', 'en': 'Ref.', 'es': 'Ref.', 'pt': 'Ref.', 'ar': 'مرجع'},
      'journal_titre':         {'fr': "Journal d'activité", 'en': 'Activity log', 'es': 'Registro de actividad', 'pt': 'Registro de atividade', 'ar': 'سجل النشاط'},
      'aucune_action':         {'fr': 'Aucune action dans le journal.', 'en': 'No actions in the log.', 'es': 'Sin acciones en el registro.', 'pt': 'Nenhuma ação no registro.', 'ar': 'لا توجد إجراءات في السجل.'},
      'col_action':            {'fr': 'Action', 'en': 'Action', 'es': 'Acción', 'pt': 'Ação', 'ar': 'الإجراء'},
      'col_auteur':            {'fr': 'Auteur', 'en': 'Author', 'es': 'Autor', 'pt': 'Autor', 'ar': 'المؤلف'},
      // PV vote
      'pv_titre':              {'fr': 'Procès-verbal de vote', 'en': 'Voting minutes', 'es': 'Acta de votación', 'pt': 'Ata de votação', 'ar': 'محضر التصويت'},
      'adopte':                {'fr': 'ADOPTÉ', 'en': 'ADOPTED', 'es': 'ADOPTADO', 'pt': 'APROVADO', 'ar': 'مقبول'},
      'rejete':                {'fr': 'REJETÉ', 'en': 'REJECTED', 'es': 'RECHAZADO', 'pt': 'REJEITADO', 'ar': 'مرفوض'},
      'sans_decision':         {'fr': 'SANS DÉCISION', 'en': 'NO DECISION', 'es': 'SIN DECISIÓN', 'pt': 'SEM DECISÃO', 'ar': 'بدون قرار'},
      'participation':         {'fr': 'Participation', 'en': 'Participation', 'es': 'Participación', 'pt': 'Participação', 'ar': 'المشاركة'},
      'depouillement':         {'fr': 'Dépouillement nominatif', 'en': 'Individual ballot count', 'es': 'Escrutinio nominativo', 'pt': 'Apuração nominativa', 'ar': 'فرز الأصوات الاسمي'},
      'aucune_voix':           {'fr': 'Aucune voix enregistrée.', 'en': 'No votes recorded.', 'es': 'Ningún voto registrado.', 'pt': 'Nenhum voto registrado.', 'ar': 'لا توجد أصوات مسجلة.'},
      'col_membre':            {'fr': 'Membre', 'en': 'Member', 'es': 'Miembro', 'pt': 'Membro', 'ar': 'العضو'},
      'col_vote':              {'fr': 'Vote', 'en': 'Vote', 'es': 'Voto', 'pt': 'Voto', 'ar': 'التصويت'},
      'col_horodatage':        {'fr': 'Horodatage', 'en': 'Timestamp', 'es': 'Fecha/hora', 'pt': 'Carimbo de data/hora', 'ar': 'الطابع الزمني'},
      'non_votants':           {'fr': "Membres n'ayant pas voté", 'en': 'Members who did not vote', 'es': 'Miembros que no votaron', 'pt': 'Membros que não votaram', 'ar': 'الأعضاء الذين لم يصوتوا'},
      'gestionnaire_label':    {'fr': 'Gestionnaire :', 'en': 'Manager:', 'es': 'Gestor:', 'pt': 'Gestor:', 'ar': 'المسير:'},
      'signature':             {'fr': 'Signature', 'en': 'Signature', 'es': 'Firma', 'pt': 'Assinatura', 'ar': 'التوقيع'},
      // Reçu cotisation
      'recu_titre':            {'fr': 'REÇU DE COTISATION', 'en': 'CONTRIBUTION RECEIPT', 'es': 'RECIBO DE CUOTA', 'pt': 'RECIBO DE CONTRIBUIÇÃO', 'ar': 'إيصال الاشتراك'},
      'recu_genere':           {'fr': 'Généré le', 'en': 'Generated on', 'es': 'Generado el', 'pt': 'Gerado em', 'ar': 'تم الإنشاء في'},
      'tontine':               {'fr': 'Tontine', 'en': 'Tontine', 'es': 'Tontina', 'pt': 'Tontina', 'ar': 'التونتين'},
      'membre':                {'fr': 'Membre', 'en': 'Member', 'es': 'Miembro', 'pt': 'Membro', 'ar': 'العضو'},
      'tour_n':                {'fr': 'Tour N°', 'en': 'Round No.', 'es': 'Ronda N°', 'pt': 'Rodada N°', 'ar': 'الجولة رقم'},
      'methode':               {'fr': 'Méthode', 'en': 'Method', 'es': 'Método', 'pt': 'Método', 'ar': 'الطريقة'},
      'col_date_label':        {'fr': 'Date', 'en': 'Date', 'es': 'Fecha', 'pt': 'Data', 'ar': 'التاريخ'},
      'reference':             {'fr': 'Référence', 'en': 'Reference', 'es': 'Referencia', 'pt': 'Referência', 'ar': 'المرجع'},
      'code_tontine':          {'fr': 'Code tontine', 'en': 'Tontine code', 'es': 'Código de tontina', 'pt': 'Código da tontina', 'ar': 'رمز التونتين'},
      'paiement_valide':       {'fr': 'Paiement enregistré et validé par TontineClair', 'en': 'Payment recorded and validated by TontineClair', 'es': 'Pago registrado y validado por TontineClair', 'pt': 'Pagamento registrado e validado pelo TontineClair', 'ar': 'تم تسجيل الدفع والتحقق منه بواسطة TontineClair'},
      'oui':                   {'fr': 'Oui', 'en': 'Yes', 'es': 'Sí', 'pt': 'Sim', 'ar': 'نعم'},
      'non':                   {'fr': 'Non', 'en': 'No', 'es': 'No', 'pt': 'Não', 'ar': 'لا'},
      'abstention':            {'fr': 'Abst.', 'en': 'Abst.', 'es': 'Abst.', 'pt': 'Abst.', 'ar': 'امتناع'},
    };
    final lang = pdf[key];
    if (lang == null) return key;
    return lang[langueCode] ?? lang['fr'] ?? key;
  }
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
    String langueCode = 'fr',
  }) async {
    // ── Génération dans un Isolate séparé pour ne pas bloquer le thread UI ──
    // Avec 100+ entrées journal, la construction du PDF peut prendre 2-5 sec.
    // compute() déplace tout dans un worker thread → plus de freeze/ANR.
    final bytes = await compute(
      _genererReleveBytes,
      _ReleveParams(
        tontine: tontine,
        nomGestionnaire: nomGestionnaire,
        langueCode: langueCode,
      ),
    );
    final nomFichier = _sanitize(tontine.data.nom).replaceAll(' ', '_');
    final filename = 'TontineClair_${nomFichier}_${tontine.code}.pdf';
    final uint8bytes = Uint8List.fromList(bytes);
    if (kIsWeb) {
      downloadPdfBytes(uint8bytes, filename);
    } else {
      await Printing.sharePdf(bytes: uint8bytes, filename: filename);
    }
  }

  /// Fonction top-level-compatible pour compute() — génère les bytes du relevé.
  static Future<List<int>> _genererReleveBytes(_ReleveParams p) async {
    // ── Isolate fix : initializeDateFormatting doit être appelé dans chaque Isolate.
    // Les Isolates Flutter ne partagent pas la mémoire → les données de locale
    // initialisées dans main() ne sont pas disponibles ici.
    await initializeDateFormatting('fr_FR', null);

    final data = p.tontine.data;
    final doc = pw.Document();

    // Bug #PDF-FONT : charger NotoSans (UTF-8) avec fallback Helvetica + sanitizer
    final polices = await _chargerPolices();
    final regular = polices.regular;
    final bold    = polices.bold;
    final san     = polices.usesSanitizer;

    final theme = pw.ThemeData.withFont(base: regular, bold: bold);

    doc.addPage(
      pw.MultiPage(
        theme: theme,
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (ctx) => _buildHeader(data, p.tontine.code, bold, regular, p.langueCode, san),
        footer: (ctx) => _buildFooter(ctx, regular, p.langueCode),
        build: (ctx) => [
          _sectionCaisse(data, bold, regular, p.langueCode, san),
          pw.SizedBox(height: 20),
          _sectionTours(data, bold, regular, p.langueCode, san),
          pw.SizedBox(height: 20),
          _sectionPrets(data, bold, regular, p.langueCode, san),
          pw.SizedBox(height: 20),
          _sectionJournal(data, bold, regular, p.langueCode, san),
        ],
      ),
    );
    return doc.save();
  }

  // ── En-tête de page ─────────────────────────────────────────────────────
  static pw.Widget _buildHeader(
    TontineData data,
    String code,
    pw.Font bold,
    pw.Font regular,
    String langueCode,
    bool san,
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
              '${_tx(_t('releve_genere', langueCode), san)} ${Formatters.dateHeure(DateTime.now())}',
              style: pw.TextStyle(font: regular, fontSize: 9, color: _texteDoux),
            ),
          ],
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          _tx('${_t("releve_titre", langueCode)} « ${data.nom} »', san),
          style: pw.TextStyle(font: bold, fontSize: 14, color: _encre),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          '${_t("code", langueCode)} : $code  ·  ${data.membres.length} ${_t("membres", langueCode)}  ·  ${Formatters.montant(data.montant, devise: data.devise)}${_t("par_pers", langueCode)}  ·  ${_tx(Formatters.periodicite(data.periode), san)}',
          style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
        ),
        pw.Divider(color: _or, thickness: 1.5),
        pw.SizedBox(height: 8),
      ],
    );
  }

  // ── Pied de page ─────────────────────────────────────────────────────────
  static pw.Widget _buildFooter(pw.Context ctx, pw.Font regular, String langueCode) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          _t('confidentiel', langueCode),
          style: pw.TextStyle(font: regular, fontSize: 8, color: _texteDoux),
        ),
        pw.Text(
          '${_t('page', langueCode)} \${ctx.pageNumber} ${_t('sur', langueCode)} \${ctx.pagesCount}',
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
    String langueCode,
    bool san,
  ) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _titreSousSection(_t('caisse_titre', langueCode), bold),
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
                _t('solde_dispo', langueCode),
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
            _t('aucun_mouvement', langueCode),
            style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
          )
        else
          pw.TableHelper.fromTextArray(
            headers: [_t('col_date', langueCode), _t('col_motif', langueCode), _t('col_par_qui', langueCode), _t('col_montant', langueCode)],
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
                _tx(m.description.isNotEmpty ? m.description : m.type, san),
                _tx(m.gestionnaire, san),
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
    String langueCode,
    bool san,
  ) {
    final historique = data.historique;
    final nbTours = data.nbTours;

    // Construire la liste des widgets de la section
    final List<pw.Widget> contenu = [
      _titreSousSection("${_t('tours_titre', langueCode)} (${_t('tour_sur', langueCode)} ${data.numerTour} sur $nbTours)", bold),
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
                    "${_t('tour_sur', langueCode)} ${data.numerTour} / $nbTours — ${_t('en_cours', langueCode)}",
                    style: pw.TextStyle(font: bold, fontSize: 10, color: PdfColors.white),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    "${_t('beneficiaire', langueCode)} : ${_tx(data.beneficiaireNomOuFallback, san)}",
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
            _t('en_attente', langueCode),
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
          _t('aucun_tour', langueCode),
          style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
        ),
      );
    } else {
      contenu.add(
        pw.TableHelper.fromTextArray(
          headers: [_t('col_tour', langueCode), _t('col_beneficiaire', langueCode), _t('cotisations', langueCode), _t('col_montant', langueCode), _t('col_date', langueCode)],
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
                    .firstOrNull ?? _t('benef_non_designe', langueCode);
              } else {
                benef = _t('benef_non_designe', langueCode);
              }
            }
            benef = _tx(benef, san);
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
    String langueCode,
    bool san,
  ) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _titreSousSection(_t('prets_titre', langueCode), bold),
        pw.SizedBox(height: 6),
        if (data.prets.isEmpty)
          pw.Text(
            _t('aucun_pret', langueCode),
            style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
          )
        else
          ...data.prets.map((p) {
            // Résoudre le nom de l'emprunteur
            final membreNomRaw = p.emprunteurNom.isNotEmpty
                ? p.emprunteurNom
                : data.membres
                    .where((m) => m.id == p.emprunteurId)
                    .map((m) => m.nom)
                    .firstOrNull ?? p.emprunteurId;
            final membreNom = _tx(membreNomRaw, san);

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
                        '$membreNom - ${Formatters.montant(p.montant, devise: data.devise)} a ${p.taux}% sur ${p.dureesMois} mois',
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
                      _tx(r.methode, san),
                      _tx(r.reference, san),
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
    String langueCode,
    bool san,
  ) {
    // Limité aux 50 DERNIÈRES entrées (les plus récentes) pour éviter crash
    // sur tontines actives (ex: 121 ops). Le journal est trié du plus ancien
    // au plus récent → on prend la fin de la liste.
    const maxEntrees = 50;
    final total = data.journal.length;
    final entries = total > maxEntrees
        ? data.journal.skip(total - maxEntrees).toList()
        : data.journal.toList();

    final titre = total > maxEntrees
        ? "${_t('journal_titre', langueCode)} (${entries.length} dernières sur $total actions)"
        : "${_t('journal_titre', langueCode)} (${entries.length} actions)";

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _titreSousSection(titre, bold),
        pw.SizedBox(height: 6),
        if (entries.isEmpty)
          pw.Text(
            _t('aucune_action', langueCode),
            style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
          )
        else
          pw.TableHelper.fromTextArray(
            headers: [_t('col_date', langueCode), _t('col_action', langueCode), _t('col_auteur', langueCode)],
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
              _tx(j.quoi, san),
              _tx(j.gestionnaire, san),
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
    String langueCode = 'fr',
  }) async {
    final data = tontine.data;
    final doc = pw.Document();

    final regular = pw.Font.helvetica();
    final bold    = pw.Font.helveticaBold();
    final theme = pw.ThemeData.withFont(base: regular, bold: bold);

    // Décompte — Bug #1 fix : utiliser membre_id (clé snake_case de Supabase)
    final oui = voixDetaillees.where((v) => (v['choix'] as String? ?? '').toLowerCase() == 'oui').length;
    final non = voixDetaillees.where((v) => (v['choix'] as String? ?? '').toLowerCase() == 'non').length;
    final abstention = voixDetaillees.where((v) => (v['choix'] as String? ?? '').toLowerCase() == 'abstention').length;
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
        header: (_) => _buildPvHeader(data, tontine.code, vote, bold, regular, langueCode),
        footer: (ctx) => _buildFooter(ctx, regular, langueCode),
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
                          ? _t('adopte', langueCode)
                          : adopte == false
                              ? _t('rejete', langueCode)
                              : _t('sans_decision', langueCode),
                      style: pw.TextStyle(font: bold, fontSize: 14, color: _or),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      "${_t('participation', langueCode)} : $totalVotants / $totalMembres ${_t('membres', langueCode)}",
                      style: pw.TextStyle(font: regular, fontSize: 9,
                          color: PdfColors.white),
                    ),
                  ],
                ),
                pw.Row(
                  children: [
                    _compteurVote(_t('oui', langueCode), oui, bold, regular),
                    pw.SizedBox(width: 16),
                    _compteurVote(_t('non', langueCode), non, bold, regular),
                    pw.SizedBox(width: 16),
                    _compteurVote(_t('abstention', langueCode), abstention, bold, regular),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 16),

          // ── Tableau nominatif des votes ───────────────────────────────────
          _titreSousSection(_t('depouillement', langueCode), bold),
          pw.SizedBox(height: 6),
          if (voixDetaillees.isEmpty)
            pw.Text(
              _t('aucune_voix', langueCode),
              style: pw.TextStyle(font: regular, fontSize: 10, color: _texteDoux),
            )
          else
            pw.TableHelper.fromTextArray(
              headers: ['#', _t('col_membre', langueCode), _t('col_vote', langueCode), _t('col_horodatage', langueCode)],
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
                final choixLabel = choix.toLowerCase() == 'oui'
                    ? _t('oui', langueCode)
                    : choix.toLowerCase() == 'non'
                        ? _t('non', langueCode)
                        : choix.toLowerCase() == 'abstention'
                            ? _t('abstention', langueCode)
                            : _t('abstention', langueCode);

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
            _titreSousSection("${_t('non_votants', langueCode)} (${nonVotants.length})", bold),
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
                  pw.Text(_t('gestionnaire_label', langueCode),
                      style: pw.TextStyle(font: regular, fontSize: 9, color: _texteDoux)),
                  pw.SizedBox(height: 2),
                  pw.Text(nomGestionnaire,
                      style: pw.TextStyle(font: bold, fontSize: 10, color: _encre)),
                  pw.SizedBox(height: 24),
                  pw.Container(width: 120, height: 1, color: _encre),
                  pw.Text(_t('signature', langueCode),
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
          '_${vote.id.length > 6 ? vote.id.substring(0, 6).toUpperCase() : vote.id.toUpperCase()}.pdf',
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
    String langueCode = 'fr',
  }) async {
    final data = tontine.data;
    final doc = pw.Document();

    final regular = pw.Font.helvetica();
    final bold    = pw.Font.helveticaBold();
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
                  "${_t('recu_genere', langueCode)} ${Formatters.dateHeure(DateTime.now())}",
                  style: pw.TextStyle(font: regular, fontSize: 8, color: _texteDoux),
                ),
              ],
            ),
            pw.Divider(color: _or, thickness: 1.5),
            pw.SizedBox(height: 12),
            pw.Text(
              _t('recu_titre', langueCode),
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
                      pw.Text(_t('col_montant', langueCode),
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
            _ligneRecu(_t('tontine', langueCode), data.nom, bold, regular),
            _ligneRecu(_t('membre', langueCode), membre.nom, bold, regular),
            _ligneRecu(_t('tour_n', langueCode), "${_t('tour_sur', langueCode)} ${data.numerTour} ${_t('sur', langueCode)} ${data.nbTours}", bold, regular),
            _ligneRecu(_t('beneficiaire', langueCode), data.beneficiaireNomOuFallback, bold, regular),
            _ligneRecu(_t('methode', langueCode), Formatters.methodePaiement(methode), bold, regular),
            _ligneRecu(_t('col_date_label', langueCode), Formatters.dateHeure(datePaiement), bold, regular),
            _ligneRecu(_t('reference', langueCode), ref, bold, regular),
            _ligneRecu(_t('code_tontine', langueCode), tontine.code as String, bold, regular),
            pw.SizedBox(height: 20),
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: const PdfColor.fromInt(0xFFE8F5E9),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
              ),
              child: pw.Text(
                _t('paiement_valide', langueCode),
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
    String langueCode,
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
          'Code tontine : $code  ·  Vote ref. : ${vote.id.length > 8 ? vote.id.substring(0, 8).toUpperCase() : vote.id.toUpperCase()}',
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

// ─────────────────────────────────────────────────────────────────────────────
// Paramètres pour compute() — doit être sérialisable (pas de closures)
// ─────────────────────────────────────────────────────────────────────────────
class _ReleveParams {
  final Tontine tontine;
  final String nomGestionnaire;
  final String langueCode;
  const _ReleveParams({
    required this.tontine,
    required this.nomGestionnaire,
    required this.langueCode,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// PdfServiceTestHelper — expose les méthodes privées de PdfService pour tests.
// Cette classe N'EST PAS utilisée en production.
// Elle évite de rendre publiques des méthodes internes de PdfService.
// ─────────────────────────────────────────────────────────────────────────────
// ignore: avoid_classes_with_only_static_members
class PdfServiceTestHelper {
  PdfServiceTestHelper._();

  /// Expose PdfService._sanitize pour les tests unitaires.
  static String sanitize(String s) => PdfService._sanitize(s);

  /// Expose PdfService._t pour les tests unitaires.
  static String t(String key, String lang) => PdfService._t(key, lang);

  /// Expose PdfService._tx pour les tests unitaires.
  static String tx(String s, bool san) => PdfService._tx(s, san);

  /// Génère le document PDF du relevé et retourne les bytes.
  /// Utilisé dans les tests pour éviter d'appeler _telechargerPdf().
  static Future<List<int>> genererReleve({
    required Tontine tontine,
    required String nomGestionnaire,
    String langueCode = 'fr',
  }) async {
    final data = tontine.data;
    final doc = pw.Document();

    // Utiliser Helvetica (pas de réseau dans les tests)
    final regular = pw.Font.helvetica();
    final bold    = pw.Font.helveticaBold();
    final theme   = pw.ThemeData.withFont(base: regular, bold: bold);
    const san = true; // sanitizer actif avec Helvetica

    doc.addPage(
      pw.MultiPage(
        theme: theme,
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (ctx) => PdfService._buildHeader(
            data, tontine.code, bold, regular, langueCode, san),
        footer: (ctx) => PdfService._buildFooter(ctx, regular, langueCode),
        build: (ctx) => [
          PdfService._sectionCaisse(data, bold, regular, langueCode, san),
          pw.SizedBox(height: 20),
          PdfService._sectionTours(data, bold, regular, langueCode, san),
          pw.SizedBox(height: 20),
          PdfService._sectionPrets(data, bold, regular, langueCode, san),
          pw.SizedBox(height: 20),
          PdfService._sectionJournal(data, bold, regular, langueCode, san),
        ],
      ),
    );
    return doc.save();
  }

  /// Génère le PV de vote et retourne les bytes.
  static Future<List<int>> genererPvVote({
    required Tontine tontine,
    required Vote vote,
    required List<Map<String, dynamic>> voixDetaillees,
    required String nomGestionnaire,
    String langueCode = 'fr',
  }) async {
    final data = tontine.data;
    final doc = pw.Document();
    final regular = pw.Font.helvetica();
    final bold    = pw.Font.helveticaBold();
    final theme   = pw.ThemeData.withFont(base: regular, bold: bold);

    final ayantVoteIds = voixDetaillees
        .map((v) =>
            v['membre_id'] as String? ?? v['membreId'] as String? ?? '')
        .toSet();
    final nonVotants =
        data.membres.where((m) => !ayantVoteIds.contains(m.id)).toList();

    doc.addPage(
      pw.MultiPage(
        theme: theme,
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (ctx) => PdfService._buildPvHeader(
          data,
          tontine.code,
          vote,
          bold,
          regular,
          langueCode,
        ),
        build: (ctx) => [
          pw.SizedBox(height: 12),
          pw.Text(
            PdfService._t('depouillement', langueCode),
            style: pw.TextStyle(font: bold, fontSize: 12),
          ),
          pw.SizedBox(height: 8),
          if (voixDetaillees.isEmpty)
            pw.Text(PdfService._t('aucune_voix', langueCode),
                style: pw.TextStyle(font: regular, fontSize: 10))
          else
            pw.TableHelper.fromTextArray(
              headers: [
                PdfService._t('col_membre', langueCode),
                PdfService._t('col_vote', langueCode),
                PdfService._t('col_horodatage', langueCode),
              ],
              headerStyle: pw.TextStyle(
                  font: bold, fontSize: 9, color: PdfColors.white),
              headerDecoration:
                  const pw.BoxDecoration(color: PdfColor.fromInt(0xFF1C2447)),
              cellStyle: pw.TextStyle(font: regular, fontSize: 9),
              cellPadding:
                  const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              data: voixDetaillees.map((v) {
                final choix = (v['choix'] as String? ?? '').toLowerCase();
                final label = choix == 'oui'
                    ? 'OUI'
                    : choix == 'non'
                        ? 'NON'
                        : 'ABST.';
                return [
                  PdfService._sanitize(v['nom'] as String? ?? ''),
                  label,
                  PdfService._sanitize(v['horodatage'] as String? ?? ''),
                ];
              }).toList(),
            ),
          if (nonVotants.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Text(PdfService._t('non_votants', langueCode),
                style: pw.TextStyle(font: bold, fontSize: 10)),
            pw.SizedBox(height: 4),
            pw.Text(
              nonVotants.map((m) => PdfService._sanitize(m.nom)).join(', '),
              style: pw.TextStyle(font: regular, fontSize: 9),
            ),
          ],
        ],
      ),
    );
    return doc.save();
  }

  /// Génère le reçu de cotisation et retourne les bytes.
  static Future<List<int>> genererRecuCotisation({
    required Tontine tontine,
    required Membre membre,
    required String ref,
    required String methode,
    required String dateStr,
    String langueCode = 'fr',
  }) async {
    final data = tontine.data;
    final doc = pw.Document();
    final regular = pw.Font.helvetica();
    final bold    = pw.Font.helveticaBold();
    final theme   = pw.ThemeData.withFont(base: regular, bold: bold);
    final datePaiement = DateTime.tryParse(dateStr);

    doc.addPage(
      pw.Page(
        theme: theme,
        pageFormat: PdfPageFormat.a5,
        margin: const pw.EdgeInsets.all(24),
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('TontineClair',
                    style: pw.TextStyle(
                        font: bold,
                        fontSize: 20,
                        color: const PdfColor.fromInt(0xFF1C2447))),
                pw.Text(
                  datePaiement != null ? datePaiement.toIso8601String() : '-',
                  style: pw.TextStyle(font: regular, fontSize: 8),
                ),
              ],
            ),
            pw.Divider(
                color: const PdfColor.fromInt(0xFFD99A2B), thickness: 1.5),
            pw.SizedBox(height: 12),
            pw.Text(
              PdfService._t('recu_titre', langueCode),
              style: pw.TextStyle(
                  font: bold,
                  fontSize: 16,
                  color: const PdfColor.fromInt(0xFF1C2447)),
            ),
            pw.SizedBox(height: 16),
            PdfService._ligneRecu(
              PdfService._t('tontine', langueCode),
              PdfService._sanitize(data.nom),
              regular,
              bold,
            ),
            PdfService._ligneRecu(
              PdfService._t('membre', langueCode),
              PdfService._sanitize(membre.nom),
              regular,
              bold,
            ),
            PdfService._ligneRecu(
              PdfService._t('methode', langueCode),
              PdfService._sanitize(methode),
              regular,
              bold,
            ),
            PdfService._ligneRecu(
              PdfService._t('reference', langueCode),
              ref,
              regular,
              bold,
            ),
            pw.SizedBox(height: 20),
            pw.Text(
              PdfService._t('paiement_valide', langueCode),
              style: pw.TextStyle(
                  font: regular,
                  fontSize: 8,
                  color: const PdfColor.fromInt(0xFF6E6C60)),
            ),
          ],
        ),
      ),
    );
    return doc.save();
  }
}
