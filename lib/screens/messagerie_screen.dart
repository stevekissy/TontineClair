import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

// =============================================================================
// MESSAGERIE INTERNE ADMIN
// =============================================================================

class AdminMessagerieScreen extends StatefulWidget {
  final String pseudo;
  final String clePerso;
  final String nom;

  const AdminMessagerieScreen({
    super.key,
    required this.pseudo,
    required this.clePerso,
    required this.nom,
  });

  @override
  State<AdminMessagerieScreen> createState() => _AdminMessagerieScreenState();
}

class _AdminMessagerieScreenState extends State<AdminMessagerieScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<Map<String, dynamic>> _recus    = [];
  List<Map<String, dynamic>> _envoyes  = [];
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
    final r = await SupabaseService.adminListerMessages(
      pseudo: widget.pseudo, clePerso: widget.clePerso, boite: 'recus');
    final e = await SupabaseService.adminListerMessages(
      pseudo: widget.pseudo, clePerso: widget.clePerso, boite: 'envoyes');
    if (mounted) setState(() { _recus = r; _envoyes = e; _loading = false; });
  }

  void _ouvrirNouveauMessage() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SheetNouveauMessage(
        pseudo:   widget.pseudo,
        clePerso: widget.clePerso,
        expediteur: widget.nom,
        onEnvoye: _charger,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: const Text('Messagerie',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.encre)),
        iconTheme: const IconThemeData(color: AppColors.encre),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _charger),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppColors.encre,
          unselectedLabelColor: AppColors.texteDoux,
          indicatorColor: AppColors.encre,
          labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          tabs: [
            Tab(text: 'Reçus (${_recus.where((m) => m['lu'] == false).length} non lus)'),
            Tab(text: 'Envoyés (${_envoyes.length})'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.encre,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Nouveau message', style: TextStyle(fontWeight: FontWeight.w700)),
        onPressed: _ouvrirNouveauMessage,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                _ListeMessages(
                  messages: _recus,
                  pseudoActuel: widget.pseudo,
                  clePerso: widget.clePerso,
                  estRecus: true,
                  onRefresh: _charger,
                ),
                _ListeMessages(
                  messages: _envoyes,
                  pseudoActuel: widget.pseudo,
                  clePerso: widget.clePerso,
                  estRecus: false,
                  onRefresh: _charger,
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Liste de messages
// ─────────────────────────────────────────────────────────────────────────────
class _ListeMessages extends StatelessWidget {
  final List<Map<String, dynamic>> messages;
  final String pseudoActuel;
  final String clePerso;
  final bool estRecus;
  final VoidCallback onRefresh;

  const _ListeMessages({
    required this.messages,
    required this.pseudoActuel,
    required this.clePerso,
    required this.estRecus,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(estRecus ? Icons.inbox_outlined : Icons.outbox_outlined,
                size: 48, color: AppColors.texteDoux.withValues(alpha: .5)),
            const SizedBox(height: 12),
            Text(estRecus ? 'Aucun message reçu' : 'Aucun message envoyé',
                style: const TextStyle(color: AppColors.texteDoux, fontSize: 15)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: messages.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final m      = messages[i];
        final lu     = m['lu'] as bool? ?? true;
        final date   = DateTime.tryParse(m['envoye_le'] as String? ?? '');
        final sujet  = m['sujet'] as String? ?? '(sans sujet)';
        final corps  = m['corps'] as String? ?? '';
        final auteur = estRecus
            ? (m['expediteur'] as String? ?? '')
            : (m['destinataire'] as String? ?? '');

        return GestureDetector(
          onTap: () => _ouvrirDetail(context, m),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: lu ? AppColors.fondCode : AppColors.encre.withValues(alpha: .05),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: lu ? AppColors.lignes : AppColors.encre.withValues(alpha: .2),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Indicateur non-lu
                if (!lu && estRecus)
                  Container(
                    margin: const EdgeInsets.only(top: 5, right: 10),
                    width: 8, height: 8,
                    decoration: const BoxDecoration(color: AppColors.encre, shape: BoxShape.circle),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            estRecus ? 'De : $auteur' : 'À : $auteur',
                            style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700,
                              color: lu ? AppColors.encreDoux : AppColors.encre,
                            ),
                          ),
                          Text(
                            date != null ? Formatters.dateFormatee(date) : '',
                            style: const TextStyle(fontSize: 11, color: AppColors.texteDoux),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(sujet,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: lu ? FontWeight.w500 : FontWeight.w700,
                            color: AppColors.encre,
                          )),
                      const SizedBox(height: 3),
                      Text(
                        corps.length > 80 ? '${corps.substring(0, 80)}…' : corps,
                        style: const TextStyle(fontSize: 12, color: AppColors.texteDoux),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _ouvrirDetail(BuildContext context, Map<String, dynamic> m) async {
    final id = m['id'] as int?;
    if (id != null && estRecus && m['lu'] == false) {
      await SupabaseService.adminMarquerLu(
        pseudo: pseudoActuel, clePerso: clePerso, messageId: id);
      onRefresh();
    }
    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SheetDetailMessage(message: m, estRecus: estRecus),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sheet — Détail d'un message
// ─────────────────────────────────────────────────────────────────────────────
class _SheetDetailMessage extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool estRecus;
  const _SheetDetailMessage({required this.message, required this.estRecus});

  @override
  Widget build(BuildContext context) {
    final date  = DateTime.tryParse(message['envoye_le'] as String? ?? '');
    final sujet = message['sujet'] as String? ?? '(sans sujet)';
    final corps = message['corps'] as String? ?? '';
    final auteur= estRecus
        ? (message['expediteur'] as String? ?? '')
        : (message['destinataire'] as String? ?? '');

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.fondPapier,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(width: 40, height: 4,
                decoration: BoxDecoration(color: AppColors.lignes, borderRadius: BorderRadius.circular(2))),
          ),
          const SizedBox(height: 20),
          Text(sujet,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.encre)),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(estRecus ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                  size: 14, color: AppColors.texteDoux),
              const SizedBox(width: 4),
              Text(
                estRecus ? 'De : $auteur' : 'À : $auteur',
                style: const TextStyle(fontSize: 12, color: AppColors.texteDoux),
              ),
              if (date != null) ...[
                const Text(' · ', style: TextStyle(color: AppColors.texteDoux)),
                Text(Formatters.dateFormatee(date),
                    style: const TextStyle(fontSize: 12, color: AppColors.texteDoux)),
              ],
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: AppColors.lignes),
          const SizedBox(height: 12),
          Text(corps, style: const TextStyle(fontSize: 14, color: AppColors.encre, height: 1.5)),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fermer'),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sheet — Nouveau message
// ─────────────────────────────────────────────────────────────────────────────
class _SheetNouveauMessage extends StatefulWidget {
  final String pseudo;
  final String clePerso;
  final String expediteur;
  final VoidCallback onEnvoye;

  const _SheetNouveauMessage({
    required this.pseudo,
    required this.clePerso,
    required this.expediteur,
    required this.onEnvoye,
  });

  @override
  State<_SheetNouveauMessage> createState() => _SheetNouveauMessageState();
}

class _SheetNouveauMessageState extends State<_SheetNouveauMessage> {
  final _destCtrl  = TextEditingController();
  final _sujetCtrl = TextEditingController();
  final _corpsCtrl = TextEditingController();
  bool _loading    = false;
  String? _erreur;

  // Envoi à tout le monde
  bool _tousMembres = false;

  @override
  void dispose() {
    _destCtrl.dispose(); _sujetCtrl.dispose(); _corpsCtrl.dispose();
    super.dispose();
  }

  Future<void> _envoyer() async {
    final dest  = _tousMembres ? 'tous' : _destCtrl.text.trim();
    final sujet = _sujetCtrl.text.trim();
    final corps = _corpsCtrl.text.trim();
    if (dest.isEmpty || corps.isEmpty) {
      setState(() => _erreur = 'Destinataire et message requis');
      return;
    }
    setState(() { _loading = true; _erreur = null; });
    final res = await SupabaseService.adminEnvoyerMessage(
      pseudo:       widget.pseudo,
      clePerso:     widget.clePerso,
      destinataire: dest,
      sujet:        sujet.isEmpty ? '(sans sujet)' : sujet,
      corps:        corps,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    if (res['ok'] == true || res['id'] != null) {
      Navigator.pop(context);
      widget.onEnvoye();
    } else {
      setState(() => _erreur = res['erreur'] as String? ?? 'Erreur d\'envoi');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.fondPapier,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(24, 12, 24, bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(width: 40, height: 4,
                decoration: BoxDecoration(color: AppColors.lignes, borderRadius: BorderRadius.circular(2))),
          ),
          const SizedBox(height: 20),
          const Text('Nouveau message',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.encre)),
          const SizedBox(height: 16),

          // Tous les membres ?
          GestureDetector(
            onTap: () => setState(() { _tousMembres = !_tousMembres; }),
            child: Row(
              children: [
                Container(
                  width: 20, height: 20,
                  decoration: BoxDecoration(
                    color: _tousMembres ? AppColors.encre : Colors.transparent,
                    border: Border.all(color: AppColors.encre),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: _tousMembres
                      ? const Icon(Icons.check_rounded, color: Colors.white, size: 14)
                      : null,
                ),
                const SizedBox(width: 8),
                const Text('Envoyer à toute l\'équipe',
                    style: TextStyle(fontSize: 13, color: AppColors.encre, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          if (!_tousMembres) ...[
            const SizedBox(height: 12),
            const Text('Pseudo du destinataire',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.texteDoux)),
            const SizedBox(height: 4),
            TextField(controller: _destCtrl, decoration: const InputDecoration(hintText: 'Ex: jean_konan')),
          ],
          const SizedBox(height: 12),
          const Text('Sujet (optionnel)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.texteDoux)),
          const SizedBox(height: 4),
          TextField(controller: _sujetCtrl, decoration: const InputDecoration(hintText: 'Objet du message')),
          const SizedBox(height: 12),
          const Text('Message',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.texteDoux)),
          const SizedBox(height: 4),
          TextField(
            controller: _corpsCtrl,
            maxLines: 4,
            decoration: const InputDecoration(hintText: 'Votre message…', alignLabelWithHint: true),
          ),
          if (_erreur != null) ...[
            const SizedBox(height: 8),
            Text(_erreur!, style: const TextStyle(fontSize: 12, color: AppColors.alerte)),
          ],
          const SizedBox(height: 20),
          BtnPrincipal(label: 'Envoyer', onTap: _envoyer, loading: _loading),
        ],
      ),
    );
  }
}
