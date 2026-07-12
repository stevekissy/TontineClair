import 'package:intl/intl.dart';
import '../services/devise_service.dart';

class Formatters {
  static final NumberFormat fcfa = NumberFormat.decimalPattern('fr_FR');
  static final DateFormat dateFormat = DateFormat('dd/MM/yyyy', 'fr_FR');
  static final DateFormat dateTimeFormat = DateFormat('dd/MM/yyyy HH:mm', 'fr_FR');
  static final DateFormat dateLongFormat = DateFormat('d MMMM yyyy', 'fr_FR');

  /// Formate un montant avec la devise FCFA (rétrocompatibilité)
  static String montantFCFA(num montant) {
    return '${fcfa.format(montant)} FCFA';
  }

  /// Formate un montant avec la devise de la tontine
  /// Si devise est null ou vide → retombe sur FCFA
  static String montant(num montant, {String? devise}) {
    if (devise == null || devise.isEmpty || devise == 'XOF') {
      return montantFCFA(montant);
    }
    return DeviseService.formaterMontant(montant, devise);
  }

  static String dateFormatee(DateTime? date) {
    if (date == null) return '—';
    return dateFormat.format(date);
  }

  static String dateLongue(DateTime? date) {
    if (date == null) return '—';
    return dateLongFormat.format(date);
  }

  static String dateHeure(DateTime? date) {
    if (date == null) return '—';
    return dateTimeFormat.format(date.toLocal());
  }

  static String joursRestants(DateTime? echeance) {
    if (echeance == null) return '';
    final diff = echeance.difference(DateTime.now()).inDays;
    if (diff < 0) return 'En retard de ${-diff} jour${(-diff) > 1 ? 's' : ''}';
    if (diff == 0) return "Aujourd'hui";
    if (diff == 1) return 'Demain';
    return 'Dans $diff jours';
  }

  static String periodicite(String p) {
    switch (p) {
      case 'journalier':
        return 'Journalière';
      case 'hebdo':
        return 'Hebdomadaire';
      case 'mensuel':
        return 'Mensuelle';
      case 'bimensuel':
        return 'Bimensuelle';
      case 'trimestriel':
        return 'Trimestrielle';
      default:
        return p;
    }
  }

  /// Libellé court de la prochaine échéance (ex: "Aujourd'hui", "Dans 3 jours")
  static String delaiEcheance(DateTime? echeance) {
    if (echeance == null) return '';
    final now = DateTime.now();
    final nowDate = DateTime(now.year, now.month, now.day);
    final echDate = DateTime(echeance.year, echeance.month, echeance.day);
    final diff = echDate.difference(nowDate).inDays;
    if (diff < 0) return 'En retard de ${-diff} j.';
    if (diff == 0) return "Aujourd'hui";
    if (diff == 1) return 'Demain';
    if (diff < 7)  return 'Dans $diff jours';
    if (diff < 14) return 'Dans 1 sem.';
    return 'Dans ${(diff / 7).round()} sem.';
  }

  static String methodeOrdre(String m) {
    switch (m) {
      case 'tirage':
        return 'Tirage certifié';
      case 'rotation':
        return 'Rotation classique';
      case 'manuel':
        return 'Ordre manuel';
      default:
        return m;
    }
  }

  static String methodePaiement(String m) {
    switch (m) {
      case 'especes':
        return 'Espèces';
      case 'orange':
        return 'Orange Money';
      case 'mtn':
        return 'MTN Money';
      case 'moov':
        return 'Moov Money';
      case 'wave':
        return 'Wave';
      default:
        return m;
    }
  }

  static String capitaliser(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  static String heureFormatee(DateTime? date) {
    if (date == null) return '';
    return DateFormat('HH:mm', 'fr_FR').format(date.toLocal());
  }

  static String genererReference() {
    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch.toString().substring(7);
    final rand = (now.microsecondsSinceEpoch % 100).toString().padLeft(2, '0');
    return 'TC$ts$rand';
  }
}
