import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/tontine.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';

/// Écran de paiement manuel.
///
/// Remplace l'ancien sélecteur Mobile Money / Crypto.
/// L'utilisateur effectue lui-même le paiement puis soumet la référence.
/// Retourne true si le paiement est confirmé, false sinon.
class PaiementChoixScreen extends StatefulWidget {
  final String  code;
  final Membre? membre;
  final String  typeFlux;
  final int?    montant;
  final String? description;
  final String? membreId;
  final String? membreNom;
  final String? pretId;
  final String? telephone;
  final String? operateur;
  final int?    taux;
  final int?    dureesMois;
  final int?    numeroTour;

  const PaiementChoixScreen({
    super.key,
    required this.code,
    required this.typeFlux,
    this.membre,
    this.montant,
    this.description,
    this.membreId,
    this.membreNom,
    this.pretId,
    this.telephone,
    this.operateur,
    this.taux,
    this.dureesMois,
    this.numeroTour,
  });

  @override
  State<PaiementChoixScreen> createState() => _PaiementChoixScreenState();
}

class _PaiementChoixScreenState extends State<PaiementChoixScreen> {
  final _referenceCtrl = TextEditingController();
  String _methodePaiement = 'mobile_money';
  bool _confirme = false;

  static const _methodes = [
    ('mobile_money', '📱 Mobile Money', 'Orange Money, Wave, MTN, Moov…'),
    ('virement',     '🏦 Virement bancaire', 'Virement ou dépôt bancaire'),
    ('especes',      '💵 Espèces',      'Paiement en main propre'),
    ('autre',        '🔗 Autre méthode', 'Chèque, Western Union, etc.'),
  ];

  @override
  void dispose() {
    _referenceCtrl.dispose();
    super.dispose();
  }

  String _libelleFlux() {
    switch (widget.typeFlux) {
      case 'cotisation':           return 'Cotisation';
      case 'caisse':               return 'Apport caisse';
      case 'depense_caisse':       return 'Dépense caisse';
      case 'penalite':             return 'Pénalité';
      case 'pret_octroye':         return 'Octroi de prêt';
      case 'remboursement_pret':   return 'Remboursement prêt';
      case 'decaissement_cagnotte':return 'Décaissement cagnotte';
      default:                     return 'Paiement';
    }
  }

  Future<void> _confirmerPaiement() async {
    final ref = _referenceCtrl.text.trim();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Confirmer le paiement',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Le paiement a bien été effectué ?',
                style: TextStyle(fontSize: 14, color: AppColors.texteDoux)),
            if (ref.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.fondSecondaire,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.lignes),
                ),
                child: Row(children: [
                  const Icon(Icons.receipt_long_outlined, size: 16, color: AppColors.texteDoux),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Réf : $ref',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                ]),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler',
                style: TextStyle(color: AppColors.texteDoux)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.or,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            child: const Text('Confirmer', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (ok == true && mounted) {
      // Retourner la méthode et la référence pour que le caller puisse
      // les passer directement à _togglePaiement (évite double-sélection).
      Navigator.of(context).pop(<String, String>{
        'methode':   _methodePaiement,
        'reference': ref,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final montantAffiche = widget.montant != null
        ? Formatters.montant(widget.montant!, devise: 'XOF')
        : '—';
    final benef = widget.membreNom ?? widget.membre?.nom;
    final tel   = widget.telephone ?? widget.membre?.numeroBenef;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: AppColors.encre),
          onPressed: () => Navigator.of(context).pop(null),
        ),
        title: Text(
          _libelleFlux(),
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AppColors.encre,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Récapitulatif ──────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.fondSecondaire,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.lignes),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Récapitulatif',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: AppColors.texteDoux)),
                  const SizedBox(height: 12),
                  _LigneInfo(label: 'Opération', valeur: _libelleFlux()),
                  if (widget.montant != null)
                    _LigneInfo(label: 'Montant', valeur: montantAffiche,
                        gras: true),
                  if (benef != null)
                    _LigneInfo(label: 'Bénéficiaire', valeur: benef),
                  if (tel != null && tel.isNotEmpty)
                    _LigneInfo(label: 'Téléphone', valeur: tel),
                  if (widget.description != null &&
                      widget.description!.isNotEmpty)
                    _LigneInfo(
                        label: 'Motif', valeur: widget.description!),
                  if (widget.taux != null)
                    _LigneInfo(
                        label: 'Taux',
                        valeur: '${widget.taux} %'),
                  if (widget.dureesMois != null)
                    _LigneInfo(
                        label: 'Durée',
                        valeur: '${widget.dureesMois} mois'),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Instruction ────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F4FD),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: const Color(0xFF2196F3).withValues(alpha: 0.3)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ℹ️', style: TextStyle(fontSize: 18)),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Effectuez le paiement vous-même via le moyen de votre choix, '
                      'puis entrez la référence ou la preuve ci-dessous pour confirmer.',
                      style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF0D47A1),
                          height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Méthode de paiement ────────────────────────────────────────
            const Text('Méthode de paiement utilisée',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: AppColors.texteDoux)),
            const SizedBox(height: 8),
            ...(_methodes.map((m) {
              final (val, titre, sous) = m;
              final selectionne = _methodePaiement == val;
              return GestureDetector(
                onTap: () => setState(() => _methodePaiement = val),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: selectionne
                        ? AppColors.or.withValues(alpha: 0.08)
                        : AppColors.fondSecondaire,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selectionne
                          ? AppColors.or
                          : AppColors.lignes,
                      width: selectionne ? 1.5 : 1,
                    ),
                  ),
                  child: Row(children: [
                    Text(titre.split(' ').first,
                        style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              titre.substring(
                                  titre.indexOf(' ') + 1),
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: selectionne
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: selectionne
                                    ? AppColors.or
                                    : AppColors.encre,
                              ),
                            ),
                            Text(sous,
                                style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppColors.texteDoux)),
                          ]),
                    ),
                    if (selectionne)
                      const Icon(Icons.check_circle_rounded,
                          color: AppColors.or, size: 20),
                  ]),
                ),
              );
            })),
            const SizedBox(height: 16),

            // ── Référence (OBLIGATOIRE) ────────────────────────────────────
            Row(
              children: [
                const Text('Référence / preuve de paiement',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.texteDoux)),
                const SizedBox(width: 4),
                const Text('*',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: AppColors.alerte)),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Entrez le numéro de transaction, la référence ou la preuve de votre paiement.',
              style: TextStyle(fontSize: 11.5, color: AppColors.texteDoux, height: 1.4),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _referenceCtrl,
              maxLength: 120,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Ex : REF-123456 ou numéro de transaction',
                counterText: '',
                filled: true,
                fillColor: _referenceCtrl.text.trim().isEmpty && _confirme
                    ? AppColors.alerteFond
                    : AppColors.fondSecondaire,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: _referenceCtrl.text.trim().isEmpty && _confirme
                        ? AppColors.alerte
                        : AppColors.lignes,
                  ),
                ),
                errorText: _referenceCtrl.text.trim().isEmpty && _confirme
                    ? 'La référence est obligatoire'
                    : null,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: _referenceCtrl.text.trim().isEmpty && _confirme
                        ? AppColors.alerte
                        : AppColors.lignes,
                    width: _referenceCtrl.text.trim().isEmpty && _confirme ? 1.5 : 1,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: _referenceCtrl.text.trim().isEmpty && _confirme
                        ? AppColors.alerte
                        : AppColors.or,
                    width: 1.5,
                  ),
                ),
                suffixIcon: _referenceCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.copy_outlined,
                            size: 18, color: AppColors.texteDoux),
                        tooltip: 'Copier',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(
                              text: _referenceCtrl.text.trim()));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Référence copiée'),
                                duration: Duration(seconds: 1)),
                          );
                        },
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 20),

            // ── Checkbox confirmation ──────────────────────────────────────
            GestureDetector(
              onTap: () => setState(() => _confirme = !_confirme),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: _confirme
                          ? AppColors.or
                          : Colors.transparent,
                      border: Border.all(
                        color:
                            _confirme ? AppColors.or : AppColors.lignes,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: _confirme
                        ? const Icon(Icons.check,
                            size: 14, color: Colors.white)
                        : null,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'J\'ai bien effectué le paiement et je confirme son enregistrement.',
                      style: TextStyle(
                          fontSize: 13,
                          color: AppColors.encre,
                          height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ── Bouton confirmer ───────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _confirme && _referenceCtrl.text.trim().isNotEmpty
                    ? _confirmerPaiement
                    : () => setState(() {}),  // force rebuild pour afficher erreur
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _confirme && _referenceCtrl.text.trim().isNotEmpty
                          ? AppColors.or
                          : AppColors.lignes,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: const Text('Confirmer le paiement',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Annuler',
                    style: TextStyle(color: AppColors.texteDoux)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Widget utilitaire ──────────────────────────────────────────────────────

class _LigneInfo extends StatelessWidget {
  final String label;
  final String valeur;
  final bool gras;

  const _LigneInfo({
    required this.label,
    required this.valeur,
    this.gras = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.texteDoux)),
          ),
          Expanded(
            child: Text(
              valeur,
              style: TextStyle(
                fontSize: 13,
                fontWeight: gras ? FontWeight.w700 : FontWeight.w500,
                color: gras ? AppColors.or : AppColors.encre,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
