import 'package:flutter/foundation.dart';
import '../models/tontine.dart';
import '../services/supabase_service.dart';
import '../services/storage_service.dart';

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
  }

  Future<void> chargerTontine(String code) async {
    _enChargement = true;
    _erreur = null;
    notifyListeners();

    try {
      _courante = await SupabaseService.lireTontine(code);
      await StorageService.mettreAJourNom(code, _courante!.data.nom);
      _mesTontines = await StorageService.getListe();

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
      } else {
        _erreur = msg;
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
      final ok = await SupabaseService.ecrireTontine(
        code: _courante!.code,
        nom: _gestActifNom!,
        pin: pin,
        data: data,
      );
      if (ok) {
        await chargerTontine(_courante!.code);
      }
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
    String? echeance,
    required List<String> membres,
    required List<Gestionnaire> gestionnaires,
  }) async {
    try {
      final code = _genererCode();
      final data = TontineData(
        nom: nom,
        montant: montant,
        periode: periode,
        methodeOrdre: methodeOrdre,
        echeance: echeance,
        gestionnaires: gestionnaires,
        membres: membres
            .asMap()
            .entries
            .map((e) => Membre(
                  id: 'm${e.key + 1}',
                  nom: e.value,
                ))
            .toList(),
      );

      await SupabaseService.creerTontine(
        code: code,
        gestionnaires: gestionnaires.map((g) => g.toJson()).toList(),
        data: data.toJson(),
      );

      await StorageService.ajouterTontine(TontineLocale(code: code, nom: nom));
      // Enregistrer que cette tontine a été CRÉÉE (pas juste rejointe)
      await StorageService.enregistrerTontineCree(code);
      _mesTontines = await StorageService.getListe();
      notifyListeners();
      return code;
    } catch (e) {
      _erreur = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      return null;
    }
  }

  Future<bool> rejoindre(String code) async {
    _erreur = null;
    try {
      // Vérifier côté serveur que le code est valide (v16+)
      final check = await SupabaseService.verifierCodeInvitation(code);
      if (check['ok'] == false) {
        final erreur = check['erreur'] as String? ?? '';
        if (erreur == 'TONTINE_DELETED') {
          _erreur = 'Cette tontine a été supprimée. Son code d\'invitation n\'est plus valide.';
        } else if (erreur == 'INVITATION_INACTIVE') {
          _erreur = 'Le code d\'invitation de cette tontine n\'est plus actif.';
        } else {
          _erreur = check['message'] as String? ?? 'Code invalide.';
        }
        notifyListeners();
        return false;
      }
      final t = await SupabaseService.lireTontine(code);
      await StorageService.ajouterTontine(
          TontineLocale(code: t.code, nom: t.data.nom));
      _mesTontines = await StorageService.getListe();
      notifyListeners();
      return true;
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      if (msg == 'TONTINE_DELETED') {
        _erreur = 'Cette tontine a été supprimée. Son code d\'invitation n\'est plus valide.';
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
        // Recharger depuis Supabase → tous les context.watch<TontineProvider>()
        // seront notifiés : classement_screen, membres_screen, dashboard_screen.
        await chargerTontine(_courante!.code);
      }
      return result;
    } catch (e) {
      return {'ok': false, 'message': e.toString()};
    }
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
