// ─────────────────────────────────────────────────────────────────────────────
// PaiementMethodesService — Moyens de paiement disponibles par devise
//
// Pour chaque devise (code ISO), on définit la liste des moyens de paiement
// que le gestionnaire peut pré-enregistrer dans la fiche d'un membre.
//
// Structure PaiementMethode :
//   code       — identifiant unique stable (ex: 'orange_money', 'iban', 'zelle')
//   label      — nom affiché (ex: 'Orange Money', 'Virement IBAN')
//   icone      — emoji représentatif
//   typeChamp  — type du champ de saisie (phone, iban, email, texte)
//   hintTexte  — placeholder du champ de saisie
//   labelChamp — libellé du champ (ex: 'Numéro', 'IBAN', 'Adresse email')
// ─────────────────────────────────────────────────────────────────────────────

enum TypeChampPaiement { phone, iban, email, texte, crypto }

class PaiementMethode {
  final String code;
  final String label;
  final String icone;
  final TypeChampPaiement typeChamp;
  final String labelChamp;
  final String hintTexte;

  const PaiementMethode({
    required this.code,
    required this.label,
    required this.icone,
    required this.typeChamp,
    required this.labelChamp,
    required this.hintTexte,
  });

  /// Affichage court pour les listes et badges
  String get affichageCourt => '$icone $label';
}

class PaiementMethodesService {
  // ── Toutes les méthodes définies ──────────────────────────────────────────
  static const Map<String, PaiementMethode> _toutes = {

    // ── Mobile Money Afrique de l'Ouest ──────────────────────────────────
    'orange_money': PaiementMethode(
      code: 'orange_money', label: 'Orange Money', icone: '🟠',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Orange Money', hintTexte: 'Ex : +225 07 00 00 00',
    ),
    'wave': PaiementMethode(
      code: 'wave', label: 'Wave', icone: '🌊',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Wave', hintTexte: 'Ex : +221 77 000 00 00',
    ),
    'moov_money': PaiementMethode(
      code: 'moov_money', label: 'Moov Money', icone: '🔵',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Moov Money', hintTexte: 'Ex : +229 97 00 00 00',
    ),
    'mtn_momo': PaiementMethode(
      code: 'mtn_momo', label: 'MTN Mobile Money', icone: '🟡',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro MTN MoMo', hintTexte: 'Ex : +237 67 00 00 00',
    ),
    'free_money': PaiementMethode(
      code: 'free_money', label: 'Free Money', icone: '🟢',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Free Money', hintTexte: 'Ex : +221 76 000 00 00',
    ),
    'expresso_money': PaiementMethode(
      code: 'expresso_money', label: 'Expresso Money', icone: '🔴',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Expresso', hintTexte: 'Ex : +221 70 000 00 00',
    ),
    'airtel_money': PaiementMethode(
      code: 'airtel_money', label: 'Airtel Money', icone: '📡',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Airtel Money', hintTexte: 'Ex : +256 75 000 000',
    ),
    'tigo_cash': PaiementMethode(
      code: 'tigo_cash', label: 'Tigo Cash', icone: '📱',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Tigo Cash', hintTexte: 'Ex : +255 71 000 0000',
    ),
    'mpesa': PaiementMethode(
      code: 'mpesa', label: 'M-Pesa', icone: '🟢',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro M-Pesa', hintTexte: 'Ex : +254 700 000 000',
    ),

    // ── Mobile Money Afrique Centrale ─────────────────────────────────────
    'momo_cameroun': PaiementMethode(
      code: 'momo_cameroun', label: 'Mobile Money (Cameroun)', icone: '🟡',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Mobile Money', hintTexte: 'Ex : +237 6 70 00 00 00',
    ),
    'flooz': PaiementMethode(
      code: 'flooz', label: 'Flooz', icone: '🔶',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Flooz', hintTexte: 'Ex : +228 90 00 00 00',
    ),

    // ── Mobile Money Afrique du Nord ──────────────────────────────────────
    'cih_bank': PaiementMethode(
      code: 'cih_bank', label: 'CIH Bank Mobile', icone: '🏦',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro CIH', hintTexte: 'Ex : +212 6 00 00 00 00',
    ),
    'attijariwafa': PaiementMethode(
      code: 'attijariwafa', label: 'Attijariwafa (Maroc)', icone: '🏦',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro compte', hintTexte: 'Ex : +212 6 00 00 00 00',
    ),
    'instapay': PaiementMethode(
      code: 'instapay', label: 'InstaPay (Egypte)', icone: '📲',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro / compte', hintTexte: 'Ex : +20 10 0000 0000',
    ),

    // ── Mobile Money Afrique Australe ─────────────────────────────────────
    'ecocash': PaiementMethode(
      code: 'ecocash', label: 'EcoCash', icone: '💚',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro EcoCash', hintTexte: 'Ex : +263 77 000 0000',
    ),
    'mtn_rwanda': PaiementMethode(
      code: 'mtn_rwanda', label: 'MTN MoMo Rwanda', icone: '🟡',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro MoMo', hintTexte: 'Ex : +250 78 000 0000',
    ),

    // ── Virement bancaire / IBAN (Europe & international) ─────────────────
    'virement_iban': PaiementMethode(
      code: 'virement_iban', label: 'Virement IBAN', icone: '🏦',
      typeChamp: TypeChampPaiement.iban,
      labelChamp: 'IBAN', hintTexte: 'Ex : FR76 3000 6000 0112 3456 7890 189',
    ),
    'virement_sepa': PaiementMethode(
      code: 'virement_sepa', label: 'Virement SEPA', icone: '🏦',
      typeChamp: TypeChampPaiement.iban,
      labelChamp: 'IBAN (SEPA)', hintTexte: 'Ex : FR76 3000 6000 0112 3456 7890 189',
    ),
    'revolut': PaiementMethode(
      code: 'revolut', label: 'Revolut', icone: '⚡',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'Tag / numéro Revolut', hintTexte: 'Ex : @prenom.nom ou +33 6 00 00 00 00',
    ),
    'paylib': PaiementMethode(
      code: 'paylib', label: 'Paylib', icone: '💳',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Paylib', hintTexte: 'Ex : +33 6 00 00 00 00',
    ),
    'lydia': PaiementMethode(
      code: 'lydia', label: 'Lydia / Sumeria', icone: '💜',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Lydia', hintTexte: 'Ex : +33 6 00 00 00 00',
    ),
    'virement_uk': PaiementMethode(
      code: 'virement_uk', label: 'Virement UK (Sort Code)', icone: '🏦',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'Sort Code + Account Number', hintTexte: 'Ex : 20-00-00 / 12345678',
    ),
    'monese': PaiementMethode(
      code: 'monese', label: 'Monese', icone: '💳',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'Tag / numéro Monese', hintTexte: 'Ex : +44 7000 000000',
    ),

    // ── USA / Canada ──────────────────────────────────────────────────────
    'zelle': PaiementMethode(
      code: 'zelle', label: 'Zelle', icone: '💜',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'Email ou numéro Zelle', hintTexte: 'Ex : prenom@gmail.com ou +1 555 000 0000',
    ),
    'cashapp': PaiementMethode(
      code: 'cashapp', label: 'Cash App', icone: '💚',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: '\$Cashtag', hintTexte: 'Ex : \$prenom',
    ),
    'venmo': PaiementMethode(
      code: 'venmo', label: 'Venmo', icone: '🔵',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'Profil Venmo (@)', hintTexte: 'Ex : @prenom-nom',
    ),
    'paypal': PaiementMethode(
      code: 'paypal', label: 'PayPal', icone: '🔵',
      typeChamp: TypeChampPaiement.email,
      labelChamp: 'Email PayPal', hintTexte: 'Ex : prenom@exemple.com',
    ),
    'wire_ach': PaiementMethode(
      code: 'wire_ach', label: 'Virement ACH / Wire', icone: '🏦',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'Routing + Account Number', hintTexte: 'Ex : 021000021 / 1234567890',
    ),
    'interac': PaiementMethode(
      code: 'interac', label: 'Interac e-Transfer', icone: '🍁',
      typeChamp: TypeChampPaiement.email,
      labelChamp: 'Email Interac', hintTexte: 'Ex : prenom@exemple.ca',
    ),

    // ── Amérique du Sud / Latine ──────────────────────────────────────────
    'pix': PaiementMethode(
      code: 'pix', label: 'PIX (Brésil)', icone: '🔷',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'Clé PIX', hintTexte: 'CPF, email, téléphone ou clé aléatoire',
    ),
    'mercadopago': PaiementMethode(
      code: 'mercadopago', label: 'MercadoPago', icone: '💛',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'Alias / CBU', hintTexte: 'Ex : prenom.nom.123',
    ),

    // ── Asie & Océanie ────────────────────────────────────────────────────
    'gcash': PaiementMethode(
      code: 'gcash', label: 'GCash (Philippines)', icone: '💙',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro GCash', hintTexte: 'Ex : +63 917 000 0000',
    ),
    'paynow': PaiementMethode(
      code: 'paynow', label: 'PayNow (Singapour)', icone: '🔶',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'Numéro / NRIC', hintTexte: 'Ex : +65 9000 0000',
    ),
    'prompt_pay': PaiementMethode(
      code: 'prompt_pay', label: 'PromptPay (Thaïlande)', icone: '🇹🇭',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro PromptPay', hintTexte: 'Ex : +66 81 000 0000',
    ),
    'alipay': PaiementMethode(
      code: 'alipay', label: 'Alipay', icone: '💙',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'Compte Alipay', hintTexte: 'Ex : email ou numéro de téléphone',
    ),
    'wechat_pay': PaiementMethode(
      code: 'wechat_pay', label: 'WeChat Pay', icone: '💚',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'ID WeChat', hintTexte: 'Ex : wxid_XXXXXXXX',
    ),
    'paytm': PaiementMethode(
      code: 'paytm', label: 'Paytm (Inde)', icone: '💙',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Paytm', hintTexte: 'Ex : +91 98 0000 0000',
    ),
    'upi': PaiementMethode(
      code: 'upi', label: 'UPI (Inde)', icone: '🇮🇳',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'UPI ID', hintTexte: 'Ex : prenom@upi',
    ),
    'bkash': PaiementMethode(
      code: 'bkash', label: 'bKash (Bangladesh)', icone: '🩷',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro bKash', hintTexte: 'Ex : +880 17 0000 0000',
    ),

    // ── Moyen-Orient ──────────────────────────────────────────────────────
    'stcpay': PaiementMethode(
      code: 'stcpay', label: 'STC Pay (Arabie)', icone: '🟣',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro STC Pay', hintTexte: 'Ex : +966 5 0000 0000',
    ),
    'fawry': PaiementMethode(
      code: 'fawry', label: 'Fawry (Égypte)', icone: '🟠',
      typeChamp: TypeChampPaiement.phone,
      labelChamp: 'Numéro Fawry', hintTexte: 'Ex : +20 10 0000 0000',
    ),

    // ── Universel (toujours disponible) ───────────────────────────────────
    'virement_international': PaiementMethode(
      code: 'virement_international', label: 'Virement international (SWIFT)', icone: '🌐',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'IBAN / SWIFT + référence', hintTexte: 'Ex : IBAN FR76… / SWIFT BNPAFRPP',
    ),
    'autre': PaiementMethode(
      code: 'autre', label: 'Autre moyen', icone: '💰',
      typeChamp: TypeChampPaiement.texte,
      labelChamp: 'Coordonnées de paiement', hintTexte: 'Ex : compte postal, chèque, espèces…',
    ),
  };

  // ── Map devise → codes des méthodes disponibles ───────────────────────────
  // Les méthodes universelles (virement_international, autre) sont toujours
  // ajoutées en fin de liste dans methodesParDevise().
  static const Map<String, List<String>> _methodesCodes = {

    // ── XOF — Franc CFA Ouest-Africain ─────────────────────────────────────
    'XOF': [
      'orange_money', 'wave', 'free_money', 'moov_money', 'mtn_momo',
      'expresso_money', 'virement_iban',
    ],

    // ── XAF — Franc CFA Centre-Africain ────────────────────────────────────
    'XAF': [
      'orange_money', 'mtn_momo', 'momo_cameroun', 'moov_money',
      'airtel_money', 'virement_iban',
    ],

    // ── GHS — Cedi ghanéen ─────────────────────────────────────────────────
    'GHS': ['mtn_momo', 'airtel_money', 'tigo_cash', 'virement_iban'],

    // ── NGN — Naira nigérian ───────────────────────────────────────────────
    'NGN': ['mtn_momo', 'airtel_money', 'virement_iban'],

    // ── GNF — Franc guinéen ───────────────────────────────────────────────
    'GNF': ['orange_money', 'mtn_momo', 'moov_money', 'virement_iban'],

    // ── KES — Shilling kényan ──────────────────────────────────────────────
    'KES': ['mpesa', 'airtel_money', 'virement_iban'],

    // ── TZS — Shilling tanzanien ───────────────────────────────────────────
    'TZS': ['mpesa', 'tigo_cash', 'airtel_money', 'virement_iban'],

    // ── UGX — Shilling ougandais ───────────────────────────────────────────
    'UGX': ['mtn_momo', 'airtel_money', 'virement_iban'],

    // ── RWF — Franc rwandais ───────────────────────────────────────────────
    'RWF': ['mtn_rwanda', 'airtel_money', 'virement_iban'],

    // ── ZAR — Rand sud-africain ────────────────────────────────────────────
    'ZAR': ['virement_iban'],

    // ── MAD — Dirham marocain ─────────────────────────────────────────────
    'MAD': ['cih_bank', 'attijariwafa', 'virement_iban'],

    // ── EGP — Livre égyptienne ────────────────────────────────────────────
    'EGP': ['instapay', 'fawry', 'virement_iban'],

    // ── CDF — Franc congolais ─────────────────────────────────────────────
    'CDF': ['airtel_money', 'orange_money', 'virement_iban'],

    // ── EUR — Euro ────────────────────────────────────────────────────────
    'EUR': ['virement_sepa', 'revolut', 'paypal', 'lydia', 'paylib'],

    // ── GBP — Livre sterling ──────────────────────────────────────────────
    'GBP': ['virement_uk', 'revolut', 'paypal', 'monese'],

    // ── CHF — Franc suisse ────────────────────────────────────────────────
    'CHF': ['virement_iban', 'revolut', 'paypal'],

    // ── USD — Dollar américain ─────────────────────────────────────────────
    'USD': ['zelle', 'cashapp', 'venmo', 'paypal', 'wire_ach'],

    // ── CAD — Dollar canadien ─────────────────────────────────────────────
    'CAD': ['interac', 'paypal', 'wire_ach'],

    // ── BRL — Réal brésilien ──────────────────────────────────────────────
    'BRL': ['pix', 'paypal'],

    // ── ARS — Peso argentin ───────────────────────────────────────────────
    'ARS': ['mercadopago', 'paypal'],

    // ── MXN — Peso mexicain ───────────────────────────────────────────────
    'MXN': ['paypal', 'virement_iban'],

    // ── INR — Roupie indienne ─────────────────────────────────────────────
    'INR': ['upi', 'paytm', 'paypal', 'virement_iban'],

    // ── PHP — Peso philippin ──────────────────────────────────────────────
    'PHP': ['gcash', 'paypal', 'virement_iban'],

    // ── SGD — Dollar singapourien ─────────────────────────────────────────
    'SGD': ['paynow', 'paypal', 'virement_iban'],

    // ── THB — Baht thaïlandais ────────────────────────────────────────────
    'THB': ['prompt_pay', 'paypal', 'virement_iban'],

    // ── CNY — Yuan chinois ────────────────────────────────────────────────
    'CNY': ['alipay', 'wechat_pay'],

    // ── SAR — Riyal saoudien ──────────────────────────────────────────────
    'SAR': ['stcpay', 'virement_iban'],

    // ── AED — Dirham EAU ─────────────────────────────────────────────────
    'AED': ['virement_iban', 'paypal'],

    // ── JPY — Yen japonais ────────────────────────────────────────────────
    'JPY': ['virement_iban', 'paypal'],

    // ── KRW — Won coréen ─────────────────────────────────────────────────
    'KRW': ['virement_iban', 'paypal'],

    // ── AUD — Dollar australien ───────────────────────────────────────────
    'AUD': ['paypal', 'virement_iban'],

    // ── NZD — Dollar néo-zélandais ────────────────────────────────────────
    'NZD': ['paypal', 'virement_iban'],

    // ── HTG — Gourde haïtienne ────────────────────────────────────────────
    'HTG': ['moncash', 'paypal'],

    // ── BDT — Taka bangladais ─────────────────────────────────────────────
    'BDT': ['bkash', 'virement_iban'],
  };

  /// Retourne la liste des moyens de paiement pour une devise donnée.
  /// Toujours + virement_international + autre en fin de liste.
  static List<PaiementMethode> methodesParDevise(String? codeDevise) {
    final codes = _methodesCodes[codeDevise ?? 'XOF'] ??
        _methodesCodes['XOF']!; // fallback XOF

    final methodes = codes
        .map((c) => _toutes[c])
        .whereType<PaiementMethode>()
        .toList();

    // Toujours ajouter les méthodes universelles en fin (si pas déjà présentes)
    for (final universel in ['virement_international', 'autre']) {
      if (!codes.contains(universel)) {
        final m = _toutes[universel];
        if (m != null) methodes.add(m);
      }
    }

    return methodes;
  }

  /// Retourne une PaiementMethode par son code (null si inconnue).
  static PaiementMethode? parCode(String? code) {
    if (code == null || code.isEmpty) return null;
    return _toutes[code];
  }

  /// Rétro-compatibilité : convertit l'ancien code opérateur
  /// ('orange' | 'moov' | 'mtn' | 'wave') vers le nouveau code.
  static String convertirAncienOperateur(String ancien) {
    const map = {
      'orange': 'orange_money',
      'moov':   'moov_money',
      'mtn':    'mtn_momo',
      'wave':   'wave',
    };
    return map[ancien.toLowerCase()] ?? ancien;
  }

  /// Icône d'un moyen de paiement par code (fallback 💰).
  static String icone(String? code) => parCode(code)?.icone ?? '💰';

  /// Label court (sans icône) d'un moyen de paiement par code.
  static String label(String? code) => parCode(code)?.label ?? (code ?? 'Inconnu');

  /// Affichage complet "icone label" (ex: "🟠 Orange Money").
  static String affichage(String? code) {
    final m = parCode(code);
    if (m == null) return code ?? '';
    return '${m.icone} ${m.label}';
  }
}
