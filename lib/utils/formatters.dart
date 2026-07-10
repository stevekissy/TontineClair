import 'package:intl/intl.dart';

class Formatters {
  static final NumberFormat fcfa = NumberFormat.decimalPattern('fr_FR');
  static final DateFormat dateFormat = DateFormat('dd/MM/yyyy', 'fr_FR');
  static final DateFormat dateTimeFormat = DateFormat('dd/MM/yyyy HH:mm', 'fr_FR');
  static final DateFormat dateLongFormat = DateFormat('d MMMM yyyy', 'fr_FR');

  static String montantFCFA(num montant) {
    return '${fcfa.format(montant)} FCFA';
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
      case 'hebdo':
        return 'Hebdomadaire';
      case 'mensuel':
        return 'Mensuel';
      default:
        return p;
    }
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

  static String genererReference() {
    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch.toString().substring(7);
    final rand = (now.microsecondsSinceEpoch % 100).toString().padLeft(2, '0');
    return 'TC$ts$rand';
  }
}
