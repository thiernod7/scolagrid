part of 'configuration.dart';

/// Reprise des élèves d'une école qui adopte Scolagrid, depuis un fichier
/// Excel : dépôt, contrôle, puis validation. Rien n'est écrit avant.

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
  Map<String, Object?> _classesParId = {};

  Future<void> _choisir() async {
    final choix = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    if (choix.isEmpty) return;
    setState(() {
      _travail = true;
      _message = null;
    });
    try {
      final classeur = xl.Excel.decodeBytes(await choix.single.readAsBytes());
      final feuille = classeur.tables[classeur.tables.keys.first]!;
      final lignes = [for (final r in feuille.rows) [for (final c in r) _texteCellule(c)]];
      final o = widget.espace.orgId;
      final sites = await _sitesOuJInscris(o);
      final classes = (await db.getAll(
              '''SELECT c.id, c.nom, c.site_id, s.code AS code_site FROM classes c JOIN sites s ON s.id = c.site_id
                 JOIN annees_scolaires a ON a.id = c.annee_id AND a.en_cours = 1 WHERE c.organisation_id = ?''', [o]))
          .where((c) => sites.containsKey(c['site_id']));
      final existants = await db.getAll('SELECT nom, prenoms, date_naissance FROM eleves WHERE organisation_id = ?', [o]);
      final resultat = analyserImport(
        lignes: lignes,
        classes: {for (final c in classes) nomSimplifie('${c['nom']}'): c['id'] as String},
        existants: [
          for (final e in existants)
            (nom: '${e['nom']}', prenoms: '${e['prenoms']}', naissance: DateTime.tryParse('${e['date_naissance']}')),
        ],
      );
      setState(() {
        _fichier = choix.single.name;
        _lignes = resultat;
        _classesParId = {for (final c in classes) c['id'] as String: Map<String, Object?>.from(c)};
        if (resultat.isEmpty) _message = 'Aucune ligne lue. La première ligne doit contenir les titres des colonnes.';
      });
    } catch (e) {
      setState(() => _message = 'Fichier illisible. Enregistrez-le au format Excel (.xlsx) et réessayez.');
    } finally {
      if (mounted) setState(() => _travail = false);
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
          ];
          final matricule = matriculeSuivant(prefixe, deja);
          deja.add(matricule);
          final eleveId = (await tx.get('SELECT uuid() AS id'))['id'] as String;
          await tx.execute(
              '''INSERT INTO eleves (id, organisation_id, matricule, matricule_etat, site_origine_id, site_id, nom, prenoms, sexe,
                   date_naissance, lieu_naissance, nationalite, quartier, date_premiere_inscription, poste_id, cree_par,
                   created_at, updated_at)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'Guinéenne', ?, ?, ?, ?, ?, ?)''',
              [
                eleveId, o, matricule, l.valeurs['matricule_etat'], classe['site_id'], classe['site_id'], l.nom, l.prenoms,
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
        const Text('Reprenez vos élèves depuis un fichier Excel (.xlsx). La première ligne contient les titres des colonnes :'),
        const SizedBox(height: 8),
        const Text('NOM · PRÉNOMS · SEXE · DATE DE NAISSANCE · LIEU DE NAISSANCE · CLASSE · TYPE · PARENT · TÉLÉPHONE · '
            "LIEN · MATRICULE D'ÉTAT · QUARTIER",
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Seuls NOM, PRÉNOMS et CLASSE sont obligatoires. La classe doit porter exactement le nom créé dans '
            "Scolagrid (ex. 7ème A). TYPE : Nouvelle, Réinscription (par défaut) ou Transfert. Les élèves qui partagent le "
            'téléphone du parent sont reliés en fratrie. Les matricules sont attribués par Scolagrid.'),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _travail ? null : _choisir,
          icon: const Icon(Icons.upload_file),
          label: Text(_fichier == null ? 'Choisir le fichier Excel' : 'Choisir un autre fichier'),
        ),
        if (_travail) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
        if (_message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message!)),
        if (l != null && l.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('$_fichier : ${l.length} lignes lues', style: texte.titleMedium),
          const SizedBox(height: 8),
          groupe('Valides', EtatLigne.valide, Colors.teal),
          groupe('Incomplètes (acceptées, à compléter ensuite)', EtatLigne.incomplete, Colors.amber),
          groupe('Doublons probables', EtatLigne.doublon, Colors.orange),
          groupe('Rejetées (à corriger dans le fichier)', EtatLigne.rejetee, Colors.red),
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
