import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/paydunya_service.dart';
import '../utils/formatters.dart';

/// Écran de paiement PayDunya — Mobile Money (Orange Money, Wave, MTN, Moov…)
///
/// Workflow :
///   1. creerInvoice → checkout_url + token PayDunya
///   2. Ouverture du checkout_url dans le navigateur (page PayDunya)
///   3. Polling toutes les 8s (max 15 min) pour détecter la confirmation
///   4. Dès status "completed" → confirmerEtCrediter → crédit Supabase
///   5. Affichage "Paiement confirmé"
///
/// Garanties :
///   • Clés PayDunya uniquement côté Edge Function (jamais dans Flutter)
///   • Crédit uniquement via confirmerEtCrediter (double vérification serveur)
///   • Double-click protégé par [_enTraitement]
class PaiementPayDunyaScreen extends StatefulWidget {
  final String  code;
  final String  typeFlux;      // cotisation | caisse | penalite | remboursement_pret | pret_octroye
  final Membre? membre;
  final int?    montant;
  final String  description;
  final String? membreId;
  final String? membreNom;
  final String? membreEmail;
  final String? telephone;
  final String? pretId;
  final int?    taux;
  final int?    dureesMois;
  final int?    numeroTour;

  const PaiementPayDunyaScreen({
    super.key,
    required this.code,
    required this.typeFlux,
    this.membre,
    this.montant,
    this.description = 'Paiement',
    this.membreId,
    this.membreNom,
    this.membreEmail,
    this.telephone,
    this.pretId,
    this.taux,
    this.dureesMois,
    this.numeroTour,
  });

  @override
  State<PaiementPayDunyaScreen> createState() => _PaiementPayDunyaScreenState();
}

class _PaiementPayDunyaScreenState extends State<PaiementPayDunyaScreen>
    with WidgetsBindingObserver {

  // ── Couleurs PayDunya (Mobile Money orange) ───────────────────────────────
  static const Color _couleurPrimaire = Color(0xFFFF6B35);  // Orange vif
  static const Color _couleurFond     = Color(0xFFFFF5F2);

  // ── État ─────────────────────────────────────────────────────────────────
  bool                _enTraitement      = false;
  bool                _invoiceCree       = false;
  bool                _paiementOuvert    = false;
  bool                _confirme          = false;
  bool                _annule            = false;
  bool                _enPolling         = false;
  String?             _erreur;
  String?             _checkoutUrl;
  String?             _pdToken;
  String?             _numCommande;
  PayDunyaStatut?     _dernierStatut;
  int                 _tentativesPolling = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Créer l'invoice automatiquement à l'ouverture
    WidgetsBinding.instance.addPostFrameCallback((_) => _creerInvoice());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Quand l'utilisateur revient dans l'app après avoir payé sur PayDunya
    if (state == AppLifecycleState.resumed && _paiementOuvert && !_confirme && !_annule) {
      if (kDebugMode) debugPrint('[PayDunya] App reprise → vérif statut');
      if (!_enPolling) _lancerPolling();
    }
  }

  // ── Montant effectif ─────────────────────────────────────────────────────

  int get _montantEffectif {
    if (widget.montant != null && widget.montant! > 0) return widget.montant!;
    return 0;
  }

  String get _membreIdEffectif  => widget.membreId  ?? widget.membre?.id  ?? '';
  String get _membreNomEffectif => widget.membreNom  ?? widget.membre?.nom ?? '';

  // ── Créer l'invoice PayDunya ──────────────────────────────────────────────

  Future<void> _creerInvoice() async {
    if (_enTraitement || _invoiceCree) return;
    if (_montantEffectif <= 0) {
      setState(() => _erreur = 'Montant invalide. Veuillez réessayer.');
      return;
    }

    setState(() {
      _enTraitement = true;
      _erreur       = null;
    });

    try {
      final resultat = await PayDunyaService.creerInvoice(
        tontineCode:    widget.code,
        typeOperation:  widget.typeFlux,
        montantXof:     _montantEffectif,
        description:    widget.description,
        membreId:       _membreIdEffectif.isNotEmpty ? _membreIdEffectif : null,
        membreNom:      _membreNomEffectif.isNotEmpty ? _membreNomEffectif : null,
        membreEmail:    widget.membreEmail,
        telephone:      widget.telephone ?? widget.membre?.tel,
        pretId:         widget.pretId,
      );

      if (!mounted) return;
      setState(() {
        _checkoutUrl   = resultat.checkoutUrl;
        _pdToken       = resultat.token;
        _numCommande   = resultat.numCommande;
        _invoiceCree   = true;
        _enTraitement  = false;
      });

      if (kDebugMode) {
        debugPrint('[PayDunya] Invoice créée: token=${resultat.token}');
        debugPrint('[PayDunya] Ref: ${resultat.numCommande}');
      }

    } on PayDunyaException catch (e) {
      if (!mounted) return;
      setState(() {
        _erreur       = e.message;
        _enTraitement = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erreur       = 'Erreur inattendue: $e';
        _enTraitement = false;
      });
    }
  }

  // ── Ouvrir la page de paiement PayDunya ─────────────────────────────────

  Future<void> _ouvrirPaiement() async {
    if (_checkoutUrl == null || _enTraitement) return;

    try {
      final uri = Uri.parse(_checkoutUrl!);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        setState(() => _paiementOuvert = true);
        // Démarrer le polling dans 10s (laisser le temps à l'utilisateur)
        Future<void>.delayed(const Duration(seconds: 10), () {
          if (mounted && !_confirme && !_annule) _lancerPolling();
        });
      } else {
        setState(() => _erreur = 'Impossible d\'ouvrir le lien de paiement.');
      }
    } catch (e) {
      setState(() => _erreur = 'Erreur: $e');
    }
  }

  // ── Polling statut ───────────────────────────────────────────────────────

  Future<void> _lancerPolling() async {
    if (_enPolling || _confirme || _annule || _pdToken == null) return;
    setState(() { _enPolling = true; _tentativesPolling = 0; });

    await PayDunyaService.pollerjusquaConfirmation(
      numCommande:   _numCommande!,
      tontineCode:   widget.code,
      typeOperation: widget.typeFlux,
      token:         _pdToken!,
      membreNom:     _membreNomEffectif.isNotEmpty ? _membreNomEffectif : null,
      membreId:      _membreIdEffectif.isNotEmpty  ? _membreIdEffectif  : null,
      pretId:        widget.pretId,
      montantXof:    _montantEffectif,
      intervalle:    const Duration(seconds: 8),
      timeout:       const Duration(minutes: 15),
      onStatutChange: (s) {
        if (!mounted) return;
        setState(() {
          _dernierStatut = s;
          _tentativesPolling++;
        });
      },
      onConfirme: (s) {
        if (!mounted) return;
        setState(() {
          _confirme  = true;
          _enPolling = false;
          _dernierStatut = s;
        });
        HapticFeedback.heavyImpact();
      },
      onEchec: (msg) {
        if (!mounted) return;
        setState(() {
          _annule    = true;
          _enPolling = false;
          _erreur    = msg;
        });
      },
      onTimeout: () {
        if (!mounted) return;
        setState(() {
          _enPolling = false;
          _erreur    = 'Délai de vérification dépassé. Si vous avez payé, '
                       'le crédit sera automatique via notification.';
        });
      },
    );
  }

  // ── Vérification manuelle ────────────────────────────────────────────────

  Future<void> _verifierManuellement() async {
    if (_enTraitement || _pdToken == null) return;
    setState(() { _enTraitement = true; _erreur = null; });

    try {
      final statut = await PayDunyaService.confirmerEtCrediter(
        numCommande:   _numCommande!,
        tontineCode:   widget.code,
        typeOperation: widget.typeFlux,
        membreNom:     _membreNomEffectif.isNotEmpty ? _membreNomEffectif : null,
        membreId:      _membreIdEffectif.isNotEmpty  ? _membreIdEffectif  : null,
        pretId:        widget.pretId,
        montantXof:    _montantEffectif,
      );

      if (!mounted) return;
      if (statut.ok) {
        setState(() { _confirme = true; _enTraitement = false; });
        HapticFeedback.heavyImpact();
      } else {
        setState(() {
          _enTraitement = false;
          _erreur = statut.status == 'pending'
              ? 'Paiement pas encore reçu. Patientez ou recommencez le paiement.'
              : 'Statut: ${statut.status}';
        });
      }
    } on PayDunyaException catch (e) {
      if (!mounted) return;
      setState(() { _enTraitement = false; _erreur = e.message; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _enTraitement = false; _erreur = 'Erreur: $e'; });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _couleurFond,
      appBar: AppBar(
        backgroundColor: _couleurPrimaire,
        foregroundColor: Colors.white,
        title: const Text(
          'Paiement Mobile Money',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
        centerTitle: true,
        elevation: 0,
      ),
      body: SafeArea(
        child: _confirme
            ? _buildConfirme()
            : _annule
                ? _buildAnnule()
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildRecapitulatif(),
                        const SizedBox(height: 20),
                        _buildOperateurs(),
                        const SizedBox(height: 20),
                        if (_erreur != null) _buildErreur(),
                        if (_enPolling) _buildPolling(),
                        if (!_invoiceCree && _enTraitement) _buildCreationInvoice(),
                        if (_invoiceCree && !_confirme) _buildBoutonPayer(),
                        const SizedBox(height: 12),
                        if (_paiementOuvert && !_confirme && !_enPolling)
                          _buildBoutonVerifier(),
                        const SizedBox(height: 20),
                        _buildAide(),
                      ],
                    ),
                  ),
      ),
    );
  }

  // ── Récapitulatif paiement ────────────────────────────────────────────────

  Widget _buildRecapitulatif() {
    return Container(
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _couleurPrimaire.withValues(alpha: 0.1),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  color:        _couleurPrimaire.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.phone_android, color: _couleurPrimaire, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.description,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    Text(
                      'Tontine ${widget.code}',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Montant', style: TextStyle(color: Colors.grey)),
              Text(
                Formatters.montant(_montantEffectif),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: _couleurPrimaire,
                ),
              ),
            ],
          ),
          if (_membreNomEffectif.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Membre', style: TextStyle(color: Colors.grey)),
                Text(
                  _membreNomEffectif,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ],
          if (_numCommande != null) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Référence', style: TextStyle(color: Colors.grey, fontSize: 11)),
                Text(
                  _numCommande!,
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Opérateurs Mobile Money disponibles ──────────────────────────────────

  Widget _buildOperateurs() {
    final operateurs = [
      _OperateurInfo('Orange Money', 'orange-money-ci', const Color(0xFFFF6600), Icons.phone_android),
      _OperateurInfo('Wave',         'wave-ci',         const Color(0xFF1A73E8), Icons.waves),
      _OperateurInfo('MTN MoMo',     'mtn-ci',          const Color(0xFFFFCC00), Icons.smartphone),
      _OperateurInfo('Moov Money',   'moov-ci',         const Color(0xFF00A0DC), Icons.mobile_friendly),
      _OperateurInfo('Djamo',        'djamo-ci',        const Color(0xFF6C63FF), Icons.credit_card),
    ];

    return Container(
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Opérateurs disponibles',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: operateurs.map((op) => _buildOperateurChip(op)).toList(),
          ),
          const SizedBox(height: 10),
          Text(
            'Sélectionnez votre opérateur sur la page de paiement PayDunya.',
            style: TextStyle(color: Colors.grey[600], fontSize: 11, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }

  Widget _buildOperateurChip(_OperateurInfo op) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color:        op.couleur.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border:       Border.all(color: op.couleur.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(op.icone, color: op.couleur, size: 14),
          const SizedBox(width: 4),
          Text(op.nom, style: TextStyle(color: op.couleur, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ── Bouton principal : payer ──────────────────────────────────────────────

  Widget _buildBoutonPayer() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _enTraitement ? null : _ouvrirPaiement,
        icon: _enTraitement
            ? const SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
              )
            : const Icon(Icons.open_in_new),
        label: Text(
          _paiementOuvert ? 'Rouvrir la page de paiement' : 'Payer maintenant',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _couleurPrimaire,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 3,
        ),
      ),
    );
  }

  // ── Bouton vérification manuelle ─────────────────────────────────────────

  Widget _buildBoutonVerifier() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _enTraitement ? null : _verifierManuellement,
        icon: _enTraitement
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.check_circle_outline),
        label: const Text('J\'ai payé — Vérifier maintenant'),
        style: OutlinedButton.styleFrom(
          foregroundColor: _couleurPrimaire,
          side: const BorderSide(color: _couleurPrimaire),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }

  // ── Création invoice en cours ─────────────────────────────────────────────

  Widget _buildCreationInvoice() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 24, height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: _couleurPrimaire),
          ),
          SizedBox(width: 16),
          Text('Préparation de la facture…', style: TextStyle(fontSize: 15)),
        ],
      ),
    );
  }

  // ── Polling actif ─────────────────────────────────────────────────────────

  Widget _buildPolling() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        Colors.blue[50],
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: Colors.blue[200]!),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Vérification en cours…',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue),
                ),
                Text(
                  'Vérification #$_tentativesPolling — retournez dans l\'app après paiement.',
                  style: TextStyle(fontSize: 12, color: Colors.blue[700]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Erreur ────────────────────────────────────────────────────────────────

  Widget _buildErreur() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        Colors.red[50],
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: Colors.red[200]!),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(_erreur!, style: const TextStyle(color: Colors.red, fontSize: 13))),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.red, size: 18),
            onPressed: _creerInvoice,
            tooltip: 'Réessayer',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  // ── Aide ─────────────────────────────────────────────────────────────────

  Widget _buildAide() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Comment ça marche ?',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 8),
          ...[
            '1. Appuyez sur "Payer maintenant" pour ouvrir la page PayDunya',
            '2. Sélectionnez votre opérateur (Orange, Wave, MTN, Moov…)',
            '3. Entrez votre numéro et validez le paiement',
            '4. Revenez dans l\'app — le crédit est automatique',
          ].map((t) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(t, style: const TextStyle(fontSize: 12, color: Colors.black87)),
          )),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.security, size: 14, color: Colors.green),
              const SizedBox(width: 4),
              Text(
                'Paiement sécurisé par PayDunya',
                style: TextStyle(fontSize: 11, color: Colors.green[700], fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Écran de confirmation ─────────────────────────────────────────────────

  Widget _buildConfirme() {
    final operateurLabel = _dernierStatut?.operateurLabel ?? 'Mobile Money';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90, height: 90,
              decoration: BoxDecoration(
                color:  const Color(0xFF4CAF50).withValues(alpha: 0.15),
                shape:  BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle, color: Color(0xFF4CAF50), size: 54),
            ),
            const SizedBox(height: 24),
            const Text(
              'Paiement confirmé !',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color:     Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${Formatters.montant(_montantEffectif)} reçus via $operateurLabel',
              style: TextStyle(fontSize: 15, color: Colors.grey[700]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              widget.description,
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  foregroundColor: Colors.white,
                  padding:         const EdgeInsets.symmetric(vertical: 16),
                  shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Retour à l\'accueil', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Retour'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Écran d'annulation ────────────────────────────────────────────────────

  Widget _buildAnnule() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cancel_outlined, color: Colors.red, size: 48),
            ),
            const SizedBox(height: 24),
            const Text(
              'Paiement annulé',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            if (_erreur != null) ...[
              const SizedBox(height: 12),
              Text(
                _erreur!,
                style: TextStyle(color: Colors.grey[600], fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    _annule      = false;
                    _invoiceCree = false;
                    _paiementOuvert = false;
                    _erreur      = null;
                  });
                  _creerInvoice();
                },
                icon:  const Icon(Icons.refresh),
                label: const Text('Réessayer', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _couleurPrimaire,
                  foregroundColor: Colors.white,
                  padding:         const EdgeInsets.symmetric(vertical: 16),
                  shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Retour'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Données opérateurs
// ─────────────────────────────────────────────────────────────────────────────

class _OperateurInfo {
  final String nom;
  final String code;
  final Color  couleur;
  final IconData icone;
  const _OperateurInfo(this.nom, this.code, this.couleur, this.icone);
}
