part of 'configuration.dart';

/// Reprise des élèves d'une école qui adopte Scolagrid, depuis un fichier
/// Excel ou CSV : dépôt, contrôle, puis validation. Rien n'est écrit avant.

String? _texteCellule(xl.Data? d) {
  final v = d?.value;
  return switch (v) {
    null => null,
    xl.DateCellValue() => '${v.day}/${v.month}/${v.year}',
    xl.DateTimeCellValue() => '${v.day}/${v.month}/${v.year}',
    xl.IntCellValue() => '${v.value}',
    xl.DoubleCellValue() => v.value == v.value.roundToDouble() ? '${v.value.toInt()}' : '${v.value}',
    _ => v.toString(),
  };
}

class ImportElevesScreen extends StatefulWidget {
  const ImportElevesScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<ImportElevesScreen> createState() => _ImportElevesScreenState();
}

class _ImportElevesScreenState extends State<ImportElevesScreen> {
  List<LigneImport>? _lignes;
  String? _fichier;
  bool _avecDoublons = false;
  bool _travail = false;
  String? _message;
  Map<String, Map<String, Object?>> _classesParId = {};

  /// Lignes brutes du dernier fichier : on les réanalyse après avoir créé des classes.
  List<List<String?>>? _brut;
  List<ClasseAbsente> _absentes = [];

  /// Pourquoi une classe absente ne peut pas être créée tout de suite (null : elle peut l'être).
  Map<ClasseAbsente, String?> _blocages = {};
  Map<String, String> _sites = {};
  Map<String, Object?>? _annee;

  Future<void> _choisir() async {
    final choix = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'csv']);
    if (choix.isEmpty) return;
    setState(() {
      _travail = true;
      _message = null;
    });
    try {
      final octets = await choix.single.readAsBytes();
      final List<List<String?>> lignes;
      if (choix.single.name.toLowerCase().endsWith('.csv')) {
        lignes = lireCsv(octets);
      } else {
        final classeur = xl.Excel.decodeBytes(octets);
        // Notre modèle range les élèves dans l'onglet « Élèves » ; sinon, le premier onglet.
        final onglets = classeur.tables.keys;
        final feuille = classeur.tables[onglets.firstWhere((k) => nomSimplifie(k) == 'ELEVES', orElse: () => onglets.first)]!;
        lignes = [for (final r in feuille.rows) [for (final c in r) _texteCellule(c)]];
      }
      _brut = lignes;
      _fichier = choix.single.name;
      await _analyser();
    } catch (e) {
      setState(() => _message = 'Fichier illisible. Enregistrez-le au format Excel (.xlsx) ou CSV et réessayez.');
    } finally {
      if (mounted) setState(() => _travail = false);
    }
  }

  /// Contrôle les lignes du fichier contre ce qui existe dans ScolaGrid.
  Future<void> _analyser() async {
    final lignes = _brut;
    if (lignes == null) return;
    final o = widget.espace.orgId;
    final sites = await _sitesOuJInscris(o);
    final annee = await db.getOptional('SELECT id, libelle FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1', [o]);
    final classes = (await db.getAll(
            '''SELECT c.id, c.nom, c.site_id, s.code AS code_site FROM classes c JOIN sites s ON s.id = c.site_id
               JOIN annees_scolaires a ON a.id = c.annee_id AND a.en_cours = 1 WHERE c.organisation_id = ? AND c.fermee = 0''', [o]))
        .where((c) => sites.containsKey(c['site_id']));
    final existants = await db.getAll('SELECT nom, prenoms, date_naissance, ancien_matricule FROM eleves WHERE organisation_id = ?', [o]);
    final resultat = analyserImport(
      lignes: lignes,
      classes: {for (final c in classes) '${c['nom']}': c['id'] as String},
      existants: [
        for (final e in existants)
          (nom: '${e['nom']}', prenoms: '${e['prenoms']}', naissance: DateTime.tryParse('${e['date_naissance']}')),
      ],
      anciensMatricules: {
        for (final e in existants)
          if (e['ancien_matricule'] != null) '${e['ancien_matricule']}'.trim().toLowerCase(): '${e['nom']} ${e['prenoms']}',
      },
    );
    // Classes du fichier absentes de ScolaGrid : créables si leur niveau existe et a ses frais.
    final niveaux = [
      for (final n in await db.getAll('SELECT id, nom, nom_usage, series FROM niveaux WHERE organisation_id = ?', [o]))
        (id: n['id'] as String, nom: '${n['nom']}', usage: n['nom_usage'] as String?, series: n['series'] as String?),
    ];
    final absentes = classesAbsentes(resultat, niveaux);
    final blocages = <ClasseAbsente, String?>{};
    if (absentes.isNotEmpty) {
      final avecFrais = annee == null
          ? <String>{}
          : {
              for (final f in await db.getAll(
                  'SELECT DISTINCT niveau_id, site_id FROM frais WHERE annee_id = ? AND niveau_id IS NOT NULL', [annee['id']]))
                if (f['site_id'] == null || sites.containsKey(f['site_id'])) f['niveau_id'] as String,
            };
      final fermees = annee == null
          ? <String>{}
          : {
              for (final c in await db.getAll('SELECT nom FROM classes WHERE annee_id = ? AND fermee = 1', [annee['id']]))
                cleClasse('${c['nom']}'),
            };
      for (final a in absentes) {
        blocages[a] = annee == null
            ? "Il n'y a pas d'année scolaire en cours."
            : a.niveau == null
                ? "Ce niveau n'existe pas dans ScolaGrid : ajoutez-le dans Paramètres › Niveaux, puis ses frais. "
                    "Voyez l'onglet « Guide des classes » du modèle pour l'écriture."
                : a.probleme != null
                ? 'Classe mal écrite dans le fichier : ${a.probleme} Corrigez le fichier puis rechargez-le.'
                : !avecFrais.contains(a.niveau!.id)
                    ? 'Le niveau ${a.niveau!.nom} n\'a pas encore de frais : ajoutez-les dans Paramètres › Frais scolaires.'
                    : fermees.contains(cleClasse(a.nom))
                        ? 'La classe ${a.nom} a été fermée : rouvrez-la dans Paramètres › Classes.'
                        : null;
      }
    }
    if (!mounted) return;
    setState(() {
      _lignes = resultat;
      _absentes = absentes;
      _blocages = blocages;
      _sites = sites;
      _annee = annee;
      _classesParId = {for (final c in classes) c['id'] as String: Map<String, Object?>.from(c)};
      _message = resultat.isEmpty ? 'Aucune ligne lue. La première ligne doit contenir les titres des colonnes.' : null;
    });
  }

  /// Crée les classes absentes dont le niveau est prêt, puis revérifie le fichier.
  Future<void> _creerClasses(List<ClasseAbsente> aCreer) async {
    final messager = ScaffoldMessenger.of(context);
    final annee = _annee;
    final geres = {for (final s in _sites.entries) if (widget.espace.gereSite(s.key)) s.key: s.value};
    if (annee == null || aCreer.isEmpty) return;
    if (geres.isEmpty) {
      messager.showSnackBar(const SnackBar(content: Text('Seule la direction peut créer des classes. Demandez-lui de le faire.')));
      return;
    }
    var site = geres.keys.first;
    final noms = aCreer.map((a) => a.nom).join(', ');
    final ok = geres.length > 1
        ? await _formulaire(context, 'Créer des classes', (maj) => [
              Text('Seront créées pour ${annee['libelle']} : $noms'),
              _liste('Site', site, geres, (v) => maj(() => site = v)),
            ])
        : await _confirmer(context, 'Créer ${aCreer.length > 1 ? 'les classes' : 'la classe'} $noms pour l\'année ${annee['libelle']} ?');
    if (!ok) return;
    final m = _maintenant();
    await db.writeTransaction((tx) async {
      for (final a in aCreer) {
        await tx.execute(
            'INSERT INTO classes (id, organisation_id, site_id, annee_id, niveau_id, nom, serie, lettre, fermee, created_at, updated_at) '
            'VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)',
            [widget.espace.orgId, site, annee['id'], a.niveau!.id, a.nom, a.serie, a.lettre, m, m]);
      }
    });
    await _analyser();
    messager.showSnackBar(SnackBar(content: Text('${aCreer.length} classe(s) créée(s). Leurs élèves sont repris ci-dessous.')));
  }

  Future<void> _ouvrirReglage(String cle) async {
    final r = _reglages.firstWhere((r) => r.cle == cle);
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => r.ecran(widget.espace)));
    await _analyser();
  }

  /// Le modèle à remplir, en Excel : listes déroulantes (classe, sexe, type, lien),
  /// onglets « Aide » et « Classes ». Une ligne par classe de l'école (ou du modèle
  /// guinéen s'il n'y en a pas encore).
  Future<void> _telechargerModele() async {
    final messager = ScaffoldMessenger.of(context);
    final sites = await _sitesOuJInscris(widget.espace.orgId);
    final classes = [
      for (final c in await db.getAll(
          '''SELECT c.nom, c.site_id FROM classes c JOIN niveaux n ON n.id = c.niveau_id
             JOIN annees_scolaires a ON a.id = c.annee_id AND a.en_cours = 1
             WHERE c.organisation_id = ? AND c.fermee = 0 ORDER BY n.ordre, c.nom''', [widget.espace.orgId]))
        if (sites.containsKey(c['site_id'])) '${c['nom']}',
    ];
    final niveaux = [
      for (final n in await db.getAll('SELECT nom, nom_usage, series FROM niveaux WHERE organisation_id = ? ORDER BY ordre',
          [widget.espace.orgId]))
        (nom: '${n['nom']}', usage: n['nom_usage'] as String?, series: n['series'] as String?),
    ];
    try {
      await FilePicker.saveFile(
        dialogTitle: 'Enregistrer le modèle',
        fileName: 'modele-import-eleves.xlsx',
        bytes: modeleExcelPour(classes.isEmpty ? classesModeleGuineen : classes, niveauxEcole: niveaux),
      );
    } catch (_) {
      messager.showSnackBar(const SnackBar(content: Text("Impossible d'enregistrer le fichier sur cet appareil.")));
    }
  }

  Iterable<LigneImport> get _aImporter => (_lignes ?? []).where((l) =>
      l.etat == EtatLigne.valide || l.etat == EtatLigne.incomplete || (_avecDoublons && l.etat == EtatLigne.doublon));

  Future<void> _importer() async {
    final messager = ScaffoldMessenger.of(context);
    final o = widget.espace.orgId;
    final org = await db.get('SELECT code FROM organisations WHERE id = ?', [o]);
    final annee = await db.getOptional('SELECT * FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1', [o]);
    final poste = await cePoste();
    if (org['code'] == null || annee == null || poste == null ||
        _aImporter.any((l) => _classesParId[l.classeId]?['code_site'] == null)) {
      messager.showSnackBar(const SnackBar(
          content: Text("Il faut le sigle de l'école, le code du site, une année en cours et ce poste activé.")));
      return;
    }
    final lignes = _aImporter.toList();
    if (!mounted) return;
    if (!await _confirmer(context, 'Créer ${lignes.length} fiches élèves avec leur inscription ? '
        'Les matricules seront attribués par Scolagrid.')) {
      return;
    }
    setState(() => _travail = true);
    try {
      final maintenant = _maintenant();
      final aujourdhui = _date(DateTime.now());
      await db.writeTransaction((tx) async {
        // Les parents déjà connus (même téléphone) sont repris : les fratries se relient seules.
        final contacts = {
          for (final c in await tx.getAll('SELECT id, telephone FROM contacts WHERE organisation_id = ? AND telephone IS NOT NULL', [o]))
            (c['telephone'] as String).replaceAll(' ', ''): c['id'] as String,
        };
        final matricules = <String, List<String>>{};
        for (final l in lignes) {
          final classe = _classesParId[l.classeId]!;
          final prefixe = prefixeMatricule(
              sigle: org['code'] as String,
              codeSite: classe['code_site'] as String,
              annee: '${annee['libelle']}',
              lettre: poste['code'] as String);
          final deja = matricules[prefixe] ??= [
            for (final m in await tx.getAll('SELECT matricule FROM eleves WHERE matricule LIKE ?', ['$prefixe%'])) m['matricule'] as String,
            ...await derniersNumeros(tx, 'mat:$prefixe'),
          ];
          final matricule = matriculeSuivant(prefixe, deja);
          deja.add(matricule);
          await noterNumero(tx, 'mat:$prefixe', matricule);
          final eleveId = (await tx.get('SELECT uuid() AS id'))['id'] as String;
          await tx.execute(
              '''INSERT INTO eleves (id, organisation_id, matricule, matricule_etat, ancien_matricule, site_origine_id, site_id, nom, prenoms, sexe,
                   date_naissance, lieu_naissance, nationalite, quartier, date_premiere_inscription, poste_id, cree_par,
                   created_at, updated_at)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'Guinéenne', ?, ?, ?, ?, ?, ?)''',
              [
                eleveId, o, matricule, l.valeurs['matricule_etat'], l.valeurs['ancien_matricule'], classe['site_id'], classe['site_id'], l.nom, l.prenoms,
                l.sexe, l.naissance == null ? null : _date(l.naissance!), l.valeurs['lieu'], l.valeurs['quartier'], aujourdhui,
                poste['poste_id'], monId, maintenant, maintenant,
              ]);
          final tel = l.telephone == null ? null : numeroInternational(l.telephone!);
          final nomParent = l.valeurs['parent'] ?? (tel == null ? null : 'Parent de ${l.prenoms}');
          if (nomParent != null && nomParent.trim().length >= 2) {
            var contactId = tel == null ? null : contacts[tel];
            if (contactId == null) {
              contactId = (await tx.get('SELECT uuid() AS id'))['id'] as String;
              await tx.execute(
                  'INSERT INTO contacts (id, organisation_id, nom_complet, telephone, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
                  [contactId, o, nomParent.trim(), tel, maintenant, maintenant]);
              if (tel != null) contacts[tel] = contactId;
            }
            await tx.execute(
                'INSERT INTO eleves_contacts (id, organisation_id, eleve_id, contact_id, lien, tuteur_principal, responsable_financier, '
                'created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, 1, 1, ?, ?)',
                [o, eleveId, contactId, l.lien, maintenant, maintenant]);
          }
          await tx.execute(
              '''INSERT INTO inscriptions (id, organisation_id, eleve_id, annee_id, site_id, classe_id, type_admission, statut,
                   date_effective, poste_id, cree_par, created_at, updated_at)
                 VALUES (uuid(), ?, ?, ?, ?, ?, ?, 'en_attente', ?, ?, ?, ?, ?)''',
              [o, eleveId, annee['id'], classe['site_id'], l.classeId, l.type, aujourdhui, poste['poste_id'], monId, maintenant, maintenant]);
        }
      });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Import terminé'),
          content: Text('${lignes.length} élèves créés sur ce poste. Ils partent vers le serveur dès que la connexion le permet '
              '(cela peut prendre quelques minutes). Complétez ensuite les fiches incomplètes.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Compris'))],
        ),
      );
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _travail = false);
    }
  }

  /// Les classes du fichier qui n'existent pas encore : les créer, ou dire quoi faire avant.
  Widget _cadreAbsentes() {
    final pretes = [for (final a in _absentes) if (_blocages[a] == null) a];
    final direction = _sites.keys.any(widget.espace.gereSite);
    final sansNiveau = _absentes.any((a) => _blocages[a] != null && a.niveau == null);
    final sansFrais = _absentes.any((a) => _blocages[a] != null && a.niveau != null && a.probleme == null);
    final eleves = _absentes.fold<int>(0, (s, a) => s + a.eleves);
    return Card(
      color: Couleurs.attente.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Classes absentes de ScolaGrid : ${_absentes.length} ($eleves élèves)',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
              direction
                  ? 'Créez-les ici : leurs élèves seront repris sans recharger le fichier.'
                  : 'Seule la direction peut créer des classes : demandez-lui de les créer, puis revenez ici.',
              style: const TextStyle(fontSize: 13)),
          for (final a in _absentes)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('« ${a.saisie} » · ${a.eleves} élève${a.eleves > 1 ? 's' : ''}'),
              subtitle: Text(_blocages[a] ?? 'Sera créée sous le nom « ${a.nom} ».'),
              trailing: _blocages[a] == null && direction
                  ? TextButton(onPressed: _travail ? null : () => _creerClasses([a]), child: const Text('Créer'))
                  : null,
            ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (direction && pretes.length > 1)
              FilledButton.tonal(
                  onPressed: _travail ? null : () => _creerClasses(pretes), child: Text('Créer les ${pretes.length} classes')),
            if (sansNiveau && widget.espace.fondateur)
              OutlinedButton(onPressed: () => _ouvrirReglage('niveaux'), child: const Text('Ouvrir les niveaux')),
            if ((sansNiveau || sansFrais) && widget.espace.gestionnaire)
              OutlinedButton(onPressed: () => _ouvrirReglage('frais'), child: const Text('Ouvrir les frais')),
            TextButton(onPressed: _travail ? null : _analyser, child: const Text('Revérifier')),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    final l = _lignes;
    int n(EtatLigne e) => (l ?? []).where((x) => x.etat == e).length;
    Widget groupe(String titre, EtatLigne e, Color couleur) => n(e) == 0
        ? const SizedBox.shrink()
        : Card(
            child: ExpansionTile(
              leading: Icon(Icons.circle, color: couleur, size: 14),
              title: Text('$titre : ${n(e)}'),
              children: [
                for (final x in l!.where((x) => x.etat == e).take(200))
                  ListTile(
                    dense: true,
                    title: Text('Ligne ${x.numero} · ${x.nom} ${x.prenoms}'),
                    subtitle: x.remarques.isEmpty ? null : Text(x.remarques.join(' · ')),
                  ),
              ],
            ),
          );
    return _Page(
      titre: 'Importer des élèves',
      corps: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Reprenez vos élèves depuis un fichier Excel (.xlsx) ou CSV (séparé par des points-virgules ou des '
            'virgules). La première ligne contient les titres des colonnes :'),
        const SizedBox(height: 8),
        const Text('NOM · PRÉNOMS · SEXE · DATE DE NAISSANCE · LIEU DE NAISSANCE · CLASSE · TYPE · PARENT · TÉLÉPHONE · '
            "LIEN · MATRICULE D'ÉTAT · ANCIEN MATRICULE · QUARTIER",
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Seuls NOM, PRÉNOMS et CLASSE sont obligatoires. Le plus simple : téléchargez le modèle Excel. '
            'La classe, le sexe, le type et le lien se choisissent dans une liste déroulante, et l\'onglet « Aide » '
            'explique chaque colonne avec un exemple. Il y a déjà une ligne par classe de l\'école : écrivez les élèves '
            'dessus et copiez la ligne autant de fois que nécessaire (les lignes sans nom sont ignorées). Une classe '
            "absente de ScolaGrid peut être créée ici, à l'import, si son niveau et ses frais existent. Les élèves "
            'qui partagent le téléphone du parent sont reliés en fratrie. Les matricules sont attribués par ScolaGrid.'),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: _travail ? null : _choisir,
            icon: const Icon(Icons.upload_file),
            label: Text(_fichier == null ? 'Choisir le fichier (Excel ou CSV)' : 'Choisir un autre fichier'),
          ),
          OutlinedButton.icon(
            onPressed: _telechargerModele,
            icon: const Icon(Icons.download_outlined),
            label: const Text('Télécharger le modèle Excel'),
          ),
        ]),
        if (_travail) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
        if (_message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message!)),
        if (l != null && l.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('$_fichier : ${l.length} lignes lues', style: texte.titleMedium),
          const SizedBox(height: 8),
          if (_absentes.isNotEmpty) _cadreAbsentes(),
          groupe('Valides', EtatLigne.valide, Couleurs.regle),
          groupe('Incomplètes (acceptées, à compléter ensuite)', EtatLigne.incomplete, Couleurs.attente),
          groupe('Doublons probables', EtatLigne.doublon, Couleurs.attente),
          groupe('Rejetées (à corriger dans le fichier)', EtatLigne.rejetee, Couleurs.retard),
          if (n(EtatLigne.doublon) > 0)
            CheckboxListTile(
              value: _avecDoublons,
              onChanged: (v) => setState(() => _avecDoublons = v ?? false),
              title: const Text('Importer aussi les doublons probables'),
              subtitle: const Text('Seulement si ce sont des homonymes, pas le même enfant.'),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _travail || _aImporter.isEmpty ? null : _importer,
            icon: const Icon(Icons.check),
            label: Text('Importer ${_aImporter.length} élèves'),
          ),
        ],
      ]),
    );
  }
}
