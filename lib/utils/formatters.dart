import 'package:intl/intl.dart';
import '../services/devise_service.dart';
import '../services/paiement_service.dart';

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
    return PaiementService.label(m);
  }

  static String capitaliser(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  // ── Labels Mobile Money PayDunya (codes operateur → libellé) ────────────
  static const _labelsPaydunya = <String, String>{
    'orange-money-ci': 'Orange Money',
    'orange-money-sn': 'Orange Money',
    'orange-money-ml': 'Orange Money',
    'orange-money-bf': 'Orange Money',
    'orange-money-gn': 'Orange Money',
    'orange':          'Orange Money',
    'wave-ci':         'Wave',
    'wave-sn':         'Wave',
    'wave':            'Wave',
    'mtn-ci':          'MTN Mobile Money',
    'mtn-gh':          'MTN Mobile Money',
    'mtn':             'MTN Mobile Money',
    'moov-ci':         'Moov Money',
    'moov-bf':         'Moov Money',
    'moov':            'Moov Money',
    'free-money-sn':   'Free Money',
    'free':            'Free Money',
    'wizall':          'Wizall',
    'tmoney':          'T-Money',
    'flooz':           'Flooz',
  };

  // ── Labels crypto CoinPayments (currency2 → libellé court) ───────────────
  static const _labelsCrypto = <String, String>{
    'USDT.TRC20': 'USDT (TRC20)',
    'USDT.ERC20': 'USDT (ERC20)',
    'USDT':       'USDT',
    'BTC':        'Bitcoin (BTC)',
    'ETH':        'Ethereum (ETH)',
    'LTC':        'Litecoin (LTC)',
    'BNB':        'BNB',
    'XRP':        'Ripple (XRP)',
    'DOGE':       'Dogecoin (DOGE)',
    'TRX':        'TRON (TRX)',
    'SOL':        'Solana (SOL)',
  };

  /// Extrait, à partir des champs bruts d'un mouvement, un libellé de paiement
  /// lisible et professionnel.
  ///
  /// [par]         : champ `par` du JSON (ex: 'SycaPay', 'orange-money-ci', 'Arnaud')
  /// [description] : champ `motif`/`description` (peut contenir '(COINPAYMENTS)', 'USDT')
  /// [reference]   : champ `recu` (ex: 'CPKH4WBV2NQ…' pour CoinPayments)
  ///
  /// Retourne :
  ///   - Crypto  : 'Crypto · USDT (TRC20)'  ou  'Crypto · CoinPayments'
  ///   - MM      : 'Mobile Money · Orange Money'
  ///   - Vrai gestionnaire (nom propre) : retourné tel quel
  ///   - Inconnu : 'Système'
  static String decrypterPaiement({
    required String par,
    String description = '',
    String reference  = '',
  }) {
    final parLower  = par.trim().toLowerCase();
    final descLower = description.toLowerCase();
    final refLower  = reference.toLowerCase();

    // ── 1. Détecter CoinPayments / Crypto ────────────────────────────────────
    // Indices : reference commençant par 'cpkh' ou 'cp_', description contenant
    // 'coinpayments', par == 'sycapay' ou 'coinpayments'
    final isCrypto = parLower == 'sycapay'
        || parLower == 'coinpayments'
        || descLower.contains('coinpayments')
        || descLower.contains('coinpay')
        || refLower.startsWith('cpkh')
        || refLower.startsWith('cp_');

    if (isCrypto) {
      // Chercher la crypto exacte dans la description
      // Ex: '... (COINPAYMENTS) — 700 XOF ...' ne contient pas forcément la devise crypto
      // Ex: description peut contenir 'USDT.TRC20', 'BTC', 'ETH'…
      for (final entry in _labelsCrypto.entries) {
        if (description.contains(entry.key) || reference.toUpperCase().contains(entry.key)) {
          return 'Crypto · ${entry.value}';
        }
      }
      return 'Crypto · CoinPayments';
    }

    // ── 2. Détecter PayDunya / Mobile Money ──────────────────────────────────
    // Indices : par contient un code opérateur PayDunya, ou description contient 'paydunya'
    final isPaydunya = descLower.contains('paydunya')
        || _labelsPaydunya.containsKey(parLower)
        || _labelsPaydunya.containsKey(par.trim());

    if (isPaydunya) {
      final label = _labelsPaydunya[parLower]
          ?? _labelsPaydunya[par.trim()]
          ?? 'Mobile Money';
      return 'Mobile Money · $label';
    }

    // Cas : par contient un code opérateur sans paydunya dans la description
    // (certaines versions écrivent juste 'orange', 'wave', 'mtn'…)
    if (_labelsPaydunya.containsKey(parLower)) {
      return 'Mobile Money · ${_labelsPaydunya[parLower]}';
    }

    // ── 3. Vrai nom de gestionnaire — retourner tel quel ─────────────────────
    final trimmed = par.trim();
    return trimmed.isEmpty ? 'Système' : trimmed;
  }

  /// Compatibilité descendante — ancienne méthode nettoyerAuteur().
  /// Utiliser decrypterPaiement() à la place pour un affichage complet.
  static String nettoyerAuteur(String auteur) =>
      decrypterPaiement(par: auteur);

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
