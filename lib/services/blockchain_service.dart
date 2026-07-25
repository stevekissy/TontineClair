// ═══════════════════════════════════════════════════════════════════════════════
// BlockchainService  —  TontineClair Web2+Web3 Phase 1
//
// Couche Flutter d'accès au journal blockchain.
// Appelle l'Edge Function "blockchain-tx" via HTTP (même pattern que
// CoinPaymentsService et SupabaseService).
//
// PRINCIPE CLÉ :
//   • Toutes les opérations blockchain sont NON-BLOQUANTES.
//   • Si la blockchain échoue → l'opération TontineClair reste valide.
//   • L'utilisateur ne voit jamais la blockchain → expérience identique.
//   • Le journal sert à l'audit, à la transparence et à la conformité.
//
// Réseau : Polygon MAINNET (chainId 137) — Phase 4 production
// Token  : USDT ERC-20
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'supabase_service.dart';
import 'notification_service.dart';

// ── Modèle d'une entrée du journal blockchain ─────────────────────────────────
class BlockchainEntry {
  final int?    id;
  final String  tontineCode;
  final String  typeOperation;
  final String? membreId;
  final String? membreNom;
  final int?    montantXof;
  final double? montantUsdt;
  final double? tauxXofUsdt;
  final String  reseau;
  final String? txHash;
  final int?    blockNumber;
  final String? walletTontine;
  final String  statut;
  final String? signature;
  final String? payloadHash;
  final String? refCoinpayments;
  final String? refInterne;
  final Map<String, dynamic> metadata;
  final DateTime  createdAt;
  final DateTime? confirmedAt;

  const BlockchainEntry({
    this.id,
    required this.tontineCode,
    required this.typeOperation,
    this.membreId,
    this.membreNom,
    this.montantXof,
    this.montantUsdt,
    this.tauxXofUsdt,
    this.reseau       = 'polygon-mainnet',
    this.txHash,
    this.blockNumber,
    this.walletTontine,
    this.statut       = 'pending',
    this.signature,
    this.payloadHash,
    this.refCoinpayments,
    this.refInterne,
    this.metadata     = const {},
    required this.createdAt,
    this.confirmedAt,
  });

  factory BlockchainEntry.fromJson(Map<String, dynamic> j) {
    return BlockchainEntry(
      id             : j['id'] as int?,
      tontineCode    : j['tontine_code']    as String? ?? '',
      typeOperation  : j['type_operation']  as String? ?? '',
      membreId       : j['membre_id']       as String?,
      membreNom      : j['membre_nom']      as String?,
      montantXof     : j['montant_xof']     is num ? (j['montant_xof'] as num).toInt() : null,
      montantUsdt    : j['montant_usdt']    is num ? (j['montant_usdt'] as num).toDouble() : null,
      tauxXofUsdt    : j['taux_xof_usdt']   is num ? (j['taux_xof_usdt'] as num).toDouble() : null,
      reseau         : j['reseau']          as String? ?? 'polygon-mainnet',
      txHash         : j['tx_hash']         as String?,
      blockNumber    : j['block_number']    is num ? (j['block_number'] as num).toInt() : null,
      walletTontine  : j['wallet_tontine']  as String?,
      statut         : j['statut']          as String? ?? 'pending',
      signature      : j['signature']       as String?,
      payloadHash    : j['payload_hash']    as String?,
      refCoinpayments: j['ref_coinpayments'] as String?,
      refInterne     : j['ref_interne']     as String?,
      metadata       : (j['metadata']       as Map<String, dynamic>?) ?? {},
      createdAt      : DateTime.tryParse(j['created_at'] as String? ?? '')
                     ?? DateTime.now(),
      confirmedAt    : j['confirmed_at'] != null
                     ? DateTime.tryParse(j['confirmed_at'] as String)
                     : null,
    );
  }

  // ── Getters sémantiques ───────────────────────────────────────────────────
  bool get estConfirme => statut == 'confirmed';
  bool get estPending  => statut == 'pending' || statut == 'submitted';
  bool get estEchec    => statut == 'failed';

  String get explorerUrl =>
      txHash != null ? 'https://polygonscan.com/tx/$txHash' : '';

  // ── Mapper métier complet ─────────────────────────────────────────────────
  static const _metier = <String, Map<String, String>>{
    'cotisation'              : {'icone': '💰', 'label': 'Cotisation',            'desc': 'Cotisation mensuelle'},
    'decaissement'            : {'icone': '💸', 'label': 'Décaissement',          'desc': 'Décaissement vers membre'},
    'distribution'            : {'icone': '🎁', 'label': 'Distribution',          'desc': 'Distribution du tour'},
    'apport'                  : {'icone': '🤝', 'label': 'Apport',                'desc': 'Apport en caisse'},
    'depot'                   : {'icone': '📥', 'label': 'Dépôt',                 'desc': 'Dépôt de fonds'},
    'retrait'                 : {'icone': '📤', 'label': 'Retrait',               'desc': 'Retrait de fonds'},
    'retrait_propose'         : {'icone': '📤', 'label': 'Retrait proposé',       'desc': 'Retrait proposé'},
    'paiement'                : {'icone': '💳', 'label': 'Paiement',              'desc': 'Paiement effectué'},
    'penalite'                : {'icone': '⚠️',  'label': 'Pénalité',             'desc': 'Pénalité appliquée'},
    'pret'                    : {'icone': '🏦', 'label': 'Prêt accordé',          'desc': 'Prêt accordé à membre'},
    'remboursement'           : {'icone': '💵', 'label': 'Remboursement de prêt', 'desc': 'Remboursement de prêt'},
    'ajout_membre'            : {'icone': '👤', 'label': 'Ajout de membre',       'desc': 'Nouveau membre ajouté'},
    'suppression_membre'      : {'icone': '❌', 'label': 'Suppression de membre', 'desc': 'Membre retiré'},
    'mise_a_jour'             : {'icone': '⚙️',  'label': 'Mise à jour',          'desc': 'Mise à jour paramètres'},
    'vote'                    : {'icone': '🗳️',  'label': 'Vote',                 'desc': 'Vote enregistré'},
    'vote_cree'               : {'icone': '🗳️',  'label': 'Vote créé',            'desc': 'Nouveau vote créé'},
    'vote_clos'               : {'icone': '🗳️',  'label': 'Vote clôturé',         'desc': 'Vote clôturé'},
    'creation'                : {'icone': '🏦', 'label': 'Création tontine',      'desc': 'Tontine créée'},
    'sync_balance'            : {'icone': '🔄', 'label': 'Synchronisation',       'desc': 'Solde synchronisé on-chain'},
    'depense_caisse'          : {'icone': '💸', 'label': 'Dépense caisse',        'desc': 'Dépense depuis la caisse'},
    'annulation_cotisation'   : {'icone': '↩️',  'label': 'Annulation cotisation','desc': 'Cotisation annulée'},
    'annulation_remboursement': {'icone': '↩️',  'label': 'Annulation remboursement','desc': 'Remboursement annulé'},
    'tirage_verrouille'       : {'icone': '🔒', 'label': 'Tirage verrouillé',     'desc': 'Tirage verrouillé'},
    'score_modifie'           : {'icone': '⭐', 'label': 'Score modifié',         'desc': 'Score de membre modifié'},
    'upgrade_pro'             : {'icone': '🚀', 'label': 'Passage Pro',            'desc': 'Mise à niveau vers Pro'},
    'nouveau_cycle'           : {'icone': '🔁', 'label': 'Nouveau cycle',          'desc': 'Nouveau cycle démarré'},
  };

  String get iconeMetier =>
      _metier[typeOperation]?['icone'] ?? '📋';

  String get typeLabel =>
      _metier[typeOperation]?['label'] ??
      typeOperation.replaceAll('_', ' ').toUpperCase();

  /// Description lisible enrichie avec le contexte (membre, tontine, montant)
  String get descriptionMetier {
    final base = _metier[typeOperation]?['desc'] ?? typeLabel;
    final parties = <String>[];
    if (membreNom != null && membreNom!.isNotEmpty) parties.add(membreNom!);
    if (tontineCode.isNotEmpty) parties.add('– Groupe $tontineCode');
    if (montantXof != null && montantXof! > 0) {
      final s = montantXof.toString();
      final buf = StringBuffer();
      for (int i = 0; i < s.length; i++) {
        if (i > 0 && (s.length - i) % 3 == 0) buf.write('\u202F');
        buf.write(s[i]);
      }
      parties.add('(${buf.toString()} XOF)');
    }
    return parties.isEmpty ? base : '$base · ${parties.join(' ')}';
  }

  String get statutLabel {
    const map = {
      'confirmed' : 'Confirmé ✓',
      'pending'   : 'En attente',
      'submitted' : 'Soumis',
      'failed'    : 'Échoué',
      'skipped'   : 'Ignoré',
    };
    return map[statut] ?? statut;
  }

  String get txHashCourt =>
      txHash != null && txHash!.length > 12
          ? '${txHash!.substring(0, 8)}…${txHash!.substring(txHash!.length - 6)}'
          : (txHash ?? '—');
}

// ── Résultat d'enregistrement ─────────────────────────────────────────────────
class BlockchainResultat {
  final bool    ok;
  final String? journalId;
  final String? txHash;
  final int?    blockNumber;
  final String? explorerUrl;
  final double? montantUsdt;
  final double? tauxXofUsdt;
  final String? signature;
  final String  statut;
  final String? erreur;
  final int     phase;           // 1 = SHA-256 proof, 2 = vrai TX Ethereum
  final String? contractAddress; // adresse TontineVault.sol (Phase 2)

  const BlockchainResultat({
    required this.ok,
    this.journalId,
    this.txHash,
    this.blockNumber,
    this.explorerUrl,
    this.montantUsdt,
    this.tauxXofUsdt,
    this.signature,
    this.statut = 'pending',
    this.erreur,
    this.phase   = 1,
    this.contractAddress,
  });

  /// true si c'est un vrai hash Ethereum on-chain (Phase 2)
  bool get estOnChain => phase == 2 && txHash != null && txHash!.length == 66;

  /// Lien PolygonScan vers le contrat
  String? get explorerContrat => contractAddress != null
      ? 'https://polygonscan.com/address/$contractAddress'
      : null;

  factory BlockchainResultat.fromJson(Map<String, dynamic> j) {
    return BlockchainResultat(
      ok             : j['ok'] == true,
      journalId      : j['entry_id']?.toString() ?? j['journal_id']?.toString(),
      txHash         : j['tx_hash']      as String?,
      blockNumber    : j['block_number'] is num ? (j['block_number'] as num).toInt() : null,
      explorerUrl    : j['explorer_url'] as String?,
      montantUsdt    : j['montant_usdt'] is num ? (j['montant_usdt'] as num).toDouble() : null,
      tauxXofUsdt    : j['taux_xof_usdt'] is num ? (j['taux_xof_usdt'] as num).toDouble() : null,
      signature      : j['signature']    as String?,
      statut         : j['statut']       as String? ?? 'pending',
      erreur         : j['message']      as String?,
      phase          : j['phase']        is num ? (j['phase'] as num).toInt() : 1,
      contractAddress: j['contract']     as String?,
    );
  }

  factory BlockchainResultat.echec(String message) => BlockchainResultat(
    ok: false, statut: 'failed', erreur: message,
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// SERVICE PRINCIPAL
// ═══════════════════════════════════════════════════════════════════════════════
class BlockchainService {

  // ── URL de l'Edge Function ────────────────────────────────────────────────
  static String get _edgeUrl =>
      '${SupabaseService.supabaseUrl}/functions/v1/blockchain-tx';

  static String get _anonKey => SupabaseService.supabaseAnonKey;

  // ── Timeout adapté Phase 2 (TX on-chain peut prendre jusqu'à 60s) ────────
  static const Duration _timeoutPhase2 = Duration(seconds: 75);
  static const Duration _timeoutLecture = Duration(seconds: 15);

  // ── Appel HTTP vers l'Edge Function ─────────────────────────────────────
  static Future<Map<String, dynamic>> _appeler(
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 75),
  }) async {
    try {
      final res = await http.post(
        Uri.parse(_edgeUrl),
        headers: {
          'Content-Type' : 'application/json',
          'Authorization': 'Bearer $_anonKey',
          'apikey'       : _anonKey,
        },
        body: jsonEncode(payload),
      ).timeout(timeout);

      final json = jsonDecode(res.body) as Map<String, dynamic>;

      if (kDebugMode) {
        debugPrint('[Blockchain] action=${payload["action"]} → ${res.statusCode} | '
            'statut=${json["statut"]} | tx=${json["tx_hash"]}');
      }
      return json;
    } catch (e) {
      if (kDebugMode) debugPrint('[Blockchain] ERREUR: $e');
      return {'ok': false, 'erreur': true, 'message': e.toString()};
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MÉTHODES PUBLIQUES — enregistrement des opérations financières
  // ═══════════════════════════════════════════════════════════════════════════

  /// Enregistre UNE COTISATION dans le journal blockchain.
  /// Appelé après validation du paiement (IPN CoinPayments ou Mobile Money).
  /// NON-BLOQUANT : si Polygon échoue, TontineClair continue normalement.
  static Future<BlockchainResultat> enregistrerCotisation({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    montantXof,
    String? refCoinpayments,
    String? refInterne,
    String? walletTontine,
  }) async {
    return _enregistrer(
      tontineCode    : tontineCode,
      typeOperation  : 'cotisation',
      membreId       : membreId,
      membreNom      : membreNom,
      montantXof     : montantXof,
      refCoinpayments: refCoinpayments,
      refInterne     : refInterne,
      walletTontine  : walletTontine,
    );
  }

  /// Enregistre une DISTRIBUTION (décaissement vers bénéficiaire du tour).
  static Future<BlockchainResultat> enregistrerDistribution({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    montantXof,
    String? walletMembre,
    String? walletTontine,
    String? refInterne,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'distribution',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : montantXof,
      walletMembre : walletMembre,
      walletTontine: walletTontine,
      refInterne   : refInterne,
    );
  }

  /// Enregistre l'OCTROI D'UN PRÊT.
  static Future<BlockchainResultat> enregistrerPret({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    montantXof,
    String? refInterne,
    String? walletTontine,
    Map<String, dynamic>? metadata,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'pret',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : montantXof,
      refInterne   : refInterne,
      walletTontine: walletTontine,
      metadata     : metadata,
    );
  }

  /// Enregistre un REMBOURSEMENT DE PRÊT.
  static Future<BlockchainResultat> enregistrerRemboursement({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    montantXof,
    String? refInterne,
    String? walletTontine,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'remboursement',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : montantXof,
      refInterne   : refInterne,
      walletTontine: walletTontine,
    );
  }

  /// Enregistre un VOTE (pas de montant — on hash le résultat).
  static Future<BlockchainResultat> enregistrerVote({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required String question,
    required String choix,
    String? refInterne,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'vote',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : null,
      refInterne   : refInterne,
      metadata     : {'question': question, 'choix': choix},
    );
  }

  /// Enregistre la CRÉATION D'UNE TONTINE.
  static Future<BlockchainResultat> enregistrerCreation({
    required String tontineCode,
    required String gestionnaire,
    required String nomTontine,
    int? cotisationMensuelle,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'creation',
      membreNom    : gestionnaire,
      montantXof   : cotisationMensuelle,
      metadata     : {'nom_tontine': nomTontine},
    );
  }

  /// Enregistre une PÉNALITÉ appliquée à un membre.
  static Future<BlockchainResultat> enregistrerPenalite({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    montantXof,
    String? refInterne,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'penalite',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : montantXof,
      refInterne   : refInterne,
    );
  }

  /// Enregistre une DÉPENSE CAISSE (hors pénalité).
  static Future<BlockchainResultat> enregistrerDepenseCaisse({
    required String tontineCode,
    required int    montantXof,
    required String description,
    String? refInterne,
    String? gestionnaire,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'depense_caisse',
      membreNom    : gestionnaire,
      montantXof   : montantXof,
      refInterne   : refInterne,
      metadata     : {'description': description},
    );
  }

  /// Enregistre une ANNULATION DE COTISATION.
  static Future<BlockchainResultat> enregistrerAnnulationCotisation({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    montantXof,
    required int    numerTour,
    String? refInterne,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'annulation_cotisation',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : montantXof,
      refInterne   : refInterne,
      metadata     : {'tour': numerTour},
    );
  }

  /// Enregistre une ANNULATION DE REMBOURSEMENT.
  static Future<BlockchainResultat> enregistrerAnnulationRemboursement({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    montantXof,
    String? refInterne,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'annulation_remboursement',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : montantXof,
      refInterne   : refInterne,
    );
  }

  /// Enregistre le VERROUILLAGE DU TIRAGE.
  static Future<BlockchainResultat> enregistrerTirageVerrouille({
    required String tontineCode,
    required String gestionnaire,
    required String empreinte,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'tirage_verrouille',
      membreNom    : gestionnaire,
      montantXof   : null,
      metadata     : {'empreinte': empreinte},
    );
  }

  /// Enregistre la CRÉATION D'UN VOTE.
  static Future<BlockchainResultat> enregistrerVoteCree({
    required String tontineCode,
    required String gestionnaire,
    required String typeVote,
    required String question,
    String? refInterne,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'vote_cree',
      membreNom    : gestionnaire,
      montantXof   : null,
      refInterne   : refInterne,
      metadata     : {'type_vote': typeVote, 'question': question},
    );
  }

  /// Enregistre la CLÔTURE D'UN VOTE (adopté ou rejeté).
  static Future<BlockchainResultat> enregistrerVoteClos({
    required String tontineCode,
    required String gestionnaire,
    required String typeVote,
    required String voteId,
    required bool   adopte,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'vote_clos',
      membreNom    : gestionnaire,
      montantXof   : null,
      refInterne   : voteId,
      metadata     : {'type_vote': typeVote, 'adopte': adopte, 'vote_id': voteId},
    );
  }

  /// Enregistre une MODIFICATION DE SCORE de confiance.
  static Future<BlockchainResultat> enregistrerScoreModifie({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    ancienScore,
    required int    nouveauScore,
    required String motif,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'score_modifie',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : null,
      metadata     : {'ancien': ancienScore, 'nouveau': nouveauScore, 'motif': motif},
    );
  }

  /// Enregistre une PROPOSITION DE RETRAIT d'un membre.
  static Future<BlockchainResultat> enregistrerRetraitPropose({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    score,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'retrait_propose',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : null,
      metadata     : {'score': score},
    );
  }

  /// Enregistre le PASSAGE EN FORMULE PRO.
  static Future<BlockchainResultat> enregistrerUpgradePro({
    required String tontineCode,
    required String gestionnaire,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'upgrade_pro',
      membreNom    : gestionnaire,
      montantXof   : null,
    );
  }

  /// Enregistre le DÉMARRAGE D'UN NOUVEAU CYCLE.
  static Future<BlockchainResultat> enregistrerNouveauCycle({
    required String tontineCode,
    required String gestionnaire,
    required int    cycleNum,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'nouveau_cycle',
      membreNom    : gestionnaire,
      montantXof   : null,
      metadata     : {'cycle_num': cycleNum},
    );
  }

  /// Enregistre un APPORT EN CAISSE.
  static Future<BlockchainResultat> enregistrerApport({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    montantXof,
    String? refCoinpayments,
    String? refInterne,
  }) async {
    return _enregistrer(
      tontineCode    : tontineCode,
      typeOperation  : 'apport',
      membreId       : membreId,
      membreNom      : membreNom,
      montantXof     : montantXof,
      refCoinpayments: refCoinpayments,
      refInterne     : refInterne,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MÉTHODES DE LECTURE
  // ═══════════════════════════════════════════════════════════════════════════

  /// Lit le journal blockchain pour une tontine.
  static Future<List<BlockchainEntry>> lireJournal({
    String?  tontineCode,
    String?  statut,
    String?  typeOperation,
    int      limit  = 50,
    int      offset = 0,
  }) async {
    final rep = await _appeler({
      'action'        : 'lire_journal',
      if (tontineCode   != null) 'tontine_code'  : tontineCode,
      if (statut        != null) 'statut'         : statut,
      if (typeOperation != null) 'type_operation' : typeOperation,
      'limit' : limit,
      'offset': offset,
    });

    if (rep['ok'] != true) return [];
    final rows = rep['journal'] as List<dynamic>? ?? (rep['rows'] as List<dynamic>? ?? []);
    return rows
        .whereType<Map<String, dynamic>>()
        .map(BlockchainEntry.fromJson)
        .toList();
  }

  /// Statistiques globales du journal.
  static Future<Map<String, dynamic>> statsJournal() async {
    return _appeler({'action': 'stats_journal'});
  }

  /// Statistiques enrichies avec soldes agrégés par tontine.
  /// Utilisé par AdminSoldesScreen pour charger tous les soldes en une seule requête.
  static Future<Map<String, dynamic>> statsSoldes() async {
    return _appeler({'action': 'stats_soldes'}, timeout: _timeoutLecture);
  }

  /// Vérifie le statut d'une TX on-chain.
  static Future<Map<String, dynamic>> verifierTx(String txHash) async {
    return _appeler({'action': 'verifier_tx', 'tx_hash': txHash});
  }

  /// Taux de conversion XOF/USDT actuel.
  static Future<Map<String, dynamic>> tauxUsdt() async {
    return _appeler({'action': 'taux_usdt'}, timeout: _timeoutLecture);
  }

  /// Infos du smart contract TontineVault (Phase 2).
  /// Retourne phase=1 si le contrat n'est pas encore déployé.
  static Future<Map<String, dynamic>> contractInfo() async {
    return _appeler({'action': 'contract_info'}, timeout: _timeoutLecture);
  }

  /// Synchronise le solde d'une tontine sur la blockchain.
  ///
  /// Envoie un event OperationEnregistree(type=sync_balance) on-chain
  /// avec le solde consolidé (entrées, sorties, net) en tant que payload.
  /// En Phase 1 : génère une preuve SHA-256 dans blockchain_journal.
  /// En Phase 2 : envoie une vraie TX sur Polygon Mainnet.
  static Future<BlockchainResultat> syncBalanceTontine({
    required String tontineCode,
    required int    soldeBrut,
    required int    totalEntrees,
    required int    totalSorties,
    required int    nbOps,
  }) async {
    return _enregistrer(
      tontineCode   : tontineCode,
      typeOperation : 'sync_balance',
      montantXof    : soldeBrut,
      refInterne    : 'SYNC-${DateTime.now().millisecondsSinceEpoch}',
      metadata      : {
        'total_entrees' : totalEntrees,
        'total_sorties' : totalSorties,
        'solde_net'     : soldeBrut,
        'nb_ops'        : nbOps,
        'sync_at'       : DateTime.now().toIso8601String(),
        'source'        : 'admin_sync',
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MÉTHODE INTERNE COMMUNE
  // ═══════════════════════════════════════════════════════════════════════════
  static Future<BlockchainResultat> _enregistrer({
    required String  tontineCode,
    required String  typeOperation,
    String?  membreId,
    String?  membreNom,
    int?     montantXof,
    String?  refCoinpayments,
    String?  refInterne,
    String?  walletTontine,
    String?  walletMembre,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final rep = await _appeler({
        'action'         : 'enregistrer_operation',
        'tontine_code'   : tontineCode,
        'type_operation' : typeOperation,
        if (membreId        != null) 'membre_id'       : membreId,
        if (membreNom       != null) 'membre_nom'      : membreNom,
        if (montantXof      != null) 'montant_xof'     : montantXof,
        if (refCoinpayments != null) 'ref_coinpayments': refCoinpayments,
        if (refInterne      != null) 'ref_interne'     : refInterne,
        if (walletTontine   != null) 'wallet_tontine'  : walletTontine,
        if (walletMembre    != null) 'wallet_membre'   : walletMembre,
        if (metadata        != null) 'metadata'        : metadata,
      }, timeout: _timeoutPhase2); // 75s pour laisser la TX se confirmer

      final res = BlockchainResultat.fromJson(rep);
      if (kDebugMode) {
        debugPrint('[Blockchain] $typeOperation phase=${res.phase} '
            'tx=${res.txHash?.substring(0,10)}... statut=${res.statut}');
      }

      // ── Phase 4 Option Y : notification push locale ───────────────────────
      // Non-bloquant — si la notif échoue, l'opération reste valide
      if (res.ok) {
        NotificationService.notifierOperationBlockchain(
          tontineCode  : tontineCode,
          nomTontine   : tontineCode, // code utilisé comme fallback (pas de nom ici)
          typeOperation: typeOperation,
          phase        : res.phase,
          txHash       : res.txHash,
          montantXof   : montantXof,
          membreNom    : membreNom,
        ).catchError((_) {});  // Non-bloquant
      }

      return res;
    } catch (e) {
      if (kDebugMode) debugPrint('[Blockchain] _enregistrer ERREUR: $e');
      // NON-BLOQUANT : retourne un résultat échec sans lever d'exception
      return BlockchainResultat.echec(e.toString());
    }
  }
}
