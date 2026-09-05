// ─────────────────────────────────────────────────────────────────────────────
// Tests PdfService — TontineClair
//
// Stratégie :
//  1. Tester les fonctions PURES via PdfServiceTestHelper (sanitize, _t, _tx).
//  2. Smoke tests : génération PDF ne doit pas lever d'exception.
//  3. Vérifier la signature %PDF des bytes produits.
//  4. Cas limites : données vides, accents, emojis, montants nuls.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:tontine/models/tontine.dart';
import 'package:tontine/services/pdf_service.dart';

// ── Helpers de construction des objets de test ───────────────────────────────

MouvementCaisse _mvt({
  String id = 'mvt1',
  String type = 'cotisation',
  String description = 'Cotisation Tour 1',
  int montant = 5000,
  String gestionnaire = 'Alice',
  String date = '2024-01-15T10:00:00',
  String reference = 'REF-001',
}) =>
    MouvementCaisse(
      id: id,
      type: type,
      description: description,
      montant: montant,
      gestionnaire: gestionnaire,
      date: date,
      reference: reference,
    );

Pret _pret({
  String id = 'p1',
  String emprunteurId = 'm2',
  String emprunteurNom = 'Bob Martin',
  int montant = 10000,
  double taux = 5,
  int dureesMois = 3,
  String dateDebut = '2024-01-10',
  String gestionnaire = 'Alice',
  String reference = 'PRET-001',
  String statut = 'en cours',
}) =>
    Pret(
      id: id,
      emprunteurId: emprunteurId,
      emprunteurNom: emprunteurNom,
      montant: montant,
      taux: taux,
      dureesMois: dureesMois,
      dateDebut: dateDebut,
      remboursements: [],
      echeancier: [],
      gestionnaire: gestionnaire,
      reference: reference,
      statut: statut,
    );

JournalEntry _journal({
  String quoi = 'Création de la tontine',
  String gestionnaire = 'Alice',
  String quand = '2024-01-01T08:00:00',
}) =>
    JournalEntry(quoi: quoi, gestionnaire: gestionnaire, quand: quand);

Membre _membre({
  String id = 'm1',
  String nom = 'Alice Dupont',
  String? tel = '0700000001',
  String role = 'Gestionnaire',
  bool paye = true,
  String? datePaiement = '2024-01-15T10:00:00',
  String? methodePaiement = 'cash',
  String? referencePaiement = 'REF-001',
  int score = 80,
}) =>
    Membre(
      id: id,
      nom: nom,
      tel: tel,
      role: role,
      paye: paye,
      datePaiement: datePaiement,
      methodePaiement: methodePaiement,
      referencePaiement: referencePaiement,
      score: score,
    );

Tontine _tontineTest({
  String code = 'TEST01',
  String nom = 'Tontine de Test',
  List<Membre>? membres,
  List<MouvementCaisse>? caisse,
  List<Pret>? prets,
  List<JournalEntry>? journal,
  List<Map<String, dynamic>>? historique,
  int tourActuel = 0,
  bool cycleTermine = false,
}) {
  final m = membres ??
      [
        _membre(id: 'm1', nom: 'Alice Dupont', role: 'Gestionnaire'),
        _membre(
            id: 'm2',
            nom: 'Bob Martin',
            role: 'Membre',
            paye: false,
            datePaiement: null,
            methodePaiement: null,
            referencePaiement: null),
        _membre(
            id: 'm3',
            nom: 'Céline Évrard',
            role: 'Membre',
            score: 75,
            datePaiement: '2024-01-16T09:00:00'),
      ];

  final data = TontineData(
    nom: nom,
    montant: 5000,
    periode: 'mensuel',
    methodeOrdre: 'manuel',
    devise: 'XOF',
    tourActuel: tourActuel,
    cycleTermine: cycleTermine,
    gestionnaires: [
      Gestionnaire(nom: 'Alice Dupont', pin: 'hash123'),
    ],
    membres: m,
    caisse: caisse ??
        [
          _mvt(
              id: 'c1',
              type: 'cotisation',
              description: 'Cotisation Alice — Tour 1',
              montant: 5000),
          _mvt(
              id: 'c2',
              type: 'decaissement',
              description: 'Décaissement Tour 1',
              montant: -15000),
        ],
    prets: prets ?? [_pret()],
    journal: journal ??
        [
          _journal(quoi: 'Création de la tontine', quand: '2024-01-01T08:00:00'),
          _journal(
              quoi: 'Cotisation enregistrée — Alice',
              quand: '2024-01-15T10:00:00'),
        ],
    historique: historique ??
        [
          {
            'tour': 1,
            'beneficiaire': 'Alice Dupont',
            'totalRecu': 15000,
            'totalAttendu': 15000,
            'date': '2024-01-31',
          },
        ],
    ordre: ['m1', 'm2', 'm3'],
    paiements: {'m1': true, 'm3': true},
  );

  return Tontine(code: code, data: data);
}

Vote _voteTest({bool clos = true, bool? adopte = true}) => Vote(
      id: 'v1',
      type: 'libre',
      question: 'Augmenter la cotisation à 7500 XOF ?',
      createur: 'Alice Dupont',
      dateCreation: '2024-01-20T10:00:00',
      clos: clos,
      adopte: adopte,
      statut: clos ? 'clos' : 'ouvert',
      dateCloture: clos ? '2024-01-25T18:00:00' : null,
    );

List<Map<String, dynamic>> _voixTest() => [
      {
        'membre_id': 'm1',
        'nom': 'Alice Dupont',
        'choix': 'oui',
        'horodatage': '2024-01-21T09:00:00',
      },
      {
        'membre_id': 'm2',
        'nom': 'Bob Martin',
        'choix': 'non',
        'horodatage': '2024-01-22T11:00:00',
      },
    ];

// ─────────────────────────────────────────────────────────────────────────────
void main() {
  // Initialiser les données de locale intl (requis par Formatters.dateHeure)
  setUpAll(() async {
    await initializeDateFormatting('fr_FR', null);
    await initializeDateFormatting('en_US', null);
    await initializeDateFormatting('ar', null);
  });

  // ── Groupe 1 : _sanitize ──────────────────────────────────────────────────
  group('PdfServiceTestHelper.sanitize', () {
    test('remplace tirets em et en', () {
      final r = PdfServiceTestHelper.sanitize('Coût—Résultat–Final');
      expect(r, contains('-'));
      expect(r, isNot(contains('—')));
      expect(r, isNot(contains('–')));
    });

    test('remplace apostrophes typographiques', () {
      final r = PdfServiceTestHelper.sanitize("L\u2019homme d\u2019affaires");
      expect(r, contains("'"));
      expect(r, isNot(contains('\u2019')));
    });

    test('remplace guillemets français', () {
      final r = PdfServiceTestHelper.sanitize('«Bonjour»');
      expect(r, contains('"'));
    });

    test('remplace lettres accentuées minuscules', () {
      expect(PdfServiceTestHelper.sanitize('àâéèêîùûç'), 'aaeeeiuuc');
    });

    test('remplace lettres accentuées majuscules', () {
      expect(PdfServiceTestHelper.sanitize('ÀÂÉÈÊÎÙÛÇ'), 'AAEEEIUUC');
    });

    test('remplace emojis par ?', () {
      final r = PdfServiceTestHelper.sanitize('Bonjour 🎉 monde');
      expect(r, contains('?'));
      expect(r, isNot(contains('🎉')));
    });

    test('chaîne vide reste vide', () {
      expect(PdfServiceTestHelper.sanitize(''), '');
    });

    test('texte ASCII pur reste inchangé', () {
      const texte = 'Hello World 123 !@#';
      expect(PdfServiceTestHelper.sanitize(texte), texte);
    });

    test('nom africain typique', () {
      expect(
          PdfServiceTestHelper.sanitize('Kéïta Mamadou Sékou'), 'Keita Mamadou Sekou');
    });

    test('tous les accents courants en français', () {
      final r = PdfServiceTestHelper.sanitize('résumé crêpe naïf façon');
      expect(r, 'resume crepe naif facon');
    });
  });

  // ── Groupe 2 : _t (traductions) ───────────────────────────────────────────
  group('PdfServiceTestHelper.t (traductions PDF)', () {
    test('releve_titre en français', () {
      expect(PdfServiceTestHelper.t('releve_titre', 'fr'), 'Relevé de la tontine');
    });

    test('releve_titre en anglais', () {
      expect(PdfServiceTestHelper.t('releve_titre', 'en'), 'Tontine statement');
    });

    test('releve_titre en espagnol', () {
      expect(PdfServiceTestHelper.t('releve_titre', 'es'), 'Estado de la tontina');
    });

    test('releve_titre en portugais', () {
      expect(PdfServiceTestHelper.t('releve_titre', 'pt'), 'Extrato da tontina');
    });

    test('releve_titre en arabe', () {
      expect(PdfServiceTestHelper.t('releve_titre', 'ar'), 'كشف التونتين');
    });

    test('clé inconnue → retourne la clé', () {
      expect(PdfServiceTestHelper.t('cle_xyz_inexistante', 'fr'), 'cle_xyz_inexistante');
    });

    test('langue inconnue → fallback français', () {
      expect(PdfServiceTestHelper.t('releve_titre', 'zh'), 'Relevé de la tontine');
    });

    test('recu_titre en français', () {
      expect(PdfServiceTestHelper.t('recu_titre', 'fr'), 'REÇU DE COTISATION');
    });

    test('recu_titre en anglais', () {
      expect(PdfServiceTestHelper.t('recu_titre', 'en'), 'CONTRIBUTION RECEIPT');
    });

    test('pv_titre en français', () {
      expect(PdfServiceTestHelper.t('pv_titre', 'fr'), 'Procès-verbal de vote');
    });

    test('adopte en français', () {
      expect(PdfServiceTestHelper.t('adopte', 'fr'), 'ADOPTÉ');
    });

    test('rejete en français', () {
      expect(PdfServiceTestHelper.t('rejete', 'fr'), 'REJETÉ');
    });

    test('caisse_titre dans les 4 langues principales', () {
      expect(PdfServiceTestHelper.t('caisse_titre', 'fr'), 'Caisse commune');
      expect(PdfServiceTestHelper.t('caisse_titre', 'en'), 'Common treasury');
      expect(PdfServiceTestHelper.t('caisse_titre', 'es'), 'Caja común');
      expect(PdfServiceTestHelper.t('caisse_titre', 'pt'), 'Caixa comum');
    });

    test('aucun_mouvement en français', () {
      expect(
          PdfServiceTestHelper.t('aucun_mouvement', 'fr'), 'Aucun mouvement enregistré.');
    });
  });

  // ── Groupe 3 : _tx ────────────────────────────────────────────────────────
  group('PdfServiceTestHelper.tx', () {
    test('sanitize=true → applique la sanitisation', () {
      expect(PdfServiceTestHelper.tx('Héllo', true), 'Hello');
    });

    test('sanitize=false → retourne la chaîne inchangée', () {
      expect(PdfServiceTestHelper.tx('Héllo', false), 'Héllo');
    });

    test('chaîne vide → vide dans les 2 modes', () {
      expect(PdfServiceTestHelper.tx('', true), '');
      expect(PdfServiceTestHelper.tx('', false), '');
    });

    test('ASCII pur → identique dans les 2 modes', () {
      const s = 'Hello World';
      expect(PdfServiceTestHelper.tx(s, true), s);
      expect(PdfServiceTestHelper.tx(s, false), s);
    });
  });

  // ── Groupe 4 : Relevé PDF complet ────────────────────────────────────────
  group('PdfServiceTestHelper.genererReleve', () {
    test('génère un PDF non vide avec données complètes', () async {
      final bytes = await PdfServiceTestHelper.genererReleve(
        tontine: _tontineTest(),
        nomGestionnaire: 'Alice Dupont',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
      expect(bytes.length, greaterThan(1000));
    });

    test('commence par la signature PDF (%PDF)', () async {
      final bytes = await PdfServiceTestHelper.genererReleve(
        tontine: _tontineTest(),
        nomGestionnaire: 'Alice',
        langueCode: 'fr',
      );
      final debut = String.fromCharCodes(bytes.take(4));
      expect(debut, '%PDF');
    });

    test('génère PDF avec listes vides (caisse, prêts, journal, historique)', () async {
      final bytes = await PdfServiceTestHelper.genererReleve(
        tontine: _tontineTest(
          caisse: [],
          prets: [],
          journal: [],
          historique: [],
        ),
        nomGestionnaire: 'Alice',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère PDF en anglais', () async {
      final bytes = await PdfServiceTestHelper.genererReleve(
        tontine: _tontineTest(),
        nomGestionnaire: 'Alice',
        langueCode: 'en',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère PDF en arabe', () async {
      final bytes = await PdfServiceTestHelper.genererReleve(
        tontine: _tontineTest(),
        nomGestionnaire: 'Alice',
        langueCode: 'ar',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère PDF avec accents dans les noms', () async {
      final bytes = await PdfServiceTestHelper.genererReleve(
        tontine: _tontineTest(nom: "Tontine Côte d'Ivoire — Abidjan"),
        nomGestionnaire: 'Étienne Ébomé',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère PDF avec cycle terminé', () async {
      final bytes = await PdfServiceTestHelper.genererReleve(
        tontine: _tontineTest(cycleTermine: true, tourActuel: 2),
        nomGestionnaire: 'Alice',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère PDF avec montant décaissement négatif', () async {
      final bytes = await PdfServiceTestHelper.genererReleve(
        tontine: _tontineTest(caisse: [
          _mvt(
              id: 'c_neg',
              type: 'decaissement',
              montant: -25000,
              description: 'Décaissement Tour 3'),
        ]),
        nomGestionnaire: 'Alice',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère PDF avec historique — bénéficiaireId inconnu', () async {
      final bytes = await PdfServiceTestHelper.genererReleve(
        tontine: _tontineTest(historique: [
          {
            'tour': 1,
            'beneficiaireId': 'id_introuvable',
            'totalRecu': 5000,
            'totalAttendu': 5000,
          },
        ]),
        nomGestionnaire: 'Alice',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère PDF avec 20 membres', () async {
      final membres = List.generate(
        20,
        (i) => _membre(
          id: 'm$i',
          nom: 'Membre Numéro $i',
          role: 'Membre',
          paye: i.isEven,
          datePaiement: i.isEven ? '2024-01-${10 + i % 10}T08:00:00' : null,
          methodePaiement: i.isEven ? 'cash' : null,
          referencePaiement: i.isEven ? 'REF-$i' : null,
        ),
      );
      final bytes = await PdfServiceTestHelper.genererReleve(
        tontine: _tontineTest(membres: membres),
        nomGestionnaire: 'Admin',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère PDF avec nom contenant des emojis (sanitization)', () async {
      final bytes = await PdfServiceTestHelper.genererReleve(
        tontine: _tontineTest(nom: '🎉 Tontine Solidarité 🌍'),
        nomGestionnaire: '🌟 Alice',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });
  });

  // ── Groupe 5 : PV de vote ─────────────────────────────────────────────────
  group('PdfServiceTestHelper.genererPvVote', () {
    test('génère PV vote adopté', () async {
      final bytes = await PdfServiceTestHelper.genererPvVote(
        tontine: _tontineTest(),
        vote: _voteTest(clos: true, adopte: true),
        voixDetaillees: _voixTest(),
        nomGestionnaire: 'Alice Dupont',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('commence par %PDF', () async {
      final bytes = await PdfServiceTestHelper.genererPvVote(
        tontine: _tontineTest(),
        vote: _voteTest(),
        voixDetaillees: _voixTest(),
        nomGestionnaire: 'Alice',
        langueCode: 'fr',
      );
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('génère PV vote rejeté', () async {
      final bytes = await PdfServiceTestHelper.genererPvVote(
        tontine: _tontineTest(),
        vote: _voteTest(clos: true, adopte: false),
        voixDetaillees: _voixTest(),
        nomGestionnaire: 'Alice',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère PV sans voix (aucun votant)', () async {
      final bytes = await PdfServiceTestHelper.genererPvVote(
        tontine: _tontineTest(),
        vote: _voteTest(clos: true, adopte: null),
        voixDetaillees: [],
        nomGestionnaire: 'Alice',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère PV vote non clôturé', () async {
      final bytes = await PdfServiceTestHelper.genererPvVote(
        tontine: _tontineTest(),
        vote: _voteTest(clos: false, adopte: null),
        voixDetaillees: _voixTest(),
        nomGestionnaire: 'Alice',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère PV en anglais', () async {
      final bytes = await PdfServiceTestHelper.genererPvVote(
        tontine: _tontineTest(),
        vote: _voteTest(),
        voixDetaillees: _voixTest(),
        nomGestionnaire: 'Alice',
        langueCode: 'en',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère PV avec votes mixtes (oui/non/abstention)', () async {
      final voix = [
        {'membre_id': 'm1', 'nom': 'Alice', 'choix': 'oui', 'horodatage': '2024-01-21T09:00:00'},
        {'membre_id': 'm2', 'nom': 'Bob', 'choix': 'non', 'horodatage': '2024-01-21T10:00:00'},
        {'membre_id': 'm3', 'nom': 'Céline', 'choix': 'abstention', 'horodatage': '2024-01-21T11:00:00'},
      ];
      final bytes = await PdfServiceTestHelper.genererPvVote(
        tontine: _tontineTest(),
        vote: _voteTest(),
        voixDetaillees: voix,
        nomGestionnaire: 'Alice',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });
  });

  // ── Groupe 6 : Reçu de cotisation ────────────────────────────────────────
  group('PdfServiceTestHelper.genererRecuCotisation', () {
    test('génère reçu standard', () async {
      final tontine = _tontineTest();
      final bytes = await PdfServiceTestHelper.genererRecuCotisation(
        tontine: tontine,
        membre: tontine.data.membres.first,
        ref: 'REF-TEST-001',
        methode: 'cash',
        dateStr: '2024-01-15T10:00:00',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('commence par %PDF', () async {
      final tontine = _tontineTest();
      final bytes = await PdfServiceTestHelper.genererRecuCotisation(
        tontine: tontine,
        membre: tontine.data.membres.first,
        ref: 'REF-001',
        methode: 'cash',
        dateStr: '2024-01-15T10:00:00',
        langueCode: 'fr',
      );
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('génère reçu avec mobile money', () async {
      final tontine = _tontineTest();
      final bytes = await PdfServiceTestHelper.genererRecuCotisation(
        tontine: tontine,
        membre: _membre(
            id: 'm_mm',
            nom: 'Sékou Traoré',
            methodePaiement: 'orange_money',
            referencePaiement: 'OM-XYZ-789'),
        ref: 'OM-XYZ-789',
        methode: 'Orange Money',
        dateStr: '2024-02-01T09:30:00',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère reçu sans date (dateStr vide)', () async {
      final tontine = _tontineTest();
      final bytes = await PdfServiceTestHelper.genererRecuCotisation(
        tontine: tontine,
        membre: tontine.data.membres.first,
        ref: 'REF-NODATE',
        methode: 'especes',
        dateStr: '',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère reçu en anglais', () async {
      final tontine = _tontineTest();
      final bytes = await PdfServiceTestHelper.genererRecuCotisation(
        tontine: tontine,
        membre: tontine.data.membres.first,
        ref: 'REF-EN-001',
        methode: 'cash',
        dateStr: '2024-01-15T10:00:00',
        langueCode: 'en',
      );
      expect(bytes, isNotEmpty);
    });

    test('génère reçu avec accents dans le nom du membre', () async {
      final tontine = _tontineTest();
      final bytes = await PdfServiceTestHelper.genererRecuCotisation(
        tontine: tontine,
        membre: _membre(id: 'm_acc', nom: 'Étienne Ébomé Ndoré'),
        ref: 'REF-ACC',
        methode: 'Wave',
        dateStr: '2024-03-05T14:00:00',
        langueCode: 'fr',
      );
      expect(bytes, isNotEmpty);
    });
  });
}
