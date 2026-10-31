import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:powersync/powersync.dart' show SyncStatus;
import 'package:url_launcher/url_launcher.dart';

import 'base.dart';
import 'cloud.dart';
import 'configuration.dart';
import 'fonctions.dart';
import 'onboarding.dart';


/// Accueil : l'espace de l'école tel qu'il est dans la base locale.
/// Tout s'affiche et se modifie hors ligne ; la synchro suit quand elle peut.
class AccueilScreen extends StatefulWidget {
  const AccueilScreen({super.key});

  @override
  State<AccueilScreen> createState() => _AccueilScreenState();
}

class _AccueilScreenState extends State<AccueilScreen> {
  final _abonnements = <StreamSubscription<Object?>>[];
  Map<String, Object?>? _organisation;
  Map<String, Object?>? _rattachement;
  List<Map<String, Object?>> _sites = [];
  String? _nom;
  SyncStatus _statut = db.currentStatus;
  int _enAttente = 0;
  Map<String, Object?>? _cePoste;
  DateTime? _dernierSignal;

  @override
  void initState() {
    super.initState();
    final moi = monId;
    _abonnements
      ..add(db.watch('SELECT * FROM rattachements WHERE user_id = ? AND actif = 1 '
          // La fonction qui donne le plus de droits de gestion d'abord.
          "ORDER BY CASE role WHEN 'fondateur' THEN 0 WHEN 'directeur' THEN 1 ELSE 2 END, site_id IS NOT NULL "
          'LIMIT 1', parameters: [moi]).listen((r) {
        setState(() => _rattachement = r.isEmpty ? null : r.first);
      }))
      ..add(db.watch('SELECT o.* FROM organisations o JOIN rattachements r ON r.organisation_id = o.id '
          'WHERE r.user_id = ? AND r.actif = 1 ORDER BY o.created_at LIMIT 1', parameters: [moi]).listen((r) {
        setState(() => _organisation = r.isEmpty ? null : r.first);
      }))
      ..add(db.watch('SELECT s.* FROM sites s JOIN rattachements r ON r.organisation_id = s.organisation_id '
          'WHERE r.user_id = ? AND r.actif = 1 GROUP BY s.id ORDER BY s.created_at', parameters: [moi]).listen((r) {
        setState(() => _sites = r.toList());
      }))
      ..add(db.watch('SELECT nom_complet FROM personnes WHERE id = ?', parameters: [moi]).listen((r) {
        setState(() => _nom = r.isEmpty ? null : r.first['nom_complet'] as String?);
      }))
      ..add(db.watch('SELECT c.*, p.statut FROM ce_poste c LEFT JOIN postes p ON p.id = c.poste_id').listen((r) {
        setState(() => _cePoste = r.isEmpty ? null : r.first);
        if (r.isNotEmpty && r.first['statut'] == 'bloque') _posteBloque();
      }))
      ..add(db.statusStream.listen((s) {
        setState(() => _statut = s);
        _majEnAttente();
        if (s.connected && s.lastSyncedAt != null) _signalerSynchro();
      }));
  }

  /// Le poste indique au serveur qu'il est vivant (au plus une fois par heure).
  Future<void> _signalerSynchro() async {
    final poste = _cePoste;
    if (poste == null) return;
    if (_dernierSignal != null && DateTime.now().difference(_dernierSignal!) < const Duration(hours: 1)) return;
    _dernierSignal = DateTime.now();
    final maintenant = DateTime.now().toUtc().toIso8601String();
    await db.execute('UPDATE postes SET derniere_synchro = ?, version_app = ?, updated_at = ? WHERE id = ?',
        [maintenant, versionApp, maintenant, poste['poste_id']]);
  }

  /// L'école a bloqué ce poste (perdu ou volé) : on efface tout.
  bool _effacement = false;
  Future<void> _posteBloque() async {
    if (_effacement) return;
    _effacement = true;
    await deconnecter(db);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) => const BienvenueScreen(
                avertissement: "Ce poste a été bloqué par l'école. Ses données ont été effacées.")),
        (_) => false);
  }

  Future<void> _majEnAttente() async {
    final stats = await db.getUploadQueueStats();
    if (mounted) setState(() => _enAttente = stats.count);
  }

  @override
  void dispose() {
    for (final a in _abonnements) {
      a.cancel();
    }
    super.dispose();
  }

  bool get _estFondateur => _rattachement?['role'] == 'fondateur';

  Espace _espace(Map<String, Object?> org) => Espace(
        orgId: org['id'] as String,
        ville: org['ville'] as String? ?? '',
        role: _rattachement?['role'] as String? ?? '',
        siteId: _rattachement?['site_id'] as String?,
      );

  Future<void> _ajouterSite() async {
    final nom = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nouveau site'),
        content: TextField(
          controller: nom,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nom du site', hintText: 'Site de Ratoma'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Ajouter')),
        ],
      ),
    );
    if (ok != true || nom.text.trim().length < 2) return;
    final maintenant = DateTime.now().toUtc().toIso8601String();
    // Écrit en local : visible tout de suite, envoyé au serveur dès que possible.
    await db.execute(
      'INSERT INTO sites (id, organisation_id, nom, ville, created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?)',
      [_organisation!['id'], nom.text.trim(), _organisation!['ville'], maintenant, maintenant],
    );
    _majEnAttente();
  }

  Future<void> _seDeconnecter() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Se déconnecter ?'),
        content: Text(_enAttente > 0
            ? 'Attention : $_enAttente changement(s) pas encore envoyé(s) seront perdus.'
            : 'Les données de ce poste seront effacées. Elles restent sur le serveur.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Se déconnecter')),
        ],
      ),
    );
    if (ok != true) return;
    await deconnecter(db);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const BienvenueScreen()), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    final org = _organisation;
    final synchro = _statut.connected
        ? (_enAttente == 0 ? ('À jour', Icons.cloud_done_outlined, Colors.teal)
            : ('Envoi en cours', Icons.cloud_upload_outlined, Colors.teal))
        : ('Hors ligne', Icons.cloud_off_outlined, Colors.orange);

    return Scaffold(
      appBar: AppBar(
        title: Text(org?['nom'] as String? ?? 'Scolagrid'),
        actions: [
          IconButton(tooltip: 'Se déconnecter', onPressed: _seDeconnecter, icon: const Icon(Icons.logout)),
        ],
      ),
      floatingActionButton: org != null && _estFondateur
          ? FloatingActionButton.extended(
              onPressed: _ajouterSite, icon: const Icon(Icons.add), label: const Text('Ajouter un site'))
          : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: org == null
              ? const Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Synchronisation de votre espace…'),
                ])
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    if (_nom != null) Text('Bonjour $_nom', style: texte.headlineSmall),
                    const SizedBox(height: 4),
                    Text([
                      fonctions[_rattachement?['role']] ?? '',
                      org['ville'],
                      if (_cePoste != null) 'poste ${_cePoste!['code']}',
                    ].join(' · '), style: texte.bodyMedium),
                    if (org['statut'] == 'en_attente')
                      Card(
                        margin: const EdgeInsets.only(top: 16),
                        color: Theme.of(context).colorScheme.tertiaryContainer,
                        child: const ListTile(
                          leading: Icon(Icons.hourglass_top),
                          title: Text("Espace en attente d'activation"),
                          subtitle: Text("Vous pouvez déjà tout configurer. L'équipe Scolagrid "
                              'activera votre espace après vérification.'),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Card(
                      child: ListTile(
                        leading: Icon(synchro.$2, color: synchro.$3),
                        title: Text('Synchronisation : ${synchro.$1}'),
                        subtitle: Text(_enAttente == 0
                            ? 'Toutes les données de ce poste sont sur le serveur.'
                            : "$_enAttente changement(s) en attente d'envoi."),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.tune),
                        title: const Text("Configurer l'établissement"),
                        subtitle: const Text('Année, niveaux, matières, classes, frais'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => ConfigurationScreen(espace: _espace(org)),
                        )),
                      ),
                    ),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.school_outlined),
                        title: const Text('Élèves et inscriptions'),
                        subtitle: const Text('Inscrire, rechercher, listes de classe'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => ElevesScreen(espace: _espace(org)))),
                      ),
                    ),
                    FutureBuilder(
                      future: jAiLeDroitQuelquePart(org['id'] as String, 'encaisser'),
                      builder: (context, s) => s.data != true
                          ? const SizedBox.shrink()
                          : Card(
                              child: ListTile(
                                leading: const Icon(Icons.point_of_sale),
                                title: const Text('Caisse'),
                                subtitle: const Text('Encaisser, reçus, journal du jour'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => CaisseScreen(espace: _espace(org)))),
                              ),
                            ),
                    ),
                    if (_cePoste == null)
                      Card(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        child: ListTile(
                          leading: const Icon(Icons.devices_outlined),
                          title: const Text('Activer ce poste'),
                          subtitle: const Text('Une fois par appareil, avec internet : lettre du poste et code PIN'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => ActiverPosteScreen(orgId: org['id'] as String))),
                        ),
                      ),
                    if (_espace(org).gestionnaire)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.devices_other_outlined),
                          title: const Text("Postes de l'école"),
                          subtitle: const Text('Appareils activés, dernière synchro, blocage'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(builder: (_) => PostesScreen(espace: _espace(org)))),
                        ),
                      ),
                    if (_espace(org).gestionnaire)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.groups_outlined),
                          title: const Text('Personnel et accès'),
                          subtitle: const Text("Fiches, fonctions, droits, invitations à l'app"),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(builder: (_) => PersonnelScreen(espace: _espace(org)))),
                        ),
                      ),
                    if (kIsWeb) const _InstallerPostes(),
                    const SizedBox(height: 16),
                    Text('Sites (${_sites.length})', style: texte.titleMedium),
                    const SizedBox(height: 8),
                    for (final s in _sites)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.location_city_outlined),
                          title: Text(s['nom'] as String? ?? ''),
                          subtitle: Text(s['ville'] as String? ?? ''),
                        ),
                      ),
                    const SizedBox(height: 80),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Sur le web : les postes de l'école travaillent avec l'app installée,
/// téléchargeable depuis ce même site (étape 4 de l'onboarding).
class _InstallerPostes extends StatelessWidget {
  const _InstallerPostes();

  @override
  Widget build(BuildContext context) {
    Future<void> ouvrir(String fichier) => launchUrl(Uri.base.resolve('/telechargements/$fichier'));
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.download_outlined),
            title: Text("Installer Scolagrid sur les postes de l'école"),
            subtitle: Text("Les postes de l'école utilisent l'app installée : elle fonctionne même sans internet."),
          ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: () => ouvrir('scolagrid-windows.zip'),
              icon: const Icon(Icons.desktop_windows_outlined),
              label: const Text('Windows'),
            ),
            OutlinedButton.icon(
              onPressed: () => ouvrir('scolagrid-android.apk'),
              icon: const Icon(Icons.android),
              label: const Text('Android'),
            ),
          ]),
        ]),
      ),
    );
  }
}
