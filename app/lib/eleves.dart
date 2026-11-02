part of 'configuration.dart';

/// Module Inscriptions : élèves, parents et inscriptions.
/// Tout s'écrit dans la base locale (hors ligne) ; le matricule est fabriqué
/// par le poste avec sa lettre, donc unique sans réseau.

const statutsInscription = {
  'en_attente': 'En attente de paiement',
  'actif': 'Actif',
  'suspendu': 'Suspendu',
  'annule': 'Annulé',
  'exclu': 'Exclu',
  'transfert_sortant': 'Parti (transfert)',
  'diplome': 'Diplômé',
};

const typesAdmission = {
  'nouvelle': 'Nouvelle inscription',
  'reinscription': 'Réinscription',
  'transfert': "Transfert (vient d'une autre école)",
};

const liensFamille = {
  'pere': 'Père',
  'mere': 'Mère',
  'tuteur': 'Tuteur',
  'oncle': 'Oncle',
  'tante': 'Tante',
  'grand_parent': 'Grand-parent',
  'frere_soeur': 'Frère ou sœur',
  'autre': 'Autre',
};

/// Les droits de la personne connectée, d'après sa fiche synchronisée sur ce
/// poste. Le serveur vérifie de son côté ; ici on évite d'afficher l'impossible.
Future<bool> jAiLeDroit(String orgId, String? siteId, String droit) async {
  final fiche = await db.getOptional(
      "SELECT id FROM personnel WHERE organisation_id = ? AND user_id = ? AND statut = 'actif'", [orgId, monId]);
  if (fiche == null) return false;
  final aff = await db.getAll('SELECT fonction, site_id FROM affectations WHERE personnel_id = ? AND actif = 1', [fiche['id']]);
  if (aff.any((a) => a['fonction'] == 'fondateur')) return true;
  bool surCeSite(Map<String, Object?> l) => l['site_id'] == null || l['site_id'] == siteId;
  final exceptions = (await db.getAll('SELECT droit, accorde, site_id FROM droits_personnel WHERE personnel_id = ?',
          [fiche['id']]))
      .where(surCeSite)
      .where((d) => d['droit'] == droit);
  final parDefaut = droitsDesFonctions(aff.where(surCeSite).map((a) => a['fonction'] as String)).contains(droit);
  return (parDefaut || exceptions.any((d) => d['accorde'] == 1)) && !exceptions.any((d) => d['accorde'] == 0);
}

/// Sites où je peux inscrire.
Future<Map<String, String>> _sitesOuJInscris(String orgId) async => {
      for (final s in await db.getAll('SELECT id, nom FROM sites WHERE organisation_id = ? ORDER BY created_at', [orgId]))
        if (await jAiLeDroit(orgId, s['id'] as String, 'gerer_inscriptions')) s['id'] as String: s['nom'] as String,
    };

String _nomEleve(Map<String, Object?> e) => '${e['nom']} ${e['prenoms']}';

/// Statut d'une inscription, écrit en toutes lettres sur sa couleur.
Widget etatInscription(String statut) => Etat(
      switch (statut) {
        'en_attente' => 'En attente',
        'transfert_sortant' => 'Parti',
        _ => statutsInscription[statut] ?? statut,
      },
      ton: switch (statut) {
        'actif' || 'diplome' => Ton.regle,
        'en_attente' || 'suspendu' => Ton.attente,
        'exclu' => Ton.retard,
        _ => Ton.neutre,
      },
    );

Future<DateTime?> _choisirDate(BuildContext context, DateTime? initiale, {DateTime? premier, DateTime? dernier}) =>
    showDatePicker(
      context: context,
      initialEntryMode: DatePickerEntryMode.input,
      initialDate: initiale ?? DateTime(DateTime.now().year - 10),
      firstDate: premier ?? DateTime(1990),
      lastDate: dernier ?? DateTime.now(),
      helpText: 'Date (jj/mm/aaaa)',
    );

// Liste des élèves -------------------------------------------------------------
//
// Comme dans la maquette : en-tête (titre, nombre, boutons), filtres, puis un
// tableau dont les colonnes se retirent quand la place manque. Un clic sur une
// ligne ouvre la fiche : à côté du tableau au-delà de 1280 px (on feuillette
// sans rien refermer), en tiroir qui glisse depuis la droite en dessous, en
// plein écran sur téléphone.

/// Âge en années révolues.
int? _age(Object? naissance) {
  final d = DateTime.tryParse('${naissance ?? ''}');
  if (d == null) return null;
  final a = DateTime.now();
  var n = a.year - d.year;
  if (a.month < d.month || (a.month == d.month && a.day < d.day)) n--;
  return n;
}

/// Statut d'un élève sur la liste : celui de son inscription de l'année, ou
/// « Pas inscrit » (neutre : un élève pas encore revenu n'est pas une faute).
Widget _badgeStatut(Object? statut) =>
    statut == null ? const Etat('Pas inscrit') : etatInscription('$statut');

class ElevesScreen extends StatefulWidget {
  const ElevesScreen({super.key, required this.espace, this.rechercheInitiale});

  final Espace espace;

  /// Texte tapé dans la barre de recherche du haut (PC).
  final String? rechercheInitiale;

  @override
  State<ElevesScreen> createState() => _ElevesScreenState();
}

class _ElevesScreenState extends State<ElevesScreen> {
  late final _recherche = TextEditingController(text: widget.rechercheInitiale ?? '');
  String? _cycle;
  String? _classe;
  String? _statut;
  String _tri = 'nom';
  int _ordre = 1;
  int _page = 0;
  int _parPage = 50;
  String? _ouvert;
  bool _peutInscrire = false;

  /// Téléphone : élèves en liste, ou en grille de deux colonnes (grandes photos).
  /// Le choix est gardé sur ce poste.
  bool _grille = false;

  Future<void> _basculerVue() async {
    setState(() => _grille = !_grille);
    await db.writeTransaction((tx) async {
      await tx.execute("DELETE FROM preferences WHERE id = 'vue_eleves'");
      await tx.execute("INSERT INTO preferences (id, valeur) VALUES ('vue_eleves', ?)", [_grille ? 'grille' : 'liste']);
    });
  }

  @override
  void initState() {
    super.initState();
    db.getOptional("SELECT valeur FROM preferences WHERE id = 'vue_eleves'").then((p) {
      if (mounted && p?['valeur'] == 'grille') setState(() => _grille = true);
    });
    _sitesOuJInscris(widget.espace.orgId).then((s) {
      if (mounted) setState(() => _peutInscrire = s.isNotEmpty);
    });
  }

  void _trier(String colonne) => setState(() {
        if (_tri == colonne) {
          _ordre = -_ordre;
        } else {
          _tri = colonne;
          _ordre = 1;
        }
      });

  void _ouvrir(String eleveId) {
    final largeur = MediaQuery.sizeOf(context).width;
    if (largeur >= 1280) {
      setState(() => _ouvert = eleveId);
    } else if (largeur < 640) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: widget.espace, eleveId: eleveId)));
    } else {
      // Tiroir qui glisse depuis la droite, par-dessus la liste.
      setState(() => _ouvert = eleveId);
      showGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Fermer',
        barrierColor: Colors.black26,
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, _, _) => Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 8,
            child: SizedBox(
              width: largeur < 600 ? largeur : 576,
              height: double.infinity,
              child: SafeArea(
                child: FicheEleve(espace: widget.espace, eleveId: eleveId, onFermer: () => Navigator.of(context).pop()),
              ),
            ),
          ),
        ),
        transitionBuilder: (context, animation, _, enfant) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero)
              .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: enfant,
        ),
      ).then((_) {
        if (mounted) setState(() => _ouvert = null);
      });
    }
  }

  Future<void> _imprimerListe() async {
    final c = await db.get(
        '''SELECT c.nom, a.libelle, coalesce(o.nom_officiel, o.nom) AS ecole FROM classes c
           JOIN annees_scolaires a ON a.id = c.annee_id JOIN organisations o ON o.id = c.organisation_id WHERE c.id = ?''',
        [_classe]);
    final eleves = await db.getAll(
        '''SELECT e.* FROM eleves e JOIN inscriptions i ON i.eleve_id = e.id
           WHERE i.classe_id = ? AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')
           ORDER BY e.nom, e.prenoms''',
        [_classe]);
    final pdf = await listeClassePdf(
        ecole: '${c['ecole']}', classe: '${c['nom']}', annee: '${c['libelle']}', eleves: [for (final e in eleves) Map.of(e)]);
    await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Liste ${c['nom']}');
  }

  /// La liste qu'on a sous les yeux (filtres compris), en fichier Excel.
  Future<void> _exporter(Lignes eleves, String nom) async {
    final messager = ScaffoldMessenger.of(context);
    final classeur = xl.Excel.createExcel();
    final feuille = classeur['Élèves'];
    classeur.setDefaultSheet('Élèves');
    xl.TextCellValue t(Object? v) => xl.TextCellValue(v == null ? '' : '$v');
    feuille.appendRow([
      for (final c in const [
        'Matricule', "Matricule d'État", 'Nom', 'Prénoms', 'Sexe', 'Date de naissance', 'Classe', 'Statut', 'Tuteur',
        'Téléphone', 'Quartier',
      ])
        t(c),
    ]);
    for (final e in eleves) {
      feuille.appendRow([
        t(e['matricule']), t(e['matricule_etat']), t(e['nom']), t(e['prenoms']), t(e['sexe']),
        t(e['date_naissance'] == null ? null : _dateLisible(e['date_naissance'])), t(e['classe']),
        t(e['statut'] == null ? 'Pas inscrit' : statutsInscription[e['statut']]), t(e['tuteur']), t(e['tuteur_tel']),
        t(e['quartier']),
      ]);
    }
    for (final f in classeur.tables.keys.toList()) {
      if (f != 'Élèves') classeur.delete(f);
    }
    final octets = classeur.encode();
    if (octets == null) return;
    try {
      await FilePicker.saveFile(
        dialogTitle: 'Exporter la liste',
        fileName: '$nom.xlsx',
        bytes: Uint8List.fromList(octets),
      );
      messager.showSnackBar(SnackBar(content: Text('${eleves.length} élève(s) exporté(s).')));
    } catch (_) {
      messager.showSnackBar(const SnackBar(content: Text("Impossible d'enregistrer le fichier sur cet appareil.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.espace.orgId;
    return Scaffold(
      body: Requete(
        '''SELECT a.libelle AS annee, c.id, c.nom, c.capacite, c.site_id, s.nom AS site, n.cycle, n.ordre,
             (SELECT count(*) FROM inscriptions i WHERE i.classe_id = c.id
              AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')) AS effectif
           FROM annees_scolaires a
           LEFT JOIN classes c ON c.annee_id = a.id
           LEFT JOIN niveaux n ON n.id = c.niveau_id
           LEFT JOIN sites s ON s.id = c.site_id
           WHERE a.organisation_id = ? AND a.en_cours = 1
           ORDER BY n.ordre, c.nom''',
        parametres: [o],
        builder: (context, lignesClasses) => Requete(
          '''SELECT e.id, e.nom, e.prenoms, e.matricule, e.matricule_etat, e.sexe, e.date_naissance, e.quartier,
               e.allergies, e.sante, e.created_at, e.site_id, s.nom AS site,
               i.statut, i.classe_id, c.nom AS classe, n.cycle,
               (SELECT p.updated_at FROM photos_eleves p WHERE p.eleve_id = e.id) AS photo_maj,
               (SELECT ct.nom_complet FROM eleves_contacts ec JOIN contacts ct ON ct.id = ec.contact_id
                WHERE ec.eleve_id = e.id AND ec.tuteur_principal = 1) AS tuteur,
               (SELECT ct.telephone FROM eleves_contacts ec JOIN contacts ct ON ct.id = ec.contact_id
                WHERE ec.eleve_id = e.id AND ec.tuteur_principal = 1) AS tuteur_tel,
               (SELECT group_concat(ct.nom_complet || ' ' || replace(coalesce(ct.telephone, ''), ' ', ''), ' ')
                FROM eleves_contacts ec JOIN contacts ct ON ct.id = ec.contact_id WHERE ec.eleve_id = e.id) AS familles
             FROM eleves e
             LEFT JOIN sites s ON s.id = e.site_id
             LEFT JOIN annees_scolaires a ON a.organisation_id = e.organisation_id AND a.en_cours = 1
             LEFT JOIN inscriptions i ON i.eleve_id = e.id AND i.annee_id = a.id
             LEFT JOIN classes c ON c.id = i.classe_id
             LEFT JOIN niveaux n ON n.id = c.niveau_id
             WHERE e.organisation_id = ?''',
          parametres: [o],
          builder: (context, tous) => _contenu(context, lignesClasses, tous),
        ),
      ),
    );
  }

  Widget _contenu(BuildContext context, Lignes lignesClasses, Lignes tous) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final largeur = MediaQuery.sizeOf(context).width;
    final scinde = largeur >= 1280;
    final telephone = largeur < 640;
    final panneau = scinde && _ouvert != null;

    final annee = lignesClasses.isEmpty ? null : lignesClasses.first['annee'] as String?;
    final classes = lignesClasses.where((c) => c['id'] != null).toList();
    final cycles = <String>[];
    for (final c in classes) {
      final cy = c['cycle'] as String?;
      if (cy != null && !cycles.contains(cy)) cycles.add(cy);
    }
    final plusieursSites = classes.map((c) => c['site_id']).toSet().length > 1;
    Map<String, Object?>? classe;
    for (final c in classes) {
      if (c['id'] == _classe) classe = c;
    }

    // Filtres, puis tri, puis page.
    final base = tous.where((e) => classe != null ? e['classe_id'] == _classe : (_cycle == null || e['cycle'] == _cycle)).toList();
    final q = nomSimplifie(_recherche.text);
    final chiffres = _recherche.text.replaceAll(RegExp(r'[^0-9]'), '');
    final eleves = base.where((e) {
      if (_statut != null && (e['statut'] ?? 'non_inscrit') != _statut) return false;
      if (q.isEmpty) return true;
      final texte = nomSimplifie([
        e['nom'], e['prenoms'], e['nom'], e['matricule'], e['matricule_etat'], e['classe'], e['familles'],
      ].whereType<String>().join(' '));
      if (texte.contains(q) || nomSimplifie('${e['prenoms']} ${e['nom']}').contains(q)) return true;
      return chiffres.length >= 4 && '${e['familles'] ?? ''}'.contains(chiffres);
    }).toList()
      ..sort((a, b) {
        int v;
        switch (_tri) {
          case 'classe':
            v = '${a['classe'] ?? '￿'}'.compareTo('${b['classe'] ?? '￿'}');
          case 'naissance':
            v = '${a['date_naissance'] ?? '9999'}'.compareTo('${b['date_naissance'] ?? '9999'}');
          default:
            v = nomSimplifie(_nomEleve(a)).compareTo(nomSimplifie(_nomEleve(b)));
        }
        return v * _ordre;
      });
    final enAttente = base.where((e) => e['statut'] == 'en_attente').length;
    final filtres = _recherche.text.isNotEmpty || _statut != null || _cycle != null || _classe != null;
    final pages = eleves.isEmpty ? 1 : (eleves.length / _parPage).ceil();
    final page = _page.clamp(0, pages - 1);
    final affiches = eleves.skip(page * _parPage).take(_parPage).toList();

    void filtrer(VoidCallback f) => setState(() {
          f();
          _page = 0;
        });

    // En-tête ----------------------------------------------------------------
    final titre = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 12, children: [
        Text(classe != null ? '${classe['nom']}' : 'Élèves',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -.2)),
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
              '${eleves.length}${eleves.length != base.length ? ' sur ${base.length}' : ''}${annee == null ? '' : ' · $annee'}',
              style: TextStyle(fontSize: 14, color: gris)),
        ),
      ]),
      const SizedBox(height: 2),
      Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (classe != null) ...[
          if (classe['cycle'] != null) Text('${classe['cycle']}', style: TextStyle(fontSize: 14, color: gris)),
          Text('${classe['site']}', style: TextStyle(fontSize: 14, color: gris)),
          Text('${classe['effectif']}${classe['capacite'] == null ? '' : ' / ${classe['capacite']} places'}',
              style: TextStyle(fontSize: 14, color: gris)),
        ],
        if (enAttente > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: Couleurs.doux(context), borderRadius: BorderRadius.circular(4)),
            child: Text('$enAttente en attente', style: TextStyle(fontSize: 12, color: gris)),
          ),
      ]),
    ]);
    final boutons = Wrap(spacing: 8, runSpacing: 8, children: [
      if (classe != null)
        OutlinedButton.icon(
            onPressed: _imprimerListe, icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Imprimer la liste')),
      // Importer et exporter : des gestes rares, rangés dans « ⋯ ».
      if (_peutInscrire || !telephone)
        PopupMenuButton<String>(
          tooltip: "Importer, exporter",
          icon: const Icon(Icons.more_horiz),
          onSelected: (v) => v == 'importer'
              ? Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImportElevesScreen(espace: widget.espace)))
              : _exporter(eleves, 'eleves-${classe?['nom'] ?? 'liste'}'.replaceAll(' ', '-')),
          itemBuilder: (_) => [
            if (_peutInscrire)
              const PopupMenuItem(value: 'importer', child: _ItemMenu(Icons.upload_file_outlined, 'Importer (Excel ou CSV)')),
            if (!telephone)
              PopupMenuItem(
                  value: 'exporter', enabled: eleves.isNotEmpty, child: const _ItemMenu(Icons.download_outlined, 'Exporter en Excel')),
          ],
        ),
      if (_peutInscrire)
        FilledButton.icon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => InscrireScreen(espace: widget.espace))),
          icon: const Icon(Icons.person_add_alt, size: 16),
          label: const Text('Nouvelle inscription'),
        ),
    ]);

    // Filtres ------------------------------------------------------------------
    Widget menu<T>(double largeurMenu, T? valeur, String tous, Map<T, String> choix, ValueChanged<T?> change) => SizedBox(
          width: largeurMenu,
          height: 36,
          child: DropdownButtonHideUnderline(
            child: Container(
              padding: const EdgeInsets.only(left: 12, right: 8),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(6),
                color: schema.surface,
              ),
              child: DropdownButton<T?>(
                value: valeur,
                isExpanded: true,
                isDense: true,
                icon: Icon(Icons.keyboard_arrow_down, size: 18, color: gris),
                style: TextStyle(fontFamily: policeTexte, fontSize: 14, color: schema.onSurface),
                items: [
                  DropdownMenuItem<T?>(value: null, child: Text(tous, overflow: TextOverflow.ellipsis)),
                  for (final c in choix.entries)
                    DropdownMenuItem<T?>(value: c.key, child: Text(c.value, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: change,
              ),
            ),
          ),
        );
    // Les menus de filtre ; [apres] rafraîchit la feuille du téléphone.
    List<Widget> menusFiltres(VoidCallback apres, {double? largeurFixe}) => [
          if (cycles.isNotEmpty)
            menu<String>(largeurFixe ?? 160, _cycle, 'Tous les cycles', {for (final c in cycles) c: c}, (v) {
              filtrer(() {
                _cycle = v;
                if (classe != null && v != null && classe['cycle'] != v) _classe = null;
              });
              apres();
            }),
          menu<String>(largeurFixe ?? 176, _classe, 'Toutes les classes', {
            for (final c in classes)
              if (_cycle == null || c['cycle'] == _cycle)
                c['id'] as String: '${c['nom']}${plusieursSites ? ' · ${c['site']}' : ''}  ${c['effectif']}',
          }, (v) {
            filtrer(() {
              _classe = v;
              for (final c in classes) {
                if (c['id'] == v) _cycle = c['cycle'] as String?;
              }
            });
            apres();
          }),
          menu<String>(largeurFixe ?? 160, _statut, 'Tous les statuts', {
            for (final s in statutsInscription.entries) s.key: s.value == 'En attente de paiement' ? 'En attente' : s.value,
            'non_inscrit': 'Pas inscrit',
          }, (v) {
            filtrer(() => _statut = v);
            apres();
          }),
        ];
    final nbFiltres = [_cycle, _classe, _statut].where((x) => x != null).length;
    final barreFiltres = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SizedBox(
        width: telephone ? MediaQuery.sizeOf(context).width - 24 - 104 : (panneau ? 260 : 340),
        height: 36,
        child: TextField(
          controller: _recherche,
          onChanged: (_) => filtrer(() {}),
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            prefixIcon: Icon(Icons.search, size: 18, color: gris),
            prefixIconConstraints: const BoxConstraints(minWidth: 36),
            hintText: "Nom, matricule système ou d'État, tuteur…",
            hintStyle: TextStyle(fontSize: 14, color: gris),
          ),
        ),
      ),
      if (telephone)
        SizedBox(
          width: 44,
          height: 36,
          child: IconButton.outlined(
            tooltip: _grille ? 'Afficher en liste' : 'Afficher en grille (grandes photos)',
            padding: EdgeInsets.zero,
            icon: Icon(_grille ? Icons.view_agenda_outlined : Icons.grid_view, size: 18),
            onPressed: _basculerVue,
          ),
        ),
      if (telephone)
        SizedBox(
          width: 44,
          height: 36,
          child: Badge(
            isLabelVisible: nbFiltres > 0,
            label: Text('$nbFiltres'),
            child: IconButton.outlined(
              tooltip: 'Filtres',
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.tune, size: 18),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                builder: (context) => StatefulBuilder(
                  builder: (context, maj) => SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const Text('Filtres', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 12),
                        for (final m in menusFiltres(() => maj(() {}), largeurFixe: double.infinity)) ...[m, const SizedBox(height: 10)],
                        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Voir les élèves')),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        )
      else
        ...menusFiltres(() {}),
      if (filtres && !telephone)
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: gris, minimumSize: const Size(36, 36)),
          onPressed: () => filtrer(() {
            _recherche.clear();
            _statut = null;
            _cycle = null;
            _classe = null;
          }),
          icon: const Icon(Icons.close, size: 14),
          label: const Text('Réinitialiser', style: TextStyle(fontSize: 14)),
        ),
    ]);

    // Pied : position et pages -----------------------------------------------------
    final pied = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        Text(
            eleves.isEmpty
                ? 'Aucun résultat'
                : '${page * _parPage + 1}–${page * _parPage + affiches.length} sur ${eleves.length}',
            style: TextStyle(fontSize: 14, color: gris)),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (!telephone) ...[
            menu<int>(136, _parPage == 50 ? null : _parPage, '50 par page', {25: '25 par page', 100: '100 par page'},
                (v) => filtrer(() => _parPage = v ?? 50)),
            const SizedBox(width: 8),
          ],
          _BoutonPage(icone: Icons.chevron_left, onPressed: page == 0 ? null : () => setState(() => _page = page - 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('${page + 1} / $pages', style: TextStyle(fontSize: 14, color: gris)),
          ),
          _BoutonPage(icone: Icons.chevron_right, onPressed: page >= pages - 1 ? null : () => setState(() => _page = page + 1)),
        ]),
      ],
    );

    final tableau = _TableauEleves(
      espace: widget.espace,
      eleves: affiches,
      vide: tous.isEmpty
          ? (_peutInscrire ? 'Aucun élève pour le moment. Inscrivez le premier, ou importez une liste Excel.' : 'Aucun élève pour le moment.')
          : 'Aucun élève ne correspond.',
      ouvert: _ouvert,
      onOuvrir: _ouvrir,
      tri: _tri,
      onTrier: _trier,
      colonnes: (
        matricule: largeur >= 768,
        classe: classe == null,
        site: classe == null && plusieursSites && !panneau && largeur >= 1280,
        naissance: !panneau && largeur >= 1024,
        tuteur: !panneau && largeur >= 1280,
        quartier: !panneau && largeur >= 1536,
      ),
      telephone: telephone,
      grille: _grille,
    );

    final liste = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (telephone) ...[
        titre,
        const SizedBox(height: 8),
        boutons,
      ] else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: titre),
          const SizedBox(width: 8),
          Flexible(child: Align(alignment: Alignment.topRight, child: boutons)),
        ]),
      const SizedBox(height: 12),
      barreFiltres,
      const SizedBox(height: 12),
      Expanded(child: tableau),
      const SizedBox(height: 12),
      pied,
    ]);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: Padding(
          padding: EdgeInsets.all(telephone ? 12 : 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: liste),
            if (panneau) ...[
              const SizedBox(width: 16),
              _PanneauLateral(
                key: const ValueKey('panneau'),
                child: FicheEleve(
                  key: ValueKey(_ouvert),
                  espace: widget.espace,
                  eleveId: _ouvert!,
                  onFermer: () => setState(() => _ouvert = null),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

class _BoutonPage extends StatelessWidget {
  const _BoutonPage({required this.icone, required this.onPressed});

  final IconData icone;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 32,
        height: 32,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(32, 32)),
          onPressed: onPressed,
          child: Icon(icone, size: 16),
        ),
      );
}

/// La fiche posée à côté du tableau : elle arrive en glissant de la droite.
class _PanneauLateral extends StatelessWidget {
  const _PanneauLateral({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        builder: (context, t, enfant) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(24 * (1 - t), 0), child: enfant),
        ),
        child: Container(
          width: 432,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      );
}

/// Colonnes qu'on peut se permettre selon la place.
typedef _Colonnes = ({bool matricule, bool classe, bool site, bool naissance, bool tuteur, bool quartier});

class _TableauEleves extends StatelessWidget {
  const _TableauEleves({
    required this.espace,
    required this.eleves,
    required this.vide,
    required this.ouvert,
    required this.onOuvrir,
    required this.tri,
    required this.onTrier,
    required this.colonnes,
    required this.telephone,
    this.grille = false,
  });

  final Espace espace;
  final Lignes eleves;
  final String vide;
  final String? ouvert;
  final ValueChanged<String> onOuvrir;
  final String tri;
  final ValueChanged<String> onTrier;
  final _Colonnes colonnes;
  final bool telephone;
  final bool grille;

  Future<void> _action(BuildContext context, String action, Map<String, Object?> e) async {
    final id = e['id'] as String;
    switch (action) {
      case 'ouvrir':
        onOuvrir(id);
      case 'encaisser':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EncaisserScreen(espace: espace, eleveId: id)));
      case 'reinscrire':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => InscrireScreen(espace: espace, eleveId: id)));
      default:
        final complet = await db.get('SELECT * FROM eleves WHERE id = ?', [id]);
        final ins = await _inscriptionEnCours(id);
        if (!context.mounted) return;
        switch (action) {
          case 'modifier':
            await _modifierIdentiteEleve(context, Map.of(complet));
          case 'attestation':
            if (ins != null) await _imprimerAttestation(context, Map.of(complet), ins);
          case 'classe':
            if (ins != null) await _changerClasseEleve(context, ins);
          case 'clore':
            if (ins != null) await _clore(context, ins);
        }
    }
  }

  /// Les gestes possibles sur un élève : (action, icône, libellé, en rouge ?).
  /// Un `null` sépare les groupes.
  static List<(String, IconData, String, bool)?> _gestes(Map<String, Object?> e) => [
        ('ouvrir', Icons.description_outlined, 'Ouvrir la fiche', false),
        ('modifier', Icons.edit_outlined, 'Modifier', false),
        null,
        ('encaisser', Icons.account_balance_wallet_outlined, 'Encaisser', false),
        if (e['statut'] == 'actif') ('attestation', Icons.description_outlined, "Attestation d'inscription", false),
        null,
        if (e['statut'] == null)
          ('reinscrire', Icons.how_to_reg_outlined, 'Réinscrire', false)
        else if (e['statut'] == 'actif' || e['statut'] == 'en_attente') ...[
          ('classe', Icons.swap_horiz, 'Changer de classe', false),
          null,
          ('clore', Icons.block, "Clore l'inscription", true),
        ],
      ];

  /// Téléphone : un appui long ouvre les gestes en bas de l'écran.
  Future<void> _feuilleGestes(BuildContext context, Map<String, Object?> e) async {
    final choix = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(_nomEleve(e), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          for (final g in _gestes(e))
            if (g == null)
              const Divider(height: 1)
            else
              ListTile(
                leading: Icon(g.$2, color: g.$4 ? Couleurs.retard : null),
                title: Text(g.$3, style: TextStyle(color: g.$4 ? Couleurs.retard : null)),
                onTap: () => Navigator.pop(context, g.$1),
              ),
        ]),
      ),
    );
    if (choix != null && context.mounted) await _action(context, choix, e);
  }

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    const entete = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);
    final c = colonnes;

    // Téléphone : une liste de cartes plutôt qu'un tableau.
    if (telephone) {
      if (eleves.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(vide, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: gris)),
          ),
        );
      }
      if (grille) {
        // Deux élèves par ligne, grande photo carrée : pour reconnaître les visages.
        return GridView.builder(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: eleves.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: .66,
          ),
          itemBuilder: (context, i) {
            final e = eleves[i];
            return Material(
              color: schema.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: bordure)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onOuvrir(e['id'] as String),
                onLongPress: () => _feuilleGestes(context, e),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: Stack(fit: StackFit.expand, children: [
                      PhotoEleve(eleveId: e['id'] as String, nom: _nomEleve(e), version: e['photo_maj'] as String?, carre: true),
                      Positioned(top: 6, left: 6, child: _badgeStatut(e['statut'])),
                      if (AlerteSante.concerne(e)) Positioned(top: 6, right: 6, child: AlerteSante(eleve: e)),
                    ]),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_nomEleve(e),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.2)),
                        const Spacer(),
                        Text('${e['classe'] ?? 'Pas inscrit'}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
                      ]),
                    ),
                  ),
                ]),
              ),
            );
          },
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: eleves.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final e = eleves[i];
          return Material(
            color: schema.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: bordure)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onOuvrir(e['id'] as String),
              onLongPress: () => _feuilleGestes(context, e),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  _AvatarListe(eleve: e, taille: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(
                          child: Text(_nomEleve(e),
                              overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        ),
                        if (AlerteSante.concerne(e)) ...[const SizedBox(width: 6), AlerteSante(eleve: e)],
                      ]),
                      const SizedBox(height: 2),
                      Text('${e['classe'] ?? 'Pas inscrit'} · ${e['matricule']}',
                          overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
                      if (e['tuteur'] != null)
                        Text('${e['tuteur']}${e['tuteur_tel'] != null ? ' · ${e['tuteur_tel']}' : ''}',
                            overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    _badgeStatut(e['statut']),
                    IconButton(
                      tooltip: 'Actions',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.more_horiz, size: 18),
                      onPressed: () => _feuilleGestes(context, e),
                    ),
                  ]),
                ]),
              ),
            ),
          );
        },
      );
    }

    Widget triable(String libelle, String cle) => InkWell(
          onTap: () => onTrier(cle),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(libelle, style: entete),
            const SizedBox(width: 4),
            Icon(tri == cle ? Icons.swap_vert : Icons.unfold_more, size: 13, color: gris.withValues(alpha: tri == cle ? 1 : .6)),
          ]),
        );
    Widget cellule(double? largeur, Widget enfant, {int flex = 1}) {
      final contenu = Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: enfant);
      return largeur == null ? Expanded(flex: flex, child: contenu) : SizedBox(width: largeur, child: contenu);
    }

    final enTete = Container(
      height: 36,
      decoration: BoxDecoration(color: schema.surface, border: Border(bottom: BorderSide(color: bordure))),
      child: Row(children: [
        SizedBox(width: telephone ? 56 : 72),
        cellule(null, Align(alignment: Alignment.centerLeft, child: triable('Élève', 'nom')), flex: 3),
        if (!telephone) ...[
          if (c.matricule) cellule(224, const Text('Matricule', style: entete)),
          cellule(64, const Text('Sexe', style: entete)),
          if (c.classe) cellule(128, Align(alignment: Alignment.centerLeft, child: triable('Classe', 'classe'))),
          if (c.site) cellule(112, const Text('Site', style: entete)),
          if (c.naissance) cellule(144, Align(alignment: Alignment.centerLeft, child: triable('Né(e) le', 'naissance'))),
          if (c.tuteur) cellule(null, const Text('Tuteur principal', style: entete), flex: 2),
          if (c.quartier) cellule(128, const Text('Quartier', style: entete)),
        ],
        cellule(telephone ? 104 : 144, const Text('Statut', style: entete)),
        const SizedBox(width: 48),
      ]),
    );

    Widget ligne(Map<String, Object?> e) {
      final id = e['id'] as String;
      final choisi = id == ouvert;
      final age = _age(e['date_naissance']);
      final nouveau = DateTime.tryParse('${e['created_at']}')?.isAfter(DateTime.now().subtract(const Duration(hours: 24))) ?? false;
      final petit = TextStyle(fontSize: 12, color: gris);
      return Material(
        color: choisi ? Couleurs.doux(context) : Colors.transparent,
        child: InkWell(
          onTap: () => onOuvrir(id),
          hoverColor: Couleurs.doux(context).withValues(alpha: .5),
          child: Container(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bordure))),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: _AvatarListe(eleve: e, taille: telephone ? 40 : 56),
              ),
              cellule(
                null,
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(_nomEleve(e),
                          overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    ),
                    if (AlerteSante.concerne(e)) ...[const SizedBox(width: 8), AlerteSante(eleve: e)],
                    if (nouveau) ...[
                      const SizedBox(width: 8),
                      const Etat('nouveau', ton: Ton.regle),
                    ],
                  ]),
                  if (!c.matricule || telephone)
                    Text(telephone ? '${e['matricule']} · ${e['classe'] ?? '—'}' : '${e['matricule']}',
                        overflow: TextOverflow.ellipsis, style: styleMono.copyWith(fontSize: 12, color: gris)),
                ]),
                flex: 3,
              ),
              if (!telephone) ...[
                if (c.matricule)
                  cellule(
                    224,
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${e['matricule']}', overflow: TextOverflow.ellipsis, style: styleMono.copyWith(fontSize: 12)),
                      Text(e['matricule_etat'] as String? ?? 'État : en attente',
                          overflow: TextOverflow.ellipsis, style: styleMono.copyWith(fontSize: 12, color: gris)),
                    ]),
                  ),
                cellule(64, Text('${e['sexe'] ?? '—'}', style: const TextStyle(fontSize: 14))),
                if (c.classe) cellule(128, Text('${e['classe'] ?? '—'}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
                if (c.site) cellule(112, Text('${e['site'] ?? ''}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
                if (c.naissance)
                  cellule(
                    144,
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(e['date_naissance'] == null ? '—' : _dateLisible(e['date_naissance']), style: const TextStyle(fontSize: 14)),
                      if (age != null) Text('$age ans', style: petit),
                    ]),
                  ),
                if (c.tuteur)
                  cellule(
                    null,
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${e['tuteur'] ?? ''}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                      if (e['tuteur_tel'] != null) Text('${e['tuteur_tel']}', overflow: TextOverflow.ellipsis, style: petit),
                    ]),
                    flex: 2,
                  ),
                if (c.quartier)
                  cellule(128, Text('${e['quartier'] ?? ''}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
              ],
              cellule(telephone ? 104 : 144, Align(alignment: Alignment.centerLeft, child: _badgeStatut(e['statut']))),
              SizedBox(
                width: 48,
                child: PopupMenuButton<String>(
                  tooltip: 'Actions',
                  icon: const Icon(Icons.more_horiz, size: 18),
                  onSelected: (a) => _action(context, a, e),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'ouvrir', child: _ItemMenu(Icons.description_outlined, 'Ouvrir la fiche')),
                    const PopupMenuItem(value: 'modifier', child: _ItemMenu(Icons.edit_outlined, 'Modifier')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'encaisser', child: _ItemMenu(Icons.account_balance_wallet_outlined, 'Encaisser')),
                    if (e['statut'] == 'actif')
                      const PopupMenuItem(value: 'attestation', child: _ItemMenu(Icons.description_outlined, "Attestation d'inscription")),
                    const PopupMenuDivider(),
                    if (e['statut'] == null)
                      const PopupMenuItem(value: 'reinscrire', child: _ItemMenu(Icons.how_to_reg_outlined, 'Réinscrire'))
                    else if (e['statut'] == 'actif' || e['statut'] == 'en_attente') ...[
                      const PopupMenuItem(value: 'classe', child: _ItemMenu(Icons.swap_horiz, 'Changer de classe')),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                          value: 'clore', child: _ItemMenu(Icons.block, "Clore l'inscription", couleur: Couleurs.retard)),
                    ],
                  ],
                ),
              ),
            ]),
          ),
        ),
      );
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: schema.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: bordure),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        enTete,
        Expanded(
          child: eleves.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(vide, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: gris)),
                  ),
                )
              : ListView.builder(
                  itemCount: eleves.length,
                  itemBuilder: (context, i) => ligne(eleves[i]),
                ),
        ),
      ]),
    );
  }
}

class _ItemMenu extends StatelessWidget {
  const _ItemMenu(this.icone, this.libelle, {this.couleur});

  final IconData icone;
  final String libelle;
  final Color? couleur;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icone, size: 16, color: couleur),
        const SizedBox(width: 10),
        Text(libelle, style: TextStyle(fontSize: 14, color: couleur)),
      ]);
}

/// Vignette de la liste : la photo, ou les initiales avec un petit appareil
/// photo qui signale que la photo d'identité manque.
class _AvatarListe extends StatelessWidget {
  const _AvatarListe({required this.eleve, required this.taille});

  final Map<String, Object?> eleve;
  final double taille;

  @override
  Widget build(BuildContext context) {
    final sansPhoto = eleve['photo_maj'] == null;
    return SizedBox(
      width: taille,
      height: taille,
      child: Stack(clipBehavior: Clip.none, children: [
        PhotoEleve(
            eleveId: eleve['id'] as String, nom: _nomEleve(eleve), version: eleve['photo_maj'] as String?, taille: taille),
        if (sansPhoto)
          Positioned(
            right: -2,
            bottom: -2,
            child: Tooltip(
              message: 'Photo non fournie',
              child: Container(
                width: taille * .4,
                height: taille * .4,
                decoration: BoxDecoration(
                  color: Couleurs.doux(context),
                  shape: BoxShape.circle,
                  border: Border.all(color: Theme.of(context).colorScheme.surface, width: 1.5),
                ),
                child: Icon(Icons.photo_camera_outlined, size: taille * .22, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
      ]),
    );
  }
}
