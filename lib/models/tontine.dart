// ─────────────────────────────────────────────────────────────────────────────
// Modèles alignés sur le format JSON réel stocké dans Supabase (champ `data`).
// Vérifié contre la réponse brute de lire_tontine('D4CQZZ').
// ─────────────────────────────────────────────────────────────────────────────

class Gestionnaire {
  final String nom;
  final String pin; // uniquement côté création locale, jamais retourné par lire_tontine

  Gestionnaire({required this.nom, required this.pin});

  factory Gestionnaire.fromJson(Map<String, dynamic> json) {
    return Gestionnaire(
      nom: json['nom'] as String? ?? '',
      pin: json['pin'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'nom': nom, 'pin': pin};
}

class Membre {
  final String id;
  final String nom;
  final String? tel;
  final String? role;
  bool paye;             // calculé localement depuis paiements{}, pas stocké dans membres[]
  String? datePaiement;
  String? methodePaiement;
  String? referencePaiement;
  int score;
  String? pinVote;

  Membre({
    required this.id,
    required this.nom,
    this.tel,
    this.role,
    this.paye = false,
    this.datePaiement,
    this.methodePaiement,
    this.referencePaiement,
    this.score = 50,
    this.pinVote,
  });

  factory Membre.fromJson(Map<String, dynamic> json) {
    return Membre(
      id: json['id'] as String? ?? '',
      nom: json['nom'] as String? ?? '',
      tel: json['tel'] as String?,
      role: json['role'] as String?,
      // 'paye' n'est pas dans les membres[] de Supabase — calculé depuis paiements{}
      paye: json['paye'] as bool? ?? false,
      datePaiement: json['datePaiement'] as String?,
      methodePaiement: json['methodePaiement'] as String?,
      referencePaiement: json['referencePaiement'] as String?,
      score: (json['score'] as num?)?.toInt() ?? 50,
      pinVote: json['pinVote'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'nom': nom,
        if (tel != null) 'tel': tel,
        if (role != null) 'role': role,
        'paye': paye,
        if (datePaiement != null) 'datePaiement': datePaiement,
        if (methodePaiement != null) 'methodePaiement': methodePaiement,
        if (referencePaiement != null) 'referencePaiement': referencePaiement,
        'score': score,
        if (pinVote != null) 'pinVote': pinVote,
      };
}

// ─── Mouvement de caisse ──────────────────────────────────────────────────────
// Format réel : {id, le (timestamp ms), par, type, motif, montant, membreId?}
class MouvementCaisse {
  final String id;
  final String type;      // 'depot','pret','remboursement','penalite','correction','depense'
  final int montant;      // peut être négatif pour pret/depense/correction
  final String description; // = motif dans le JSON
  final String gestionnaire; // = par dans le JSON
  final String date;        // = le (timestamp ms) converti en chaîne
  final String reference;

  MouvementCaisse({
    required this.id,
    required this.type,
    required this.montant,
    required this.description,
    required this.gestionnaire,
    required this.date,
    required this.reference,
  });

  factory MouvementCaisse.fromJson(Map<String, dynamic> json) {
    // Support des deux formats : ancien (date string) et nouveau (le timestamp ms)
    final leRaw = json['le'];
    String dateStr;
    if (leRaw is int) {
      dateStr = DateTime.fromMillisecondsSinceEpoch(leRaw).toIso8601String();
    } else if (leRaw is String) {
      dateStr = leRaw;
    } else {
      dateStr = json['date'] as String? ?? '';
    }

    return MouvementCaisse(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? '',
      montant: (json['montant'] as num?)?.toInt() ?? 0,
      description: json['motif'] as String? ?? json['description'] as String? ?? '',
      gestionnaire: json['par'] as String? ?? json['gestionnaire'] as String? ?? '',
      date: dateStr,
      reference: json['recu'] as String? ?? json['reference'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'montant': montant,
        'description': description,
        'gestionnaire': gestionnaire,
        'date': date,
        'reference': reference,
      };
}

// ─── Remboursement de prêt ────────────────────────────────────────────────────
// Format réel : {id, le, par, date, note, recu, methode, montant}
class Remboursement {
  final String id;
  final int montant;
  final String date;
  final String methode;
  final String reference;

  Remboursement({
    required this.id,
    required this.montant,
    required this.date,
    required this.methode,
    required this.reference,
  });

  factory Remboursement.fromJson(Map<String, dynamic> json) {
    final leRaw = json['le'];
    String dateStr;
    if (leRaw is int) {
      dateStr = DateTime.fromMillisecondsSinceEpoch(leRaw).toIso8601String();
    } else {
      dateStr = json['date'] as String? ?? '';
    }
    return Remboursement(
      id: json['id'] as String? ?? '',
      montant: (json['montant'] as num?)?.toInt() ?? 0,
      date: dateStr,
      methode: json['methode'] as String? ?? '',
      reference: json['recu'] as String? ?? json['reference'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'montant': montant,
        'date': date,
        'methode': methode,
        'reference': reference,
      };
}

// ─── Prêt ─────────────────────────────────────────────────────────────────────
// Format réel : {id, le, taux, duree, statut, montant, soldeLe?, totalDu,
//                membreId, echeances[], accordePar, remboursements[]}
class Pret {
  final String id;
  final String emprunteurId;    // = membreId
  final String emprunteurNom;   // résolu depuis membres[]
  final int montant;
  final double taux;
  final int dureesMois;         // = duree
  final String dateDebut;       // = le (timestamp ms)
  final List<Remboursement> remboursements;
  final List<Map<String, dynamic>> echeancier; // = echeances[]
  final String gestionnaire;    // = accordePar
  final String reference;
  final String statut;          // 'en cours', 'soldé', etc.

  Pret({
    required this.id,
    required this.emprunteurId,
    required this.emprunteurNom,
    required this.montant,
    required this.taux,
    required this.dureesMois,
    required this.dateDebut,
    required this.remboursements,
    required this.echeancier,
    required this.gestionnaire,
    required this.reference,
    this.statut = 'en cours',
  });

  int get totalRembourse =>
      remboursements.fold(0, (sum, r) => sum + r.montant);

  int get totalDu {
    // Formule de la fiche : totalDu = montant × (1 + taux/100)
    // (intérêt total fixe, pas proratisé sur la durée)
    final interet = (montant * taux / 100).round();
    return montant + interet;
  }

  int get resteADu => totalDu - totalRembourse;

  String get statutCalcule {
    // Priorité au statut stocké dans Supabase
    if (statut == 'soldé' || statut == 'solde') return 'solde';
    if (resteADu <= 0) return 'solde';
    if (totalRembourse == 0) return 'en_cours';
    final dateD = DateTime.tryParse(dateDebut);
    if (dateD != null) {
      final moisEcoules = DateTime.now().difference(dateD).inDays ~/ 30;
      if (moisEcoules >= dureesMois && resteADu > 0) return 'retard';
    }
    return 'partiel';
  }

  factory Pret.fromJson(Map<String, dynamic> json) {
    // Conversion du timestamp `le` en date ISO
    final leRaw = json['le'];
    String dateDebut;
    if (leRaw is int) {
      dateDebut = DateTime.fromMillisecondsSinceEpoch(leRaw).toIso8601String();
    } else {
      dateDebut = json['dateDebut'] as String? ?? '';
    }

    // echeances → echeancier
    final echeancesRaw = json['echeances'] as List<dynamic>?
        ?? json['echeancier'] as List<dynamic>?
        ?? [];
    final echeancier = echeancesRaw.map((e) {
      if (e is Map<String, dynamic>) return e;
      return <String, dynamic>{};
    }).toList();

    return Pret(
      id: json['id'] as String? ?? '',
      emprunteurId: json['membreId'] as String? ?? json['emprunteurId'] as String? ?? '',
      emprunteurNom: json['emprunteurNom'] as String? ?? '',
      montant: (json['montant'] as num?)?.toInt() ?? 0,
      taux: (json['taux'] as num?)?.toDouble() ?? 0,
      dureesMois: (json['duree'] as num?)?.toInt()
          ?? (json['dureesMois'] as num?)?.toInt()
          ?? 1,
      dateDebut: dateDebut,
      remboursements: (json['remboursements'] as List<dynamic>?)
              ?.map((r) => Remboursement.fromJson(r as Map<String, dynamic>))
              .toList() ??
          [],
      echeancier: echeancier,
      gestionnaire: json['accordePar'] as String? ?? json['gestionnaire'] as String? ?? '',
      reference: json['recu'] as String? ?? json['reference'] as String? ?? '',
      statut: json['statut'] as String? ?? 'en cours',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'emprunteurId': emprunteurId,
        'emprunteurNom': emprunteurNom,
        'montant': montant,
        'taux': taux,
        'dureesMois': dureesMois,
        'dateDebut': dateDebut,
        'remboursements': remboursements.map((r) => r.toJson()).toList(),
        'echeancier': echeancier,
        'gestionnaire': gestionnaire,
        'reference': reference,
        'statut': statut,
      };
}

// ─── Vote ─────────────────────────────────────────────────────────────────────
// Format réel : {id, le, mode?, type?, voix{}, sujet, statut:'ouvert'/'clos',
//                creePar, closLe?, resultat?, description, decompte?, candidat?}
class Vote {
  final String id;
  final String type;
  final String question;    // = sujet
  final String createur;    // = creePar
  final String dateCreation; // = le (timestamp)
  bool clos;                // = (statut == 'clos')
  bool? adopte;             // true/false/null selon résultat du vote clos
  String statut;            // 'ouvert' ou 'clos'
  String? dateCloture;
  String? nouveauMembreNom;
  String? ancienOrdreId;
  Map<String, dynamic>? decompte;
  Map<String, dynamic>? candidat;
  String? resultat;
  String? description;
  String? mode;             // 'securise' ou absent
  Map<String, dynamic> voix; // {membreId: choix} pour ancien format

  Vote({
    required this.id,
    required this.type,
    required this.question,
    required this.createur,
    required this.dateCreation,
    this.clos = false,
    this.adopte,
    this.statut = 'ouvert',
    this.dateCloture,
    this.nouveauMembreNom,
    this.ancienOrdreId,
    this.decompte,
    this.candidat,
    this.resultat,
    this.description,
    this.mode,
    this.voix = const {},
  });

  factory Vote.fromJson(Map<String, dynamic> json) {
    // Statut : Supabase stocke 'ouvert'/'clos' OU bool clos:true
    final closBool = json['clos'] as bool? ?? false;
    final statut = json['statut'] as String?
        ?? (closBool ? 'clos' : 'ouvert');
    final leRaw = json['le'];
    String dateCreation;
    if (leRaw is int) {
      dateCreation = DateTime.fromMillisecondsSinceEpoch(leRaw).toIso8601String();
    } else {
      dateCreation = json['dateCreation'] as String?
          ?? (leRaw as String? ?? '');
    }

    // closLe timestamp → string
    String? dateCloture;
    final closLeRaw = json['closLe'];
    if (closLeRaw is int) {
      dateCloture = DateTime.fromMillisecondsSinceEpoch(closLeRaw).toIso8601String();
    } else if (closLeRaw is String) {
      dateCloture = closLeRaw;
    } else {
      dateCloture = json['dateCloture'] as String?;
    }

    // voix : peut être Map<String, dynamic> ou absent
    final voixRaw = json['voix'];
    Map<String, dynamic> voix = {};
    if (voixRaw is Map) {
      voix = Map<String, dynamic>.from(voixRaw);
    }

    // candidat : peut contenir le nom du nouveau membre (admission)
    final candidatRaw = json['candidat'] as Map<String, dynamic>?;
    final nouveauMembreNomResolu = json['nouveauMembreNom'] as String?
        ?? candidatRaw?['nom'] as String?;

    return Vote(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'libre',
      question: json['sujet'] as String? ?? json['question'] as String? ?? '',
      createur: json['creePar'] as String? ?? json['createur'] as String? ?? '',
      dateCreation: dateCreation,
      clos: statut == 'clos' || closBool,
      adopte: json['adopte'] as bool?,
      statut: statut,
      dateCloture: dateCloture,
      nouveauMembreNom: nouveauMembreNomResolu,
      ancienOrdreId: json['ancienOrdreId'] as String?,
      decompte: json['decompte'] as Map<String, dynamic>?,
      candidat: json['candidat'] as Map<String, dynamic>?,
      resultat: json['resultat'] as String?,
      description: json['description'] as String?,
      mode: json['mode'] as String?,
      voix: voix,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'sujet': question,
        'question': question,          // compatibilité double clé
        'creePar': createur,
        'createur': createur,          // compatibilité double clé
        'le': dateCreation,
        'dateCreation': dateCreation,  // compatibilité double clé
        'statut': clos ? 'clos' : 'ouvert',
        'clos': clos,
        if (adopte != null) 'adopte': adopte,
        if (dateCloture != null) 'dateCloture': dateCloture,
        if (dateCloture != null) 'closLe': dateCloture,
        if (nouveauMembreNom != null) 'nouveauMembreNom': nouveauMembreNom,
        if (ancienOrdreId != null) 'ancienOrdreId': ancienOrdreId,
        if (decompte != null) 'decompte': decompte,
        if (candidat != null) 'candidat': candidat,
        if (resultat != null) 'resultat': resultat,
        if (description != null) 'description': description,
        if (mode != null) 'mode': mode,
        'voix': voix,
      };
}

// ─── Journal ──────────────────────────────────────────────────────────────────
// Format réel : {le (timestamp ms), par, quoi}
class JournalEntry {
  final String quoi;
  final String gestionnaire; // = par
  final String quand;        // = le converti
  final String? reference;

  JournalEntry({
    required this.quoi,
    required this.gestionnaire,
    required this.quand,
    this.reference,
  });

  factory JournalEntry.fromJson(Map<String, dynamic> json) {
    // Supporte les deux formats : {le, par, quoi} et {quand, gestionnaire, quoi}
    final leRaw = json['le'];
    String quand;
    if (leRaw is int) {
      quand = DateTime.fromMillisecondsSinceEpoch(leRaw).toIso8601String();
    } else if (leRaw is String) {
      quand = leRaw;
    } else {
      quand = json['quand'] as String? ?? '';
    }
    return JournalEntry(
      quoi: json['quoi'] as String? ?? '',
      gestionnaire: json['par'] as String? ?? json['gestionnaire'] as String? ?? '',
      quand: quand,
      reference: json['reference'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'quoi': quoi,
        'gestionnaire': gestionnaire,
        'quand': quand,
        if (reference != null) 'reference': reference,
      };
}

// ─── TontineData ──────────────────────────────────────────────────────────────
// Parseur du champ `data` jsonb retourné par lire_tontine().
// Format réel vérifié contre D4CQZZ et index.html de référence.
//
// ⚠️  CONVENTION CRITIQUE (alignée sur index.html) :
//   • tourActuel  = INDEX 0-based dans ordre[]  (jamais un numéro humain)
//   • numérTour   = tourActuel + 1              (affiché à l'utilisateur)
//   • beneficiaire = membres[ ordre[tourActuel] ]
//   • cycleTermine = bool stocké dans Supabase (ou tourActuel >= ordre.length)
//
// Les deux informations suivantes sont TOTALEMENT INDÉPENDANTES :
//   1. isBeneficiaire(membreId) → ordre[tourActuel] == membreId
//   2. aPaye(membreId)          → paiements[membreId] existe
class TontineData {
  final String nom;
  final int montant;
  final String periode;     // = periodicite ('hebdo', 'mensuel', etc.)
  final String methodeOrdre;
  String? echeance;

  /// INDEX 0-based dans ordre[] — jamais afficher directement.
  /// Numéro humain = tourActuel + 1
  int tourActuel;

  /// true quand tous les membres ont été servis
  bool cycleTermine;

  bool tirageVerrouille;    // = ordreVerrouille ou ordreMeta.verrouille
  List<Gestionnaire> gestionnaires; // liste de noms seulement dans data (sans PIN)
  List<Membre> membres;
  List<MouvementCaisse> caisse;  // extrait de caisse.mouvements[]
  List<Pret> prets;
  List<Vote> votes;
  List<JournalEntry> journal;
  List<String> ordre;            // ordre de passage des membres (IDs)
  Map<String, dynamic> paiements; // paiements du tour courant {membreId: {...}}
  List<Map<String, dynamic>> historique; // historique des tours
  Map<String, dynamic> stats;    // stats par membre

  TontineData({
    required this.nom,
    required this.montant,
    required this.periode,
    required this.methodeOrdre,
    this.echeance,
    this.tourActuel = 0,
    this.cycleTermine = false,
    this.tirageVerrouille = false,
    required this.gestionnaires,
    required this.membres,
    this.caisse = const [],
    this.prets = const [],
    this.votes = const [],
    this.journal = const [],
    this.ordre = const [],
    this.paiements = const {},
    this.historique = const [],
    this.stats = const {},
  });

  // ── Accesseurs calculés ────────────────────────────────────────────────────

  /// Numéro de tour affiché à l'utilisateur (1-based)
  int get numerTour => tourActuel + 1;

  /// ID du bénéficiaire courant (null si cycle terminé ou ordre vide)
  String? get beneficiaireId {
    if (cycleTermine || ordre.isEmpty || tourActuel >= ordre.length) return null;
    return ordre[tourActuel];
  }

  /// Bénéficiaire courant (null si cycle terminé ou ordre vide)
  Membre? get beneficiaire {
    final id = beneficiaireId;
    if (id == null) return null;
    try {
      return membres.firstWhere((m) => m.id == id);
    } catch (_) {
      return null;
    }
  }

  /// true si le membre donné est le bénéficiaire de ce tour
  bool isBeneficiaire(String membreId) => beneficiaireId == membreId;

  /// Nombre de membres qui ont payé (selon paiements{} — source de vérité)
  int get nbPayes => membres.where((m) => m.paye).length;

  int get soldeCaisse {
    int total = 0;
    for (final m in caisse) {
      // Les montants sont toujours positifs dans la DB.
      // On détermine le signe selon le type de mouvement.
      switch (m.type) {
        case 'apport':
        case 'cotisation':
        case 'depot':
        case 'remboursement':
        case 'penalite':
          total += m.montant.abs();
        case 'depense':
        case 'pret':
        case 'retrait':
        case 'correction':
          total -= m.montant.abs();
        default:
          // Montant déjà signé (ancien format)
          total += m.montant;
      }
    }
    return total;
  }

  // Rétrocompatibilité : certains widgets utilisaient tourCourant (1-based).
  // Désormais on expose tourActuel (0-based) + numerTour (1-based).
  // Ne plus utiliser tourCourant — remplacé par tourActuel / numerTour.

  factory TontineData.fromJson(Map<String, dynamic> json) {
    // ── Gestionnaires ──
    List<Gestionnaire> gests = [];
    final gestsRaw = json['gestionnaires'];
    if (gestsRaw is List) {
      for (final g in gestsRaw) {
        if (g is String) {
          gests.add(Gestionnaire(nom: g, pin: ''));
        } else if (g is Map<String, dynamic>) {
          gests.add(Gestionnaire.fromJson(g));
        }
      }
    }

    // ── Membres ──
    final membres = (json['membres'] as List<dynamic>?)
            ?.map((m) => Membre.fromJson(m as Map<String, dynamic>))
            .toList() ??
        [];

    // ── Caisse ──
    List<MouvementCaisse> caisse = [];
    final caisseRaw = json['caisse'];
    if (caisseRaw is Map<String, dynamic>) {
      final mouvements = caisseRaw['mouvements'] as List<dynamic>? ?? [];
      caisse = mouvements
          .map((m) => MouvementCaisse.fromJson(m as Map<String, dynamic>))
          .toList();
    } else if (caisseRaw is List) {
      caisse = caisseRaw
          .map((m) => MouvementCaisse.fromJson(m as Map<String, dynamic>))
          .toList();
    }

    // ── Prêts ──
    final prets = (json['prets'] as List<dynamic>?)
            ?.map((p) => Pret.fromJson(p as Map<String, dynamic>))
            .toList() ??
        [];

    // ── Résoudre les noms des emprunteurs ──
    // La résolution est différée : l'UI accède aux noms via membres[].
    // (La map locale n'est pas utilisée ici pour éviter un warning lint.)

    // ── Votes ──
    final votes = (json['votes'] as List<dynamic>?)
            ?.map((v) => Vote.fromJson(v as Map<String, dynamic>))
            .toList() ??
        [];

    // ── Journal ──
    final journal = (json['journal'] as List<dynamic>?)
            ?.map((j) => JournalEntry.fromJson(j as Map<String, dynamic>))
            .toList() ??
        [];

    // ── Ordre ──
    final ordreRaw = json['ordre'] as List<dynamic>?;
    final ordre = ordreRaw?.map((e) => e.toString()).toList() ?? [];

    // ── Paiements ──
    final paiements = json['paiements'] as Map<String, dynamic>? ?? {};

    // ── Historique ──
    final historique = (json['historique'] as List<dynamic>?)
            ?.map((h) => h as Map<String, dynamic>)
            .toList() ??
        [];

    // ── Stats ──
    final stats = json['stats'] as Map<String, dynamic>? ?? {};

    // ── tourActuel : INDEX 0-based (aligné sur index.html) ────────────────
    // Supabase stocke 'tourActuel' comme index 0-based dans ordre[].
    // Ancien format Flutter stockait 'tourCourant' comme numéro 1-based.
    // → On lit 'tourActuel' en priorité (0-based direct).
    // → Si absent, on lit 'tourCourant' et on soustrait 1 pour revenir à 0-based.
    int tourActuel;
    if (json.containsKey('tourActuel')) {
      tourActuel = (json['tourActuel'] as num?)?.toInt() ?? 0;
    } else if (json.containsKey('tourCourant')) {
      // Format local ancien : tourCourant était 1-based → convertir en 0-based
      final tc = (json['tourCourant'] as num?)?.toInt() ?? 1;
      tourActuel = (tc - 1).clamp(0, ordre.isNotEmpty ? ordre.length - 1 : 0);
    } else {
      tourActuel = 0;
    }

    // ── cycleTermine ──────────────────────────────────────────────────────
    final cycleTermine = json['cycleTermine'] as bool?
        ?? (ordre.isNotEmpty && tourActuel >= ordre.length);

    // ── tirageVerrouille ──────────────────────────────────────────────────
    bool tirageVerrouille = false;
    final ordreMeta = json['ordreMeta'] as Map<String, dynamic>?;
    if (ordreMeta != null) {
      tirageVerrouille = ordreMeta['verrouille'] as bool? ?? false;
    }
    tirageVerrouille = json['ordreVerrouille'] as bool? ?? tirageVerrouille;

    // ── Périodicité ──────────────────────────────────────────────────────
    final periode = json['periodicite'] as String?
        ?? json['periode'] as String?
        ?? 'mensuel';

    // ── RÉCONCILIATION paye : paiements{} → membres[].paye ───────────────
    //
    // SOURCE DE VÉRITÉ (alignée sur index.html) :
    //   Un membre a payé  ⟺  paiements[son_id] existe
    //   Ces deux états sont INDÉPENDANTS : bénéficiaire et paye
    //
    // Supabase ne stocke JAMAIS membres[].paye — toujours null en retour.
    // On reconstitue depuis paiements{} (clés = IDs des membres ayant payé).
    //
    // Fallback (tour déjà clôturé → paiements{} vidé) :
    //   historique[tour == numerTour].payesIds conserve les IDs du dernier tour.
    //   numerTour = tourActuel + 1 AVANT la clôture, donc l'entrée dans historique
    //   porte h['tour'] == tourActuel + 1 (numéro humain du tour clôturé).
    //   Après clôture Supabase fait tourActuel++ → le tour suivant démarre.
    //   Le fallback doit chercher historique[tour == tourActuel] (le tour PRÉCÉDENT
    //   après l'incrément, mais qui était numerTour avant → h['tour'] == tourActuel).
    //
    //   Exemple D4CQZZ : tourActuel=3 après clôture du tour 3 (Monique).
    //   historique[0].tour = 3. Après clôture tourActuel aurait dû être 3 (index),
    //   mais Supabase stocke tourActuel = index du PROCHAIN tour.
    //   Cas particulier : paiements{} vide + historique le plus récent
    //   correspond au tour PRÉCÉDENT (tourActuel - 1 en numéro humain).
    //   → On cherche historique[tour == tourActuel] car tourActuel (index 0-based)
    //     coïncide avec le numéro humain du dernier tour clôturé quand Supabase
    //     stocke tourActuel APRÈS incrément.
    final idsPayesTourCourant = <String>{};

    // Source 1 : paiements{} — source principale (tour en cours, non clôturé)
    idsPayesTourCourant.addAll(paiements.keys);

    // Source 2 : fallback historique (tour clôturé → paiements{} vidé)
    // Le tour le plus récent dans historique est historique[0] (unshift).
    // Son champ 'tour' est le numéro humain (1-based) du tour clôturé.
    // Après clôture du tour N (humain), tourActuel passe à N (index 0-based)
    // car tourActuel++ depuis l'index N-1.
    // Donc historique[0].tour == tourActuel (0-based index == numéro humain
    // du tour clôturé, par coïncidence pour les petits N).
    // On cherche le tour le plus récent (historique[0]) sans se fier au numéro.
    if (idsPayesTourCourant.isEmpty && historique.isNotEmpty) {
      // Le plus récent tour clôturé est historique[0] (insertion en tête)
      final dernierTour = historique[0];
      final payesIds = dernierTour['payesIds'] as List<dynamic>?;
      if (payesIds != null) {
        idsPayesTourCourant.addAll(payesIds.map((e) => e.toString()));
      }
    }

    // Appliquer aux membres
    for (final m in membres) {
      if (idsPayesTourCourant.isNotEmpty) {
        m.paye = idsPayesTourCourant.contains(m.id);
      }
    }
    // ── Fin réconciliation ──────────────────────────────────────────────────

    return TontineData(
      nom: json['nom'] as String? ?? '',
      montant: (json['montant'] as num?)?.toInt() ?? 0,
      periode: periode,
      methodeOrdre: json['methodeOrdre'] as String? ?? 'rotation',
      echeance: json['echeance'] as String?,
      tourActuel: tourActuel,
      cycleTermine: cycleTermine,
      tirageVerrouille: tirageVerrouille,
      gestionnaires: gests,
      membres: membres,
      caisse: caisse,
      prets: prets,
      votes: votes,
      journal: journal,
      ordre: ordre,
      paiements: paiements,
      historique: historique,
      stats: stats,
    );
  }

  Map<String, dynamic> toJson() => {
        'nom': nom,
        'montant': montant,
        'periodicite': periode,
        'methodeOrdre': methodeOrdre,
        if (echeance != null) 'echeance': echeance,
        // Supabase attend 'tourActuel' (index 0-based)
        'tourActuel': tourActuel,
        'cycleTermine': cycleTermine,
        'ordreVerrouille': tirageVerrouille,
        'ordreMeta': {'verrouille': tirageVerrouille, 'methode': methodeOrdre, 'tirage': null},
        'gestionnaires': gestionnaires.map((g) => g.nom).toList(),
        'membres': membres.map((m) => m.toJson()).toList(),
        'caisse': {'mouvements': caisse.map((c) => c.toJson()).toList()},
        'prets': prets.map((p) => p.toJson()).toList(),
        'votes': votes.map((v) => v.toJson()).toList(),
        'journal': journal.map((j) => j.toJson()).toList(),
        'ordre': ordre,
        'paiements': paiements,
        'historique': historique,
        'stats': stats,
      };
}

// ─── Tontine (enveloppe locale) ───────────────────────────────────────────────
class Tontine {
  final String code;
  TontineData data;
  String plan;
  DateTime? planExpire;

  Tontine({
    required this.code,
    required this.data,
    this.plan = 'free',
    this.planExpire,
  });

  bool get isPremium {
    if (plan != 'premium') return false;
    if (planExpire == null) return true;
    return planExpire!.isAfter(DateTime.now());
  }
}

// ─── TontineLocale (liste mémorisée sur l'appareil) ──────────────────────────
class TontineLocale {
  final String code;
  final String nom;

  TontineLocale({required this.code, required this.nom});

  factory TontineLocale.fromJson(Map<String, dynamic> json) {
    return TontineLocale(
      code: json['code'] as String? ?? '',
      nom: json['nom'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'code': code, 'nom': nom};
}
