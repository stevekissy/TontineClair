import '../models/tontine.dart';
import '../services/supabase_service.dart';

/// Service gérant le Mode Gestion : Libre ↔ Mandat.
///
/// – Gestion Libre  : toutes fonctionnalités, 0% commission, gratuit.
/// – Gestion Mandat : identique + paiement réel, commission 1% sur décaissements,
///                    forfait 1 500 FCFA/mois.
class MandatService {
  // ── Constantes publiques ──────────────────────────────────────────────────
  static const double commissionPct     = 0.01;   // 1 %
  static const int    forfaitMensuelFCFA = 1500;  // 1 500 FCFA/mois

  // ── Calculs financiers ────────────────────────────────────────────────────

  /// Commission due sur [montantDecaissement] (arrondie à l'entier le plus proche).
  static int calculerCommission(int montantDecaissement) =>
      (montantDecaissement * commissionPct).round();

  /// Montant net reçu par le bénéficiaire après déduction de la commission.
  static int calculerNetApresCommission(int montantDecaissement) =>
      montantDecaissement - calculerCommission(montantDecaissement);

  /// Retourne le libellé du mode courant pour affichage UI.
  static String libelleMode(String modeGestion) =>
      modeGestion == 'mandat' ? 'Gestion sous Mandat' : 'Gestion Libre';

  // ── Basculement de mode ───────────────────────────────────────────────────

  /// Bascule la tontine [code] vers [nouveauMode] ('libre' | 'mandat').
  ///
  /// Appelle `ecrireTontine` avec le champ `modeGestion` mis à jour,
  /// ajoute une entrée dans le journal et envoie une notification push.
  ///
  /// Retourne `null` en cas de succès, ou un message d'erreur en cas d'échec.
  static Future<String?> basculerMode({
    required String code,
    required String nom,           // nom du gestionnaire
    required String pin,
    required String nouveauMode,   // 'libre' | 'mandat'
    required TontineData data,
  }) async {
    assert(nouveauMode == 'libre' || nouveauMode == 'mandat',
        'nouveauMode doit être "libre" ou "mandat"');

    // ── 1. Mise à jour du champ modeGestion dans les données JSON ────────────
    final dataJson = data.toJson();
    dataJson['modeGestion'] = nouveauMode;

    // ── 2. Ajout d'une entrée journal ─────────────────────────────────────────
    final journal = List<Map<String, dynamic>>.from(
      (dataJson['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
    );
    final ancienMode = data.modeGestion;
    journal.insert(0, {
      'type':     'mode_gestion',
      'date':     DateTime.now().toIso8601String(),
      'auteur':   nom,
      'message':  ancienMode == 'mandat'
          ? '🔓 Mode Gestion basculé : Mandat → Libre'
          : '🔐 Mode Gestion basculé : Libre → Mandat',
      'details': {
        'ancien': ancienMode,
        'nouveau': nouveauMode,
      },
    });
    dataJson['journal'] = journal;

    // ── 3. Écriture en base ───────────────────────────────────────────────────
    final ok = await SupabaseService.ecrireTontine(
      code: code,
      nom:  nom,
      pin:  pin,
      data: dataJson,
    );

    if (!ok) return 'Échec de la mise à jour. Vérifiez votre PIN.';

    // ── 4. Notification push ──────────────────────────────────────────────────
    final typeNotif = nouveauMode == 'mandat' ? 'mandat_active' : 'mandat_desactive';
    final tNotif = SupabaseService.notifTexte(typeNotif, 'fr');
    SupabaseService.envoyerNotification(
      code:         code,
      type:         typeNotif,
      titre:        tNotif['titre']!,
      message:      tNotif['message']!,
      donneesExtra: {'modeGestion': nouveauMode},
    );

    return null; // succès
  }
}
