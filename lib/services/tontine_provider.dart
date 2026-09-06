import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/tontine.dart';
import '../services/supabase_service.dart';
import '../services/storage_service.dart';
import '../services/echeance_service.dart';
import '../services/notification_service.dart';
import '../services/rappel_service.dart';
import '../services/blockchain_service.dart';

class TontineProvider extends ChangeNotifier {
  List<TontineLocale> _mesTontines = [];
  Tontine? _courante;
  String? _gestActifNom;
  bool _enChargement = false;
  String? _erreur;

  List<TontineLocale> get mesTontines => _mesTontines;
  Tontine? get courante => _courante;
  String? get gestActifNom => _gestActifNom;
  bool get enChargement => _enChargement;
  String? get erreur => _erreur;
  bool get estDebloque => _gestActifNom != null;

  Future<void> initialiser() async {
    await StorageService.loadSupabaseConfig();
    _mesTontines = await StorageService.getListe();
    notifyListeners();

    // ── FIX NOTIFICATIONS BROADCAST ────────────────────────────────────────
    // ÉTAPE CRITIQUE : synchroniser tontines_codes (ancienne clé SharedPrefs)
    // avec StorageService (source de vérité = tontines_liste) AVANT de
    // ré-abonner aux topics FCM.
    //
    // Sans cette synchro, après réinstallation ou changement d'appareil :
    //   • tontines_codes est VIDE (jamais alimentée)
    //   • _reabonnerTousTopic ne trouve aucun code → 0 topic FCM → 0 notif
    //
    // Cette synchro garantit que les deux clés sont cohérentes au démarrage.
    try {
      if (_mesTontines.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        final codesStorageService =
            _mesTontines.map((t) => t.code.toUpperCase()).toList();
        // Fusionner avec les codes déjà présents (au lieu d'écraser)
        final codesExistants = prefs.getStringList('tontines_codes') ?? [];
        final codesFusionnes = <String>{...codesStorageService, ...codesExistants}.toList();
        await prefs.setStringList('tontines_codes', codesFusionnes);
        if (kDebugMode) {
          debugPrint('[TontineProvider] ✅ tontines_codes synchronisé: $codesFusionnes');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[TontineProvider] ⚠️ synchro tontines_codes: $e');
    }

    // Re-abonner aux topics FCM de TOUTES les tontines au démarrage.
    // Garantit que chaque membre reçoit les notifications même après :
    //   - Réinstallation de l'app
    //   - Changement d'appareil
    //   - Expiration/rotation du token FCM
    // unawaited — ne bloque pas le démarrage de l'app
    NotificationService.reabonnerImmediatement();
  }

  Future<void> chargerTontine(String code, {bool silencieux = false}) async {
    // silencieux = true → pas de spinner, on garde l'écran actuel pendant le retry
    if (!silencieux) {
      _enChargement = true;
      _erreur = null;
      notifyListeners();
    }

    try {
      // lireTontine intègre déjà 3 retries dans SupabaseService.rpc()
      _courante = await SupabaseService.lireTontine(code);
      _erreur = null; // Succès → effacer toute erreur précédente
      await StorageService.mettreAJourNom(code, _courante!.data.nom);
      // Synchroniser le tier (Lite/Pro) dans le cache local pour le badge accueil
      await StorageService.mettreAJourTier(code, _courante!.isPremium);
      _mesTontines = await StorageService.getListe();
      // Abonner l'appareil aux notifications de cette tontine
      NotificationService.abonnerATontine(code);

      // Vérifier l'échéance et envoyer un rappel si nécessaire
      RappelService.verifierEtNotifier(
        data: _courante!.data,
        code: code,
        gestNom: _gestActifNom,
      );

      // Restaurer le gestionnaire actif si en session
      final gest = await StorageService.getGestActif(code);
      if (gest != null) {
        _gestActifNom = gest['nom'];
      }
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      if (msg == 'TONTINE_DELETED') {
        // Retirer silencieusement de la liste locale — elle a été supprimée
        await StorageService.retirerTontine(code);
        await StorageService.effacerGestActif(code);
        _mesTontines = await StorageService.getListe();
        _erreur = 'TONTINE_DELETED';
      } else if (msg.startsWith('RESEAU:')) {
        // Erreur réseau classifiée : afficher seulement si pas de données en cache
        if (_courante == null) {
          _erreur = msg; // sera traduit en message lisible par l'UI
        }
        // Si _courante chargée → on garde les données actuelles sans crasher
      } else {
        // Erreur inconnue → logguer mais ne pas afficher brut à l'utilisateur
        if (kDebugMode) debugPrint('[TontineProvider] erreur non classifiée: $msg');
        _erreur = 'RESEAU:SERVEUR'; // fallback sûr
      }
    } finally {
      _enChargement = false;
      notifyListeners();
    }
  }

  Future<bool> verifierEtDebloqur({
    required String nom,
    required String pin,
  }) async {
    if (_courante == null) return false;
    try {
      final ok = await SupabaseService.verifierGestionnaire(
        code: _courante!.code,
        nom: nom,
        pin: pin,
      );
      if (ok) {
        _gestActifNom = nom;
        await StorageService.sauvegarderGestActif(
          code: _courante!.code,
          nom: nom,
        );
        notifyListeners();
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  void verrouiller() {
    if (_courante != null) {
      StorageService.effacerGestActif(_courante!.code);
    }
    _gestActifNom = null;
    notifyListeners();
  }

  Future<bool> ecrire(Map<String, dynamic> data, String pin) async {
    if (_courante == null || _gestActifNom == null) return false;
    try {
      final code = _courante!.code;
      final ok = await SupabaseService.ecrireTontine(
        code: code,
        nom: _gestActifNom!,
        pin: pin,
        data: data,
      );
      if (ok) {
        await chargerTontine(code);

        // ── BLOCKCHAIN : sync solde caisse après chaque écriture (non-bloquant) ──
        // Délai de 3s pour que le mouvement caisse soit bien enregistré avant
        // la sync — garantit que la Synchronisation apparaît APRÈS l'opération
        // dans le journal blockchain (ordre chronologique correct).
        final tontine = _courante;
        if (tontine != null) {
          final td = tontine.data;
          final soldeBrut    = td.soldeCaisse;
          final totalEntrees = td.caisse
              .where((m) => ['apport','cotisation','depot','remboursement'].contains(m.type))
              .fold<int>(0, (s, m) => s + m.montant.abs());
          final totalSorties = td.caisse
              .where((m) => ['depense','decaissement','decaissement_cagnotte','pret','retrait'].contains(m.type))
              .fold<int>(0, (s, m) => s + m.montant.abs());
          Future.delayed(const Duration(seconds: 3), () {
            BlockchainService.syncBalanceTontine(
              tontineCode  : code,
              soldeBrut    : soldeBrut,
              totalEntrees : totalEntrees,
              totalSorties : totalSorties,
              nbOps        : td.caisse.length,
            ).catchError((e) {
              if (kDebugMode) debugPrint('[Blockchain] sync_balance erreur: $e');
              return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
            });
          });
        }
        // ────────────────────────────────────────────────────────────────────────
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Écrit les données sans PIN gestionnaire.
  /// Utilisé pour les paiements initiés par un membre ordinaire
  /// (cotisation Premium auto-déclarée) — la vérification d'identité
  /// est assurée par la confirmation explicite dans l'UI.
  Future<bool> ecrireSansPin(
    Map<String, dynamic> data, {
    String?  membreId,
    String?  membreNom,
    int?     montantXof,
    String?  typeOperationBlockchain,
    String?  refInterne,
  }) async {
    if (_courante == null) return false;
    try {
      final code = _courante!.code;
      final ok = await SupabaseService.ecrireTontineSansPIN(
        code:                    code,
        data:                    data,
        membreId:                membreId,
        membreNom:               membreNom,
        montantXof:              montantXof,
        typeOperationBlockchain: typeOperationBlockchain,
        refInterne:              refInterne,
      );
      if (ok) await chargerTontine(code);
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<String?> creer({
    required String nom,
    required int montant,
    required String periode,
    required String methodeOrdre,
    String devise = 'XOF',
    required List<String> membres,
    List<String?> membresEmails = const [],  // e-mails membres (Premium uniquement)
    required List<Gestionnaire> gestionnaires,
    String tier = 'gratuite',
  }) async {
    try {
      // Calcul automatique de l'échéance selon la périodicité
      final echeanceAuto = EcheanceService.prochaineEcheance(periode: periode).toIso8601String();
      final code = _genererCode();
      final now = DateTime.now().toIso8601String();
      final gestNom = gestionnaires.isNotEmpty ? gestionnaires.first.nom : 'Inconnu';

      final data = TontineData(
        nom: nom,
        montant: montant,
        periode: periode,
        methodeOrdre: methodeOrdre,
        echeance: echeanceAuto,
        devise: devise,
        tier: tier,
        gestionnaires: gestionnaires,
        membres: membres
            .asMap()
            .entries
            .map((e) {
              final email = e.key < membresEmails.length
                  ? membresEmails[e.key]
                  : null;
              return Membre(
                id: 'm${e.key + 1}',
                nom: e.value,
                email: (email != null && email.isNotEmpty) ? email : null,
              );
            })
            .toList(),
        // Journal initial : enregistrer la création immédiatement
        journal: [
          JournalEntry(
            quoi: 'CRÉATION TONTINE «$nom» — ${membres.length} membre(s) — '
                '$montant ($devise) / $periode',
            gestionnaire: gestNom,
            quand: now,
            reference: code,
          ),
        ],
      );

      await SupabaseService.creerTontine(
        code: code,
        gestionnaires: gestionnaires.map((g) => g.toJson()).toList(),
        data: data.toJson(),
      );

      await StorageService.ajouterTontine(TontineLocale(code: code, nom: nom, isPremium: tier == 'premium'));
      // Enregistrer que cette tontine a été CRÉÉE (pas juste rejointe)
      await StorageService.enregistrerTontineCree(code);
      _mesTontines = await StorageService.getListe();
      notifyListeners();

      // ── BROADCAST FIX : s'abonner aux notifications dès la création ─────────
      NotificationService.abonnerATontine(code); // unawaited — non-bloquant

      // ── BLOCKCHAIN : ancrage création tontine (non-bloquant) ─────────────────
      BlockchainService.enregistrerCreation(
        tontineCode : code,
        gestionnaire: gestNom,
        nomTontine  : nom,
      ).then((res) {
        if (res.ok) {
          // Notifier tous les membres (topic FCM) : tontine créée
          NotificationService.notifierOperationBlockchain(
            tontineCode  : code,
            nomTontine   : nom,
            typeOperation: 'creation',
            phase        : res.phase,
            txHash       : res.txHash,
            membreNom    : gestNom,
          ).catchError((_) {});
        }
      }).catchError((_) {}); // Non-bloquant — la création reste valide même si blockchain KO

      return code;
    } catch (e) {
      _erreur = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // rejoindre : entrée UNIQUE pour adhérer à une tontine par code.
  //
  // ARCHITECTURE DÉFENSE EN PROFONDEUR — 3 barrières successives :
  //
  //   1. verifierCodeInvitation (RPC check_invitation_code v17)
  //      → retourne TONTINE_DELETED, INVITATION_INACTIVE, CODE_INTROUVABLE
  //      → fallback pessimiste si RPC absente (passe à la barrière 2)
  //
  //   2. lireTontine (RPC lire_tontine v16)
  //      → détecte __deleted__ sentinel : lance Exception('TONTINE_DELETED')
  //      → si status != 'active' dans la réponse : bloque aussi
  //
  //   3. Vérification post-chargement : si t.estSupprimee → abort
  //
  // JAMAIS de StorageService.ajouterTontine si la tontine est supprimée.
  // JAMAIS de navigation vers DetailScreen si la tontine est supprimée.
  // ─────────────────────────────────────────────────────────────────────────
  Future<bool> rejoindre(String code) async {
    _erreur = null;
    try {
      // ── BARRIÈRE 1 : check_invitation_code (v17) ───────────────────────────
      // Note : fallback PESSIMISTE — si RPC absente, on continue vers barrière 2
      // (on ne retourne plus ok:true en fallback)
      final check = await SupabaseService.verifierCodeInvitation(code);

      if (check['ok'] == false) {
        final erreur = check['erreur'] as String? ?? '';
        if (erreur == 'TONTINE_DELETED') {
          _erreur = 'TONTINE_DELETED';
        } else if (erreur == 'INVITATION_INACTIVE') {
          _erreur = 'Le code d\'invitation de cette tontine n\'est plus actif.';
        } else if (erreur == 'CODE_INTROUVABLE') {
          _erreur = 'CODE_INTROUVABLE';
        } else {
          _erreur = check['message'] as String? ?? 'CODE_INTROUVABLE';
        }
        notifyListeners();
        return false;
      }

      // ── BARRIÈRE 2 : lire_tontine (v16) ────────────────────────────────────
      // lireTontine lance Exception('TONTINE_DELETED') si __deleted__ == true
      final t = await SupabaseService.lireTontine(code);

      // ── BARRIÈRE 3 : vérification post-désérialisation ──────────────────────
      // Si le status n'est pas 'active', refuser même si les barrières 1&2 ont
      // laissé passer (ex: migration partielle côté Supabase)
      if (t.estSupprimee) {
        _erreur = 'TONTINE_DELETED';
        notifyListeners();
        return false;
      }
      if (t.estBloquee) {
        _erreur = 'TONTINE_BLOCKED';
        notifyListeners();
        return false;
      }
      if (!t.estActive) {
        _erreur = 'Cette tontine n\'est pas active (statut: ${t.status}).';
        notifyListeners();
        return false;
      }

      // ── Succès : enregistrer localement ────────────────────────────────────
      await StorageService.ajouterTontine(
          TontineLocale(code: t.code, nom: t.data.nom));
      _mesTontines = await StorageService.getListe();
      notifyListeners();

      // ── BROADCAST FIX : s'abonner aux notifications dès la jonction ─────────
      // Sans ça, le nouveau membre n'a aucun token en base → il ne reçoit
      // aucune notification des autres membres même s'ils font des opérations.
      NotificationService.abonnerATontine(t.code); // unawaited — non-bloquant

      return true;

    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      if (msg == 'TONTINE_DELETED') {
        _erreur = 'TONTINE_DELETED';
      } else {
        _erreur = msg;
      }
      notifyListeners();
      return false;
    }
  }

  Future<void> retirer(String code) async {
    await StorageService.retirerTontine(code);
    if (_courante?.code == code) {
      _courante = null;
      _gestActifNom = null;
    }
    _mesTontines = await StorageService.getListe();
    notifyListeners();
  }

  void clearErreur() {
    _erreur = null;
    notifyListeners();
  }

  // ── Score Override ─────────────────────────────────────────────────────────

  /// Modifie manuellement le score d'un membre (RPC atomique v13).
  ///
  /// Après succès, recharge la tontine depuis Supabase et notifie tous les
  /// widgets abonnés (classement, liste membres, tableau de bord).
  /// Retourne {ok: bool, ancien: int, nouveau: int, message: String}
  Future<Map<String, dynamic>> modifierScoreMembre({
    required String membreId,
    required int nouveau,
    required String motif,
    required String pin,
  }) async {
    if (_courante == null || _gestActifNom == null) {
      return {'ok': false, 'message': 'Session gestionnaire non active.'};
    }
    try {
      final result = await SupabaseService.modifierScoreMembre(
        code:     _courante!.code,
        nom:      _gestActifNom!,
        pin:      pin,
        membreId: membreId,
        nouveau:  nouveau,
        motif:    motif,
      );
      if (result['ok'] == true) {
        // ── Écrire dans le journal JSONB de la tontine (visible aux membres) ──
        // Le RPC modifier_score_membre écrit dans journal_audit (table dédiée),
        // mais pas dans data.journal. On complète ici.
        try {
          final ancienScore = result['ancien'] as int? ?? 0;
          final data = _courante!.data;
          final newData = data.toJson();
          final journal = List<Map<String, dynamic>>.from(
            (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
          );
          // Trouver le nom du membre
          final membreNom = data.membres
              .where((m) => m.id == membreId)
              .map((m) => m.nom)
              .firstOrNull ?? membreId;
          journal.insert(0, {
            'quoi': 'SCORE MODIFIÉ — $membreNom : $ancienScore → $nouveau/100 — Motif : $motif',
            'gestionnaire': _gestActifNom!,
            'quand': DateTime.now().toIso8601String(),
          });
          newData['journal'] = journal;
          await SupabaseService.ecrireTontine(
            code: _courante!.code,
            nom: _gestActifNom!,
            pin: pin,
            data: newData,
          );

          // ── BLOCKCHAIN : score modifié (non-bloquant) ──────────────────────
          BlockchainService.enregistrerScoreModifie(
            tontineCode : _courante!.code,
            membreId    : membreId,
            membreNom   : membreNom,
            ancienScore : ancienScore,
            nouveauScore: nouveau,
            motif       : motif,
          ).catchError((e) {
            if (kDebugMode) debugPrint('[Blockchain] score_modifie erreur: $e');
            return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
          });
          // ───────────────────────────────────────────────────────────────────
        } catch (_) {
          // Échec silencieux : le score a bien été modifié, seul le journal JSONB a échoué
        }

        // Recharger depuis Supabase → tous les context.watch<TontineProvider>()
        // seront notifiés : classement_screen, membres_screen, dashboard_screen.
        await chargerTontine(_courante!.code);
      }
      return result;
    } catch (e) {
      return {'ok': false, 'message': e.toString()};
    }
  }

  // ── Injection voix fraîches ────────────────────────────────────────────────

  /// Injecte les voix fraîches dans les votes de _courante puis notifie
  /// les widgets. Appelé après chaque vote pour mettre à jour les compteurs
  /// "Résultats en temps réel" sans attendre un rechargement complet.
  Future<void> injecterVoix(String code) async {
    if (_courante == null) return;
    try {
      final voixBrutes = await SupabaseService.lireVoix(code);
      if (voixBrutes.isEmpty) return;
      for (final v in _courante!.data.votes) {
        final voixDuVote = voixBrutes.where((vb) {
          final id = vb['vote_id'] as String?
              ?? vb['voteId'] as String?
              ?? '';
          return id == v.id;
        }).toList();
        if (voixDuVote.isEmpty) continue;
        final nouvellesVoix = <String, dynamic>{};
        for (final vb in voixDuVote) {
          final memId = vb['membre_id'] as String?
              ?? vb['membreId'] as String?
              ?? '';
          final choix = vb['choix'] as String? ?? '';
          if (memId.isNotEmpty) nouvellesVoix[memId] = choix;
        }
        v.voix = nouvellesVoix;
      }
      notifyListeners();
    } catch (_) {}
  }

  // ── Nouveau Cycle ──────────────────────────────────────────────────────────

  /// Propose un nouveau cycle en créant un vote de redémarrage.
  /// [pin] : PIN du gestionnaire actif.
  /// Retourne {ok: bool, vote_id?: String, erreur?: String}
  Future<Map<String, dynamic>> proposerNouveauCycle({required String pin}) async {
    if (_courante == null || _gestActifNom == null) {
      return {'ok': false, 'erreur': 'Session gestionnaire non active.'};
    }
    try {
      final result = await SupabaseService.proposerNouveauCycle(
        code: _courante!.code,
        nom: _gestActifNom!,
        pin: pin,
      );
      if (result['ok'] == true) {
        await chargerTontine(_courante!.code);
      }
      return result;
    } catch (e) {
      return {'ok': false, 'erreur': e.toString()};
    }
  }

  /// Clôture le vote de redémarrage et calcule le résultat.
  Future<Map<String, dynamic>> cloreVoteRedemarrage({
    required String voteId,
    required String pin,
  }) async {
    if (_courante == null || _gestActifNom == null) {
      return {'ok': false, 'erreur': 'Session gestionnaire non active.'};
    }
    try {
      final result = await SupabaseService.cloreVoteRedemarrage(
        code: _courante!.code,
        nom: _gestActifNom!,
        pin: pin,
        voteId: voteId,
      );
      if (result['ok'] == true) {
        await chargerTontine(_courante!.code);
      }
      return result;
    } catch (e) {
      return {'ok': false, 'erreur': e.toString()};
    }
  }

  /// Démarre le nouveau cycle après un vote favorable.
  /// Retourne {ok: bool, cycleNum?: int, message?: String, erreur?: String}
  Future<Map<String, dynamic>> demarrerNouveauCycle({
    required String voteId,
    required String pin,
    int? montant,
    String? periodicite,
    String? echeance,
    String? methodeOrdre,
  }) async {
    if (_courante == null || _gestActifNom == null) {
      return {'ok': false, 'erreur': 'Session gestionnaire non active.'};
    }
    try {
      final result = await SupabaseService.demarrerNouveauCycle(
        code: _courante!.code,
        nom: _gestActifNom!,
        pin: pin,
        voteId: voteId,
        montant: montant,
        periodicite: periodicite,
        echeance: echeance,
        methodeOrdre: methodeOrdre,
      );
      if (result['ok'] == true) {
        await chargerTontine(_courante!.code);
      }
      return result;
    } catch (e) {
      return {'ok': false, 'erreur': e.toString()};
    }
  }

  // ── Soft Delete ────────────────────────────────────────────────────────────

  /// Supprime logiquement la tontine courante (soft delete).
  /// Retourne {ok: bool, message?: String, erreur?: String}
  Future<Map<String, dynamic>> supprimerTontine({
    required String pin,
    required String raison,
    required String nomConfirmation,
  }) async {
    if (_courante == null || _gestActifNom == null) {
      return {'ok': false, 'erreur': 'Session gestionnaire non active.'};
    }
    try {
      final result = await SupabaseService.supprimerTontine(
        code:             _courante!.code,
        nom:              _gestActifNom!,
        pin:              pin,
        raison:           raison,
        nomConfirmation:  nomConfirmation,
      );
      if (result['ok'] == true) {
        final code = _courante!.code;
        // Retirer de la liste locale + session gestionnaire
        await StorageService.retirerTontine(code);
        await StorageService.retirerTontineCree(code);
        await StorageService.effacerGestActif(code);
        _courante = null;
        _gestActifNom = null;
        _mesTontines = await StorageService.getListe();
        notifyListeners();
      }
      return result;
    } catch (e) {
      return {'ok': false, 'erreur': e.toString()};
    }
  }

  /// Restaure une tontine supprimée (Super Admin uniquement).
  Future<Map<String, dynamic>> restaurerTontine({
    required String cle,
    required String code,
    required String motif,
  }) async {
    try {
      return await SupabaseService.restaurerTontine(
        cle: cle, code: code, motif: motif,
      );
    } catch (e) {
      return {'ok': false, 'erreur': e.toString()};
    }
  }

  /// Rafraîchit les données en arrière-plan sans afficher d'erreur réseau.
  /// Utilisé par le pull-to-refresh et les timers de rafraîchissement auto.
  /// Si le réseau échoue mais que les données sont en cache → on garde l'écran.
  Future<void> rafraichirSilencieux() async {
    if (_courante == null) return;
    await chargerTontine(_courante!.code, silencieux: true);
  }

  String _genererCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = DateTime.now().millisecondsSinceEpoch;
    String code = '';
    var seed = rand;
    for (int i = 0; i < 6; i++) {
      code += chars[seed % chars.length];
      seed = seed ~/ chars.length + (seed % 37) * 13 + i * 7;
    }
    return code;
  }
}
