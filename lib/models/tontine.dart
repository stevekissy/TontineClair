// ─────────────────────────────────────────────────────────────────────────────
// Modèles alignés sur le format JSON réel stocké dans Supabase (champ `data`).
// Vérifié contre la réponse brute de lire_tontine('D4CQZZ').
// ─────────────────────────────────────────────────────────────────────────────

// ignore: unused_import — utilisé via EcheanceService dans les getters de TontineData
// (import circulaire évité : EcheanceService n'importe pas tontine.dart)

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

  // ── Score Override : score forcé manuellement par un admin ──────────────────
  // Quand scoreOverride != null, ScoreService l'utilise DIRECTEMENT au lieu
  // de recalculer depuis data.stats[]. Cela garantit que la modification
  // manuelle persiste sur toutes les interfaces (liste, fiche, classement, IA).
  int? scoreOverride;    // null = score calculé automatiquement
  String? motifOverride; // raison de la modification manuelle
  String? dateOverride;  // ISO 8601 de la modification
  String? adminOverride; // nom du gestionnaire ayant modifié

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
    this.scoreOverride,
    this.motifOverride,
    this.dateOverride,
    this.adminOverride,
  });

  /// Score effectif : scoreOverride s'il existe, sinon score calculé.
  /// C'est cette valeur que ScoreService et toutes les interfaces doivent utiliser.
  int get scoreEffectif => scoreOverride ?? score;

  /// true si ce membre a un score forcé manuellement
  bool get aScoreOverride => scoreOverride != null;

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
      // Champs override (écrits par modifier_score_membre RPC)
      scoreOverride: (json['scoreOverride'] as num?)?.toInt(),
      motifOverride: json['motifOverride'] as String?,
      dateOverride:  json['dateOverride']  as String?,
      adminOverride: json['adminOverride'] as String?,
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
        // Champs override : inclus seulement si présents
        if (scoreOverride != null) 'scoreOverride': scoreOverride,
        if (motifOverride != null) 'motifOverride': motifOverride,
        if (dateOverride  != null) 'dateOverride':  dateOverride,
        if (adminOverride != null) 'adminOverride': adminOverride,
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

  /// true quand tous les membres ont été servis (cycle réellement terminé)
  bool cycleTermine;

  /// true si la tontine a été créée mais n'a pas encore démarré (ordre vide, cycleTermine false).
  /// DIFFÉRENT de cycleTermine : une tontine en attente n'est PAS terminée, elle n'a jamais commencé.
  bool get cycleEnAttente => ordre.isEmpty && !cycleTermine;

  /// true si le cycle est actif (a démarré et n'est pas encore terminé)
  bool get cycleActif => ordre.isNotEmpty && !cycleTermine;

  /// Numéro du cycle courant (1-based, incrémenté à chaque nouveau cycle)
  int cycleNumero;

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
  List<Map<String, dynamic>> cyclesArchives; // archives des anciens cycles
  Map<String, dynamic> stats;    // stats par membre

  TontineData({
    required this.nom,
    required this.montant,
    required this.periode,
    required this.methodeOrdre,
    this.echeance,
    this.tourActuel = 0,
    this.cycleTermine = false,
    this.cycleNumero = 1,
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
    this.cyclesArchives = const [],
    this.stats = const {},
  });

  // ── Accesseurs calculés ────────────────────────────────────────────────────

  /// Numéro de tour affiché à l'utilisateur (1-based)
  int get numerTour => tourActuel + 1;

  /// Prochaine échéance effective : utilise l'échéance stockée si disponible
  /// et valide, sinon calcule automatiquement selon la périodicité.
  /// Retourne toujours une date dans le futur (ou aujourd'hui).
  DateTime get prochaineEcheanceDate {
    final now = DateTime.now();
    if (echeance != null && echeance!.isNotEmpty) {
      final d = DateTime.tryParse(echeance!);
      if (d != null && d.isAfter(now)) return d;
    }
    // Calcul automatique selon la périodicité (sans importer EcheanceService)
    return _calculerProchaineEcheance(now);
  }

  DateTime _calculerProchaineEcheance(DateTime depuis) {
    switch (periode) {
      case 'journalier':
        return depuis.add(const Duration(days: 1));
      case 'hebdo':
        return depuis.add(const Duration(days: 7));
      case 'mensuel':
        final mois = depuis.month == 12 ? 1 : depuis.month + 1;
        final annee = depuis.month == 12 ? depuis.year + 1 : depuis.year;
        final maxJour = DateTime(annee, mois + 1, 0).day;
        return DateTime(annee, mois, depuis.day.clamp(1, maxJour));
      case 'trimestriel':
        var m = depuis.month + 3;
        var a = depuis.year;
        while (m > 12) { m -= 12; a++; }
        final maxJ = DateTime(a, m + 1, 0).day;
        return DateTime(a, m, depuis.day.clamp(1, maxJ));
      default:
        return depuis.add(const Duration(days: 30));
    }
  }

  /// Durée d'un cycle en jours (approximatif pour l'affichage)
  int get joursCycle {
    switch (periode) {
      case 'journalier':   return 1;
      case 'hebdo':        return 7;
      case 'mensuel':      return 30;
      case 'trimestriel':  return 90;
      default:             return 30;
    }
  }

  // ── SOURCE UNIQUE DE MEMBRES — utilisée par TOUS les modules ──────────────
  //
  // RÈGLE : cette méthode est la SEULE référence pour construire la liste de
  // membres affichée dans Cotisations, Votes, Prêts, Relances WhatsApp.
  //
  // Algorithme en 3 niveaux de priorité :
  //
  //   1. ordre[] non vide ET la jointure avec membres[] donne ≥1 résultat
  //      → retourne les membres dans l'ordre de passage (cas normal)
  //
  //   2. ordre[] vide OU la jointure donne 0 résultat (IDs divergents)
  //      → retourne directement data.membres (même liste que l'onglet Membres)
  //      → identique à ce que MembresScreen affiche toujours
  //
  //   3. membres[] lui-même est vide (tontine sans membres)
  //      → retourne []
  //
  // Pourquoi le problème survenait :
  //   ordre[] peut contenir des IDs (ex: 'm1','m2') qui ne matchent plus
  //   les membres[] si la tontine a été modifiée côté Supabase/index.html
  //   avec des IDs différents (UUIDs, etc.). La jointure .whereType<Membre>()
  //   filtrait alors tous les null → liste vide → "Aucun membre à afficher".
  //   MembresScreen lisait membres[] directement → 10 membres visibles.
  //   Cette divergence est maintenant gérée par le fallback niveau 2.
  List<Membre> get membresActifs {
    if (membres.isEmpty) return const [];

    // Niveau 1 : ordre[] avec jointure réussie
    if (ordre.isNotEmpty) {
      final parId = {for (final m in membres) m.id: m};
      final ordonnes = ordre
          .map((id) => parId[id])
          .whereType<Membre>()
          .toList();
      if (ordonnes.isNotEmpty) return ordonnes;
      // Niveau 2 : IDs de ordre[] ne correspondent pas aux IDs de membres[]
      // → fallback sur membres[] bruts (même liste que MembresScreen)
    }

    // Niveau 2 : ordre[] vide ou jointure échouée → membres[] directement
    return List<Membre>.unmodifiable(membres);
  }

  /// Nombre de membres éligibles au vote / à la cotisation
  int get nbMembresActifs => membresActifs.length;

  /// Nombre total de tours du cycle = nombre de membres participants.
  /// Utilisé pour afficher "Tour X sur N".
  /// - Si ordre[] non vide → N = ordre.length (source de vérité Supabase)
  /// - Sinon → N = membres.length (fallback, avant verrouillage tirage)
  /// Ne retourne JAMAIS 0 si des membres existent.
  int get nbTours {
    if (ordre.isNotEmpty) return ordre.length;
    return membres.length;
  }

  /// Nom du bénéficiaire courant pour l'affichage.
  /// Retourne "Bénéficiaire non encore désigné" si non défini.
  String get beneficiaireNomOuFallback {
    final b = beneficiaire;
    if (b != null) return b.nom;
    return 'Bénéficiaire non encore désigné';
  }

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

  // ── Nouveau Cycle ──────────────────────────────────────────────────────────

  /// Numéro du cycle courant (1-based, incrémenté à chaque redémarrage).
  /// Alias lisible vers cycleNumero.
  int get cycleNum => cycleNumero;

  /// Vote de redémarrage actif (ouvert ou clos récent)
  /// Retourne le vote 'nouveau_cycle' le plus récent, ou null.
  Vote? get voteRedemarrage {
    Vote? candidat;
    for (final v in votes) {
      if (v.type == 'nouveau_cycle') {
        if (candidat == null) {
          candidat = v;
        } else {
          // Garder le plus récent
          if (v.dateCreation.compareTo(candidat.dateCreation) > 0) {
            candidat = v;
          }
        }
      }
    }
    return candidat;
  }

  /// true si le gestionnaire peut proposer un nouveau cycle :
  ///   - cycleTermine == true
  ///   - aucun vote 'nouveau_cycle' déjà ouvert
  ///   - la tontine a au moins 2 membres et un ordre de passage défini
  bool get peutProposerNouveauCycle {
    // Un cycle en attente (jamais lancé) ou en cours n'est PAS un cycle terminé
    if (!cycleTermine) return false;
    // Sécurité : le cycle doit avoir réellement démarré (historique ou ordre non vide)
    // Si ordre vide + cycleTermine=true → donnée corrompue → bloquer
    if (historique.isEmpty && ordre.isEmpty) return false;
    // Vérifier qu'il n'y a pas déjà un vote ouvert
    for (final v in votes) {
      if (v.type == 'nouveau_cycle' && !v.clos) return false;
    }
    return true;
  }

  /// true si un vote de redémarrage ouvert existe (membres peuvent voter)
  bool get voteRedemarrageOuvert {
    final v = voteRedemarrage;
    return v != null && !v.clos;
  }

  /// true si le vote de redémarrage est clos et accepté
  bool get voteRedemarrageAccepte {
    final v = voteRedemarrage;
    return v != null && v.clos && (v.adopte == true);
  }

  /// true si le vote de redémarrage est clos et refusé
  bool get voteRedemarrageRefuse {
    final v = voteRedemarrage;
    return v != null && v.clos && (v.adopte != true);
  }

  /// Nombre de membres ayant voté sur le vote de redémarrage
  int get nbVotesCastesRedemarrage {
    final v = voteRedemarrage;
    if (v == null) return 0;
    return v.voix.length;
  }

  /// Décompte du vote de redémarrage {oui, non, abstention}
  Map<String, int> get decompteRedemarrage {
    final v = voteRedemarrage;
    if (v == null) return {'oui': 0, 'non': 0, 'abstention': 0};
    if (v.decompte != null) {
      return {
        'oui':        (v.decompte!['oui'] as num?)?.toInt() ?? 0,
        'non':        (v.decompte!['non'] as num?)?.toInt() ?? 0,
        'abstention': (v.decompte!['abstention'] as num?)?.toInt() ?? 0,
      };
    }
    // Calculer depuis voix{}
    int oui = 0, non = 0, abs = 0;
    for (final choix in v.voix.values) {
      switch (choix.toString()) {
        case 'oui':        oui++; break;
        case 'non':        non++; break;
        case 'abstention': abs++; break;
      }
    }
    return {'oui': oui, 'non': non, 'abstention': abs};
  }

  /// Membres n'ayant pas encore voté sur le vote de redémarrage
  List<Membre> get membresNonVotesRedemarrage {
    final v = voteRedemarrage;
    if (v == null || v.clos) return [];
    return membresActifs.where((m) => !v.voix.containsKey(m.id)).toList();
  }

  /// Nombre de membres qui ont déjà voté sur le vote de redémarrage
  int get nbMembresVotesRedemarrage {
    final v = voteRedemarrage;
    if (v == null) return 0;
    return v.voix.length;
  }

  /// Nombre de membres qui n'ont pas encore voté
  int get nbMembresRestantAVoterRedemarrage {
    return membresNonVotesRedemarrage.length;
  }

  /// Numéro de quorum requis pour le vote de redémarrage
  int get quorumRedemarrage {
    final v = voteRedemarrage;
    if (v?.candidat != null) {
      final q = v!.candidat!['quorum'] as int?;
      if (q != null) return q;
    }
    return (membresActifs.length / 2).ceil();
  }

  /// Nombre de membres qui ont voté dans le vote de redémarrage, 
  /// un membre peut voter Oui, Non ou Abstention
  bool aMemberVoteRedemarrage(String membreId) {
    final v = voteRedemarrage;
    return v != null && v.voix.containsKey(membreId);
  }

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

    // ── CycleNumero ──
    final cycleNumero = (json['cycleNum'] as num?)?.toInt() ?? 1;

    // ── CyclesArchives ──
    final cyclesArchives = (json['cyclesArchives'] as List<dynamic>?)
            ?.map((h) => h as Map<String, dynamic>)
            .toList() ??
        [];

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
    // Règle : cycleTermine = true UNIQUEMENT si Supabase le dit explicitement
    // OU si le cycle a réellement démarré (ordre non vide) ET tous les tours sont faits.
    // Une tontine nouvellement créée (ordre vide, cycleTermine absent) n'est PAS terminée.
    // Elle est en attente de démarrage.
    final cycleTermineBrut = json['cycleTermine'] as bool?;
    // ── Historique pour la garde anti-corruption ──────────────────────────
    final historiquePourGarde = (json['historique'] as List?)?.length ?? 0;
    final bool cycleTermine;
    if (cycleTermineBrut == true && ordre.isEmpty && historiquePourGarde == 0) {
      // ⚠️  Donnée corrompue : Supabase dit "terminé" mais la tontine n'a
      //     jamais démarré (ordre vide, historique vide).
      //     → On force cycleEnAttente (pas cycleTermine).
      //     La migration SQL v15 corrige aussi ce cas côté serveur.
      cycleTermine = false;
    } else if (cycleTermineBrut != null) {
      // Supabase l'a posé explicitement → source de vérité
      cycleTermine = cycleTermineBrut;
    } else if (ordre.isEmpty) {
      // Tontine jamais lancée (ordre non défini) → PAS terminée, en attente
      cycleTermine = false;
    } else {
      // Calcul de sécurité : tous les tours effectués
      cycleTermine = tourActuel >= ordre.length;
    }

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

    // ── Échéance : lire depuis Supabase ou calculer automatiquement ──────────
    // Si aucune échéance n'est stockée dans data, on ne bloque pas l'app :
    // EcheanceService calcule la prochaine échéance à la volée dans l'UI.
    // On stocke la valeur brute de Supabase sans modification ici.
    // La normalisation (recalcul si passée) est faite dans EcheanceService.
    final echeanceRaw = json['echeance'] as String?;

    return TontineData(
      nom: json['nom'] as String? ?? '',
      montant: (json['montant'] as num?)?.toInt() ?? 0,
      periode: periode,
      methodeOrdre: json['methodeOrdre'] as String? ?? 'rotation',
      echeance: echeanceRaw,
      tourActuel: tourActuel,
      cycleTermine: cycleTermine,
      cycleNumero: cycleNumero,
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
      cyclesArchives: cyclesArchives,
      stats: stats,
    );
  }

  Map<String, dynamic> toJson() => {
        'nom': nom,
        'montant': montant,
        'periodicite': periode,
        'periode': periode,
        'methodeOrdre': methodeOrdre,
        'cycleNum': cycleNumero,
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
        'cyclesArchives': cyclesArchives,
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
