// ═══════════════════════════════════════════════════════════════════════════════
// BlockchainService  —  TontineClair Web2+Web3 Phase 1
//
// Couche Flutter d'accès au journal blockchain.
// Appelle l'Edge Function "blockchain-tx" via HTTP.
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

  /// Devise réelle de la tontine — lue dans metadata['devise'].
  /// Jamais de fallback XOF : si absent → chaîne vide (affichage numérique seul).
  String get devise => (metadata['devise'] as String?)?.trim() ?? '';

  String get explorerUrl =>
      txHash != null ? 'https://polygonscan.com/tx/$txHash' : '';

  // ── Mapping 4-byte Ethereum ABI selectors → type métier ─────────────────
  // Ces sélecteurs sont les 4 premiers bytes de keccak256(signature_fonction)
  // générés par blockchain-tx/index.ts et peuvent se retrouver dans type_operation
  // pour des entrées historiques ou des erreurs de stockage.
  static const _selectorVersType = <String, String>{
    // ── TontineVaultV3 — 18 fonctions métier ─────────────────────────────────
    '0xa3980ee2': 'cotisation',        // enregistrerCotisation
    '0x7948515e': 'decaissement',      // enregistrerDecaissement  (absent V1 → V3)
    '0x5ee35c39': 'distribution',      // enregistrerDistribution
    '0xe8309f9d': 'apport',            // enregistrerApport
    '0x3a34a193': 'depot',             // enregistrerDepot
    '0x566519de': 'retrait',           // enregistrerRetrait
    '0x49b4279e': 'retrait_propose',   // enregistrerRetraitPropose
    '0x1d00f9ce': 'penalite',          // enregistrerPenalite
    '0x3bfe5ba7': 'pret',              // enregistrerPret
    '0x673efd5f': 'remboursement',     // enregistrerRemboursement
    '0xace3c9ee': 'vote',              // enregistrerVoteIndividuel
    '0x05797094': 'vote_cree',         // enregistrerVoteCree
    '0xf4ef3be9': 'vote_clos',         // enregistrerVoteClos
    '0x69d1a0f8': 'creation',          // enregistrerCreation
    '0x54ce7c65': 'sync_balance',      // enregistrerSynchronisation
    '0x89808c56': 'score_modifie',     // enregistrerScoreModifie
    '0x0496be90': 'upgrade_pro',       // enregistrerUpgradePro
    '0x19c2cd10': 'nouveau_cycle',     // enregistrerNouveauCycle
    // ── TontineVaultV3 — fonctions système ───────────────────────────────────
    '0xb38ff71f': 'mise_a_jour',       // transfererAdmin(address)
    '0xf851a440': 'mise_a_jour',       // admin()
    '0x54fd4d50': 'mise_a_jour',       // version()
    '0x5a9b0b89': 'sync_balance',      // getInfo()
    '0xed232029': 'sync_balance',      // totalOperations()
    // ── TontineVaultV1/V2 — anciens sélecteurs (rétrocompat) ─────────────────
    '0xbaa62d66': 'cotisation',        // enregistrerOperation V1
    '0xd3795e53': 'vote',              // enregistrerVote V1
    '0x68054f4e': 'creation',          // enregistrerCreation V1
    '0x60c06040': 'cotisation',        // variante enregistrerOperation
    '0xa9059cbb': 'remboursement',     // ERC-20 transfer(address,uint256)
    '0x095ea7b3': 'mise_a_jour',       // ERC-20 approve(address,uint256)
    '0x23b872dd': 'distribution',      // ERC-20 transferFrom(address,address,uint256)
  };

  /// Résout un type_operation : si c'est un sélecteur hex 0x…, retourne le type métier.
  /// Méthode privée utilisée par les getters internes.
  static String _resoudreTypeOperation(String raw) {
    if (raw.startsWith('0x') && raw.length <= 10) {
      return _selectorVersType[raw.toLowerCase()] ?? raw;
    }
    return raw;
  }

  /// Méthode publique statique : résout un type_operation brut (hex ou string) → type métier.
  /// Utilisée par les écrans externes (blockchain_admin_screen.dart).
  static String resoudreType(String raw) => _resoudreTypeOperation(raw);

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

  /// Type opération résolu : si hex selector 0x…, traduit vers type métier.
  String get typeOperationResolu => _resoudreTypeOperation(typeOperation);

  String get iconeMetier =>
      _metier[typeOperationResolu]?['icone'] ?? '❓';

  String get typeLabel {
    final resolu = typeOperationResolu;
    if (_metier.containsKey(resolu)) {
      return _metier[resolu]!['label']!;
    }
    // Si c'était un selector hex non mappé, afficher "❓ Action inconnue"
    if (typeOperation.startsWith('0x')) {
      return '❓ Action inconnue';
    }
    return typeOperation.replaceAll('_', ' ').toUpperCase();
  }

  /// Description lisible enrichie avec le contexte (membre, tontine, montant).
  /// Formule naturelle pour un novice : "Cotisation de Koffi", "Prêt accordé à Koffi", etc.
  String get descriptionMetier {
    final resolu  = typeOperationResolu;
    final nom     = (membreNom != null && membreNom!.isNotEmpty) ? membreNom! : null;

    // Phrases naturelles par type — intègrent le nom du membre
    String phrase;
    switch (resolu) {
      case 'cotisation':
        phrase = nom != null ? 'Cotisation de $nom' : 'Cotisation mensuelle';
        break;
      case 'decaissement':
        phrase = nom != null ? 'Décaissement vers $nom' : 'Décaissement';
        break;
      case 'distribution':
        phrase = nom != null ? 'Tour attribué à $nom' : 'Distribution du tour';
        break;
      case 'pret':
        phrase = nom != null ? 'Prêt accordé à $nom' : 'Prêt accordé';
        break;
      case 'remboursement':
        phrase = nom != null ? 'Remboursement de $nom' : 'Remboursement de prêt';
        break;
      case 'vote':
      case 'vote_cree':
        // Le nom du gestionnaire est déjà affiché sur la ligne "membreNom" en dessous
        // → éviter la redondance "Vote — Arnaud / Arnaud le Président"
        phrase = 'Vote ouvert';
        break;
      case 'vote_clos':
        phrase = 'Vote clôturé';
        break;
      case 'penalite':
        phrase = nom != null ? 'Pénalité appliquée à $nom' : 'Pénalité';
        break;
      case 'ajout_membre':
        phrase = nom != null ? '$nom rejoint la tontine' : 'Nouveau membre ajouté';
        break;
      case 'suppression_membre':
        phrase = nom != null ? '$nom retiré de la tontine' : 'Membre retiré';
        break;
      case 'retrait':
      case 'retrait_propose':
        phrase = nom != null ? 'Retrait demandé par $nom' : 'Retrait de fonds';
        break;
      case 'apport':
        phrase = nom != null ? 'Apport de $nom' : 'Apport en caisse';
        break;
      case 'annulation_cotisation':
        phrase = nom != null ? 'Cotisation de $nom annulée' : 'Cotisation annulée';
        break;
      default:
        // Fallback générique : garde l'ancienne logique
        phrase = _metier[resolu]?['desc'] ?? typeLabel;
        if (nom != null) phrase = '$phrase · $nom';
    }

    // Le montant est déjà affiché dans la colonne droite de la carte (montantXof).
    // On ne le répète PAS dans la description pour éviter la redondance.
    return phrase;
  }

  /// Formate un entier XOF avec espace fine comme séparateur de milliers.
  /// Utilisé par les écrans externes (ex: _CarteResume dans verification_publique_screen).
  static String formaterXof(int xof) {
    final s = xof.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('\u202F');
      buf.write(s[i]);
    }
    return buf.toString();
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

  /// Version courte du TX hash, ASCII-safe (pas d'ellipse Unicode).
  /// Utilisé notamment dans la génération PDF.
  String get txHashCourt =>
      txHash != null && txHash!.length > 12
          ? '${txHash!.substring(0, 8)}...${txHash!.substring(txHash!.length - 6)}'
          : (txHash ?? '-');
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
  /// Appelé après validation du paiement.
  /// NON-BLOQUANT : si Polygon échoue, TontineClair continue normalement.
  static Future<BlockchainResultat> enregistrerCotisation({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    montantXof,
    String? devise,
    String? refInterne,
    String? walletTontine,
  }) async {
    return _enregistrer(
      tontineCode   : tontineCode,
      typeOperation : 'cotisation',
      membreId      : membreId,
      membreNom     : membreNom,
      montantXof    : montantXof,
      devise        : devise,
      refInterne    : refInterne,
      walletTontine : walletTontine,
    );
  }

  /// Enregistre une DISTRIBUTION (décaissement vers bénéficiaire du tour).
  static Future<BlockchainResultat> enregistrerDistribution({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    montantXof,
    String? devise,
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
      devise       : devise,
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
    String? devise,
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
      devise       : devise,
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
    String? devise,
    String? refInterne,
    String? walletTontine,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'remboursement',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : montantXof,
      devise       : devise,
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

  /// Enregistre l'AJOUT D'UN MEMBRE (admission par vote ou directement).
  static Future<BlockchainResultat> enregistrerAjoutMembre({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    String? gestionnaire,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'ajout_membre',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : null,
      metadata     : gestionnaire != null ? {'gestionnaire': gestionnaire} : null,
    );
  }

  /// Enregistre la SUPPRESSION D'UN MEMBRE (vote retrait adopté ou exclusion).
  static Future<BlockchainResultat> enregistrerSuppressionMembre({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    String? gestionnaire,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'suppression_membre',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : null,
      metadata     : gestionnaire != null ? {'gestionnaire': gestionnaire} : null,
    );
  }

  /// Enregistre une PÉNALITÉ appliquée à un membre.
  static Future<BlockchainResultat> enregistrerPenalite({
    required String tontineCode,
    required String membreId,
    required String membreNom,
    required int    montantXof,
    String? devise,
    String? refInterne,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'penalite',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : montantXof,
      devise       : devise,
      refInterne   : refInterne,
    );
  }

  /// Enregistre une DÉPENSE CAISSE (hors pénalité).
  static Future<BlockchainResultat> enregistrerDepenseCaisse({
    required String tontineCode,
    required int    montantXof,
    required String description,
    String? devise,
    String? refInterne,
    String? gestionnaire,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'depense_caisse',
      membreNom    : gestionnaire,
      montantXof   : montantXof,
      devise       : devise,
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
    String? devise,
    String? refInterne,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'annulation_cotisation',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : montantXof,
      devise       : devise,
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
    String? devise,
    String? refInterne,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'annulation_remboursement',
      membreId     : membreId,
      membreNom    : membreNom,
      montantXof   : montantXof,
      devise       : devise,
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
    String? membreId,
    String? refInterne,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'vote_cree',
      membreId     : membreId,
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
    String? membreId,
  }) async {
    return _enregistrer(
      tontineCode  : tontineCode,
      typeOperation: 'vote_clos',
      membreId     : membreId,
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
    String? devise,
    String? refInterne,
  }) async {
    return _enregistrer(
      tontineCode   : tontineCode,
      typeOperation : 'apport',
      membreId      : membreId,
      membreNom     : membreNom,
      montantXof    : montantXof,
      devise        : devise,
      refInterne    : refInterne,
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
    String?  devise,            // devise ISO de la tontine (EUR, USD, XOF…)
    String?  refInterne,
    String?  walletTontine,
    String?  walletMembre,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      // Enrichir les métadonnées avec la devise pour que PolygonScan
      // affiche la bonne devise (EUR, USD, etc.) et non "XOF" par défaut.
      final metadataEnrichie = <String, dynamic>{
        if (devise != null) 'devise': devise,
        ...?metadata,
      };
      final rep = await _appeler({
        'action'         : 'enregistrer_operation',
        'tontine_code'   : tontineCode,
        'type_operation' : typeOperation,
        if (membreId        != null) 'membre_id'       : membreId,
        if (membreNom       != null) 'membre_nom'      : membreNom,
        if (montantXof      != null) 'montant_xof'     : montantXof,
        // devise aussi au niveau RACINE du payload — lue directement par l'Edge Function
        // pour l'encoder dans refInterne → visible dans Polygonscan Input Data
        if (devise != null && devise.isNotEmpty) 'devise' : devise,
        if (metadataEnrichie.isNotEmpty) 'metadata'    : metadataEnrichie,
        if (refInterne      != null) 'ref_interne'     : refInterne,
        if (walletTontine   != null) 'wallet_tontine'  : walletTontine,
        if (walletMembre    != null) 'wallet_membre'   : walletMembre,
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
          devise       : devise,   // transmet la vraie devise — jamais XOF hardcodé
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
