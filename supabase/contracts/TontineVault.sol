// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ═══════════════════════════════════════════════════════════════════════════════
// TontineVault.sol  —  TontineClair Phase 2
//
// Contrat journal d'événements pour TontineClair.
// Architecture : B1 (journal only) + A1 (wallet maître) + C1 (wallet unique)
//
// PRINCIPE :
//   • L'argent reste dans Supabase (custodial Web2)
//   • Ce contrat enregistre UNIQUEMENT des événements on-chain
//   • Chaque opération financière génère un vrai TX Ethereum sur Polygon Amoy
//   • Le TX hash est vérifiable publiquement sur PolygonScan Amoy
//   • Seul l'admin wallet peut émettre des événements (onlyAdmin)
//
// Réseau : Polygon Amoy testnet (chainId 80002) → Polygon Mainnet (Phase 4)
// ═══════════════════════════════════════════════════════════════════════════════

contract TontineVault {

    // ── Storage ────────────────────────────────────────────────────────────────
    address public admin;
    string  public version = "2.0.0";
    uint256 public totalOperations;

    // ── Events ─────────────────────────────────────────────────────────────────
    // Paramètres réduits pour éviter "stack too deep"
    // payloadHash = HMAC-SHA256 de (tontineCode|type|montant|membreId|timestamp)

    event OperationEnregistree(
        string  indexed tontineCode,
        string  typeOperation,   // cotisation|distribution|pret|remboursement|vote|creation|apport
        string  membreId,
        uint256 montantXof,
        uint256 montantUsdt,     // en micro-USDT (× 1e6)
        string  refInterne,
        bytes32 payloadHash,
        uint256 timestamp
    );

    event VoteEnregistre(
        string  indexed tontineCode,
        string  membreId,
        string  question,
        string  choix,
        bytes32 payloadHash,
        uint256 timestamp
    );

    event CreationEnregistree(
        string  indexed tontineCode,
        string  gestionnaireId,
        string  nomTontine,
        bytes32 payloadHash,
        uint256 timestamp
    );

    event AdminTransfere(
        address indexed ancienAdmin,
        address indexed nouvelAdmin,
        uint256 timestamp
    );

    // ── Modifier ───────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "TontineVault: not admin");
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────────────

    constructor() {
        admin = msg.sender;
        emit AdminTransfere(address(0), msg.sender, block.timestamp);
    }

    // ── Admin ──────────────────────────────────────────────────────────────────

    function transfererAdmin(address nouvelAdmin) external onlyAdmin {
        require(nouvelAdmin != address(0), "zero address");
        address ancien = admin;
        admin = nouvelAdmin;
        emit AdminTransfere(ancien, nouvelAdmin, block.timestamp);
    }

    // ── Enregistrement opération financière ────────────────────────────────────
    // Une seule fonction pour cotisation / distribution / pret / remboursement / apport

    function enregistrerOperation(
        string  calldata tontineCode,
        string  calldata typeOperation,
        string  calldata membreId,
        uint256          montantXof,
        uint256          montantUsdt,
        string  calldata refInterne,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit OperationEnregistree(
            tontineCode,
            typeOperation,
            membreId,
            montantXof,
            montantUsdt,
            refInterne,
            payloadHash,
            block.timestamp
        );
    }

    // ── Vote ───────────────────────────────────────────────────────────────────

    function enregistrerVote(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata question,
        string  calldata choix,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit VoteEnregistre(
            tontineCode,
            membreId,
            question,
            choix,
            payloadHash,
            block.timestamp
        );
    }

    // ── Création tontine ───────────────────────────────────────────────────────

    function enregistrerCreation(
        string  calldata tontineCode,
        string  calldata gestionnaireId,
        string  calldata nomTontine,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit CreationEnregistree(
            tontineCode,
            gestionnaireId,
            nomTontine,
            payloadHash,
            block.timestamp
        );
    }

    // ── View ───────────────────────────────────────────────────────────────────

    function getInfo() external view returns (
        address _admin,
        string memory _version,
        uint256 _totalOperations,
        uint256 _chainId
    ) {
        uint256 chainId;
        assembly { chainId := chainid() }
        return (admin, version, totalOperations, chainId);
    }
}
