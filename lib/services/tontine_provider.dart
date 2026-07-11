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
      _erreur = e.toString().replaceFirst('Exception: ', '');
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
      final t = await SupabaseService.lireTontine(code);
      await StorageService.ajouterTontine(
          TontineLocale(code: t.code, nom: t.data.nom));
      _mesTontines = await StorageService.getListe();
      notifyListeners();
      return true;
    } catch (e) {
      _erreur = e.toString().replaceFirst('Exception: ', '');
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
