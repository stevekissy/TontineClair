// ─────────────────────────────────────────────────────────────────────────────
// PaiementService — Moyens de paiement digitaux par devise
// Logique : chaque devise propose les méthodes les plus utilisées dans sa zone.
// "especes" est toujours ajouté en dernier (universel).
// ─────────────────────────────────────────────────────────────────────────────

class MethodePaiement {
  final String code;   // clé interne ex: 'orange', 'paypal'
  final String label;  // libellé affiché ex: 'Orange Money'
  final String emoji;  // icône visuelle

  const MethodePaiement({
    required this.code,
    required this.label,
    required this.emoji,
  });
}

class PaiementService {
  // ── Catalogue complet de toutes les méthodes ────────────────────────────────
  static const Map<String, MethodePaiement> catalogue = {

    // ── Universel ──────────────────────────────────────────────────────────────
    'especes':       MethodePaiement(code: 'especes',       label: 'Espèces',             emoji: '💵'),
    'virement':      MethodePaiement(code: 'virement',      label: 'Virement bancaire',   emoji: '🏦'),
    'paypal':        MethodePaiement(code: 'paypal',        label: 'PayPal',              emoji: '🅿️'),
    'wise':          MethodePaiement(code: 'wise',          label: 'Wise',                emoji: '🌐'),

    // ── Afrique de l'Ouest (FCFA XOF) ─────────────────────────────────────────
    'orange':        MethodePaiement(code: 'orange',        label: 'Orange Money',        emoji: '🟠'),
    'mtn':           MethodePaiement(code: 'mtn',           label: 'MTN Money',           emoji: '🟡'),
    'moov':          MethodePaiement(code: 'moov',          label: 'Moov Money',          emoji: '🔵'),
    'wave':          MethodePaiement(code: 'wave',          label: 'Wave',                emoji: '🌊'),
    'free_money':    MethodePaiement(code: 'free_money',    label: 'Free Money',          emoji: '📲'),
    'wizall':        MethodePaiement(code: 'wizall',        label: 'Wizall',              emoji: '💳'),

    // ── Nigeria (NGN) ──────────────────────────────────────────────────────────
    'opay':          MethodePaiement(code: 'opay',          label: 'OPay',                emoji: '🟢'),
    'palmpay':       MethodePaiement(code: 'palmpay',       label: 'PalmPay',             emoji: '🌴'),
    'flutterwave':   MethodePaiement(code: 'flutterwave',   label: 'Flutterwave',         emoji: '🦋'),
    'kuda':          MethodePaiement(code: 'kuda',          label: 'Kuda Bank',           emoji: '🏦'),
    'gtbank':        MethodePaiement(code: 'gtbank',        label: 'GTBank Transfer',     emoji: '🏧'),

    // ── Ghana (GHS) ────────────────────────────────────────────────────────────
    'mtn_momo':      MethodePaiement(code: 'mtn_momo',      label: 'MTN MoMo',            emoji: '🟡'),
    'vodafone_cash': MethodePaiement(code: 'vodafone_cash', label: 'Vodafone Cash',       emoji: '🔴'),
    'airteltigo':    MethodePaiement(code: 'airteltigo',    label: 'AirtelTigo Money',    emoji: '📡'),

    // ── Afrique de l'Est (KES / TZS / UGX / RWF / ETB) ───────────────────────
    'mpesa':         MethodePaiement(code: 'mpesa',         label: 'M-Pesa',              emoji: '📱'),
    'airtel_money':  MethodePaiement(code: 'airtel_money',  label: 'Airtel Money',        emoji: '📶'),
    'equitel':       MethodePaiement(code: 'equitel',       label: 'Equitel',             emoji: '💰'),
    'tigopesa':      MethodePaiement(code: 'tigopesa',      label: 'Tigo Pesa',           emoji: '🐯'),

    // ── Afrique du Nord (EGP / MAD / DZD / TND) ───────────────────────────────
    'instapay':      MethodePaiement(code: 'instapay',      label: 'InstaPay',            emoji: '⚡'),
    'fawry':         MethodePaiement(code: 'fawry',         label: 'Fawry',               emoji: '🟣'),
    'cih_pay':       MethodePaiement(code: 'cih_pay',       label: 'CIH Pay',             emoji: '🏦'),
    'd17':           MethodePaiement(code: 'd17',           label: 'D17',                 emoji: '🇹🇳'),
    'baridimob':     MethodePaiement(code: 'baridimob',     label: 'BaridiMob',           emoji: '📬'),
    'gcash_ma':      MethodePaiement(code: 'gcash_ma',      label: 'Maroc Telecom Pay',   emoji: '📲'),

    // ── Afrique du Sud (ZAR) ───────────────────────────────────────────────────
    'snapscan':      MethodePaiement(code: 'snapscan',      label: 'SnapScan',            emoji: '📷'),
    'zapper':        MethodePaiement(code: 'zapper',        label: 'Zapper',              emoji: '⚡'),
    'fnb_ewallet':   MethodePaiement(code: 'fnb_ewallet',   label: 'FNB eWallet',         emoji: '💼'),

    // ── Europe (EUR / CHF / SEK / NOK / DKK / PLN...) ─────────────────────────
    'sepa':          MethodePaiement(code: 'sepa',          label: 'Virement SEPA',       emoji: '🇪🇺'),
    'lydia':         MethodePaiement(code: 'lydia',         label: 'Lydia / Sumeria',     emoji: '💜'),
    'revolut':       MethodePaiement(code: 'revolut',       label: 'Revolut',             emoji: '🔷'),
    'sumup':         MethodePaiement(code: 'sumup',         label: 'SumUp',               emoji: '💳'),
    'twint':         MethodePaiement(code: 'twint',         label: 'Twint',               emoji: '🇨🇭'),
    'swish':         MethodePaiement(code: 'swish',         label: 'Swish',               emoji: '🇸🇪'),
    'mobilepay':     MethodePaiement(code: 'mobilepay',     label: 'MobilePay',           emoji: '🇩🇰'),
    'blik':          MethodePaiement(code: 'blik',          label: 'BLIK',                emoji: '🇵🇱'),

    // ── Royaume-Uni (GBP) ──────────────────────────────────────────────────────
    'monzo':         MethodePaiement(code: 'monzo',         label: 'Monzo',               emoji: '🔥'),
    'faster_pay':    MethodePaiement(code: 'faster_pay',    label: 'Faster Payments',     emoji: '🏦'),

    // ── États-Unis (USD) ───────────────────────────────────────────────────────
    'zelle':         MethodePaiement(code: 'zelle',         label: 'Zelle',               emoji: '💜'),
    'venmo':         MethodePaiement(code: 'venmo',         label: 'Venmo',               emoji: '🔵'),
    'cashapp':       MethodePaiement(code: 'cashapp',       label: 'Cash App',            emoji: '💚'),
    'apple_pay':     MethodePaiement(code: 'apple_pay',     label: 'Apple Pay',           emoji: '🍎'),
    'google_pay':    MethodePaiement(code: 'google_pay',    label: 'Google Pay',          emoji: '🔵'),

    // ── Canada (CAD) ───────────────────────────────────────────────────────────
    'interac':       MethodePaiement(code: 'interac',       label: 'Interac e-Transfer',  emoji: '🍁'),

    // ── Brésil (BRL) ───────────────────────────────────────────────────────────
    'pix':           MethodePaiement(code: 'pix',           label: 'Pix',                 emoji: '⚡'),
    'picpay':        MethodePaiement(code: 'picpay',        label: 'PicPay',              emoji: '🟢'),

    // ── Mexique (MXN) ──────────────────────────────────────────────────────────
    'spei':          MethodePaiement(code: 'spei',          label: 'SPEI',                emoji: '🇲🇽'),
    'oxxo':          MethodePaiement(code: 'oxxo',          label: 'OXXO Pay',            emoji: '🏪'),

    // ── Inde (INR) ─────────────────────────────────────────────────────────────
    'upi':           MethodePaiement(code: 'upi',           label: 'UPI',                 emoji: '🇮🇳'),
    'phonepe':       MethodePaiement(code: 'phonepe',       label: 'PhonePe',             emoji: '💜'),
    'paytm':         MethodePaiement(code: 'paytm',         label: 'Paytm',               emoji: '🔵'),

    // ── Chine (CNY) ────────────────────────────────────────────────────────────
    'wechat_pay':    MethodePaiement(code: 'wechat_pay',    label: 'WeChat Pay',          emoji: '🟢'),
    'alipay':        MethodePaiement(code: 'alipay',        label: 'Alipay',              emoji: '🔵'),

    // ── Japon (JPY) ────────────────────────────────────────────────────────────
    'paypay':        MethodePaiement(code: 'paypay',        label: 'PayPay',              emoji: '🇯🇵'),
    'line_pay':      MethodePaiement(code: 'line_pay',      label: 'Line Pay',            emoji: '🟢'),

    // ── Corée du Sud (KRW) ─────────────────────────────────────────────────────
    'kakaopay':      MethodePaiement(code: 'kakaopay',      label: 'KakaoPay',            emoji: '🟡'),
    'naver_pay':     MethodePaiement(code: 'naver_pay',     label: 'Naver Pay',           emoji: '🟢'),
    'toss':          MethodePaiement(code: 'toss',          label: 'Toss',                emoji: '💙'),

    // ── Golfe / Moyen-Orient (SAR / AED / QAR / KWD) ──────────────────────────
    'stc_pay':       MethodePaiement(code: 'stc_pay',       label: 'STC Pay',             emoji: '🟣'),
    'payby':         MethodePaiement(code: 'payby',         label: 'PayBy',               emoji: '💳'),
    'benefit_pay':   MethodePaiement(code: 'benefit_pay',   label: 'Benefit Pay',         emoji: '🏦'),
    'urpay':         MethodePaiement(code: 'urpay',         label: 'urpay',               emoji: '💰'),

    // ── Asie du Sud-Est (IDR / MYR / PHP / THB / VND) ─────────────────────────
    'dana':          MethodePaiement(code: 'dana',          label: 'DANA',                emoji: '🇮🇩'),
    'gopay':         MethodePaiement(code: 'gopay',         label: 'GoPay',               emoji: '🟢'),
    'ovo':           MethodePaiement(code: 'ovo',           label: 'OVO',                 emoji: '🟣'),
    'touchngo':      MethodePaiement(code: 'touchngo',      label: "Touch 'n Go",         emoji: '🇲🇾'),
    'boost':         MethodePaiement(code: 'boost',         label: 'Boost',               emoji: '⚡'),
    'gcash':         MethodePaiement(code: 'gcash',         label: 'GCash',               emoji: '🔵'),
    'maya':          MethodePaiement(code: 'maya',          label: 'Maya (PayMaya)',       emoji: '🟢'),
    'promptpay':     MethodePaiement(code: 'promptpay',     label: 'PromptPay',           emoji: '🇹🇭'),
    'momo_vn':       MethodePaiement(code: 'momo_vn',       label: 'MoMo (Vietnam)',      emoji: '🇻🇳'),

    // ── Australie / Océanie (AUD / NZD) ───────────────────────────────────────
    'payid':         MethodePaiement(code: 'payid',         label: 'PayID',               emoji: '🇦🇺'),
    'bpay':          MethodePaiement(code: 'bpay',          label: 'BPAY',                emoji: '💳'),
  };

  // ── Mapping devise → liste de codes de méthodes ────────────────────────────
  // "especes" est toujours ajouté automatiquement en dernier par methodesPour().
  static const Map<String, List<String>> _parDevise = {

    // ── Afrique de l'Ouest ─────────────────────────────────────────────────────
    'XOF': ['orange', 'mtn', 'moov', 'wave', 'free_money', 'wizall'],
    'GNF': ['orange', 'mtn', 'moov', 'wave'],
    'GMD': ['wave', 'orange', 'afrimoney'],
    'MRU': ['bankily', 'masrivi'],
    'SLL': ['orange', 'afrimoney'],
    'LRD': ['lonestar_cell', 'orange'],
    'CVE': ['vinti4', 'orange'],

    // ── Afrique Centrale ───────────────────────────────────────────────────────
    'XAF': ['orange', 'mtn', 'moov', 'wave'],
    'CDF': ['orange', 'airtel_money', 'mpesa'],

    // ── Afrique de l'Est ───────────────────────────────────────────────────────
    'KES': ['mpesa', 'airtel_money', 'equitel'],
    'TZS': ['mpesa', 'tigopesa', 'airtel_money', 'mtn_momo'],
    'UGX': ['mpesa', 'airtel_money', 'mtn_momo'],
    'RWF': ['mpesa', 'airtel_money', 'mtn_momo'],
    'ETB': ['mpesa', 'telebirr'],
    'BIF': ['mpesa', 'airtel_money', 'lumicash'],
    'DJF': ['mpesa', 'evs'],
    'SOS': ['hormuud', 'zaad'],
    'ERN': ['virement'],

    // ── Nigeria ────────────────────────────────────────────────────────────────
    'NGN': ['opay', 'palmpay', 'flutterwave', 'kuda', 'gtbank', 'paypal'],

    // ── Ghana ──────────────────────────────────────────────────────────────────
    'GHS': ['mtn_momo', 'vodafone_cash', 'airteltigo', 'paypal'],

    // ── Afrique Australe ───────────────────────────────────────────────────────
    'ZAR': ['snapscan', 'zapper', 'fnb_ewallet', 'paypal', 'wise'],
    'ZMW': ['airtel_money', 'mtn_momo', 'zanaco'],
    'MWK': ['airtel_money', 'mpamba'],
    'BWP': ['orange', 'mascom_mypay'],
    'NAD': ['fnb_ewallet', 'snapscan'],
    'MZN': ['mpesa', 'mkesh'],
    'AOA': ['unitel_money', 'afrikpay'],
    'MGA': ['mvola', 'airtel_money', 'orange'],

    // ── Afrique du Nord ────────────────────────────────────────────────────────
    'EGP': ['instapay', 'fawry', 'vodafone_cash', 'paypal'],
    'MAD': ['cih_pay', 'gcash_ma', 'paypal', 'wise'],
    'DZD': ['baridimob', 'ccp', 'paypal'],
    'TND': ['d17', 'paypal', 'wise'],
    'LYD': ['virement', 'paypal'],
    'SDG': ['virement'],

    // ── Europe ─────────────────────────────────────────────────────────────────
    'EUR': ['sepa', 'paypal', 'revolut', 'wise', 'lydia', 'google_pay', 'apple_pay'],
    'CHF': ['twint', 'paypal', 'revolut', 'wise', 'sepa'],
    'GBP': ['faster_pay', 'paypal', 'revolut', 'monzo', 'wise', 'google_pay', 'apple_pay'],
    'SEK': ['swish', 'paypal', 'revolut', 'wise'],
    'NOK': ['vipps', 'paypal', 'revolut', 'wise'],
    'DKK': ['mobilepay', 'paypal', 'revolut', 'wise'],
    'PLN': ['blik', 'paypal', 'revolut', 'wise'],
    'CZK': ['paypal', 'revolut', 'wise'],
    'HUF': ['paypal', 'revolut', 'wise'],
    'RON': ['paypal', 'revolut', 'wise'],
    'RUB': ['sberpay', 'yoomoney', 'tinkoff'],
    'TRY': ['papara', 'paypal', 'wise'],

    // ── Amériques ──────────────────────────────────────────────────────────────
    'USD': ['zelle', 'venmo', 'cashapp', 'paypal', 'wise', 'apple_pay', 'google_pay'],
    'CAD': ['interac', 'paypal', 'wise', 'google_pay', 'apple_pay'],
    'MXN': ['spei', 'oxxo', 'paypal', 'wise'],
    'BRL': ['pix', 'picpay', 'paypal'],
    'ARS': ['mercadopago', 'paypal', 'wise'],
    'CLP': ['webpay', 'paypal', 'wise'],
    'COP': ['nequi', 'daviplata', 'paypal'],
    'PEN': ['yape', 'plin', 'paypal'],
    'BOB': ['virement', 'paypal'],
    'PYG': ['virement', 'paypal'],
    'UYU': ['abitab', 'paypal'],
    'VES': ['pagomovil', 'paypal'],
    'HTG': ['digicel_moncash', 'natcash'],
    'JMD': ['lynk', 'paypal'],
    'TTD': ['paypal', 'wise'],

    // ── Moyen-Orient / Golfe ───────────────────────────────────────────────────
    'SAR': ['stc_pay', 'urpay', 'paypal', 'wise'],
    'AED': ['payby', 'apple_pay', 'google_pay', 'paypal', 'wise'],
    'QAR': ['stc_pay', 'paypal', 'wise'],
    'KWD': ['benefit_pay', 'paypal', 'wise'],
    'BHD': ['benefit_pay', 'paypal', 'wise'],
    'OMR': ['paypal', 'wise'],
    'ILS': ['bit', 'paybox', 'paypal'],
    'JOD': ['cliq', 'paypal'],
    'IQD': ['qi_card', 'fastpay_iq'],
    'IRR': ['shaparak', 'shetab'],
    'LBP': ['whish', 'paypal'],

    // ── Asie ───────────────────────────────────────────────────────────────────
    'JPY': ['paypay', 'line_pay', 'paypal'],
    'CNY': ['wechat_pay', 'alipay'],
    'INR': ['upi', 'phonepe', 'paytm', 'google_pay', 'paypal'],
    'KRW': ['kakaopay', 'naver_pay', 'toss', 'paypal'],
    'SGD': ['paynow', 'paypal', 'wise', 'revolut'],
    'HKD': ['fps', 'paypal', 'wise'],
    'TWD': ['line_pay', 'jko_pay', 'paypal'],
    'THB': ['promptpay', 'truemoney', 'paypal'],
    'VND': ['momo_vn', 'vnpay', 'zalopay', 'paypal'],
    'IDR': ['gopay', 'dana', 'ovo', 'paypal'],
    'MYR': ['touchngo', 'boost', 'paypal', 'wise'],
    'PHP': ['gcash', 'maya', 'paypal'],
    'PKR': ['jazzcash', 'easypaisa', 'paypal'],
    'BDT': ['bkash', 'nagad', 'rocket'],
    'LKR': ['dialog_genie', 'frimi'],
    'NPR': ['esewa', 'khalti', 'imepay'],
    'MMK': ['wavepay', 'kbzpay'],
    'KHR': ['wing', 'acleda', 'paypal'],
    'LAK': ['bcel_one', 'lao_telecom'],
    'MNT': ['mbank_mn', 'tngpay'],
    'KZT': ['kaspi_pay', 'halyk'],

    // ── Océanie ────────────────────────────────────────────────────────────────
    'AUD': ['payid', 'bpay', 'paypal', 'wise', 'google_pay', 'apple_pay'],
    'NZD': ['paypal', 'wise', 'google_pay', 'apple_pay'],
    'FJD': ['paypal', 'virement'],
    'PGK': ['paypal', 'virement'],
  };

  // ── Méthodes de fallback pour toute devise non listée ─────────────────────
  static const List<String> _fallback = ['paypal', 'wise', 'virement'];

  // ── API principale ─────────────────────────────────────────────────────────
  /// Retourne la liste des méthodes disponibles pour une devise.
  /// "especes" est toujours ajouté en dernier.
  static List<MethodePaiement> methodesPour(String? codeDevise) {
    final code = (codeDevise ?? 'XOF').toUpperCase();
    final codes = _parDevise[code] ?? _fallback;

    final liste = codes
        .map((c) => catalogue[c])
        .whereType<MethodePaiement>()
        .toList();

    // Espèces toujours en dernier
    liste.add(catalogue['especes']!);

    return liste;
  }

  /// Retourne le libellé d'une méthode par son code (fallback = code brut).
  static String label(String code) {
    return catalogue[code]?.label ?? code;
  }

  /// Retourne l'emoji d'une méthode par son code.
  static String emoji(String code) {
    return catalogue[code]?.emoji ?? '💳';
  }
}
