import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

// =============================================================================
// SUPPORT CLIENT — Vue utilisateur (ouvrir ticket + suivi)
// =============================================================================

class SupportScreen extends StatefulWidget {
  final String gestionnaire;    // nom ou pseudo du client
  final String? codeTontine;

  const SupportScreen({super.key, required this.gestionnaire, this.codeTontine});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<Map<String, dynamic>> _tickets = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _charger();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _charger() async {
    setState(() => _loading = true);
    final t = await SupabaseService.supportMesTickets(widget.gestionnaire);
    if (mounted) setState(() { _tickets = t; _loading = false; });
  }

  void _ouvrirNouveauTicket() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => _NouveauTicketScreen(
        gestionnaire: widget.gestionnaire,
        codeTontine:  widget.codeTontine,
        onCree:       _charger,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final actifs  = _tickets.where((t) => !['resolu','ferme'].contains(t['statut'])).toList();
    final fermes  = _tickets.where((t) =>  ['resolu','ferme'].contains(t['statut'])).toList();
    final nbNonLus= _tickets.fold<int>(0, (s, t) => s + ((t['nb_non_lus'] as num?)?.toInt() ?? 0));

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: const Text('Support',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.encre)),
        iconTheme: const IconThemeData(color: AppColors.encre),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded, color: AppColors.encre), onPressed: _charger),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppColors.encre,
          unselectedLabelColor: AppColors.texteDoux,
          indicatorColor: AppColors.encre,
          labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          tabs: [
            Tab(text: 'En cours (${actifs.length})'),
            Tab(text: 'Résolus (${fermes.length})'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.encre,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nouveau ticket', style: TextStyle(fontWeight: FontWeight.w700)),
        onPressed: _ouvrirNouveauTicket,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Banner réponse non lue
                if (nbNonLus > 0)
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.succes.withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.succes.withValues(alpha: .3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.mark_chat_unread_outlined, color: AppColors.succes, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$nbNonLus réponse(s) de notre équipe non lue(s)',
                            style: const TextStyle(fontSize: 13, color: AppColors.succes, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _ListeTickets(tickets: actifs,   gestionnaire: widget.gestionnaire, onRefresh: _charger),
                      _ListeTickets(tickets: fermes,   gestionnaire: widget.gestionnaire, onRefresh: _charger),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Liste tickets client
// ─────────────────────────────────────────────────────────────────────────────
class _ListeTickets extends StatelessWidget {
  final List<Map<String, dynamic>> tickets;
  final String gestionnaire;
  final VoidCallback onRefresh;

  const _ListeTickets({required this.tickets, required this.gestionnaire, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (tickets.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: AppColors.texteDoux.withValues(alpha: .5)),
            const SizedBox(height: 12),
            const Text('Aucun ticket', style: TextStyle(color: AppColors.texteDoux, fontSize: 15)),
            const SizedBox(height: 6),
            const Text('Créez votre premier ticket de support\nvia le bouton ci-dessous.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.texteDoux, fontSize: 13)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
      itemCount: tickets.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _CarteTicketClient(
        ticket:       tickets[i],
        gestionnaire: gestionnaire,
        onRefresh:    onRefresh,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Carte ticket client
// ─────────────────────────────────────────────────────────────────────────────
class _CarteTicketClient extends StatelessWidget {
  final Map<String, dynamic> ticket;
  final String gestionnaire;
  final VoidCallback onRefresh;

  const _CarteTicketClient({required this.ticket, required this.gestionnaire, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final ref      = ticket['ref']    as String? ?? '';
    final sujet    = ticket['sujet']  as String? ?? '';
    final statut   = ticket['statut'] as String? ?? 'ouvert';
    final cat      = ticket['categorie'] as String? ?? '';
    final nbNonLus = (ticket['nb_non_lus'] as num?)?.toInt() ?? 0;
    final dateStr  = ticket['mis_a_jour'] as String? ?? ticket['cree_le'] as String? ?? '';
    final date     = DateTime.tryParse(dateStr);

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => ConversationClientScreen(
          ticket:       ticket,
          gestionnaire: gestionnaire,
          onUpdate:     onRefresh,
        ),
      )),
      child: CarteTC(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icône catégorie
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: AppColors.encre.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(_iconeCategorie(cat), color: AppColors.encre, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(ref,
                          style: const TextStyle(fontSize: 11, fontFamily: 'monospace',
                              color: AppColors.encreDoux, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      _BadgeStatut(statut: statut),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(sujet,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (date != null)
                        Text('Mis à jour ${Formatters.dateFormatee(date)}',
                            style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
                      const Spacer(),
                      if (nbNonLus > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.succes,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('$nbNonLus nouveau(x)',
                              style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, color: AppColors.texteDoux),
          ],
        ),
      ),
    );
  }

  IconData _iconeCategorie(String c) => switch (c) {
    'paiement'  => Icons.payment_outlined,
    'kyc'       => Icons.badge_outlined,
    'tontine'   => Icons.group_outlined,
    'technique' => Icons.build_outlined,
    _           => Icons.help_outline_rounded,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Conversation ticket (vue client)
// ─────────────────────────────────────────────────────────────────────────────
class ConversationClientScreen extends StatefulWidget {
  final Map<String, dynamic> ticket;
  final String gestionnaire;
  final VoidCallback onUpdate;

  const ConversationClientScreen({
    super.key, required this.ticket, required this.gestionnaire, required this.onUpdate});

  @override
  State<ConversationClientScreen> createState() => _ConversationClientScreenState();
}

class _ConversationClientScreenState extends State<ConversationClientScreen> {
  final _reponseCtrl = TextEditingController();
  final _scrollCtrl  = ScrollController();
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  bool _envoi   = false;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  @override
  void dispose() {
    _reponseCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _charger() async {
    setState(() => _loading = true);
    final m = await SupabaseService.supportMessagesTicket(
      ticketId:  widget.ticket['id'] as int,
      estAdmin:  false,
      cleOuGest: widget.gestionnaire,
    );
    if (mounted) {
      setState(() { _messages = m; _loading = false; });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
        }
      });
    }
  }

  Future<void> _repondre() async {
    final corps = _reponseCtrl.text.trim();
    if (corps.isEmpty || _envoi) return;
    setState(() => _envoi = true);
    _reponseCtrl.clear();
    await SupabaseService.supportRepondre(
      ticketId:  widget.ticket['id'] as int,
      auteur:    widget.gestionnaire,
      corps:     corps,
      estAdmin:  false,
      cleOuGest: widget.gestionnaire,
    );
    await _charger();
    widget.onUpdate();
    setState(() => _envoi = false);
  }

  @override
  Widget build(BuildContext context) {
    final ref    = widget.ticket['ref']    as String? ?? '';
    final sujet  = widget.ticket['sujet']  as String? ?? '';
    final statut = widget.ticket['statut'] as String? ?? 'ouvert';

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        leading: const BackButton(color: AppColors.encre),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ref,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace',
                    color: AppColors.encreDoux, fontWeight: FontWeight.w600)),
            Text(sujet,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.encre),
                overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _BadgeStatut(statut: statut),
          ),
        ],
      ),
      body: Column(
        children: [
          // Info
          Container(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: AppColors.fondCode, borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: [
                const Icon(Icons.support_agent_outlined, size: 16, color: AppColors.encre),
                const SizedBox(width: 6),
                const Text('Notre équipe vous répondra sous 24h',
                    style: TextStyle(fontSize: 12, color: AppColors.encreDoux)),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.lignes),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? const Center(child: Text('Aucun message', style: TextStyle(color: AppColors.texteDoux)))
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) => _BulleClient(
                          message: _messages[i],
                          pseudoClient: widget.gestionnaire,
                        ),
                      ),
          ),
          // Champ réponse (si non fermé)
          if (statut != 'ferme' && statut != 'resolu')
            Container(
              color: AppColors.fondPapier,
              padding: EdgeInsets.fromLTRB(
                  16, 8, 16, MediaQuery.of(context).viewInsets.bottom + 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _reponseCtrl,
                      minLines: 1, maxLines: 4,
                      decoration: InputDecoration(
                        hintText: 'Votre message…',
                        filled: true, fillColor: AppColors.fondCode,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _repondre,
                    child: Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                          color: AppColors.encre, borderRadius: BorderRadius.circular(12)),
                      child: _envoi
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          if (statut == 'resolu' || statut == 'ferme')
            Container(
              color: AppColors.fondCode,
              padding: const EdgeInsets.all(16),
              child: Text(
                statut == 'resolu' ? '✓ Ce ticket a été résolu' : '• Ce ticket est fermé',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: statut == 'resolu' ? AppColors.succes : AppColors.texteDoux,
                  fontWeight: FontWeight.w600, fontSize: 13,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bulle de message côté client
// ─────────────────────────────────────────────────────────────────────────────
class _BulleClient extends StatelessWidget {
  final Map<String, dynamic> message;
  final String pseudoClient;
  const _BulleClient({required this.message, required this.pseudoClient});

  @override
  Widget build(BuildContext context) {
    final estAdmin = message['est_admin'] as bool? ?? false;
    final corps    = message['corps']    as String? ?? '';
    final auteur   = message['auteur']   as String? ?? '';
    final date     = DateTime.tryParse(message['envoye_le'] as String? ?? '');
    final estMoi   = !estAdmin;  // côté client, "moi" = non-admin

    return Align(
      alignment: estMoi ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .78),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: estMoi ? AppColors.encre : AppColors.fondCode,
          borderRadius: BorderRadius.only(
            topLeft:     const Radius.circular(16),
            topRight:    const Radius.circular(16),
            bottomLeft:  Radius.circular(estMoi ? 16 : 4),
            bottomRight: Radius.circular(estMoi ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: estMoi ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (estAdmin)
              const Text('Support TontineClair',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.encreDoux)),
            const SizedBox(height: 2),
            Text(corps,
                style: TextStyle(
                  fontSize: 13, height: 1.4,
                  color: estMoi ? Colors.white : AppColors.encre,
                )),
            const SizedBox(height: 4),
            Text(
              date != null ? Formatters.heureFormatee(date) : '',
              style: TextStyle(fontSize: 10, color: estMoi ? Colors.white54 : AppColors.texteDoux),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Écran Nouveau Ticket
// ─────────────────────────────────────────────────────────────────────────────
class _NouveauTicketScreen extends StatefulWidget {
  final String gestionnaire;
  final String? codeTontine;
  final VoidCallback onCree;

  const _NouveauTicketScreen({
    required this.gestionnaire,
    this.codeTontine,
    required this.onCree,
  });

  @override
  State<_NouveauTicketScreen> createState() => _NouveauTicketScreenState();
}

class _NouveauTicketScreenState extends State<_NouveauTicketScreen> {
  final _sujetCtrl = TextEditingController();
  final _descCtrl  = TextEditingController();
  String _categorie = 'autre';
  bool _loading = false;
  String? _erreur;

  final _categories = [
    ('paiement',  'Paiement / Mobile Money', Icons.payment_outlined),
    ('kyc',       'KYC / Identité',          Icons.badge_outlined),
    ('tontine',   'Tontine',                 Icons.group_outlined),
    ('technique', 'Problème technique',      Icons.build_outlined),
    ('autre',     'Autre',                   Icons.help_outline_rounded),
  ];

  @override
  void dispose() {
    _sujetCtrl.dispose(); _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _soumettre() async {
    final sujet = _sujetCtrl.text.trim();
    final desc  = _descCtrl.text.trim();
    if (sujet.isEmpty || desc.isEmpty) {
      setState(() => _erreur = 'Sujet et description requis');
      return;
    }
    setState(() { _loading = true; _erreur = null; });
    final res = await SupabaseService.supportOuvrirTicket(
      gestionnaire: widget.gestionnaire,
      codeTontine:  widget.codeTontine,
      categorie:    _categorie,
      sujet:        sujet,
      description:  desc,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    if (res['ok'] == true) {
      widget.onCree();
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ticket ${res['ref']} créé — nous vous répondrons sous 24h'),
          backgroundColor: AppColors.succes,
        ),
      );
    } else {
      setState(() => _erreur = 'Erreur lors de la création du ticket');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: const Text('Nouveau ticket',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.encre)),
        iconTheme: const IconThemeData(color: AppColors.encre),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Explication
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.encre.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.support_agent_outlined, color: AppColors.encre, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Notre équipe répond sous 24h. Décrivez votre problème avec le maximum de détails.',
                      style: TextStyle(fontSize: 13, color: AppColors.encre),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Catégorie
            const Text('Catégorie', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.encre)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: _categories.map((c) {
                final (code, label, icone) = c;
                final sel = _categorie == code;
                return GestureDetector(
                  onTap: () => setState(() => _categorie = code),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: sel ? AppColors.encre : AppColors.fondCode,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icone, size: 14, color: sel ? Colors.white : AppColors.encre),
                        const SizedBox(width: 5),
                        Text(label, style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700,
                          color: sel ? Colors.white : AppColors.encre,
                        )),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // Sujet
            ChampLabel(label: 'Sujet du problème'),
            TextField(
              controller: _sujetCtrl,
              decoration: const InputDecoration(hintText: 'Ex: Impossible de valider mon KYC'),
            ),
            const SizedBox(height: 16),

            // Description
            ChampLabel(label: 'Description détaillée'),
            TextField(
              controller: _descCtrl,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'Décrivez votre problème en détail…\nCode tontine, étapes, message d\'erreur reçu…',
                alignLabelWithHint: true,
              ),
            ),

            if (_erreur != null) ...[
              const SizedBox(height: 10),
              ChampErreur(texte: _erreur),
            ],
            const SizedBox(height: 28),
            BtnPrincipal(label: 'Envoyer le ticket', onTap: _soumettre, loading: _loading),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

// ── Widgets locaux ────────────────────────────────────────────────────────────

class _BadgeStatut extends StatelessWidget {
  final String statut;
  const _BadgeStatut({required this.statut});

  @override
  Widget build(BuildContext context) {
    final (label, couleur) = switch (statut) {
      'ouvert'   => ('Ouvert',    AppColors.alerte),
      'en_cours' => ('En cours',  AppColors.or),
      'resolu'   => ('Résolu',    AppColors.succes),
      'ferme'    => ('Fermé',     AppColors.texteDoux),
      _          => (statut,      AppColors.texteDoux),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: couleur)),
    );
  }
}
