// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ═══════════════════════════════════════════════════════════════════════════════
// TontineVaultV3.sol  —  TontineClair Phase 3
//
// NOUVEAUTÉ v3 : une fonction par action métier → noms lisibles sur PolygonScan
//
// Fonctions métier :
//   enregistrerCotisation      — paiement de cotisation mensuelle
//   enregistrerDistribution    — versement du tour à un bénéficiaire
//   enregistrerDecaissement    — décaissement fonds
//   enregistrerDepot           — dépôt dans la tontine
//   enregistrerPret            — prêt accordé à un membre
//   enregistrerRemboursement   — remboursement d'un prêt
//   enregistrerPenalite        — pénalité appliquée
//   enregistrerRetrait         — retrait de fonds
//   enregistrerApport          — apport de capital
//   enregistrerSynchronisation — sync solde on-chain
//   enregistrerVoteCree        — création d'un vote
//   enregistrerVoteClos        — clôture d'un vote (adopté/rejeté)
//   enregistrerVoteIndividuel  — vote individuel d'un membre
//   enregistrerRetraitPropose  — proposition de retrait d'un membre
//   enregistrerScoreModifie    — modification du score de confiance
//   enregistrerNouveauCycle    — démarrage d'un nouveau cycle
//   enregistrerCreation        — création de la tontine
//   enregistrerUpgradePro      — passage en formule Pro
//
// Réseau : Polygon Mainnet (chainId 137)
// Version : 3.0.0
// ═══════════════════════════════════════════════════════════════════════════════

contract TontineVaultV3 {

    // ── Storage ────────────────────────────────────────────────────────────────
    address public admin;
    string  public version = "3.0.0";
    uint256 public totalOperations;

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

    // ══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ══════════════════════════════════════════════════════════════════════════

    // Événement générique pour toutes les opérations financières
    event OperationFinanciere(
        string  indexed tontineCode,
        string  typeOperation,
        string  membreId,
        string  membreNom,
        uint256 montantXof,
        string  refInterne,
        bytes32 payloadHash,
        uint256 timestamp
    );

    // Événement pour les votes
    event EvenementVote(
        string  indexed tontineCode,
        string  typeVote,     // vote_cree | vote_clos | vote_individuel | retrait_propose
        string  membreId,
        string  membreNom,
        string  refVote,      // voteId ou question
        bytes32 payloadHash,
        uint256 timestamp
    );

    // Événement pour les événements système
    event EvenementSysteme(
        string  indexed tontineCode,
        string  typeEvenement, // creation | upgrade_pro | nouveau_cycle | score_modifie
        string  membreId,
        string  membreNom,
        string  details,
        bytes32 payloadHash,
        uint256 timestamp
    );

    event AdminTransfere(
        address indexed ancienAdmin,
        address indexed nouvelAdmin,
        uint256 timestamp
    );

    // ══════════════════════════════════════════════════════════════════════════
    // FONCTIONS MÉTIER — FINANCES
    // ══════════════════════════════════════════════════════════════════════════

    function enregistrerCotisation(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        uint256          montantXof,
        string  calldata refInterne,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit OperationFinanciere(tontineCode, "cotisation", membreId, membreNom,
            montantXof, refInterne, payloadHash, block.timestamp);
    }

    function enregistrerDistribution(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        uint256          montantXof,
        string  calldata refInterne,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit OperationFinanciere(tontineCode, "distribution", membreId, membreNom,
            montantXof, refInterne, payloadHash, block.timestamp);
    }

    function enregistrerDecaissement(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        uint256          montantXof,
        string  calldata refInterne,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit OperationFinanciere(tontineCode, "decaissement", membreId, membreNom,
            montantXof, refInterne, payloadHash, block.timestamp);
    }

    function enregistrerDepot(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        uint256          montantXof,
        string  calldata refInterne,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit OperationFinanciere(tontineCode, "depot", membreId, membreNom,
            montantXof, refInterne, payloadHash, block.timestamp);
    }

    function enregistrerPret(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        uint256          montantXof,
        string  calldata refInterne,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit OperationFinanciere(tontineCode, "pret", membreId, membreNom,
            montantXof, refInterne, payloadHash, block.timestamp);
    }

    function enregistrerRemboursement(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        uint256          montantXof,
        string  calldata refInterne,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit OperationFinanciere(tontineCode, "remboursement", membreId, membreNom,
            montantXof, refInterne, payloadHash, block.timestamp);
    }

    function enregistrerPenalite(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        uint256          montantXof,
        string  calldata refInterne,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit OperationFinanciere(tontineCode, "penalite", membreId, membreNom,
            montantXof, refInterne, payloadHash, block.timestamp);
    }

    function enregistrerRetrait(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        uint256          montantXof,
        string  calldata refInterne,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit OperationFinanciere(tontineCode, "retrait", membreId, membreNom,
            montantXof, refInterne, payloadHash, block.timestamp);
    }

    function enregistrerApport(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        uint256          montantXof,
        string  calldata refInterne,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit OperationFinanciere(tontineCode, "apport", membreId, membreNom,
            montantXof, refInterne, payloadHash, block.timestamp);
    }

    function enregistrerSynchronisation(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        uint256          montantXof,
        string  calldata refInterne,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit OperationFinanciere(tontineCode, "synchronisation", membreId, membreNom,
            montantXof, refInterne, payloadHash, block.timestamp);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // FONCTIONS MÉTIER — VOTES
    // ══════════════════════════════════════════════════════════════════════════

    function enregistrerVoteCree(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        string  calldata refVote,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit EvenementVote(tontineCode, "vote_cree", membreId, membreNom,
            refVote, payloadHash, block.timestamp);
    }

    function enregistrerVoteClos(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        string  calldata refVote,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit EvenementVote(tontineCode, "vote_clos", membreId, membreNom,
            refVote, payloadHash, block.timestamp);
    }

    function enregistrerVoteIndividuel(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        string  calldata refVote,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit EvenementVote(tontineCode, "vote", membreId, membreNom,
            refVote, payloadHash, block.timestamp);
    }

    function enregistrerRetraitPropose(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        string  calldata refVote,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit EvenementVote(tontineCode, "retrait_propose", membreId, membreNom,
            refVote, payloadHash, block.timestamp);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // FONCTIONS MÉTIER — SYSTÈME
    // ══════════════════════════════════════════════════════════════════════════

    function enregistrerCreation(
        string  calldata tontineCode,
        string  calldata gestionnaireId,
        string  calldata gestionnaireNom,
        string  calldata nomTontine,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit EvenementSysteme(tontineCode, "creation", gestionnaireId, gestionnaireNom,
            nomTontine, payloadHash, block.timestamp);
    }

    function enregistrerUpgradePro(
        string  calldata tontineCode,
        string  calldata gestionnaireId,
        string  calldata gestionnaireNom,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit EvenementSysteme(tontineCode, "upgrade_pro", gestionnaireId, gestionnaireNom,
            "", payloadHash, block.timestamp);
    }

    function enregistrerNouveauCycle(
        string  calldata tontineCode,
        string  calldata gestionnaireId,
        string  calldata gestionnaireNom,
        string  calldata details,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit EvenementSysteme(tontineCode, "nouveau_cycle", gestionnaireId, gestionnaireNom,
            details, payloadHash, block.timestamp);
    }

    function enregistrerScoreModifie(
        string  calldata tontineCode,
        string  calldata membreId,
        string  calldata membreNom,
        string  calldata details,
        bytes32          payloadHash
    ) external onlyAdmin {
        totalOperations++;
        emit EvenementSysteme(tontineCode, "score_modifie", membreId, membreNom,
            details, payloadHash, block.timestamp);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ══════════════════════════════════════════════════════════════════════════

    function transfererAdmin(address nouvelAdmin) external onlyAdmin {
        require(nouvelAdmin != address(0), "zero address");
        address ancien = admin;
        admin = nouvelAdmin;
        emit AdminTransfere(ancien, nouvelAdmin, block.timestamp);
    }

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
