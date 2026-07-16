import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

// =============================================================================
// SUPPORT CLIENT — Vue Admin (liste tickets + conversation)
// =============================================================================

class SupportAdminScreen extends StatefulWidget {
  final String cle;

  const SupportAdminScreen({super.key, required this.cle});

  @override
  State<SupportAdminScreen> createState() => _SupportAdminScreenState();
}

class _SupportAdminScreenState extends State<SupportAdminScreen> {
  List<Map<String, dynamic>> _tickets = [];
  bool _loading  = true;
  String _filtre = 'ouvert';

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() => _loading = true);
    final t = await SupabaseService.adminListerTickets(widget.cle, statut: _filtre);
    if (mounted) setState(() { _tickets = t; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final nbOuverts     = _tickets.where((t) => t['statut'] == 'ouvert').length;
    final nbEnCours     = _tickets.where((t) => t['statut'] == 'en_cours').length;
    final nbNonLus      = _tickets.fold<int>(0, (s, t) => s + ((t['nb_non_lus'] as num?)?.toInt() ?? 0));

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Support Client',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.encre)),
            if (nbNonLus > 0)
              Text('$nbNonLus message(s) client non lu(s)',
                  style: const TextStyle(fontSize: 11, color: AppColors.alerte)),
          ],
        ),
        iconTheme: const IconThemeData(color: AppColors.encre),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _charger),
        ],
      ),
      body: Column(
        children: [
          // ── Filtres statut ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _FiltreBtn(label: 'Ouverts ($nbOuverts)',     filtre: 'ouvert',   actif: _filtre == 'ouvert',   onTap: () { setState(() => _filtre = 'ouvert');   _charger(); }),
                  const SizedBox(width: 8),
                  _FiltreBtn(label: 'En cours ($nbEnCours)',    filtre: 'en_cours', actif: _filtre == 'en_cours', onTap: () { setState(() => _filtre = 'en_cours'); _charger(); }),
                  const SizedBox(width: 8),
                  _FiltreBtn(label: 'Résolus',  filtre: 'resolu',   actif: _filtre == 'resolu',   onTap: () { setState(() => _filtre = 'resolu');   _charger(); }),
                  const SizedBox(width: 8),
                  _FiltreBtn(label: 'Tous',     filtre: 'tous',     actif: _filtre == 'tous',     onTap: () { setState(() => _filtre = 'tous');     _charger(); }),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: AppColors.lignes),
          // ── Liste tickets ────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _tickets.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.support_agent_outlined, size: 48,
                                color: AppColors.texteDoux.withValues(alpha: .5)),
                            const SizedBox(height: 12),
                            const Text('Aucun ticket', style: TextStyle(color: AppColors.texteDoux, fontSize: 15)),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _tickets.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => _CarteTicketAdmin(
                          ticket: _tickets[i],
                          cle:    widget.cle,
                          onUpdate: _charger,
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Carte ticket (vue admin)
// ─────────────────────────────────────────────────────────────────────────────
class _CarteTicketAdmin extends StatelessWidget {
  final Map<String, dynamic> ticket;
  final String cle;
  final VoidCallback onUpdate;

  const _CarteTicketAdmin({required this.ticket, required this.cle, required this.onUpdate});

  @override
  Widget build(BuildContext context) {
    final ref         = ticket['ref'] as String? ?? '';
    final sujet       = ticket['sujet'] as String? ?? '';
    final gest        = ticket['gestionnaire'] as String? ?? '';
    final cat         = ticket['categorie'] as String? ?? '';
    final statut      = ticket['statut'] as String? ?? 'ouvert';
    final priorite    = ticket['priorite'] as String? ?? 'normale';
    final assigneA    = ticket['assigne_a'] as String?;
    final nbNonLus    = (ticket['nb_non_lus'] as num?)?.toInt() ?? 0;
    final date        = DateTime.tryParse(ticket['cree_le'] as String? ?? '');

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => ConversationTicketScreen(ticket: ticket, cle: cle, onUpdate: onUpdate),
      )),
      child: CarteTC(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // En-tête
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Icône priorité
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: _couleurPriorite(priorite).withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(_iconePriorite(priorite), color: _couleurPriorite(priorite), size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(ref,
                              style: const TextStyle(
                                  fontSize: 11, fontFamily: 'monospace',
                                  fontWeight: FontWeight.w700, color: AppColors.encreDoux)),
                          const Spacer(),
                          _BadgeStatutTicket(statut: statut),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(sujet,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Méta
            Wrap(
              spacing: 8, runSpacing: 4,
              children: [
                _InfoPuce(icone: Icons.person_outline_rounded, texte: gest),
                _InfoPuce(icone: _iconeCategorie(cat), texte: _labelCategorie(cat)),
                if (assigneA != null)
                  _InfoPuce(icone: Icons.assignment_ind_outlined, texte: 'Assigné: $assigneA'),
                if (date != null)
                  _InfoPuce(icone: Icons.access_time_rounded, texte: Formatters.dateFormatee(date)),
              ],
            ),
            if (nbNonLus > 0) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.alerte.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$nbNonLus nouveau(x) message(s) client',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.alerte),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _couleurPriorite(String p) => switch (p) {
    'urgente' => AppColors.alerte,
    'haute'   => AppColors.orFonce,
    'normale' => AppColors.encre,
    _         => AppColors.texteDoux,
  };

  IconData _iconePriorite(String p) => switch (p) {
    'urgente' => Icons.priority_high_rounded,
    'haute'   => Icons.keyboard_double_arrow_up_rounded,
    'normale' => Icons.remove_rounded,
    _         => Icons.keyboard_double_arrow_down_rounded,
  };

  IconData _iconeCategorie(String c) => switch (c) {
    'paiement'  => Icons.payment_outlined,
    'kyc'       => Icons.badge_outlined,
    'tontine'   => Icons.group_outlined,
    'technique' => Icons.build_outlined,
    _           => Icons.help_outline_rounded,
  };

  String _labelCategorie(String c) => switch (c) {
    'paiement'  => 'Paiement',
    'kyc'       => 'KYC',
    'tontine'   => 'Tontine',
    'technique' => 'Technique',
    _           => 'Autre',
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Conversation d'un ticket (admin)
// ─────────────────────────────────────────────────────────────────────────────
class ConversationTicketScreen extends StatefulWidget {
  final Map<String, dynamic> ticket;
  final String cle;
  final VoidCallback onUpdate;

  const ConversationTicketScreen({
    super.key, required this.ticket, required this.cle, required this.onUpdate});

  @override
  State<ConversationTicketScreen> createState() => _ConversationTicketScreenState();
}

class _ConversationTicketScreenState extends State<ConversationTicketScreen> {
  final _reponseCtrl   = TextEditingController();
  final _scrollCtrl    = ScrollController();
  List<Map<String, dynamic>> _messages = [];
  bool _loading        = true;
  bool _envoi          = false;

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
    final id = widget.ticket['id'] as int;
    final m  = await SupabaseService.supportMessagesTicket(
      ticketId: id, estAdmin: true, cleOuGest: widget.cle);
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
      auteur:    'Admin',
      corps:     corps,
      estAdmin:  true,
      cleOuGest: widget.cle,
    );
    await _charger();
    widget.onUpdate();
    setState(() => _envoi = false);
  }

  Future<void> _changerStatut(String statut) async {
    await SupabaseService.adminChangerStatutTicket(
      cle:      widget.cle,
      ticketId: widget.ticket['id'] as int,
      statut:   statut,
    );
    widget.onUpdate();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final ref    = widget.ticket['ref']    as String? ?? '';
    final sujet  = widget.ticket['sujet']  as String? ?? '';
    final statut = widget.ticket['statut'] as String? ?? 'ouvert';
    final gest   = widget.ticket['gestionnaire'] as String? ?? '';

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
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace',
                    color: AppColors.encreDoux, fontWeight: FontWeight.w700)),
            Text(sujet,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.encre),
                overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: AppColors.encre),
            color: AppColors.fondPapier,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: _changerStatut,
            itemBuilder: (_) => [
              if (statut != 'en_cours')
                const PopupMenuItem(value: 'en_cours',
                    child: Row(children: [Icon(Icons.play_arrow_rounded, color: AppColors.or, size: 18),
                      SizedBox(width: 8), Text('Marquer En cours')])),
              if (statut != 'resolu')
                const PopupMenuItem(value: 'resolu',
                    child: Row(children: [Icon(Icons.check_circle_outline_rounded, color: AppColors.succes, size: 18),
                      SizedBox(width: 8), Text('Marquer Résolu')])),
              if (statut != 'ferme')
                const PopupMenuItem(value: 'ferme',
                    child: Row(children: [Icon(Icons.lock_outline_rounded, color: AppColors.texteDoux, size: 18),
                      SizedBox(width: 8), Text('Fermer le ticket')])),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Info ticket
          Container(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.fondCode,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.person_outline_rounded, size: 16, color: AppColors.texteDoux),
                const SizedBox(width: 6),
                Text('Client : $gest', style: const TextStyle(fontSize: 12, color: AppColors.texteDoux)),
                const Spacer(),
                _BadgeStatutTicket(statut: statut),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.lignes),
          // Messages
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? const Center(child: Text('Aucun message', style: TextStyle(color: AppColors.texteDoux)))
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) => _BulleMessage(message: _messages[i]),
                      ),
          ),
          // Champ réponse
          if (statut != 'ferme')
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
                        hintText: 'Répondre au client…',
                        filled: true,
                        fillColor: AppColors.fondCode,
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
                        color: AppColors.encre,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: _envoi
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bulle de message dans la conversation
// ─────────────────────────────────────────────────────────────────────────────
class _BulleMessage extends StatelessWidget {
  final Map<String, dynamic> message;
  const _BulleMessage({required this.message});

  @override
  Widget build(BuildContext context) {
    final estAdmin = message['est_admin'] as bool? ?? false;
    final corps    = message['corps']    as String? ?? '';
    final auteur   = message['auteur']   as String? ?? '';
    final date     = DateTime.tryParse(message['envoye_le'] as String? ?? '');

    return Align(
      alignment: estAdmin ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .78),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: estAdmin ? AppColors.encre : AppColors.fondCode,
          borderRadius: BorderRadius.only(
            topLeft:     const Radius.circular(16),
            topRight:    const Radius.circular(16),
            bottomLeft:  Radius.circular(estAdmin ? 16 : 4),
            bottomRight: Radius.circular(estAdmin ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: estAdmin ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(auteur,
                style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w700,
                  color: estAdmin ? Colors.white70 : AppColors.encreDoux,
                )),
            const SizedBox(height: 4),
            Text(corps,
                style: TextStyle(
                  fontSize: 13, height: 1.4,
                  color: estAdmin ? Colors.white : AppColors.encre,
                )),
            const SizedBox(height: 4),
            Text(
              date != null ? Formatters.heureFormatee(date) : '',
              style: TextStyle(fontSize: 10, color: estAdmin ? Colors.white54 : AppColors.texteDoux),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Widgets locaux ────────────────────────────────────────────────────────────

class _BadgeStatutTicket extends StatelessWidget {
  final String statut;
  const _BadgeStatutTicket({required this.statut});

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

class _FiltreBtn extends StatelessWidget {
  final String label, filtre;
  final bool actif;
  final VoidCallback onTap;
  const _FiltreBtn({required this.label, required this.filtre, required this.actif, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: actif ? AppColors.encre : AppColors.fondCode,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700,
              color: actif ? Colors.white : AppColors.encre,
            )),
      ),
    );
  }
}

class _InfoPuce extends StatelessWidget {
  final IconData icone;
  final String texte;
  const _InfoPuce({required this.icone, required this.texte});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icone, size: 13, color: AppColors.texteDoux),
        const SizedBox(width: 3),
        Text(texte, style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
      ],
    );
  }
}
