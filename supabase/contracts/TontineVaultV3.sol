// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ═══════════════════════════════════════════════════════════════════════════════
// TontineVaultV3.sol  —  TontineClair V3  (100% Blockchain / Non-Custodial)
//
// Architecture non-custodiale sur Polygon Mainnet (chainId 137)
//
// PRINCIPE V3 :
//   • Les fonds USDT sont détenus DIRECTEMENT par ce contrat
//   • cotiser()      : approve() + transferFrom()  côté membre
//   • executerTour() : distribution automatique, appelable par quiconque
//   • reclamerDistribution() : le bénéficiaire retire ses USDT
//   • Supabase = cache/KYC/notifications uniquement (lecture)
//   • Aucun admin ne peut toucher aux fonds des membres
//   • Urgence uniquement via multisig + timelock
//
// Sécurité :
//   SafeERC20 · ReentrancyGuard · Pausable · AccessControl
//   Multisig 2-of-3 pour fonctions d'urgence · Timelock 48h
//
// Réseau : Polygon Mainnet (chainId 137)
// Token  : USDT (0xc2132D05D31c914a87C6611C10748AEb04B58e8F) — 6 décimales
//
// Version : 3.0.0
// ═══════════════════════════════════════════════════════════════════════════════

// ── OpenZeppelin inline (self-contained, pas de node_modules) ─────────────────

// IERC20
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// SafeERC20
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "SafeERC20: transfer failed");
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(token.transferFrom(from, to, value), "SafeERC20: transferFrom failed");
    }
}

// ReentrancyGuard
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;
    constructor() { _status = _NOT_ENTERED; }
    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

// Pausable
abstract contract Pausable {
    bool private _paused;
    event Paused(address account);
    event Unpaused(address account);
    constructor() { _paused = false; }
    function paused() public view returns (bool) { return _paused; }
    modifier whenNotPaused() { require(!_paused, "Pausable: paused"); _; }
    modifier whenPaused()    { require(_paused,  "Pausable: not paused"); _; }
    function _pause() internal whenNotPaused { _paused = true; emit Paused(msg.sender); }
    function _unpause() internal whenPaused  { _paused = false; emit Unpaused(msg.sender); }
}

// ═══════════════════════════════════════════════════════════════════════════════
// CONTRAT PRINCIPAL
// ═══════════════════════════════════════════════════════════════════════════════

contract TontineVaultV3 is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ── Constantes ─────────────────────────────────────────────────────────────
    IERC20  public  immutable usdt;
    uint256 public  constant  USDT_DECIMALS    = 1e6;       // 6 décimales
    uint256 public  constant  FRAIS_PLATEFORME = 100;       // 1% (base 10000)
    uint256 public  constant  PENALITE_RETARD  = 200;       // 2%
    uint256 public  constant  TIMELOCK_DUREE   = 48 hours;
    uint256 public  constant  VERSION          = 3;

    string  public  constant  VERSION_STR      = "3.0.0";

    // ── Rôles (AccessControl simplifié) ────────────────────────────────────────
    address public  owner;
    address[3] public multisigSigners;          // 3 signataires multisig
    uint256 public  multisigThreshold = 2;      // 2-of-3

    // ── Timelock ────────────────────────────────────────────────────────────────
    struct TimelockAction {
        bytes32 actionHash;
        uint256 executionTime;
        uint256 confirmations;
        mapping(address => bool) confirmed;
        bool executed;
    }
    mapping(bytes32 => TimelockAction) public timelockActions;

    // ── Types énumérés ──────────────────────────────────────────────────────────
    enum TypeOrdre    { FIXE, TIRAGE, VOTE }
    enum FrequenceTour{ HEBDO, MENSUEL, BIMENSUEL, TRIMESTRIEL }
    enum StatutTontine{ EN_ATTENTE, ACTIVE, TERMINEE, ANNULEE }
    enum StatutMembre { ACTIF, EN_RETARD, EXCLU, SORTI }

    // ── Structures ──────────────────────────────────────────────────────────────

    struct Tontine {
        string       code;                  // code unique (ex: "49LJP3")
        string       nom;
        address      gestionnaire;          // wallet du créateur
        uint256      montantCotisation;     // en USDT (micro)
        uint256      nombreMembresMax;
        uint256      nombreMembresActuel;
        FrequenceTour frequence;
        TypeOrdre    typeOrdre;
        uint256      tourActuel;            // 0-indexed
        uint256      nombreTours;           // = nombreMembresMax
        uint256      dateProchainTour;      // timestamp UNIX
        uint256      totalCollecte;         // total USDT reçu (micro)
        uint256      totalDistribue;        // total USDT distribué
        uint256      soldeContrat;          // USDT actuellement détenus
        StatutTontine statut;
        bool         inscriptionOuverte;
        uint256      createdAt;
        // Ordre des bénéficiaires (addresses dans l'ordre des tours)
        address[]    ordreBeneficiaires;
    }

    struct Membre {
        address      wallet;
        string       membreId;             // UUID Supabase
        string       nom;
        uint256      cotisationsPaye;      // nombre de tours payés
        uint256      totalVerse;           // USDT total versé (micro)
        uint256      distributionRecue;    // USDT reçu (micro)
        uint256      distributionPending;  // USDT à réclamer
        uint256      penalitesTotales;     // USDT pénalités cumulées
        bool         aBeneficie;           // a déjà reçu sa distribution
        uint256      tourBenefice;         // quel tour
        StatutMembre statut;
        uint256      dernieresCotisation;  // timestamp dernière cotisation
        bool         cotiseTourActuel;     // a cotisé ce tour ?
    }

    // ── Storage principal ───────────────────────────────────────────────────────
    mapping(string  => Tontine)  public tontines;          // code → Tontine
    mapping(string  => mapping(address => Membre)) public membres; // code → wallet → Membre
    mapping(string  => address[]) public membresList;      // code → liste wallets
    mapping(address => string[])  public tontinesParWallet; // wallet → codes

    // Frais collectés pour la plateforme
    uint256 public fraisPlatformeAccumules;

    // Anti-double distribution par tour
    mapping(string => mapping(uint256 => bool)) public tourExecute;

    // ── Events ──────────────────────────────────────────────────────────────────
    event TontineCreee(
        string  indexed code,
        address indexed gestionnaire,
        string  nom,
        uint256 montantCotisation,
        uint256 nombreMembres,
        uint8   typeOrdre,
        uint8   frequence,
        uint256 timestamp
    );

    event MembreRejoins(
        string  indexed code,
        address indexed wallet,
        string  membreId,
        uint256 positionOrdre,
        uint256 timestamp
    );

    event CotisationRecue(
        string  indexed code,
        address indexed wallet,
        string  membreId,
        uint256 montant,
        uint256 tour,
        uint256 timestamp
    );

    event RetardSignale(
        string  indexed code,
        address indexed wallet,
        uint256 tour,
        uint256 penalite,
        uint256 timestamp
    );

    event PenaliteAppliquee(
        string  indexed code,
        address indexed wallet,
        uint256 montant,
        uint256 timestamp
    );

    event TourExecute(
        string  indexed code,
        address indexed beneficiaire,
        uint256 tour,
        uint256 montantBrut,
        uint256 frais,
        uint256 montantNet,
        uint256 timestamp
    );

    event DistributionDisponible(
        string  indexed code,
        address indexed beneficiaire,
        uint256 montant,
        uint256 tour,
        uint256 timestamp
    );

    event DistributionReclamee(
        string  indexed code,
        address indexed beneficiaire,
        uint256 montant,
        uint256 timestamp
    );

    event TontineTerminee(
        string  indexed code,
        uint256 totalCollecte,
        uint256 totalDistribue,
        uint256 frais,
        uint256 timestamp
    );

    event TontineAnnulee(
        string  indexed code,
        address indexed gestionnaire,
        string  motif,
        uint256 timestamp
    );

    event RemboursementReclame(
        string  indexed code,
        address indexed wallet,
        uint256 montant,
        uint256 timestamp
    );

    event TimelockPropose(bytes32 indexed actionHash, uint256 executionTime);
    event TimelockConfirme(bytes32 indexed actionHash, address signer);
    event TimelockExecute(bytes32 indexed actionHash);
    event FraisRetires(address indexed destinataire, uint256 montant, uint256 timestamp);
    event MultisigMisAJour(address[3] signers, uint256 threshold);

    // ── Modificateurs ───────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "V3: not owner");
        _;
    }

    modifier onlyMultisig() {
        bool isSigner = false;
        for (uint i = 0; i < 3; i++) {
            if (multisigSigners[i] == msg.sender) { isSigner = true; break; }
        }
        require(isSigner, "V3: not multisig signer");
        _;
    }

    modifier tontineExiste(string calldata code) {
        require(tontines[code].createdAt > 0, "V3: tontine inexistante");
        _;
    }

    modifier tontineActive(string calldata code) {
        require(tontines[code].statut == StatutTontine.ACTIVE, "V3: tontine non active");
        _;
    }

    modifier membreExiste(string calldata code, address wallet) {
        require(membres[code][wallet].wallet != address(0), "V3: membre inexistant");
        _;
    }

    // ── Constructeur ────────────────────────────────────────────────────────────

    constructor(
        address _usdtAddress,
        address _signer1,
        address _signer2,
        address _signer3
    ) {
        require(_usdtAddress != address(0), "V3: zero USDT address");
        require(_signer1 != address(0) && _signer2 != address(0) && _signer3 != address(0),
                "V3: zero signer");
        usdt              = IERC20(_usdtAddress);
        owner             = msg.sender;
        multisigSigners[0] = _signer1;
        multisigSigners[1] = _signer2;
        multisigSigners[2] = _signer3;
    }

    // ════════════════════════════════════════════════════════════════════════════
    // FONCTIONS PUBLIQUES — Membres
    // ════════════════════════════════════════════════════════════════════════════

    // ── creerTontine ─────────────────────────────────────────────────────────────
    /// @notice Crée une nouvelle tontine on-chain.
    /// @param code          Code unique (ex: "49LJP3")
    /// @param nom           Nom de la tontine
    /// @param montant       Montant de cotisation par tour (en USDT micro = ×1e6)
    /// @param nbreMembres   Nombre de membres (= nombre de tours)
    /// @param frequence     0=hebdo, 1=mensuel, 2=bimensuel, 3=trimestriel
    /// @param typeOrdre     0=fixe, 1=tirage, 2=vote
    function creerTontine(
        string  calldata code,
        string  calldata nom,
        uint256          montant,
        uint256          nbreMembres,
        uint8            frequence,
        uint8            typeOrdre
    ) external whenNotPaused {
        require(bytes(code).length >= 4 && bytes(code).length <= 20, "V3: code invalide");
        require(tontines[code].createdAt == 0,                        "V3: code deja utilise");
        require(montant >= 1 * USDT_DECIMALS,                         "V3: montant minimum 1 USDT");
        require(nbreMembres >= 2 && nbreMembres <= 50,                "V3: 2-50 membres");
        require(frequence <= 3,                                        "V3: frequence invalide");
        require(typeOrdre <= 2,                                        "V3: typeOrdre invalide");

        Tontine storage t      = tontines[code];
        t.code                 = code;
        t.nom                  = nom;
        t.gestionnaire         = msg.sender;
        t.montantCotisation    = montant;
        t.nombreMembresMax     = nbreMembres;
        t.nombreMembresActuel  = 0;
        t.frequence            = FrequenceTour(frequence);
        t.typeOrdre            = TypeOrdre(typeOrdre);
        t.tourActuel           = 0;
        t.nombreTours          = nbreMembres;
        t.statut               = StatutTontine.EN_ATTENTE;
        t.inscriptionOuverte   = true;
        t.createdAt            = block.timestamp;

        tontinesParWallet[msg.sender].push(code);

        emit TontineCreee(code, msg.sender, nom, montant, nbreMembres, typeOrdre, frequence, block.timestamp);
    }

    // ── rejoindreTontine ─────────────────────────────────────────────────────────
    /// @notice Rejoint une tontine (inscription).
    /// @param code      Code de la tontine
    /// @param membreId  UUID Supabase du membre
    /// @param nom       Nom du membre
    function rejoindreTontine(
        string calldata code,
        string calldata membreId,
        string calldata nom
    ) external whenNotPaused tontineExiste(code) {
        Tontine storage t = tontines[code];

        require(t.inscriptionOuverte,                    "V3: inscription fermee");
        require(t.statut == StatutTontine.EN_ATTENTE,    "V3: tontine deja active");
        require(t.nombreMembresActuel < t.nombreMembresMax, "V3: tontine complete");
        require(membres[code][msg.sender].wallet == address(0), "V3: deja membre");

        Membre storage m    = membres[code][msg.sender];
        m.wallet            = msg.sender;
        m.membreId          = membreId;
        m.nom               = nom;
        m.statut            = StatutMembre.ACTIF;
        m.cotisationsPaye   = 0;
        m.totalVerse        = 0;
        m.distributionRecue = 0;
        m.aBeneficie        = false;

        t.nombreMembresActuel++;
        t.ordreBeneficiaires.push(msg.sender);
        membresList[code].push(msg.sender);
        tontinesParWallet[msg.sender].push(code);

        uint256 position = t.ordreBeneficiaires.length - 1;

        // Si tontine complète → démarrer automatiquement
        if (t.nombreMembresActuel == t.nombreMembresMax) {
            _demarrerTontine(code);
        }

        emit MembreRejoins(code, msg.sender, membreId, position, block.timestamp);
    }

    // ── cotiser ──────────────────────────────────────────────────────────────────
    /// @notice Verse la cotisation pour le tour actuel.
    ///         Le membre doit avoir approuvé ce contrat via USDT.approve()
    ///         pour au moins montantCotisation avant d'appeler cette fonction.
    /// @param code Code de la tontine
    function cotiser(string calldata code)
        external
        nonReentrant
        whenNotPaused
        tontineExiste(code)
        tontineActive(code)
        membreExiste(code, msg.sender)
    {
        Tontine storage t = tontines[code];
        Membre  storage m = membres[code][msg.sender];

        require(m.statut == StatutMembre.ACTIF || m.statut == StatutMembre.EN_RETARD,
                "V3: membre exclu");
        require(!m.cotiseTourActuel, "V3: deja cotise ce tour");
        require(t.tourActuel < t.nombreTours, "V3: tontine terminee");

        uint256 montant = t.montantCotisation;

        // Vérifier allowance
        require(
            usdt.allowance(msg.sender, address(this)) >= montant,
            "V3: allowance insuffisante - appelez USDT.approve() d'abord"
        );

        // Transfert USDT membre → contrat
        usdt.safeTransferFrom(msg.sender, address(this), montant);

        // Mise à jour état
        m.cotisationsPaye++;
        m.totalVerse         += montant;
        m.cotiseTourActuel    = true;
        m.dernieresCotisation = block.timestamp;
        if (m.statut == StatutMembre.EN_RETARD) {
            m.statut = StatutMembre.ACTIF;
        }

        t.totalCollecte  += montant;
        t.soldeContrat   += montant;

        emit CotisationRecue(code, msg.sender, m.membreId, montant, t.tourActuel, block.timestamp);
    }

    // ── executerTour ─────────────────────────────────────────────────────────────
    /// @notice Exécute le tour actuel si toutes les conditions sont remplies.
    ///         Peut être appelé par QUICONQUE (membre, automatisation, ou tiers).
    ///         Le contrat vérifie lui-même toutes les conditions.
    /// @param code Code de la tontine
    function executerTour(string calldata code)
        external
        nonReentrant
        whenNotPaused
        tontineExiste(code)
        tontineActive(code)
    {
        Tontine storage t = tontines[code];

        require(!tourExecute[code][t.tourActuel],     "V3: tour deja execute");
        require(t.tourActuel < t.nombreTours,          "V3: tous tours executes");
        require(block.timestamp >= t.dateProchainTour, "V3: trop tot pour ce tour");

        // Vérifier que suffisamment de membres ont cotisé
        uint256 cotisationsCount = _compterCotisationsActuelles(code);
        require(
            cotisationsCount >= t.nombreMembresActuel * 80 / 100,
            "V3: moins de 80% des membres ont cotise"
        );

        // Identifier le bénéficiaire
        address beneficiaire = _getBeneficiaire(code, t.tourActuel);
        require(beneficiaire != address(0), "V3: beneficiaire invalide");

        // Calculer montant brut collecté ce tour
        uint256 montantBrut = cotisationsCount * t.montantCotisation;

        // Calculer frais plateforme (1%)
        uint256 frais      = montantBrut * FRAIS_PLATEFORME / 10000;
        uint256 montantNet = montantBrut - frais;

        // Vérifier que le contrat a bien les fonds
        require(t.soldeContrat >= montantNet, "V3: solde contrat insuffisant");

        // Marquer tour comme exécuté AVANT le transfert (reentrancy protection)
        tourExecute[code][t.tourActuel] = true;

        // Accumule les frais (retirables par owner via timelock)
        fraisPlatformeAccumules += frais;

        // Créer distribution pending pour le bénéficiaire
        Membre storage benef = membres[code][beneficiaire];
        benef.distributionPending += montantNet;
        benef.aBeneficie           = true;
        benef.tourBenefice         = t.tourActuel;

        // Mise à jour tontine
        t.totalDistribue  += montantNet;
        t.soldeContrat    -= montantNet;
        t.soldeContrat    -= frais;

        // Appliquer pénalités aux retardataires
        _appliquerPenalitesRetardataires(code);

        // Réinitialiser cotiseTourActuel pour le prochain tour
        _reinitialiserCotisationsTour(code);

        // Avancer le tour
        uint256 tourExecuteNum = t.tourActuel;
        t.tourActuel++;

        // Calculer date prochain tour
        if (t.tourActuel < t.nombreTours) {
            t.dateProchainTour = _calculerProchaineTour(t.frequence);
        }

        // Terminer si dernier tour
        if (t.tourActuel >= t.nombreTours) {
            t.statut = StatutTontine.TERMINEE;
            t.inscriptionOuverte = false;
            emit TontineTerminee(code, t.totalCollecte, t.totalDistribue,
                                  fraisPlatformeAccumules, block.timestamp);
        }

        emit TourExecute(code, beneficiaire, tourExecuteNum, montantBrut, frais, montantNet, block.timestamp);
        emit DistributionDisponible(code, beneficiaire, montantNet, tourExecuteNum, block.timestamp);
    }

    // ── reclamerDistribution ─────────────────────────────────────────────────────
    /// @notice Le bénéficiaire d'un tour réclame ses USDT.
    ///         Pull pattern : le bénéficiaire initie le retrait (plus sûr que push).
    /// @param code Code de la tontine
    function reclamerDistribution(string calldata code)
        external
        nonReentrant
        whenNotPaused
        tontineExiste(code)
        membreExiste(code, msg.sender)
    {
        Membre storage m = membres[code][msg.sender];

        require(m.distributionPending > 0, "V3: aucune distribution disponible");

        uint256 montant          = m.distributionPending;
        m.distributionPending    = 0;
        m.distributionRecue     += montant;

        // Transfert USDT contrat → bénéficiaire
        usdt.safeTransfer(msg.sender, montant);

        emit DistributionReclamee(code, msg.sender, montant, block.timestamp);
    }

    // ── annulerTontine ────────────────────────────────────────────────────────────
    /// @notice Annule une tontine (gestionnaire ou owner).
    ///         Accessible uniquement en phase EN_ATTENTE ou si aucun tour n'a été exécuté.
    ///         Les fonds éventuellement déposés sont remboursables via reclamerRemboursement().
    /// @param code  Code de la tontine
    /// @param motif Raison de l'annulation
    function annulerTontine(string calldata code, string calldata motif)
        external
        tontineExiste(code)
    {
        Tontine storage t = tontines[code];

        require(
            msg.sender == t.gestionnaire || msg.sender == owner,
            "V3: non autorise"
        );
        require(
            t.statut == StatutTontine.EN_ATTENTE ||
            (t.statut == StatutTontine.ACTIVE && t.tourActuel == 0),
            "V3: annulation impossible apres premier tour"
        );

        t.statut             = StatutTontine.ANNULEE;
        t.inscriptionOuverte = false;

        emit TontineAnnulee(code, msg.sender, motif, block.timestamp);
    }

    // ── reclamerRemboursement ─────────────────────────────────────────────────────
    /// @notice Un membre réclame ses fonds si la tontine est annulée.
    ///         Rembourse les cotisations versées non encore distribuées.
    /// @param code Code de la tontine
    function reclamerRemboursement(string calldata code)
        external
        nonReentrant
        whenNotPaused
        tontineExiste(code)
        membreExiste(code, msg.sender)
    {
        Tontine storage t = tontines[code];
        Membre  storage m = membres[code][msg.sender];

        require(t.statut == StatutTontine.ANNULEE, "V3: tontine non annulee");
        require(m.totalVerse > m.distributionRecue, "V3: rien a rembourser");
        // Empêcher double remboursement
        require(m.statut != StatutMembre.SORTI, "V3: deja rembourse");

        uint256 montant = m.totalVerse - m.distributionRecue;
        // Déduire distribution pending non reclamée (déjà comptabilisée)
        if (m.distributionPending > 0) {
            montant = montant > m.distributionPending
                ? montant - m.distributionPending
                : 0;
            m.distributionPending = 0;
        }

        require(montant > 0, "V3: montant zero");
        require(t.soldeContrat >= montant, "V3: solde contrat insuffisant");

        m.statut         = StatutMembre.SORTI;
        t.soldeContrat  -= montant;

        usdt.safeTransfer(msg.sender, montant);

        emit RemboursementReclame(code, msg.sender, montant, block.timestamp);
    }

    // ── demarrerTontineManuel ─────────────────────────────────────────────────────
    /// @notice Démarre manuellement une tontine complète (si auto-démarrage échoue).
    ///         Appelable uniquement par le gestionnaire.
    function demarrerTontineManuel(string calldata code)
        external
        tontineExiste(code)
    {
        Tontine storage t = tontines[code];
        require(msg.sender == t.gestionnaire || msg.sender == owner, "V3: non autorise");
        require(t.statut == StatutTontine.EN_ATTENTE, "V3: deja active");
        require(t.nombreMembresActuel >= 2,            "V3: minimum 2 membres");

        _demarrerTontine(code);
    }

    // ════════════════════════════════════════════════════════════════════════════
    // FONCTIONS ADMIN / MULTISIG (urgence uniquement)
    // ════════════════════════════════════════════════════════════════════════════

    // ── Pause d'urgence (owner seul) ────────────────────────────────────────────
    function pauserUrgence()   external onlyOwner { _pause(); }
    function reprendreUrgence() external onlyOwner whenPaused {
        // Requiert approbation multisig via timelock
        bytes32 h = keccak256(abi.encodePacked("UNPAUSE", block.timestamp / 1 hours));
        require(_timelockReady(h), "V3: timelock non valide");
        _unpause();
        timelockActions[h].executed = true;
        emit TimelockExecute(h);
    }

    // ── Proposer action timelock (multisig) ─────────────────────────────────────
    function proposerAction(bytes32 actionHash) external onlyMultisig {
        TimelockAction storage a = timelockActions[actionHash];
        if (a.executionTime == 0) {
            a.actionHash     = actionHash;
            a.executionTime  = block.timestamp + TIMELOCK_DUREE;
            a.confirmations  = 0;
            a.executed       = false;
            emit TimelockPropose(actionHash, a.executionTime);
        }
        require(!a.confirmed[msg.sender], "V3: deja confirme");
        require(!a.executed,              "V3: deja execute");
        a.confirmed[msg.sender] = true;
        a.confirmations++;
        emit TimelockConfirme(actionHash, msg.sender);
    }

    // ── Retrait des frais plateforme (timelock + multisig) ──────────────────────
    function retirerFraisPlateforme(address destinataire) external onlyOwner nonReentrant {
        bytes32 h = keccak256(abi.encodePacked("RETIRER_FRAIS", destinataire));
        require(_timelockReady(h), "V3: timelock non confirme ou trop tot");

        uint256 montant = fraisPlatformeAccumules;
        require(montant > 0, "V3: aucun frais");

        fraisPlatformeAccumules  = 0;
        timelockActions[h].executed = true;

        usdt.safeTransfer(destinataire, montant);
        emit FraisRetires(destinataire, montant, block.timestamp);
        emit TimelockExecute(h);
    }

    // ── Mettre à jour multisig (timelock requis) ─────────────────────────────────
    function mettreAJourMultisig(
        address s1, address s2, address s3, uint256 threshold
    ) external onlyOwner {
        bytes32 h = keccak256(abi.encodePacked("UPDATE_MULTISIG", s1, s2, s3));
        require(_timelockReady(h), "V3: timelock requis");
        require(threshold >= 2 && threshold <= 3, "V3: threshold 2 ou 3");

        multisigSigners[0] = s1;
        multisigSigners[1] = s2;
        multisigSigners[2] = s3;
        multisigThreshold  = threshold;

        timelockActions[h].executed = true;
        emit MultisigMisAJour([s1, s2, s3], threshold);
        emit TimelockExecute(h);
    }

    // ════════════════════════════════════════════════════════════════════════════
    // FONCTIONS DE LECTURE (GETTERS)
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice Retourne les infos complètes d'une tontine.
    function getTontine(string calldata code) external view returns (
        string memory   _code,
        string memory   _nom,
        address         _gestionnaire,
        uint256         _montantCotisation,
        uint256         _nombreMembresMax,
        uint256         _nombreMembresActuel,
        uint8           _frequence,
        uint8           _typeOrdre,
        uint256         _tourActuel,
        uint256         _dateProchainTour,
        uint256         _totalCollecte,
        uint256         _soldeContrat,
        uint8           _statut,
        bool            _inscriptionOuverte
    ) {
        Tontine storage t = tontines[code];
        return (
            t.code, t.nom, t.gestionnaire,
            t.montantCotisation, t.nombreMembresMax, t.nombreMembresActuel,
            uint8(t.frequence), uint8(t.typeOrdre),
            t.tourActuel, t.dateProchainTour,
            t.totalCollecte, t.soldeContrat,
            uint8(t.statut), t.inscriptionOuverte
        );
    }

    /// @notice Retourne les infos d'un membre.
    function getMembre(string calldata code, address wallet) external view returns (
        address _wallet,
        string memory _membreId,
        string memory _nom,
        uint256 _cotisationsPaye,
        uint256 _totalVerse,
        uint256 _distributionRecue,
        uint256 _distributionPending,
        uint256 _penalitesTotales,
        bool    _aBeneficie,
        uint256 _tourBenefice,
        uint8   _statut
    ) {
        Membre storage m = membres[code][wallet];
        return (
            m.wallet, m.membreId, m.nom,
            m.cotisationsPaye, m.totalVerse,
            m.distributionRecue, m.distributionPending,
            m.penalitesTotales, m.aBeneficie, m.tourBenefice,
            uint8(m.statut)
        );
    }

    /// @notice Retourne le bénéficiaire du prochain tour.
    function getProchainBeneficiaire(string calldata code) external view returns (
        address _beneficiaire,
        uint256 _tourActuel,
        uint256 _dateProchainTour,
        bool    _tourPret
    ) {
        Tontine storage t = tontines[code];
        address benef = _getBeneficiaire(code, t.tourActuel);
        bool pret = block.timestamp >= t.dateProchainTour && !tourExecute[code][t.tourActuel];
        return (benef, t.tourActuel, t.dateProchainTour, pret);
    }

    /// @notice Retourne la liste des wallets membres.
    function getMembresListe(string calldata code) external view returns (address[] memory) {
        return membresList[code];
    }

    /// @notice Retourne les tontines d'un wallet.
    function getTontinesParWallet(address wallet) external view returns (string[] memory) {
        return tontinesParWallet[wallet];
    }

    /// @notice Retourne le solde USDT actuellement détenu pour une tontine.
    function getSoldeContrat(string calldata code) external view returns (uint256) {
        return tontines[code].soldeContrat;
    }

    /// @notice Retourne infos générales du contrat V3.
    function getContractInfo() external view returns (
        string memory version,
        address usdtAddress,
        uint256 fraisAccumules,
        uint256 chainId,
        bool    _paused
    ) {
        uint256 cid;
        assembly { cid := chainid() }
        return (VERSION_STR, address(usdt), fraisPlatformeAccumules, cid, paused());
    }

    // ════════════════════════════════════════════════════════════════════════════
    // FONCTIONS INTERNES
    // ════════════════════════════════════════════════════════════════════════════

    function _demarrerTontine(string memory code) internal {
        Tontine storage t = tontines[code];
        t.statut           = StatutTontine.ACTIVE;
        t.inscriptionOuverte = false;
        t.dateProchainTour = _calculerProchaineTour(t.frequence);

        // Si typeOrdre == TIRAGE → mélanger l'ordre (déterministe via blockhash)
        if (t.typeOrdre == TypeOrdre.TIRAGE) {
            _melangerOrdre(code);
        }
    }

    function _calculerProchaineTour(FrequenceTour freq) internal view returns (uint256) {
        if (freq == FrequenceTour.HEBDO)        return block.timestamp + 7  days;
        if (freq == FrequenceTour.MENSUEL)      return block.timestamp + 30 days;
        if (freq == FrequenceTour.BIMENSUEL)    return block.timestamp + 60 days;
        if (freq == FrequenceTour.TRIMESTRIEL)  return block.timestamp + 90 days;
        return block.timestamp + 30 days;
    }

    function _getBeneficiaire(string memory code, uint256 tour) internal view returns (address) {
        Tontine storage t = tontines[code];
        if (t.ordreBeneficiaires.length == 0) return address(0);
        uint256 idx = tour % t.ordreBeneficiaires.length;
        return t.ordreBeneficiaires[idx];
    }

    function _compterCotisationsActuelles(string memory code) internal view returns (uint256) {
        address[] storage liste = membresList[code];
        uint256 count = 0;
        for (uint256 i = 0; i < liste.length; i++) {
            if (membres[code][liste[i]].cotiseTourActuel) count++;
        }
        return count;
    }

    function _appliquerPenalitesRetardataires(string memory code) internal {
        Tontine storage t = tontines[code];
        address[] storage liste = membresList[code];
        for (uint256 i = 0; i < liste.length; i++) {
            Membre storage m = membres[code][liste[i]];
            if (!m.cotiseTourActuel && m.statut == StatutMembre.ACTIF) {
                m.statut = StatutMembre.EN_RETARD;
                uint256 penalite = t.montantCotisation * PENALITE_RETARD / 10000;
                m.penalitesTotales += penalite;
                fraisPlatformeAccumules += penalite; // les pénalités vont à la plateforme
                emit RetardSignale(code, liste[i], t.tourActuel, penalite, block.timestamp);
                emit PenaliteAppliquee(code, liste[i], penalite, block.timestamp);
            }
        }
    }

    function _reinitialiserCotisationsTour(string memory code) internal {
        address[] storage liste = membresList[code];
        for (uint256 i = 0; i < liste.length; i++) {
            membres[code][liste[i]].cotiseTourActuel = false;
        }
    }

    function _melangerOrdre(string memory code) internal {
        Tontine storage t = tontines[code];
        uint256 n = t.ordreBeneficiaires.length;
        // Fisher-Yates shuffle déterministe (blockhash)
        for (uint256 i = n - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encodePacked(
                blockhash(block.number - 1), i, code
            ))) % (i + 1);
            address tmp = t.ordreBeneficiaires[i];
            t.ordreBeneficiaires[i] = t.ordreBeneficiaires[j];
            t.ordreBeneficiaires[j] = tmp;
        }
    }

    function _timelockReady(bytes32 h) internal view returns (bool) {
        TimelockAction storage a = timelockActions[h];
        return (
            !a.executed &&
            a.confirmations >= multisigThreshold &&
            a.executionTime > 0 &&
            block.timestamp >= a.executionTime
        );
    }
}
