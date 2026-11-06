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

enum _Rubrique { accueil, eleves, caisse, depenses, recouvrement, familles, personnel, postes, parametres }

class _Entree {
  const _Entree(this.rubrique, this.libelle, this.icone, this.iconeActive, this.groupe);

  final _Rubrique rubrique;
  final String libelle;
  final IconData icone;
  final IconData iconeActive;
  final String? groupe;
}

/// Postes qui attendent la validation de la direction (pastille sur « Postes » dans le menu).
final _postesAValider = ValueNotifier<int>(0);

/// Dépenses qui attendent : à autoriser, à sortir ou à confirmer (pastille sur « Dépenses »).
final _depensesEnAttente = ValueNotifier<int>(0);

/// « Postes » suivi de sa pastille orange quand des postes attendent.
Widget _libelleMenu(_Entree x, TextStyle? style) {
  final texte = Text(x.libelle, style: style);
  if (x.rubrique != _Rubrique.postes && x.rubrique != _Rubrique.depenses) return texte;
  return ValueListenableBuilder<int>(
    valueListenable: x.rubrique == _Rubrique.postes ? _postesAValider : _depensesEnAttente,
    builder: (context, n, _) => n == 0
        ? texte
        : Row(mainAxisSize: MainAxisSize.min, children: [
            texte,
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(color: Couleurs.attente, borderRadius: BorderRadius.circular(10)),
              child: Text('$n', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white)),
            ),
          ]),
  );
}

/// « ScolaGrid 0.9.0 · essai » : pour savoir d'un coup d'œil quelle application on a.
String get versionAffichee => 'ScolaGrid $versionApp${environnement == 'essai' ? ' · essai' : ''}';
String get _versionCourte => 'v$versionApp${environnement == 'essai' ? '\nessai' : ''}';

const _toutes = [
  _Entree(_Rubrique.accueil, 'Accueil', Icons.home_outlined, Icons.home, null),
  _Entree(_Rubrique.eleves, 'Élèves', Icons.school_outlined, Icons.school, 'ÉLÈVES'),
  _Entree(_Rubrique.familles, 'Familles', Icons.family_restroom_outlined, Icons.family_restroom, 'ÉLÈVES'),
  _Entree(_Rubrique.caisse, 'Caisse', Icons.point_of_sale_outlined, Icons.point_of_sale, 'FINANCES'),
  _Entree(_Rubrique.depenses, 'Dépenses', Icons.outbox_outlined, Icons.outbox, 'FINANCES'),
  _Entree(_Rubrique.recouvrement, 'Recouvrement', Icons.donut_large_outlined, Icons.donut_large, 'FINANCES'),
  _Entree(_Rubrique.personnel, 'Personnel', Icons.groups_outlined, Icons.groups, 'ÉCOLE'),
  _Entree(_Rubrique.postes, 'Postes', Icons.devices_other_outlined, Icons.devices_other, 'ÉCOLE'),
  _Entree(_Rubrique.parametres, 'Paramètres', Icons.settings_outlined, Icons.settings, 'ÉCOLE'),
];

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

  /// Nom du site de la personne connectée (le premier site si elle les a tous).
  String? _nomDuSite(String? id) {
    for (final s in _sites) {
      if (s['id'] == id) return s['nom'] as String?;
    }
    return _sites.isEmpty ? null : _sites.first['nom'] as String?;
  }
  String? _nom;
  SyncStatus _statut = db.currentStatus;
  int _enAttente = 0;
  Map<String, Object?>? _cePoste;
  bool _pinDemande = false;

  /// Un poste sans code PIN s'ouvrirait sans protection : on demande d'en choisir un.
  void _demanderPin() {
    if (_pinDemande) return;
    _pinDemande = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Choisissez un code PIN'),
          content: const Text("Ce poste n'a pas de code PIN (il a été effacé ou jamais choisi). "
              "Choisissez-en un nouveau : il protège l'app quand vous la verrouillez, même sans internet."),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Choisir mon code PIN'))],
        ),
      );
      if (!mounted) return;
      // Annulé : « À faire » le rappelle, et on redemande à la prochaine ouverture.
      await definirPinPoste(context);
    });
  }
  DateTime? _dernierSignal;
  bool _peutEncaisser = false;
  Set<String> _droits = const {};
  bool _peutInscrire = false;

  _Rubrique _rubrique = _Rubrique.accueil;
  final _cles = {for (final r in _Rubrique.values) r: GlobalKey<NavigatorState>()};
  String? _recherche;
  final _champRecherche = TextEditingController();

  Timer? _horloge;

  @override
  void initState() {
    super.initState();
    // La date de l'appareil range l'argent dans sa journée de caisse : on la vérifie
    // au démarrage puis toutes les dix minutes.
    unawaited(verifierHorloge());
    _horloge = Timer.periodic(const Duration(minutes: 10), (_) => verifierHorloge());
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
        // Appareil repris par quelqu'un d'une autre école : son poste ne vaut pas ici.
        if (r.isNotEmpty) unawaited(_posteDUneAutreEcole(r.first['id'] as String));
      }))
      ..add(db.watch('SELECT s.* FROM sites s JOIN rattachements r ON r.organisation_id = s.organisation_id '
          'WHERE r.user_id = ? AND r.actif = 1 GROUP BY s.id ORDER BY s.created_at', parameters: [moi]).listen((r) {
        setState(() => _sites = [for (final x in r) Map<String, Object?>.from(x)]);
      }))
      ..add(db.watch('SELECT nom_complet FROM personnes WHERE id = ?', parameters: [moi]).listen((r) {
        setState(() => _nom = r.isEmpty ? null : r.first['nom_complet'] as String?);
      }))
      ..add(db.watch('SELECT c.*, p.statut FROM ce_poste c LEFT JOIN postes p ON p.id = c.poste_id').listen((r) {
        setState(() => _cePoste = r.isEmpty ? null : r.first);
        if (r.isNotEmpty && r.first['statut'] == 'bloque') _posteBloque();
        // Après « Code PIN oublié » (ou un PIN jamais choisi) : on en demande un tout de suite.
        if (r.isNotEmpty && r.first['pin_empreinte'] == null && r.first['statut'] != 'bloque') _demanderPin();
      }))
      ..add(db.watch("SELECT count(*) AS n FROM postes WHERE statut = 'a_valider'").listen((r) {
        _postesAValider.value = r.first['n'] as int? ?? 0;
      }))
      ..add(db.watch("SELECT count(*) AS n FROM depenses WHERE statut IN ('demande', 'autorisee') OR confirmation = 'attendue'")
          .listen((r) => _depensesEnAttente.value = r.first['n'] as int? ?? 0))
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
    final mes = <String>{
      for (final d in droits.keys)
        if (await jAiLeDroitQuelquePart(org['id'] as String, d)) d,
    };
    if (mounted) {
      setState(() {
        _droits = mes;
        _peutEncaisser = mes.contains('encaisser');
        _peutInscrire = mes.contains('gerer_inscriptions');
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
    await deconnecter(db, garderPoste: false);
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
    _horloge?.cancel();
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
        droits: _droits,
      );

  List<_Entree> _entrees(Espace e) => [
        for (final x in _toutes)
          if (switch (x.rubrique) {
            // Un lecteur voit la caisse ou le personnel si on le lui a accordé (sans pouvoir agir).
            _Rubrique.caisse => _peutEncaisser || _droits.contains('voir_caisse'),
            // Les familles : qui voit les parents (secrétariat, caisse, direction, lecteur autorisé).
            _Rubrique.familles => _droits.contains('voir_familles'),
            _Rubrique.depenses => _peutEncaisser || _droits.contains('voir_caisse') || _droits.contains('autoriser_depense'),
            // Qui voit l'argent de l'école : la caisse, la direction, un lecteur autorisé.
            _Rubrique.recouvrement => _peutEncaisser || _droits.contains('voir_caisse') || _droits.contains('consulter_tableau_bord'),
            _Rubrique.personnel => e.gestionnaire || _droits.contains('voir_personnel'),
            _Rubrique.postes => e.gestionnaire,
            _Rubrique.parametres => e.voitParametres,
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

  Future<void> _posteDUneAutreEcole(String orgId) async {
    final p = await db.getOptional('SELECT organisation_id FROM ce_poste');
    if (p != null && p['organisation_id'] != orgId) {
      await db.writeTransaction((tx) async {
        await tx.execute('DELETE FROM ce_poste');
        await tx.execute('DELETE FROM compteurs_poste');
      });
    }
  }

  /// Verrouiller : les données restent, l'app se rouvre avec le code PIN du
  /// poste, même sans internet. C'est le geste de tous les jours.
  Future<void> _verrouiller() async {
    final p = await cePoste();
    if (!mounted) return;
    if (p == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Activez d'abord ce poste (« À faire ») : le verrou utilise son code PIN.")));
      return;
    }
    if (p['pin_empreinte'] == null && !await definirPinPoste(context)) return;
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const PorteDuPoste(accueil: AccueilScreen(), sortie: BienvenueScreen())), (_) => false);
  }

  Future<void> _seDeconnecter() async {
    final horsLigne = !_statut.connected;
    final choix = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Se déconnecter ?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text("Vos données seront effacées de l'appareil (elles restent sur le serveur). "
              'Le poste garde sa lettre pour la personne suivante.'),
          if (_enAttente > 0) ...[
            const SizedBox(height: 8),
            Text('Attention : $_enAttente changement(s) pas encore envoyé(s) seront perdus.',
                style: const TextStyle(color: Couleurs.retard)),
          ],
          if (horsLigne) ...[
            const SizedBox(height: 8),
            const Text("Pas d'internet : vous ne pourrez pas vous reconnecter avant le retour du réseau.",
                style: TextStyle(color: Couleurs.retard, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 8),
          const Text('Pour une pause, verrouillez plutôt : vous rouvrirez avec le code PIN, même sans internet.'),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          OutlinedButton(onPressed: () => Navigator.pop(context, 'verrou'), child: const Text('Verrouiller plutôt')),
          FilledButton(
            style: horsLigne ? FilledButton.styleFrom(backgroundColor: Couleurs.retard) : null,
            onPressed: () => Navigator.pop(context, 'sortir'),
            child: const Text('Se déconnecter'),
          ),
        ],
      ),
    );
    if (choix == 'verrou') return _verrouiller();
    if (choix != 'sortir') return;
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
            importer: () => _ouvrirDans(_Rubrique.eleves, ImportElevesScreen(espace: e)),
            encaisser: () => _ouvrirDans(_Rubrique.caisse, EncaisserScreen(espace: e)),
            activerPoste: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ActiverPosteScreen(orgId: org['id'] as String))),
            ajouterSite: _ajouterSite,
          ),
        _Rubrique.eleves => ElevesScreen(espace: e, rechercheInitiale: _recherche),
        _Rubrique.caisse => CaisseScreen(espace: e),
        _Rubrique.depenses => DepensesScreen(espace: e),
        _Rubrique.recouvrement => RecouvrementScreen(espace: e),
        _Rubrique.familles => FamillesScreen(espace: e),
        _Rubrique.personnel => PersonnelScreen(espace: e),
        _Rubrique.postes => PostesScreen(espace: e),
        _Rubrique.parametres => ConfigurationScreen(espace: e),
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

    // Poste en attente de validation, date de l'appareil fausse : on le dit en haut de chaque écran.
    final corps = Column(children: [
      const BandeauHorloge(),
      if (_cePoste?['statut'] == 'a_valider')
        Container(
          width: double.infinity,
          color: Couleurs.attenteFond,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: const Text(messagePosteEnAttente, style: TextStyle(color: Couleurs.attente, fontSize: 13)),
        ),
      Expanded(child: contenu),
    ]);

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
              siteNom: _nomDuSite(e.siteId),
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
                  verrouiller: _verrouiller,
                ),
                Expanded(child: corps),
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
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const BoutonTheme(),
                      IconButton(tooltip: 'Verrouiller', onPressed: _verrouiller, icon: const Icon(Icons.lock_outline)),
                      IconButton(tooltip: 'Se déconnecter', onPressed: _seDeconnecter, icon: const Icon(Icons.logout)),
                      Text(_versionCourte, style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ]),
                  ),
                ),
              ),
              destinations: [
                for (final x in entrees)
                  NavigationRailDestination(icon: Icon(x.icone), selectedIcon: Icon(x.iconeActive), label: Text(x.libelle)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: corps),
          ]),
        );
      }
      // Téléphone : 3 rubriques principales en bas, le reste dans « Plus ».
      final principales = entrees.where((x) => x.rubrique.index <= _Rubrique.caisse.index).toList();
      final autres = entrees.where((x) => x.rubrique.index > _Rubrique.caisse.index).toList();
      final iPrincipale = principales.indexWhere((x) => x.rubrique == _rubrique);
      return Scaffold(
        body: corps,
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
                      title: _libelleMenu(x, null),
                      onTap: () {
                        Navigator.pop(context);
                        _aller(x.rubrique);
                      },
                    ),
                  ListTile(
                    leading: Icon(Theme.of(context).brightness == Brightness.dark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined),
                    title: Text(Theme.of(context).brightness == Brightness.dark ? 'Mode clair' : 'Mode sombre'),
                    onTap: () {
                      BoutonTheme.basculer(context);
                      Navigator.pop(context);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('Verrouiller'),
                    subtitle: const Text('Rouvrir avec le code PIN, même sans internet'),
                    onTap: () {
                      Navigator.pop(context);
                      _verrouiller();
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
                  ListTile(dense: true, enabled: false, leading: const Icon(Icons.info_outline), title: Text(versionAffichee)),
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

  /// Le logo ScolaGrid : carré noir en thème clair, carré blanc en thème sombre.
  @override
  Widget build(BuildContext context) => Image.asset(
        Theme.of(context).brightness == Brightness.dark ? 'assets/marque/icone-sombre.png' : 'assets/marque/icone.png',
        width: taille,
        height: taille,
        filterQuality: FilterQuality.medium,
        semanticLabel: 'ScolaGrid',
      );
}

/// État de la synchronisation, toujours visible : à jour, envoi, hors ligne.
class PuceSynchro extends StatelessWidget {
  const PuceSynchro({super.key, required this.statut, required this.enAttente});

  final SyncStatus statut;
  final int enAttente;

  @override
  Widget build(BuildContext context) {
    Widget etat(IconData icone, Color couleur, String texte) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icone, size: 16, color: couleur),
          const SizedBox(width: 6),
          Text(texte, style: const TextStyle(fontSize: 14)),
        ]);
    if (!statut.connected) {
      return Tooltip(
        message: 'Le poste travaille sans internet. Tout sera envoyé au retour de la connexion.',
        child: etat(Icons.cloud_off_outlined, Couleurs.attente, enAttente > 0 ? 'Hors ligne · $enAttente en attente' : 'Hors ligne'),
      );
    }
    if (enAttente > 0) return etat(Icons.cloud_upload_outlined, Couleurs.info, 'Envoi · $enAttente');
    return Tooltip(message: 'Tout est envoyé au serveur', child: etat(Icons.cloud_done_outlined, Couleurs.regle, 'Connecté'));
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
    final gris = schema.onSurfaceVariant;
    String? groupe;
    final elements = <Widget>[];
    for (final x in entrees) {
      if (x.groupe != null && x.groupe != groupe) {
        elements.add(Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
          child: Text(x.groupe!, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: .6, color: gris)),
        ));
      }
      groupe = x.groupe;
      final actif = x.rubrique == rubrique;
      elements.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Stack(children: [
          Material(
            color: actif ? Couleurs.doux(context) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              hoverColor: Couleurs.doux(context).withValues(alpha: .6),
              onTap: () => aller(x.rubrique),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(children: [
                  Icon(x.icone, size: 17, color: actif ? schema.onSurface : gris),
                  const SizedBox(width: 12),
                  _libelleMenu(
                      x,
                      TextStyle(
                          fontSize: 14,
                          fontWeight: actif ? FontWeight.w500 : FontWeight.w400,
                          color: actif ? schema.onSurface : schema.onSurface.withValues(alpha: .85))),
                ]),
              ),
            ),
          ),
          // Le trait à gauche de la rubrique ouverte.
          if (actif)
            Positioned(
              left: -12,
              top: 8,
              bottom: 8,
              child: Container(width: 2, decoration: BoxDecoration(color: schema.onSurface, borderRadius: BorderRadius.circular(2))),
            ),
        ]),
      ));
    }
    return Container(
      width: 224,
      decoration: BoxDecoration(color: schema.surface, border: Border(right: BorderSide(color: schema.outlineVariant))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: schema.outlineVariant))),
          child: Row(children: [
            const _Logo(taille: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Requete(
                'SELECT libelle FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1',
                parametres: [organisation['id']],
                builder: (context, a) => Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${organisation['nom']}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    Text([if (a.isNotEmpty) a.first['libelle'], 'GNF'].join(' · '),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
                  ],
                ),
              ),
            ),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), clipBehavior: Clip.none, children: elements),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: schema.outlineVariant))),
          child: Row(children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Couleurs.doux(context), borderRadius: BorderRadius.circular(6)),
              child: Text('${cePoste?['code'] ?? '–'}', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: schema.onSurface)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  cePoste == null ? 'Poste non activé' : 'Poste ${cePoste!['code']} · ${cePoste!['nom']}${siteNom == null ? '' : ' · $siteNom'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: gris)),
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
    required this.verrouiller,
  });

  final TextEditingController recherche;
  final void Function(String) rechercher;
  final Widget synchro;
  final String nom;
  final String fonction;
  final VoidCallback seDeconnecter;
  final VoidCallback verrouiller;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: schema.surface, border: Border(bottom: BorderSide(color: schema.outlineVariant))),
      child: Row(children: [
        SizedBox(
          width: 288,
          height: 36,
          child: TextField(
            controller: recherche,
            textInputAction: TextInputAction.search,
            onSubmitted: rechercher,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.search, size: 16, color: gris),
              prefixIconConstraints: const BoxConstraints(minWidth: 34),
              hintText: 'Élève, matricule, parent…',
              hintStyle: TextStyle(fontSize: 14, color: gris),
              contentPadding: EdgeInsets.zero,
              fillColor: schema.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
              enabledBorder:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: schema.outlineVariant)),
            ),
          ),
        ),
        const Spacer(),
        synchro,
        const SizedBox(width: 8),
        const BoutonTheme(),
        Container(width: 1, height: 24, margin: const EdgeInsets.symmetric(horizontal: 12), color: schema.outlineVariant),
        PopupMenuButton<String>(
          tooltip: 'Mon compte',
          onSelected: (v) => v == 'verrou' ? verrouiller() : seDeconnecter(),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'verrou', child: Text('Verrouiller')),
            const PopupMenuItem(value: 'sortir', child: Text('Se déconnecter')),
            PopupMenuItem(enabled: false, child: Text(versionAffichee)),
          ],
          child: Row(children: [
            Initiales(nom.isEmpty ? '?' : nom, taille: 32),
            const SizedBox(width: 10),
            Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(nom, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
              Text(fonction, style: TextStyle(fontSize: 12, color: gris)),
            ]),
            const SizedBox(width: 6),
            Icon(Icons.expand_more, size: 16, color: gris),
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
    required this.importer,
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
  final VoidCallback importer;
  final VoidCallback encaisser;
  final VoidCallback activerPoste;
  final VoidCallback ajouterSite;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final o = espace.orgId;
    return Requete(
      '''SELECT
           (SELECT count(*) FROM inscriptions i JOIN annees_scolaires a ON a.id = i.annee_id AND a.en_cours = 1
              WHERE i.organisation_id = ? AND i.statut = 'en_attente') AS attente,
           (SELECT count(*) FROM eleves e WHERE e.organisation_id = ? AND (e.date_naissance IS NULL OR e.sexe IS NULL)) AS incompletes,
           (SELECT code FROM organisations WHERE id = ?) AS sigle,
           (SELECT count(*) FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1) AS annee,
           (SELECT count(*) FROM remboursements WHERE organisation_id = ? AND statut IN ('demande', 'autorise')) AS remb,
           (SELECT count(*) FROM depenses WHERE organisation_id = ? AND (statut IN ('demande', 'autorisee') OR confirmation = 'attendue')) AS dep''',
      parametres: [o, o, o, o, o, o],
      builder: (context, l) {
        final r = l.first;
        final attente = r['attente'] as int? ?? 0;
        final incompletes = r['incompletes'] as int? ?? 0;
        final aFaire = <Widget>[
          if (organisation['statut'] == 'en_attente')
            const _AFaire(Etat('Espace', ton: Ton.info), "En attente d'activation par Scolagrid : vous pouvez déjà tout configurer.", null),
          if (cePoste == null)
            _AFaire(const Etat('Poste', ton: Ton.attente), 'Activer ce poste : sa lettre et son code PIN', activerPoste),
          if (cePoste != null && cePoste?['pin_empreinte'] == null)
            _AFaire(const Etat('Poste', ton: Ton.attente), 'Choisir le code PIN de ce poste', () => definirPinPoste(context)),
          if (espace.fondateur && r['sigle'] == null)
            _AFaire(const Etat('Réglage', ton: Ton.attente), "Choisir le sigle de l'école (matricules et reçus)",
                () => aller(_Rubrique.parametres)),
          if ((r['annee'] as int? ?? 0) == 0 && espace.fondateur)
            _AFaire(const Etat('Réglage', ton: Ton.attente), "Créer l'année scolaire en cours", () => aller(_Rubrique.parametres)),
          if (attente > 0)
            _AFaire(Etat('$attente', ton: Ton.attente), "inscription(s) en attente des frais d'inscription",
                () => aller(_Rubrique.eleves)),
          if ((peutEncaisser || espace.droits.contains('autoriser_depense')) && (r['dep'] as int? ?? 0) > 0)
            _AFaire(Etat('${r['dep']}', ton: Ton.attente), 'dépense(s) à autoriser, à sortir ou à confirmer',
                () => aller(_Rubrique.depenses)),
          if (peutEncaisser && (r['remb'] as int? ?? 0) > 0)
            _AFaire(Etat('${r['remb']}', ton: Ton.attente), 'remboursement(s) à autoriser ou à verser', () => aller(_Rubrique.caisse)),
          if (incompletes > 0)
            _AFaire(Etat('$incompletes', ton: Ton.info), 'fiche(s) élève à compléter (date de naissance, sexe)',
                () => aller(_Rubrique.eleves)),
        ];
        final bordure = BoxDecoration(
          color: schema.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: schema.outlineVariant),
        );
        return TableauDeBord(
          espace: espace,
          organisation: organisation,
          voitFinances: espace.voitFinances,
          peutInscrire: peutInscrire,
          peutEncaisser: peutEncaisser,
          aFaire: aFaire,
          inscrire: inscrire,
          importer: importer,
          encaisser: encaisser,
          pied: [
            Wrap(spacing: 12, runSpacing: 12, children: [
              Container(
                width: 360,
                padding: const EdgeInsets.all(16),
                decoration: bordure,
                child: Row(children: [
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: schema.primary, borderRadius: BorderRadius.circular(6)),
                    child: Text('${cePoste?['code'] ?? '–'}',
                        style: TextStyle(color: schema.onPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(cePoste == null ? 'Poste non activé' : 'Poste ${cePoste!['code']} · ${cePoste!['nom']}',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                      Text('${nom ?? ''} · $fonction', style: TextStyle(fontSize: 12, color: schema.onSurfaceVariant)),
                      const SizedBox(height: 6),
                      synchro,
                    ]),
                  ),
                  if (cePoste == null) TextButton(onPressed: activerPoste, child: const Text('Activer')),
                ]),
              ),
              if (espace.fondateur)
                Container(
                  width: 360,
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  decoration: bordure,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(child: Text('Sites (${sites.length})', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
                      TextButton.icon(onPressed: ajouterSite, icon: const Icon(Icons.add, size: 16), label: const Text('Ajouter')),
                    ]),
                    for (final s in sites)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          Icon(Icons.location_on_outlined, size: 16, color: schema.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(child: Text('${s['nom'] ?? ''}', style: const TextStyle(fontSize: 14))),
                          Text([s['ville'], if (s['code'] != null) s['code']].whereType<String>().join(' · '),
                              style: TextStyle(fontSize: 12, color: schema.onSurfaceVariant)),
                          const SizedBox(width: 8),
                        ]),
                      ),
                  ]),
                ),
              if (kIsWeb) const SizedBox(width: 480, child: _InstallerPostes()),
            ]),
          ],
        );
      },
    );
  }
}

class _AFaire extends StatelessWidget {
  const _AFaire(this.etat, this.texte, this.action);

  final Widget etat;
  final String texte;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: action,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            etat,
            const SizedBox(width: 12),
            Expanded(child: Text(texte, style: const TextStyle(fontSize: 14))),
            if (action != null) Icon(Icons.chevron_right, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ]),
        ),
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
