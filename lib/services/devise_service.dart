// ─────────────────────────────────────────────────────────────────────────────
// DeviseService — Devises mondiales pour TontineClair
// L'utilisateur choisit la devise à la création de la tontine.
// ─────────────────────────────────────────────────────────────────────────────

class Devise {
  final String code;    // ex: 'XOF'
  final String symbole; // ex: 'FCFA'
  final String nom;     // ex: 'Franc CFA Ouest-Africain'
  final String drapeau; // emoji drapeau représentatif

  const Devise({
    required this.code,
    required this.symbole,
    required this.nom,
    required this.drapeau,
  });

  @override
  String toString() => '$drapeau $symbole — $nom';
}

class DeviseService {
  // ── Liste complète des devises mondiales ───────────────────────────────────
  static const List<Devise> toutes = [
    // ── Afrique de l'Ouest ─────────────────────────────────────────────────
    Devise(code: 'XOF', symbole: 'FCFA', nom: 'Franc CFA Ouest-Africain',       drapeau: '🌍'),
    Devise(code: 'XAF', symbole: 'FCFA', nom: 'Franc CFA Centre-Africain',      drapeau: '🌍'),
    Devise(code: 'GHS', symbole: 'GH₵',  nom: 'Cedi ghanéen',                  drapeau: '🇬🇭'),
    Devise(code: 'NGN', symbole: '₦',    nom: 'Naira nigérian',                 drapeau: '🇳🇬'),
    Devise(code: 'GNF', symbole: 'FG',   nom: 'Franc guinéen',                  drapeau: '🇬🇳'),
    Devise(code: 'SLL', symbole: 'Le',   nom: 'Leone sierra-léonais',           drapeau: '🇸🇱'),
    Devise(code: 'LRD', symbole: 'L\$',  nom: 'Dollar libérien',                drapeau: '🇱🇷'),
    Devise(code: 'CVE', symbole: 'Esc',  nom: 'Escudo cap-verdien',             drapeau: '🇨🇻'),
    Devise(code: 'GMD', symbole: 'D',    nom: 'Dalasi gambien',                 drapeau: '🇬🇲'),
    Devise(code: 'MRU', symbole: 'UM',   nom: 'Ouguiya mauritanien',            drapeau: '🇲🇷'),

    // ── Afrique de l'Est ────────────────────────────────────────────────────
    Devise(code: 'KES', symbole: 'KSh',  nom: 'Shilling kényan',                drapeau: '🇰🇪'),
    Devise(code: 'TZS', symbole: 'TSh',  nom: 'Shilling tanzanien',             drapeau: '🇹🇿'),
    Devise(code: 'UGX', symbole: 'USh',  nom: 'Shilling ougandais',             drapeau: '🇺🇬'),
    Devise(code: 'ETB', symbole: 'Br',   nom: 'Birr éthiopien',                 drapeau: '🇪🇹'),
    Devise(code: 'RWF', symbole: 'RF',   nom: 'Franc rwandais',                 drapeau: '🇷🇼'),
    Devise(code: 'BIF', symbole: 'FBu',  nom: 'Franc burundais',                drapeau: '🇧🇮'),
    Devise(code: 'DJF', symbole: 'Fdj',  nom: 'Franc djiboutien',               drapeau: '🇩🇯'),
    Devise(code: 'ERN', symbole: 'Nkf',  nom: 'Nakfa érythréen',                drapeau: '🇪🇷'),
    Devise(code: 'SOS', symbole: 'Sh',   nom: 'Shilling somalien',              drapeau: '🇸🇴'),

    // ── Afrique du Nord ─────────────────────────────────────────────────────
    Devise(code: 'EGP', symbole: 'E£',   nom: 'Livre égyptienne',               drapeau: '🇪🇬'),
    Devise(code: 'MAD', symbole: 'DH',   nom: 'Dirham marocain',                drapeau: '🇲🇦'),
    Devise(code: 'DZD', symbole: 'DA',   nom: 'Dinar algérien',                 drapeau: '🇩🇿'),
    Devise(code: 'TND', symbole: 'DT',   nom: 'Dinar tunisien',                 drapeau: '🇹🇳'),
    Devise(code: 'LYD', symbole: 'LD',   nom: 'Dinar libyen',                   drapeau: '🇱🇾'),
    Devise(code: 'SDG', symbole: 'SD',   nom: 'Livre soudanaise',               drapeau: '🇸🇩'),

    // ── Afrique Australe & Centrale ─────────────────────────────────────────
    Devise(code: 'ZAR', symbole: 'R',    nom: 'Rand sud-africain',              drapeau: '🇿🇦'),
    Devise(code: 'ZMW', symbole: 'ZK',   nom: 'Kwacha zambien',                 drapeau: '🇿🇲'),
    Devise(code: 'MWK', symbole: 'MK',   nom: 'Kwacha malawien',                drapeau: '🇲🇼'),
    Devise(code: 'BWP', symbole: 'P',    nom: 'Pula botswanais',                drapeau: '🇧🇼'),
    Devise(code: 'NAD', symbole: 'N\$',  nom: 'Dollar namibien',                drapeau: '🇳🇦'),
    Devise(code: 'MZN', symbole: 'MT',   nom: 'Metical mozambicain',            drapeau: '🇲🇿'),
    Devise(code: 'AOA', symbole: 'Kz',   nom: 'Kwanza angolais',                drapeau: '🇦🇴'),
    Devise(code: 'CDF', symbole: 'FC',   nom: 'Franc congolais',                drapeau: '🇨🇩'),
    Devise(code: 'MGA', symbole: 'Ar',   nom: 'Ariary malgache',                drapeau: '🇲🇬'),

    // ── Amérique du Nord & Caraïbes ─────────────────────────────────────────
    Devise(code: 'USD', symbole: '\$',   nom: 'Dollar américain',               drapeau: '🇺🇸'),
    Devise(code: 'CAD', symbole: 'CA\$', nom: 'Dollar canadien',                drapeau: '🇨🇦'),
    Devise(code: 'MXN', symbole: 'MX\$', nom: 'Peso mexicain',                  drapeau: '🇲🇽'),
    Devise(code: 'HTG', symbole: 'G',    nom: 'Gourde haïtienne',               drapeau: '🇭🇹'),
    Devise(code: 'JMD', symbole: 'J\$',  nom: 'Dollar jamaïcain',               drapeau: '🇯🇲'),
    Devise(code: 'TTD', symbole: 'TT\$', nom: 'Dollar de Trinité',              drapeau: '🇹🇹'),

    // ── Amérique du Sud ─────────────────────────────────────────────────────
    Devise(code: 'BRL', symbole: 'R\$',  nom: 'Réal brésilien',                 drapeau: '🇧🇷'),
    Devise(code: 'ARS', symbole: 'AR\$', nom: 'Peso argentin',                  drapeau: '🇦🇷'),
    Devise(code: 'CLP', symbole: 'CL\$', nom: 'Peso chilien',                   drapeau: '🇨🇱'),
    Devise(code: 'COP', symbole: 'CO\$', nom: 'Peso colombien',                 drapeau: '🇨🇴'),
    Devise(code: 'PEN', symbole: 'S/',   nom: 'Sol péruvien',                   drapeau: '🇵🇪'),
    Devise(code: 'BOB', symbole: 'Bs',   nom: 'Boliviano bolivien',             drapeau: '🇧🇴'),
    Devise(code: 'PYG', symbole: '₲',    nom: 'Guaraní paraguayen',             drapeau: '🇵🇾'),
    Devise(code: 'UYU', symbole: 'UY\$', nom: 'Peso uruguayen',                 drapeau: '🇺🇾'),
    Devise(code: 'VES', symbole: 'Bs.S', nom: 'Bolívar vénézuélien',            drapeau: '🇻🇪'),

    // ── Europe ──────────────────────────────────────────────────────────────
    Devise(code: 'EUR', symbole: '€',    nom: 'Euro',                           drapeau: '🇪🇺'),
    Devise(code: 'GBP', symbole: '£',    nom: 'Livre sterling',                 drapeau: '🇬🇧'),
    Devise(code: 'CHF', symbole: 'CHF',  nom: 'Franc suisse',                   drapeau: '🇨🇭'),
    Devise(code: 'NOK', symbole: 'kr',   nom: 'Couronne norvégienne',           drapeau: '🇳🇴'),
    Devise(code: 'SEK', symbole: 'kr',   nom: 'Couronne suédoise',              drapeau: '🇸🇪'),
    Devise(code: 'DKK', symbole: 'kr',   nom: 'Couronne danoise',               drapeau: '🇩🇰'),
    Devise(code: 'PLN', symbole: 'zł',   nom: 'Zloty polonais',                 drapeau: '🇵🇱'),
    Devise(code: 'CZK', symbole: 'Kč',   nom: 'Couronne tchèque',               drapeau: '🇨🇿'),
    Devise(code: 'HUF', symbole: 'Ft',   nom: 'Forint hongrois',                drapeau: '🇭🇺'),
    Devise(code: 'RON', symbole: 'lei',  nom: 'Leu roumain',                    drapeau: '🇷🇴'),
    Devise(code: 'RUB', symbole: '₽',    nom: 'Rouble russe',                   drapeau: '🇷🇺'),
    Devise(code: 'TRY', symbole: '₺',    nom: 'Livre turque',                   drapeau: '🇹🇷'),

    // ── Moyen-Orient ────────────────────────────────────────────────────────
    Devise(code: 'SAR', symbole: '﷼',   nom: 'Riyal saoudien',                 drapeau: '🇸🇦'),
    Devise(code: 'AED', symbole: 'د.إ', nom: 'Dirham des EAU',                 drapeau: '🇦🇪'),
    Devise(code: 'QAR', symbole: '﷼',   nom: 'Riyal qatari',                   drapeau: '🇶🇦'),
    Devise(code: 'KWD', symbole: 'د.ك', nom: 'Dinar koweïtien',                drapeau: '🇰🇼'),
    Devise(code: 'BHD', symbole: 'BD',   nom: 'Dinar bahreïni',                 drapeau: '🇧🇭'),
    Devise(code: 'OMR', symbole: '﷼',   nom: 'Rial omanais',                   drapeau: '🇴🇲'),
    Devise(code: 'ILS', symbole: '₪',    nom: 'Shekel israélien',               drapeau: '🇮🇱'),
    Devise(code: 'JOD', symbole: 'JD',   nom: 'Dinar jordanien',                drapeau: '🇯🇴'),
    Devise(code: 'IQD', symbole: 'ع.د',  nom: 'Dinar irakien',                  drapeau: '🇮🇶'),
    Devise(code: 'IRR', symbole: '﷼',   nom: 'Rial iranien',                   drapeau: '🇮🇷'),
    Devise(code: 'LBP', symbole: 'L£',   nom: 'Livre libanaise',                drapeau: '🇱🇧'),

    // ── Asie ────────────────────────────────────────────────────────────────
    Devise(code: 'JPY', symbole: '¥',    nom: 'Yen japonais',                   drapeau: '🇯🇵'),
    Devise(code: 'CNY', symbole: '¥',    nom: 'Yuan chinois (renminbi)',         drapeau: '🇨🇳'),
    Devise(code: 'INR', symbole: '₹',    nom: 'Roupie indienne',                drapeau: '🇮🇳'),
    Devise(code: 'KRW', symbole: '₩',    nom: 'Won sud-coréen',                 drapeau: '🇰🇷'),
    Devise(code: 'SGD', symbole: 'S\$',  nom: 'Dollar singapourien',            drapeau: '🇸🇬'),
    Devise(code: 'HKD', symbole: 'HK\$', nom: 'Dollar de Hong Kong',            drapeau: '🇭🇰'),
    Devise(code: 'TWD', symbole: 'NT\$', nom: 'Dollar taiwanais',               drapeau: '🇹🇼'),
    Devise(code: 'THB', symbole: '฿',    nom: 'Baht thaïlandais',               drapeau: '🇹🇭'),
    Devise(code: 'VND', symbole: '₫',    nom: 'Dong vietnamien',                drapeau: '🇻🇳'),
    Devise(code: 'IDR', symbole: 'Rp',   nom: 'Roupiah indonésienne',           drapeau: '🇮🇩'),
    Devise(code: 'MYR', symbole: 'RM',   nom: 'Ringgit malaisien',              drapeau: '🇲🇾'),
    Devise(code: 'PHP', symbole: '₱',    nom: 'Peso philippin',                 drapeau: '🇵🇭'),
    Devise(code: 'PKR', symbole: '₨',    nom: 'Roupie pakistanaise',            drapeau: '🇵🇰'),
    Devise(code: 'BDT', symbole: '৳',    nom: 'Taka bangladais',                drapeau: '🇧🇩'),
    Devise(code: 'LKR', symbole: '₨',    nom: 'Roupie sri-lankaise',            drapeau: '🇱🇰'),
    Devise(code: 'NPR', symbole: '₨',    nom: 'Roupie népalaise',               drapeau: '🇳🇵'),
    Devise(code: 'MMK', symbole: 'K',    nom: 'Kyat birman',                    drapeau: '🇲🇲'),
    Devise(code: 'KHR', symbole: '៛',    nom: 'Riel cambodgien',                drapeau: '🇰🇭'),
    Devise(code: 'LAK', symbole: '₭',    nom: 'Kip laotien',                    drapeau: '🇱🇦'),
    Devise(code: 'MNT', symbole: '₮',    nom: 'Tugrik mongol',                  drapeau: '🇲🇳'),
    Devise(code: 'KZT', symbole: '₸',    nom: 'Tenge kazakh',                   drapeau: '🇰🇿'),

    // ── Océanie ─────────────────────────────────────────────────────────────
    Devise(code: 'AUD', symbole: 'A\$',  nom: 'Dollar australien',              drapeau: '🇦🇺'),
    Devise(code: 'NZD', symbole: 'NZ\$', nom: 'Dollar néo-zélandais',           drapeau: '🇳🇿'),
    Devise(code: 'FJD', symbole: 'FJ\$', nom: 'Dollar fidjien',                 drapeau: '🇫🇯'),
    Devise(code: 'PGK', symbole: 'K',    nom: 'Kina papouasien',                drapeau: '🇵🇬'),
  ];

  /// Devises mises en avant (affichées en tête de liste)
  static const List<String> codesPrioritaires = [
    'XOF', 'XAF', 'EUR', 'USD', 'GBP', 'CAD', 'CHF',
    'NGN', 'GHS', 'KES', 'ZAR', 'MAD', 'EGP', 'AED',
  ];

  /// Retourne la devise par son code (fallback FCFA)
  static Devise parCode(String? code) {
    if (code == null || code.isEmpty) return toutes.first;
    return toutes.firstWhere(
      (d) => d.code == code,
      orElse: () => toutes.first,
    );
  }

  /// Formate un montant avec le symbole de la devise
  static String formaterMontant(num montant, String? codeDevise) {
    final devise = parCode(codeDevise);
    // Formatage avec séparateur de milliers
    final entier = montant.abs().toInt();
    final str = entier.toString();
    final buffer = StringBuffer();
    for (int i = 0; i < str.length; i++) {
      if (i > 0 && (str.length - i) % 3 == 0) buffer.write('\u202F'); // espace fine
      buffer.write(str[i]);
    }
    final negatif = montant < 0 ? '-' : '';
    return '$negatif${buffer.toString()} ${devise.symbole}';
  }

  /// Liste triée : prioritaires d'abord, puis le reste par ordre alphabétique
  static List<Devise> get listeTrier {
    final prioritaires = codesPrioritaires
        .map((c) => toutes.firstWhere((d) => d.code == c, orElse: () => toutes.first))
        .toList();
    final reste = toutes.where((d) => !codesPrioritaires.contains(d.code)).toList()
      ..sort((a, b) => a.nom.compareTo(b.nom));
    return [...prioritaires, ...reste];
  }
}
