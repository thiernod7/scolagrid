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
import 'theme.dart';

/// Le cadre de l'app : menu à gauche sur PC, icônes sur tablette, onglets en
/// bas sur téléphone. Le menu ne montre que ce que la personne peut faire.
/// Chaque rubrique garde sa propre pile d'écrans : le menu reste visible.

enum _Rubrique { accueil, eleves, caisse, personnel, postes, etablissement }

class _Entree {
  const _Entree(this.rubrique, this.libelle, this.icone, this.iconeActive, this.groupe);

  final _Rubrique rubrique;
  final String libelle;
  final IconData icone;
  final IconData iconeActive;
  final String? groupe;
}

const _toutes = [
  _Entree(_Rubrique.accueil, 'Accueil', Icons.home_outlined, Icons.home, null),
  _Entree(_Rubrique.eleves, 'Élèves', Icons.school_outlined, Icons.school, 'ÉLÈVES'),
  _Entree(_Rubrique.caisse, 'Caisse', Icons.point_of_sale_outlined, Icons.point_of_sale, 'ARGENT'),
  _Entree(_Rubrique.personnel, 'Personnel', Icons.groups_outlined, Icons.groups, 'ÉCOLE'),
  _Entree(_Rubrique.postes, 'Postes', Icons.devices_other_outlined, Icons.devices_other, 'ÉCOLE'),
  _Entree(_Rubrique.etablissement, 'Établissement', Icons.tune_outlined, Icons.tune, 'ÉCOLE'),
];

String _dateDuJour() {
  const jours = ['Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche'];
  const mois = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
  final d = DateTime.now();
  return '${jours[d.weekday - 1]} ${d.day} ${mois[d.month - 1]}';
}

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
  bool _peutEncaisser = false;
  bool _peutInscrire = false;

  _Rubrique _rubrique = _Rubrique.accueil;
  final _cles = {for (final r in _Rubrique.values) r: GlobalKey<NavigatorState>()};
  String? _recherche;
  final _champRecherche = TextEditingController();

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
        _majDroits();
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
      // Les droits changent quand une fonction ou une exception est modifiée.
      ..add(db.watch('SELECT (SELECT max(updated_at) FROM affectations) AS a, (SELECT max(updated_at) FROM droits_personnel) AS d')
          .listen((_) => _majDroits()))
      ..add(db.statusStream.listen((s) {
        setState(() => _statut = s);
        _majEnAttente();
        if (s.connected && s.lastSyncedAt != null) _signalerSynchro();
      }));
  }

  Future<void> _majDroits() async {
    final org = _organisation;
    if (org == null) return;
    final encaisser = await jAiLeDroitQuelquePart(org['id'] as String, 'encaisser');
    final inscrire = await jAiLeDroitQuelquePart(org['id'] as String, 'gerer_inscriptions');
    if (mounted) {
      setState(() {
        _peutEncaisser = encaisser;
        _peutInscrire = inscrire;
      });
    }
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
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
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
    _champRecherche.dispose();
    super.dispose();
  }

  Espace _espace(Map<String, Object?> org) => Espace(
        orgId: org['id'] as String,
        ville: org['ville'] as String? ?? '',
        role: _rattachement?['role'] as String? ?? '',
        siteId: _rattachement?['site_id'] as String?,
      );

  List<_Entree> _entrees(Espace e) => [
        for (final x in _toutes)
          if (switch (x.rubrique) {
            _Rubrique.caisse => _peutEncaisser,
            _Rubrique.personnel || _Rubrique.postes || _Rubrique.etablissement => e.gestionnaire,
            _ => true,
          })
            x,
      ];

  void _aller(_Rubrique r) {
    if (r == _rubrique) {
      // Toucher la rubrique déjà ouverte revient à son premier écran.
      _cles[r]!.currentState?.popUntil((route) => route.isFirst);
    }
    setState(() => _rubrique = r);
  }

  /// Ouvre un écran dans une rubrique (ex. « Inscrire un élève » depuis l'accueil).
  void _ouvrirDans(_Rubrique r, Widget ecran) {
    setState(() => _rubrique = r);
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _cles[r]!.currentState?.push(MaterialPageRoute(builder: (_) => ecran)));
  }

  void _rechercher(String q) {
    setState(() {
      _recherche = q.trim();
      _cles[_Rubrique.eleves] = GlobalKey<NavigatorState>();
      _rubrique = _Rubrique.eleves;
    });
  }

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
    Navigator.of(context, rootNavigator: true)
        .pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const BienvenueScreen()), (_) => false);
  }

  Widget _ecran(_Rubrique r, Espace e, Map<String, Object?> org) => switch (r) {
        _Rubrique.accueil => _TableauDeBord(
            espace: e,
            organisation: org,
            nom: _nom,
            fonction: fonctions[_rattachement?['role']] ?? '',
            cePoste: _cePoste,
            sites: _sites,
            peutEncaisser: _peutEncaisser,
            peutInscrire: _peutInscrire,
            synchro: PuceSynchro(statut: _statut, enAttente: _enAttente),
            aller: _aller,
            inscrire: () => _ouvrirDans(_Rubrique.eleves, InscrireScreen(espace: e)),
            encaisser: () => _ouvrirDans(_Rubrique.caisse, EncaisserScreen(espace: e)),
            activerPoste: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ActiverPosteScreen(orgId: org['id'] as String))),
            ajouterSite: _ajouterSite,
          ),
        _Rubrique.eleves => ElevesScreen(espace: e, rechercheInitiale: _recherche),
        _Rubrique.caisse => CaisseScreen(espace: e),
        _Rubrique.personnel => PersonnelScreen(espace: e),
        _Rubrique.postes => PostesScreen(espace: e),
        _Rubrique.etablissement => ConfigurationScreen(espace: e),
      };

  @override
  Widget build(BuildContext context) {
    final org = _organisation;
    if (org == null) {
      return const Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Synchronisation de votre espace…'),
          ]),
        ),
      );
    }
    final e = _espace(org);
    final entrees = _entrees(e);
    if (!entrees.any((x) => x.rubrique == _rubrique)) _rubrique = _Rubrique.accueil;

    // Une pile d'écrans par rubrique, gardée en mémoire quand on change de rubrique.
    final contenu = _Cadre(
      construire: (r) => _ecran(r, e, org),
      child: NavigatorPopHandler(
      onPopWithResult: (_) => _cles[_rubrique]!.currentState?.maybePop(),
      child: IndexedStack(
        index: entrees.indexWhere((x) => x.rubrique == _rubrique),
        children: [
          for (final x in entrees)
            Navigator(
              key: _cles[x.rubrique],
              // Le premier écran se reconstruit avec les données du cadre (_Cadre).
              onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => _PremierEcran(x.rubrique)),
            ),
        ],
      ),
      ),
    );

    return LayoutBuilder(builder: (context, c) {
      final largeur = c.maxWidth;
      if (largeur >= 1000) {
        return Scaffold(
          body: Row(children: [
            _Barre(
              organisation: org,
              entrees: entrees,
              rubrique: _rubrique,
              aller: _aller,
              cePoste: _cePoste,
              siteNom: _sites.isEmpty ? null : _sites.firstWhere((s) => s['id'] == e.siteId, orElse: () => _sites.first)['nom'] as String?,
            ),
            Expanded(
              child: Column(children: [
                _EnTete(
                  recherche: _champRecherche,
                  rechercher: _rechercher,
                  synchro: PuceSynchro(statut: _statut, enAttente: _enAttente),
                  nom: _nom ?? '',
                  fonction: fonctions[_rattachement?['role']] ?? '',
                  seDeconnecter: _seDeconnecter,
                ),
                Expanded(child: contenu),
              ]),
            ),
          ]),
        );
      }
      if (largeur >= 640) {
        return Scaffold(
          body: Row(children: [
            NavigationRail(
              selectedIndex: entrees.indexWhere((x) => x.rubrique == _rubrique),
              onDestinationSelected: (i) => _aller(entrees[i].rubrique),
              labelType: NavigationRailLabelType.all,
              leading: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: _Logo(taille: 40)),
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: IconButton(tooltip: 'Se déconnecter', onPressed: _seDeconnecter, icon: const Icon(Icons.logout)),
                  ),
                ),
              ),
              destinations: [
                for (final x in entrees)
                  NavigationRailDestination(icon: Icon(x.icone), selectedIcon: Icon(x.iconeActive), label: Text(x.libelle)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: contenu),
          ]),
        );
      }
      // Téléphone : 3 rubriques principales en bas, le reste dans « Plus ».
      final principales = entrees.where((x) => x.rubrique.index <= _Rubrique.caisse.index).toList();
      final autres = entrees.where((x) => x.rubrique.index > _Rubrique.caisse.index).toList();
      final iPrincipale = principales.indexWhere((x) => x.rubrique == _rubrique);
      return Scaffold(
        body: contenu,
        bottomNavigationBar: NavigationBar(
          selectedIndex: iPrincipale >= 0 ? iPrincipale : principales.length,
          onDestinationSelected: (i) {
            if (i < principales.length) return _aller(principales[i].rubrique);
            showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              builder: (context) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final x in autres)
                    ListTile(
                      leading: Icon(x.icone),
                      title: Text(x.libelle),
                      onTap: () {
                        Navigator.pop(context);
                        _aller(x.rubrique);
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: const Text('Se déconnecter'),
                    onTap: () {
                      Navigator.pop(context);
                      _seDeconnecter();
                    },
                  ),
                ]),
              ),
            );
          },
          destinations: [
            for (final x in principales)
              NavigationDestination(icon: Icon(x.icone), selectedIcon: Icon(x.iconeActive), label: x.libelle),
            const NavigationDestination(icon: Icon(Icons.menu), label: 'Plus'),
          ],
        ),
      );
    });
  }
}

// Éléments du cadre -------------------------------------------------------------

/// Transmet aux premiers écrans des rubriques les données à jour du cadre.
class _Cadre extends InheritedWidget {
  const _Cadre({required this.construire, required super.child});

  final Widget Function(_Rubrique) construire;

  @override
  bool updateShouldNotify(_Cadre ancien) => true;
}

class _PremierEcran extends StatelessWidget {
  const _PremierEcran(this.rubrique);

  final _Rubrique rubrique;

  @override
  Widget build(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Cadre>()!.construire(rubrique);
}

class _Logo extends StatelessWidget {
  const _Logo({this.taille = 40});

  final double taille;

  @override
  Widget build(BuildContext context) => Container(
        width: taille,
        height: taille,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Couleurs.indigo, borderRadius: BorderRadius.circular(taille * 0.3)),
        child: Text('S', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: taille * 0.45)),
      );
}

/// État de la synchronisation, toujours visible : à jour, envoi, hors ligne.
class PuceSynchro extends StatelessWidget {
  const PuceSynchro({super.key, required this.statut, required this.enAttente});

  final SyncStatus statut;
  final int enAttente;

  @override
  Widget build(BuildContext context) {
    if (!statut.connected) {
      return Tooltip(
        message: 'Le poste travaille sans internet. Tout sera envoyé au retour de la connexion.',
        child: Etat(enAttente > 0 ? 'Hors ligne · $enAttente en attente' : 'Hors ligne',
            ton: Ton.attente, icone: Icons.cloud_off_outlined),
      );
    }
    if (enAttente > 0) return Etat('Envoi en cours · $enAttente', ton: Ton.info, icone: Icons.cloud_upload_outlined);
    return const Etat('À jour', ton: Ton.regle, icone: Icons.check);
  }
}

/// Menu de gauche (PC) : rubriques groupées, et le poste en bas.
class _Barre extends StatelessWidget {
  const _Barre({
    required this.organisation,
    required this.entrees,
    required this.rubrique,
    required this.aller,
    required this.cePoste,
    required this.siteNom,
  });

  final Map<String, Object?> organisation;
  final List<_Entree> entrees;
  final _Rubrique rubrique;
  final void Function(_Rubrique) aller;
  final Map<String, Object?>? cePoste;
  final String? siteNom;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    String? groupe;
    final elements = <Widget>[];
    for (final x in entrees) {
      if (x.groupe != null && x.groupe != groupe) {
        elements.add(Padding(
          padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
          child: Text(x.groupe!,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: schema.onSurfaceVariant)),
        ));
      }
      groupe = x.groupe;
      final actif = x.rubrique == rubrique;
      elements.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: actif ? schema.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => aller(x.rubrique),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(children: [
                Icon(actif ? x.iconeActive : x.icone, size: 21, color: actif ? schema.onPrimaryContainer : schema.onSurfaceVariant),
                const SizedBox(width: 12),
                Text(x.libelle,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: actif ? FontWeight.w600 : FontWeight.w500,
                        color: actif ? schema.onPrimaryContainer : schema.onSurface)),
              ]),
            ),
          ),
        ),
      ));
    }
    return Container(
      width: 248,
      decoration: BoxDecoration(color: schema.surface, border: Border(right: BorderSide(color: schema.outlineVariant))),
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
          child: Row(children: [
            const _Logo(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${organisation['nom']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                Text(siteNom ?? '${organisation['ville'] ?? ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: schema.onSurfaceVariant)),
              ]),
            ),
          ]),
        ),
        Expanded(child: ListView(children: elements)),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: schema.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: schema.onSurface, borderRadius: BorderRadius.circular(8)),
              child: Text('${cePoste?['code'] ?? '–'}',
                  style: TextStyle(color: schema.surface, fontWeight: FontWeight.w700, fontSize: 13)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(cePoste == null ? 'Poste non activé' : 'Poste ${cePoste!['code']} · ${cePoste!['nom']}',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Barre du haut (PC) : recherche, synchro, personne connectée.
class _EnTete extends StatelessWidget {
  const _EnTete({
    required this.recherche,
    required this.rechercher,
    required this.synchro,
    required this.nom,
    required this.fonction,
    required this.seDeconnecter,
  });

  final TextEditingController recherche;
  final void Function(String) rechercher;
  final Widget synchro;
  final String nom;
  final String fonction;
  final VoidCallback seDeconnecter;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      decoration: BoxDecoration(color: schema.surface, border: Border(bottom: BorderSide(color: schema.outlineVariant))),
      child: Row(children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SizedBox(
            height: 44,
            child: TextField(
              controller: recherche,
              textInputAction: TextInputAction.search,
              onSubmitted: rechercher,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Rechercher un élève, un matricule, un parent…',
                contentPadding: EdgeInsets.zero,
                fillColor: schema.surfaceContainerLow,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: schema.outlineVariant)),
              ),
            ),
          ),
        ),
        const Spacer(),
        synchro,
        const SizedBox(width: 18),
        PopupMenuButton<String>(
          tooltip: 'Mon compte',
          onSelected: (v) {
            if (v == 'sortir') seDeconnecter();
          },
          itemBuilder: (_) => const [PopupMenuItem(value: 'sortir', child: Text('Se déconnecter'))],
          child: Row(children: [
            Initiales(nom.isEmpty ? '?' : nom, taille: 36),
            const SizedBox(width: 10),
            Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(nom, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              Text(fonction, style: TextStyle(fontSize: 12, color: schema.onSurfaceVariant)),
            ]),
            const Icon(Icons.expand_more, size: 20),
          ]),
        ),
      ]),
    );
  }
}

// Accueil -----------------------------------------------------------------------

class _TableauDeBord extends StatelessWidget {
  const _TableauDeBord({
    required this.espace,
    required this.organisation,
    required this.nom,
    required this.fonction,
    required this.cePoste,
    required this.sites,
    required this.peutEncaisser,
    required this.peutInscrire,
    required this.synchro,
    required this.aller,
    required this.inscrire,
    required this.encaisser,
    required this.activerPoste,
    required this.ajouterSite,
  });

  final Espace espace;
  final Map<String, Object?> organisation;
  final String? nom;
  final String fonction;
  final Map<String, Object?>? cePoste;
  final List<Map<String, Object?>> sites;
  final bool peutEncaisser;
  final bool peutInscrire;
  final Widget synchro;
  final void Function(_Rubrique) aller;
  final VoidCallback inscrire;
  final VoidCallback encaisser;
  final VoidCallback activerPoste;
  final VoidCallback ajouterSite;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final schema = Theme.of(context).colorScheme;
    final prenom = (nom ?? '').trim().split(' ').first;
    final o = espace.orgId;
    final aujourdhui = DateTime.now().toIso8601String().substring(0, 10);
    return Scaffold(
      body: Requete(
        '''SELECT
             (SELECT coalesce(sum(total_gnf), 0) FROM encaissements WHERE organisation_id = ? AND statut = 'valide' AND date_effective = ?) AS encaisse,
             (SELECT count(*) FROM encaissements WHERE organisation_id = ? AND statut = 'valide' AND date_effective = ?) AS recus,
             (SELECT count(*) FROM inscriptions i JOIN annees_scolaires a ON a.id = i.annee_id AND a.en_cours = 1
                WHERE i.organisation_id = ? AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')) AS inscrits,
             (SELECT count(*) FROM inscriptions i JOIN annees_scolaires a ON a.id = i.annee_id AND a.en_cours = 1
                WHERE i.organisation_id = ? AND i.statut = 'en_attente') AS attente,
             (SELECT count(*) FROM eleves e WHERE e.organisation_id = ? AND (e.date_naissance IS NULL OR e.sexe IS NULL)) AS incompletes,
             (SELECT code FROM organisations WHERE id = ?) AS sigle,
             (SELECT count(*) FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1) AS annee,
             (SELECT count(*) FROM remboursements WHERE organisation_id = ? AND statut IN ('demande', 'autorise')) AS remb''',
        parametres: [o, aujourdhui, o, aujourdhui, o, o, o, o, o, o],
        builder: (context, l) {
          final r = l.first;
          final attente = r['attente'] as int? ?? 0;
          final incompletes = r['incompletes'] as int? ?? 0;
          final aFaire = <Widget>[
            if (organisation['statut'] == 'en_attente')
              _AFaire(const Etat('Espace', ton: Ton.info),
                  "En attente d'activation par Scolagrid : vous pouvez déjà tout configurer.", null),
            if (cePoste == null)
              _AFaire(const Etat('Poste', ton: Ton.attente), 'Activer ce poste : sa lettre et son code PIN', activerPoste),
            if (espace.fondateur && r['sigle'] == null)
              _AFaire(const Etat('Réglage', ton: Ton.attente), "Choisir le sigle de l'école (matricules et reçus)",
                  () => aller(_Rubrique.etablissement)),
            if ((r['annee'] as int? ?? 0) == 0 && espace.gestionnaire)
              _AFaire(const Etat('Réglage', ton: Ton.attente), "Créer l'année scolaire en cours",
                  () => aller(_Rubrique.etablissement)),
            if (attente > 0)
              _AFaire(Etat('$attente', ton: Ton.attente), "inscription(s) en attente des frais d'inscription",
                  () => aller(_Rubrique.eleves)),
            if (peutEncaisser && (r['remb'] as int? ?? 0) > 0)
              _AFaire(Etat('${r['remb']}', ton: Ton.attente), 'remboursement(s) à autoriser ou à verser (Caisse)',
                  () => aller(_Rubrique.caisse)),
            if (incompletes > 0)
              _AFaire(Etat('$incompletes', ton: Ton.info), 'fiche(s) élève à compléter (date de naissance, sexe)',
                  () => aller(_Rubrique.eleves)),
          ];
          return ListView(padding: const EdgeInsets.fromLTRB(24, 24, 24, 40), children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.end, children: [
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(prenom.isEmpty ? 'Bonjour' : 'Bonjour $prenom', style: t.headlineSmall),
                      const SizedBox(height: 4),
                      Text('${_dateDuJour()} · $fonction', style: t.bodyMedium?.copyWith(color: schema.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      synchro,
                    ]),
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      if (peutEncaisser)
                        OutlinedButton.icon(onPressed: encaisser, icon: const Icon(Icons.point_of_sale), label: const Text('Encaisser')),
                      if (peutInscrire)
                        FilledButton.icon(
                            onPressed: inscrire, icon: const Icon(Icons.person_add_alt_1), label: const Text('Inscrire un élève')),
                    ]),
                  ]),
                  const SizedBox(height: 20),
                  LayoutBuilder(builder: (context, c) {
                    final colonnes = c.maxWidth >= 900 ? 3 : (c.maxWidth >= 560 ? 2 : 1);
                    final cartes = <Widget>[
                      if (peutEncaisser)
                        ChiffreCle(
                            libelle: "Encaissé aujourd'hui", valeur: gnf(r['encaisse']), detail: '${r['recus']} reçu(s) valide(s)'),
                      ChiffreCle(
                        libelle: 'Élèves inscrits cette année',
                        valeur: '${r['inscrits']}',
                        etat: attente > 0
                            ? Etat('$attente en attente de paiement', ton: Ton.attente)
                            : const Etat('Tous à jour des frais d\'inscription', ton: Ton.regle),
                      ),
                      ChiffreCle(
                        libelle: 'Ce poste',
                        valeur: cePoste == null ? 'Non activé' : 'Poste ${cePoste!['code']}',
                        detail: cePoste == null ? 'Activez-le pour inscrire et encaisser' : '${cePoste!['nom']}',
                      ),
                    ];
                    return Wrap(spacing: 14, runSpacing: 4, children: [
                      for (final x in cartes) SizedBox(width: (c.maxWidth - 14 * (colonnes - 1)) / colonnes, child: x),
                    ]);
                  }),
                  if (aFaire.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text('À faire', style: t.titleMedium),
                    const SizedBox(height: 6),
                    Card(child: Column(children: aFaire)),
                  ],
                  if (espace.fondateur) ...[
                    const SizedBox(height: 20),
                    Row(children: [
                      Expanded(child: Text('Sites (${sites.length})', style: t.titleMedium)),
                      TextButton.icon(onPressed: ajouterSite, icon: const Icon(Icons.add), label: const Text('Ajouter un site')),
                    ]),
                    Card(
                      child: Column(children: [
                        for (final s in sites)
                          ListTile(
                            leading: const Icon(Icons.location_city_outlined),
                            title: Text(s['nom'] as String? ?? ''),
                            subtitle: Text([s['ville'], if (s['code'] != null) 'code ${s['code']}'].whereType<String>().join(' · ')),
                          ),
                      ]),
                    ),
                  ],
                  if (kIsWeb) ...[const SizedBox(height: 12), const _InstallerPostes()],
                ]),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class _AFaire extends StatelessWidget {
  const _AFaire(this.etat, this.texte, this.action);

  final Widget etat;
  final String texte;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: etat,
        title: Text(texte),
        trailing: action == null ? null : const Icon(Icons.chevron_right),
        onTap: action,
      );
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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
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
