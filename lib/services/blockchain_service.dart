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
// Réseau : Polygon Amoy (testnet) → Polygon Mainnet (Phase 4)
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
    this.reseau       = 'polygon_amoy',
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
      reseau         : j['reseau']          as String? ?? 'polygon_amoy',
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
      txHash != null ? 'https://amoy.polygonscan.com/tx/$txHash' : '';

  String get typeLabel {
    const map = {
      'cotisation'        : 'Cotisation',
      'distribution'      : 'Distribution',
      'pret'              : 'Prêt',
      'remboursement'     : 'Remboursement',
      'vote'              : 'Vote',
      'creation'          : 'Création tontine',
      'apport'            : 'Apport caisse',
      'penalite'          : 'Pénalité',
    };
    return map[typeOperation] ?? typeOperation.toUpperCase();
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
      ? 'https://amoy.polygonscan.com/address/$contractAddress'
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
