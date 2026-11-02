part of 'configuration.dart';

/// Niveaux (nom d'usage, examen, séries, dernier niveau) et classes de l'année
/// (nom construit, groupes d'un coup, effectifs, professeur principal,
/// fermeture avec répartition des élèves).

const _statutsPresents = "('en_attente', 'actif', 'suspendu')";

String _seriesTexte(Object? s) => '${s ?? ''}'.split(',').where((x) => x.isNotEmpty).join(', ');

// Niveaux ---------------------------------------------------------------------

class NiveauxScreen extends StatelessWidget {
  const NiveauxScreen({super.key, required this.espace});

  final Espace espace;

  Future<void> _appliquerModele(BuildContext context) async {
    final choisis = {'primaire', 'college'};
    final ok = await _formulaire(context, 'Quels cycles avez-vous ?', (maj) => [
          for (final c in cycles.entries)
            CheckboxListTile(
              value: choisis.contains(c.key),
              title: Text(c.value),
              subtitle: Text(niveauxParCycle[c.key]!.map((n) => n.nom).join(', ')),
              onChanged: (v) => maj(() => v == true ? choisis.add(c.key) : choisis.remove(c.key)),
            ),
          const Text('Noms d\'usage, examens, séries, matières et coefficients indicatifs sont ajoutés aussi. '
              'Vous pourrez tout modifier.'),
        ]);
    if (!ok || choisis.isEmpty) return;
    final maintenant = _maintenant();
    final retenus = [for (final c in cycles.keys.where(choisis.contains)) for (final n in niveauxParCycle[c]!) (c, n)];
    final dernier = retenus.last.$2.nom;
    await db.writeTransaction((tx) async {
      for (final (cycle, n) in retenus) {
        // Les tables locales de PowerSync sont des vues : pas de RETURNING, on choisit l'id avant.
        final id = (await tx.get('SELECT uuid() AS id'))['id'];
        await tx.execute(
            'INSERT INTO niveaux (id, organisation_id, cycle, nom, ordre, nom_usage, examen, series, niveau_final, created_at, updated_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [id, espace.orgId, cycle, n.nom, n.ordre, n.usage, n.examen, n.series, n.nom == dernier ? 1 : 0, maintenant, maintenant]);
        for (final m in (matieresParCycle[cycle] ?? const <String, double>{}).entries) {
          await tx.execute(
              'INSERT INTO matieres (id, organisation_id, niveau_id, nom, coefficient, created_at, updated_at) '
              'VALUES (uuid(), ?, ?, ?, ?, ?, ?)',
              [espace.orgId, id, m.key, m.value, maintenant, maintenant]);
        }
      }
    });
  }

  Future<void> _editer(BuildContext context, {Map<String, Object?>? niveau}) async {
    var cycle = '${niveau?['cycle'] ?? 'primaire'}';
    final nom = TextEditingController(text: '${niveau?['nom'] ?? ''}');
    final usage = TextEditingController(text: '${niveau?['nom_usage'] ?? ''}');
    String? examen = niveau?['examen'] as String?;
    final series = '${niveau?['series'] ?? ''}'.split(',').where((x) => x.isNotEmpty).toSet();
    var dernier = niveau?['niveau_final'] == 1;
    final ok = await _formulaire(context, niveau == null ? 'Nouveau niveau' : 'Modifier ${niveau['nom']}', (maj) => [
          if (niveau == null) _liste('Cycle', cycle, cycles, (v) => maj(() => cycle = v)),
          TextField(controller: nom, autofocus: niveau == null, decoration: _champ('Nom', aide: 'CM2, 10ème, Terminale…')),
          TextField(controller: usage, decoration: _champ("Nom d'usage (facultatif)", aide: 'Ce que disent les familles : 6ème année…')),
          _liste<String?>('Examen en fin d\'année', examen, {null: 'Aucun', ...examens}, (v) => maj(() => examen = v)),
          if (cycle == 'lycee') ...[
            const Align(alignment: Alignment.centerLeft, child: Text('Séries proposées', style: TextStyle(fontSize: 13))),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in seriesLycee.entries)
                FilterChip(
                  label: Text(s.key),
                  tooltip: s.value,
                  selected: series.contains(s.key),
                  onSelected: (v) => maj(() => v ? series.add(s.key) : series.remove(s.key)),
                ),
            ]),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: dernier,
            onChanged: (v) => maj(() => dernier = v),
            title: const Text("Dernier niveau de l'école"),
            subtitle: const Text('À la fin de ce niveau, l\'élève est « Diplômé » au lieu d\'être réinscrit.'),
          ),
        ]);
    if (!ok || nom.text.trim().isEmpty) return;
    final valeurs = <String, Object?>{
      'nom': nom.text.trim(),
      'nom_usage': usage.text.trim().isEmpty ? null : usage.text.trim(),
      'examen': examen,
      'series': cycle == 'lycee' && series.isNotEmpty ? seriesLycee.keys.where(series.contains).join(',') : null,
      'niveau_final': dernier ? 1 : 0,
    };
    final m = _maintenant();
    await db.writeTransaction((tx) async {
      // Un seul dernier niveau.
      if (dernier) {
        await tx.execute('UPDATE niveaux SET niveau_final = 0, updated_at = ? WHERE organisation_id = ? AND niveau_final = 1 AND id IS NOT ?',
            [m, espace.orgId, niveau?['id']]);
      }
      if (niveau == null) {
        final o = await tx.get('SELECT coalesce(max(ordre), 0) AS o FROM niveaux WHERE organisation_id = ?', [espace.orgId]);
        await tx.execute(
            'INSERT INTO niveaux (id, organisation_id, cycle, nom, nom_usage, examen, series, niveau_final, ordre, created_at, updated_at) '
            'VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [espace.orgId, cycle, valeurs['nom'], valeurs['nom_usage'], valeurs['examen'], valeurs['series'], valeurs['niveau_final'],
              (o['o'] as int) + 1, m, m]);
      } else {
        await tx.execute(
            'UPDATE niveaux SET nom = ?, nom_usage = ?, examen = ?, series = ?, niveau_final = ?, updated_at = ? WHERE id = ?',
            [valeurs['nom'], valeurs['nom_usage'], valeurs['examen'], valeurs['series'], valeurs['niveau_final'], m, niveau['id']]);
      }
    });
  }

  /// Frais d'examen du niveau pour l'année en cours : dû par tous ses élèves.
  Future<void> _fraisExamen(BuildContext context, Map<String, Object?> n) async {
    final montant = TextEditingController(text: n['frais_examen'] == null ? '' : '${n['frais_examen']}');
    final ok = await _formulaire(context, "Frais d'examen — ${n['nom']}", (_) => [
          Text('${examens[n['examen']] ?? n['examen']}. Dû par tous les élèves du niveau, sans qu\'on le coche.',
              style: const TextStyle(fontSize: 13)),
          TextField(
            controller: montant,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: _champ('Montant', suffixe: 'GNF', aide: 'Vide : pas de frais d\'examen'),
          ),
        ]);
    if (!ok) return;
    final v = int.tryParse(montant.text.replaceAll(RegExp(r'[^0-9]'), ''));
    if (n['frais_examen_id'] != null) {
      if (v == null || v == 0) {
        if ((n['frais_examen_payes'] as int? ?? 0) == 0) await _supprimer('frais', n['frais_examen_id'] as String);
      } else {
        await _modifier('frais', n['frais_examen_id'] as String, {'montant_gnf': v});
      }
    } else if (v != null && v > 0 && n['annee_id'] != null) {
      await _inserer('frais', {
        'organisation_id': espace.orgId,
        'annee_id': n['annee_id'],
        'niveau_id': n['id'],
        'libelle': "Frais d'examen (${n['examen']})",
        'montant_gnf': v,
        'periodicite': 'unique',
        'type_frais': 'optionnel',
        'examen': 1,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = espace.fondateur;
    return _Page(
      titre: 'Niveaux',
      ajouter: f ? () => _editer(context) : null,
      libelleAjouter: 'Niveau',
      corps: Requete('''
          SELECT n.*, a.id AS annee_id,
            (SELECT count(*) FROM classes c WHERE c.niveau_id = n.id) AS classes_toutes,
            (SELECT count(*) FROM classes c WHERE c.niveau_id = n.id AND c.annee_id = a.id AND c.fermee = 0) AS nb_classes,
            (SELECT count(*) FROM inscriptions i JOIN classes c ON c.id = i.classe_id
             WHERE c.niveau_id = n.id AND i.annee_id = a.id AND i.statut IN $_statutsPresents) AS effectif,
            (SELECT count(*) FROM inscriptions i JOIN classes c ON c.id = i.classe_id
             WHERE c.niveau_id = n.id AND i.annee_id = a.id AND i.statut IN $_statutsPresents AND i.redoublant = 1) AS redoublants,
            (SELECT fr.id FROM frais fr WHERE fr.niveau_id = n.id AND fr.annee_id = a.id AND fr.examen = 1 AND fr.site_id IS NULL LIMIT 1) AS frais_examen_id,
            (SELECT fr.montant_gnf FROM frais fr WHERE fr.niveau_id = n.id AND fr.annee_id = a.id AND fr.examen = 1 AND fr.site_id IS NULL LIMIT 1) AS frais_examen,
            (SELECT count(*) FROM lignes_encaissement l JOIN frais fr ON fr.id = l.frais_id
             WHERE fr.niveau_id = n.id AND fr.annee_id = a.id AND fr.examen = 1) AS frais_examen_payes
          FROM niveaux n
          LEFT JOIN annees_scolaires a ON a.organisation_id = n.organisation_id AND a.en_cours = 1
          WHERE n.organisation_id = ? ORDER BY n.ordre, n.nom''', parametres: [espace.orgId], builder: (context, niveaux) {
        if (niveaux.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Aucun niveau pour le moment.', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                if (f)
                  FilledButton.icon(
                    onPressed: () => _appliquerModele(context),
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('Utiliser le modèle guinéen'),
                  ),
              ]),
            ),
          );
        }
        final gris = Theme.of(context).colorScheme.onSurfaceVariant;
        final large = MediaQuery.sizeOf(context).width > 760;
        final total = niveaux.fold<int>(0, (s, n) => s + (n['effectif'] as int? ?? 0));
        final redoublants = niveaux.fold<int>(0, (s, n) => s + (n['redoublants'] as int? ?? 0));
        return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
          Text('$total élève(s) cette année · ${niveaux.length} niveaux'
              '${redoublants > 0 ? ' · $redoublants redoublant(s)' : ''}', style: TextStyle(fontSize: 13, color: gris)),
          const SizedBox(height: 10),
          Tableau(
            colonnes: [
              const ColonneTableau('Niveau', flex: 3),
              if (large) const ColonneTableau('Cycle', flex: 2),
              if (large) const ColonneTableau('Séries', flex: 2),
              const ColonneTableau('Examen', flex: 2),
              const ColonneTableau('Classes', largeur: 70, droite: true),
              const ColonneTableau('Élèves', largeur: 70, droite: true),
              if (f) const ColonneTableau('', largeur: 48),
            ],
            lignes: [
              for (final n in niveaux)
                [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      Flexible(child: Text('${n['nom']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
                      if (n['niveau_final'] == 1) ...[
                        const SizedBox(width: 6),
                        const Tooltip(message: 'Dernier niveau : ensuite Diplômé', child: Icon(Icons.school_outlined, size: 15)),
                      ],
                    ]),
                    if (n['nom_usage'] != null && n['nom_usage'] != n['nom'])
                      Text('${n['nom_usage']}', style: TextStyle(fontSize: 12, color: gris)),
                  ]),
                  if (large) Text(cycles[n['cycle']] ?? '', style: const TextStyle(fontSize: 13)),
                  if (large) Text(_seriesTexte(n['series']).isEmpty ? '—' : _seriesTexte(n['series']), style: const TextStyle(fontSize: 13)),
                  n['examen'] == null
                      ? Text('—', style: TextStyle(color: gris))
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Etat('${n['examen']}', ton: Ton.info),
                          Text(n['frais_examen'] == null ? 'frais : non fixés' : gnf(n['frais_examen']),
                              style: TextStyle(fontSize: 11, color: gris)),
                        ]),
                  Text('${n['nb_classes']}', style: styleMono.copyWith(fontSize: 13)),
                  Text('${n['effectif']}', style: styleMono.copyWith(fontSize: 13)),
                  if (f)
                    PopupMenuButton<String>(
                      tooltip: 'Actions',
                      icon: const Icon(Icons.more_horiz, size: 18),
                      onSelected: (v) async {
                        switch (v) {
                          case 'modifier':
                            await _editer(context, niveau: n);
                          case 'examen':
                            await _fraisExamen(context, n);
                          case 'supprimer':
                            if (await _confirmer(context, 'Supprimer le niveau ${n['nom']} et ses matières ?')) {
                              await _supprimer('niveaux', n['id'] as String);
                            }
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'modifier', child: Text('Modifier')),
                        if (n['examen'] != null && n['annee_id'] != null)
                          const PopupMenuItem(value: 'examen', child: Text("Frais d'examen")),
                        // Un niveau qui a déjà eu des classes reste : l'historique en dépend.
                        if ((n['classes_toutes'] as int? ?? 0) == 0) const PopupMenuItem(value: 'supprimer', child: Text('Supprimer')),
                      ],
                    ),
                ],
            ],
            onTap: f ? (i) => _editer(context, niveau: niveaux[i]) : null,
          ),
          const SizedBox(height: 10),
          Text("Les élèves d'un niveau d'examen paient ses frais d'examen d'office. "
              'Un niveau qui a déjà eu des classes ne se supprime plus.', style: TextStyle(fontSize: 12, color: gris)),
        ]);
      }),
    );
  }
}

// Classes ---------------------------------------------------------------------

/// « 7ème A », « Terminale SM B ».
String nomDeClasse(String niveau, String? serie, String? lettre) =>
    [niveau, if (serie != null) serie, if (lettre != null && lettre.isNotEmpty) lettre].join(' ');

/// Les lettres suivantes, après celles déjà prises : A, B, C…
List<String> lettresSuivantes(Iterable<String?> prises, int nombre) {
  final deja = prises.whereType<String>().toSet();
  final r = <String>[];
  for (var c = 'A'.codeUnitAt(0); r.length < nombre && c <= 'Z'.codeUnitAt(0); c++) {
    final l = String.fromCharCode(c);
    if (!deja.contains(l)) r.add(l);
  }
  return r;
}

class ClassesScreen extends StatefulWidget {
  const ClassesScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<ClassesScreen> createState() => _ClassesScreenState();
}

class _ClassesScreenState extends State<ClassesScreen> {
  String? _niveau;
  bool _fermees = false;

  /// L'année affichée : celle en cours, ou la suivante en préparation.
  String? _anneeId;
  Map<String, Object?>? _annee;

  Espace get _e => widget.espace;

  Future<Map<String, String>> _profs(String site) async => {
        for (final p in await db.getAll(
            "SELECT id, nom_complet FROM personnel WHERE organisation_id = ? AND statut = 'actif' AND (site_id IS NULL OR site_id = ?) "
            'ORDER BY nom_complet',
            [_e.orgId, site]))
          p['id'] as String: p['nom_complet'] as String,
      };

  Future<void> _creer() async {
    final annee = _annee;
    final sites = {
      for (final s in await db.getAll('SELECT id, nom FROM sites WHERE organisation_id = ? ORDER BY created_at', [_e.orgId]))
        if (_e.gereSite(s['id'] as String)) s['id'] as String: s['nom'] as String,
    };
    final niveaux = [
      for (final n in await db.getAll('SELECT id, nom, series FROM niveaux WHERE organisation_id = ? ORDER BY ordre, nom', [_e.orgId]))
        Map<String, Object?>.from(n),
    ];
    if (!mounted) return;
    if (annee == null || sites.isEmpty || niveaux.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Il faut d'abord une année scolaire en cours et des niveaux.")));
      return;
    }
    final existantes = [
      for (final c in await db.getAll('SELECT site_id, niveau_id, serie, lettre FROM classes WHERE annee_id = ?', [annee['id']]))
        Map<String, Object?>.from(c),
    ];
    if (!mounted) return;
    var site = sites.keys.first;
    var niveau = (_niveau != null && niveaux.any((n) => n['id'] == _niveau) ? _niveau : niveaux.first['id']) as String;
    String? serie;
    var nombre = 1;
    final capacite = TextEditingController();
    Map<String, Object?> nv() => niveaux.firstWhere((n) => n['id'] == niveau);
    List<String> noms() {
      final n = nv();
      final lettres = lettresSuivantes(
          existantes.where((c) => c['site_id'] == site && c['niveau_id'] == niveau && c['serie'] == serie).map((c) => c['lettre'] as String?),
          nombre);
      return [for (final l in lettres) nomDeClasse('${n['nom']}', serie, l)];
    }

    final ok = await _formulaire(context, 'Créer des classes', (maj) {
      final series = '${nv()['series'] ?? ''}'.split(',').where((x) => x.isNotEmpty).toList();
      return [
        if (sites.length > 1) _liste('Site', site, sites, (v) => maj(() => site = v)),
        _liste('Niveau', niveau, {for (final n in niveaux) n['id'] as String: '${n['nom']}'}, (v) => maj(() {
              niveau = v;
              serie = null;
            })),
        if (series.isNotEmpty)
          KeyedSubtree(
            key: ValueKey('serie-$niveau'),
            child: _liste<String?>('Série', serie, {null: 'Sans série', for (final s in series) s: '$s — ${seriesLycee[s] ?? ''}'},
                (v) => maj(() => serie = v)),
          ),
        Row(children: [
          const Expanded(child: Text('Nombre de groupes')),
          IconButton(onPressed: nombre > 1 ? () => maj(() => nombre--) : null, icon: const Icon(Icons.remove_circle_outline)),
          Text('$nombre', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          IconButton(onPressed: nombre < 10 ? () => maj(() => nombre++) : null, icon: const Icon(Icons.add_circle_outline)),
        ]),
        TextField(
          controller: capacite,
          keyboardType: TextInputType.number,
          decoration: _champ('Places par classe (facultatif)', aide: 'Au-delà, la classe passe en orange'),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Text('Seront créées : ${noms().join(', ')}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        ),
      ];
    });
    if (!ok) return;
    final cap = int.tryParse(capacite.text.trim());
    final n = nv();
    final lettres = lettresSuivantes(
        existantes.where((c) => c['site_id'] == site && c['niveau_id'] == niveau && c['serie'] == serie).map((c) => c['lettre'] as String?),
        nombre);
    final m = _maintenant();
    await db.writeTransaction((tx) async {
      for (final l in lettres) {
        await tx.execute(
            'INSERT INTO classes (id, organisation_id, site_id, annee_id, niveau_id, nom, serie, lettre, capacite, fermee, created_at, updated_at) '
            'VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)',
            [_e.orgId, site, annee['id'], niveau, nomDeClasse('${n['nom']}', serie, l), serie, l,
              cap != null && cap >= 1 && cap <= 500 ? cap : null, m, m]);
      }
    });
  }

  Future<void> _editer(Map<String, Object?> c) async {
    final nom = TextEditingController(text: '${c['nom']}');
    final salle = TextEditingController(text: '${c['salle'] ?? ''}');
    final capacite = TextEditingController(text: c['capacite'] == null ? '' : '${c['capacite']}');
    final profs = await _profs(c['site_id'] as String);
    if (!mounted) return;
    String? prof = profs.containsKey(c['professeur_principal_id']) ? c['professeur_principal_id'] as String : null;
    final ok = await _formulaire(context, 'Classe ${c['nom']}', (maj) => [
          TextField(controller: nom, decoration: _champ('Nom de la classe')),
          TextField(controller: salle, decoration: _champ('Salle (facultatif)')),
          TextField(controller: capacite, keyboardType: TextInputType.number, decoration: _champ('Places (facultatif)')),
          _liste<String?>('Professeur principal', prof, {null: 'Aucun', ...profs}, (v) => maj(() => prof = v)),
        ]);
    if (!ok || nom.text.trim().isEmpty) return;
    final cap = int.tryParse(capacite.text.trim());
    await _modifier('classes', c['id'] as String, {
      'nom': nom.text.trim(),
      'salle': salle.text.trim().isEmpty ? null : salle.text.trim(),
      'capacite': cap != null && cap >= 1 && cap <= 500 ? cap : null,
      'professeur_principal_id': prof,
    });
  }

  /// Refermer une classe : ses élèves vont d'abord dans une autre classe du
  /// même niveau, ou sont répartis entre elles (la moins chargée d'abord).
  Future<void> _refermer(Map<String, Object?> c) async {
    final effectif = c['effectif'] as int? ?? 0;
    if (effectif == 0) {
      if (await _confirmer(context, 'Refermer la classe ${c['nom']} ? Elle reste dans l\'historique et pourra être rouverte.')) {
        await _modifier('classes', c['id'] as String, {'fermee': 1});
      }
      return;
    }
    final autres = [
      for (final x in await db.getAll('''
          SELECT c.id, c.nom, c.capacite,
            (SELECT count(*) FROM inscriptions i WHERE i.classe_id = c.id AND i.statut IN $_statutsPresents) AS effectif
          FROM classes c WHERE c.annee_id = ? AND c.site_id = ? AND c.niveau_id = ? AND c.id <> ? AND c.fermee = 0
          ORDER BY c.nom''', [c['annee_id'], c['site_id'], c['niveau_id'], c['id']]))
        Map<String, Object?>.from(x),
    ];
    if (!mounted) return;
    if (autres.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${c['nom']} a $effectif élève(s) et aucune autre classe de ce niveau ne peut les accueillir. '
              'Créez-en une d\'abord.')));
      return;
    }
    String? vers; // null : répartir
    final ok = await _formulaire(context, 'Refermer ${c['nom']}', (maj) => [
          Text('$effectif élève(s) à placer avant de refermer la classe.'),
          _liste<String?>('Où vont-ils ?', vers, {
            null: 'Répartir entre ${autres.map((a) => a['nom']).join(', ')}',
            for (final a in autres) a['id'] as String: 'Tous en ${a['nom']} (${a['effectif']} élève(s))',
          }, (v) => maj(() => vers = v)),
          const Text("Chaque changement de classe est noté dans l'historique de l'élève.", style: TextStyle(fontSize: 12)),
        ]);
    if (!ok) return;
    final charge = {for (final a in autres) a['id'] as String: a['effectif'] as int? ?? 0};
    final m = _maintenant();
    await db.writeTransaction((tx) async {
      final eleves = await tx.getAll('''
          SELECT i.id FROM inscriptions i JOIN eleves e ON e.id = i.eleve_id
          WHERE i.classe_id = ? AND i.statut IN $_statutsPresents ORDER BY e.nom, e.prenoms''', [c['id']]);
      for (final i in eleves) {
        final cible = vers ?? (charge.entries.toList()..sort((a, b) => a.value.compareTo(b.value))).first.key;
        charge[cible] = charge[cible]! + 1;
        await tx.execute('UPDATE inscriptions SET classe_id = ?, updated_at = ? WHERE id = ?', [cible, m, i['id']]);
      }
      await tx.execute('UPDATE classes SET fermee = 1, updated_at = ? WHERE id = ?', [m, c['id']]);
    });
  }

  @override
  Widget build(BuildContext context) => Requete(
        "SELECT * FROM annees_scolaires WHERE organisation_id = ? AND (en_cours = 1 OR etat IN ('preparation', 'inscriptions')) ORDER BY debut",
        parametres: [_e.orgId],
        builder: (context, annees) {
          final annee = annees.where((a) => a['id'] == _anneeId).firstOrNull ??
              annees.where((a) => a['en_cours'] == 1).firstOrNull ??
              annees.firstOrNull;
          _annee = annee == null ? null : Map<String, Object?>.from(annee);
          return _Page(
            titre: annee == null ? 'Classes' : 'Classes ${annee['libelle']}',
            ajouter: _e.gestionnaire && annee != null ? _creer : null,
            libelleAjouter: 'Créer des classes',
            corps: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (annees.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Segments<String>(
                      valeur: annee!['id'] as String,
                      choix: {for (final a in annees) a['id'] as String: '${a['libelle']} · ${etatsAnnee[a['etat']] ?? ''}'},
                      onChanged: (v) => setState(() => _anneeId = v),
                    ),
                  ),
                ),
              Expanded(child: _corps(annee?['id'] as String?)),
            ]),
          );
        },
      );

  Widget _corps(String? anneeId) => anneeId == null
      ? _vide("Il faut d'abord une année scolaire en cours.")
      : Requete('''
            SELECT c.*, n.nom AS niveau, s.nom AS site, p.nom_complet AS prof,
              (SELECT count(*) FROM inscriptions i WHERE i.classe_id = c.id AND i.statut IN $_statutsPresents) AS effectif,
              (SELECT count(*) FROM inscriptions i JOIN eleves e ON e.id = i.eleve_id
               WHERE i.classe_id = c.id AND i.statut IN $_statutsPresents AND e.sexe = 'F') AS filles,
              (SELECT count(*) FROM inscriptions i JOIN eleves e ON e.id = i.eleve_id
               WHERE i.classe_id = c.id AND i.statut IN $_statutsPresents AND e.sexe = 'M') AS garcons,
              (SELECT count(*) FROM inscriptions i WHERE i.classe_id = c.id AND i.statut IN $_statutsPresents AND i.redoublant = 1) AS redoublants,
              (SELECT count(*) FROM inscriptions i WHERE i.classe_id = c.id) AS inscriptions_toutes
            FROM classes c
            JOIN annees_scolaires a ON a.id = c.annee_id AND a.id = ?
            JOIN niveaux n ON n.id = c.niveau_id
            JOIN sites s ON s.id = c.site_id
            LEFT JOIN personnel p ON p.id = c.professeur_principal_id
            WHERE c.organisation_id = ?
            ORDER BY s.created_at, n.ordre, c.nom''', parametres: [anneeId, _e.orgId], builder: (context, toutes) {
          if (toutes.isEmpty) {
            return _vide(_e.gestionnaire
                ? "Aucune classe pour l'année en cours. « Créer des classes » : un niveau, une série, le nombre de groupes."
                : "Aucune classe pour l'année en cours.");
          }
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          final large = MediaQuery.sizeOf(context).width > 760;
          final plusieursSites = toutes.map((c) => c['site_id']).toSet().length > 1;
          final niveaux = <String, String>{for (final c in toutes) c['niveau_id'] as String: '${c['niveau']}'};
          final ouvertes = toutes.where((c) => c['fermee'] != 1).toList();
          final nbFermees = toutes.length - ouvertes.length;
          final classes = toutes
              .where((c) => (_fermees || c['fermee'] != 1) && (_niveau == null || c['niveau_id'] == _niveau))
              .toList();
          int somme(String k) => ouvertes.fold<int>(0, (s, c) => s + (c[k] as int? ?? 0));
          final completes = ouvertes.where((c) => c['capacite'] != null && (c['effectif'] as int) >= (c['capacite'] as int)).length;
          final places = ouvertes.where((c) => c['capacite'] != null).fold<int>(0, (s, c) {
            final r = (c['capacite'] as int) - (c['effectif'] as int);
            return s + (r > 0 ? r : 0);
          });

          Widget effectif(Map<String, Object?> c) {
            final n = c['effectif'] as int? ?? 0;
            final cap = c['capacite'] as int?;
            if (cap == null) return Text('$n', style: styleMono.copyWith(fontSize: 13));
            final couleur = n > cap ? Couleurs.retard : (n == cap ? Couleurs.attente : null);
            return Text('$n / $cap', style: styleMono.copyWith(fontSize: 13, color: couleur, fontWeight: couleur == null ? null : FontWeight.w600));
          }

          return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
            Text(
                '${ouvertes.length} classe(s) · ${somme('effectif')} élève(s) · ${somme('filles')} F / ${somme('garcons')} G'
                '${somme('redoublants') > 0 ? ' · ${somme('redoublants')} redoublant(s)' : ''}'
                '${completes > 0 ? ' · $completes complète(s)' : ''}'
                '${places > 0 ? ' · $places place(s) libre(s)' : ''}',
                style: TextStyle(fontSize: 13, color: gris)),
            const SizedBox(height: 10),
            if (MediaQuery.sizeOf(context).width < 640)
              Row(children: [
                Expanded(
                  child: Text(niveaux[_niveau] ?? 'Tous les niveaux',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                ),
                BoutonFiltres(
                  actifs: (niveaux.containsKey(_niveau) ? 1 : 0) + (_fermees ? 1 : 0),
                  reinitialiser: () => setState(() {
                    _niveau = null;
                    _fermees = false;
                  }),
                  menus: (largeurMenu, rafraichir) => [
                    MenuCompact<String>(
                      largeur: largeurMenu,
                      valeur: niveaux.containsKey(_niveau) ? _niveau : null,
                      tous: 'Tous les niveaux',
                      choix: niveaux,
                      onChanged: (v) {
                        setState(() => _niveau = v);
                        rafraichir();
                      },
                    ),
                    if (nbFermees > 0)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('Voir les classes refermées ($nbFermees)'),
                        value: _fermees,
                        onChanged: (v) {
                          setState(() => _fermees = v);
                          rafraichir();
                        },
                      ),
                  ],
                ),
              ])
            else
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                MenuCompact<String>(
                  largeur: 180,
                  valeur: niveaux.containsKey(_niveau) ? _niveau : null,
                  tous: 'Tous les niveaux',
                  choix: niveaux,
                  onChanged: (v) => setState(() => _niveau = v),
                ),
                if (nbFermees > 0)
                  FilterChip(
                    label: Text('Refermées ($nbFermees)'),
                    selected: _fermees,
                    onSelected: (v) => setState(() => _fermees = v),
                  ),
              ]),
            const SizedBox(height: 10),
            Tableau(
              colonnes: [
                const ColonneTableau('Classe', flex: 3),
                const ColonneTableau('Effectif', largeur: 80, droite: true),
                if (large) const ColonneTableau('F / G', largeur: 70, droite: true),
                if (large) const ColonneTableau('Red.', largeur: 50, droite: true),
                if (large) const ColonneTableau('Professeur principal', flex: 3),
                const ColonneTableau('', largeur: 48),
              ],
              vide: 'Aucune classe pour ce choix.',
              lignes: [
                for (final c in classes)
                  [
                    Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        Flexible(
                          child: Text('${c['nom']}',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: c['fermee'] == 1 ? gris : null,
                                  decoration: c['fermee'] == 1 ? TextDecoration.lineThrough : null)),
                        ),
                        if (c['fermee'] == 1) ...[const SizedBox(width: 6), const Etat('Refermée')],
                      ]),
                      if (plusieursSites || c['salle'] != null || (!large && c['prof'] != null))
                        Text(
                            [
                              if (plusieursSites) c['site'],
                              if (c['salle'] != null) c['salle'],
                              if (!large && c['prof'] != null) c['prof'],
                            ].join(' · '),
                            style: TextStyle(fontSize: 12, color: gris)),
                    ]),
                    effectif(c),
                    if (large) Text('${c['filles']} / ${c['garcons']}', style: styleMono.copyWith(fontSize: 13)),
                    if (large) Text('${c['redoublants']}', style: styleMono.copyWith(fontSize: 13)),
                    if (large) Text('${c['prof'] ?? '—'}', style: TextStyle(fontSize: 13, color: c['prof'] == null ? gris : null)),
                    if (_e.gereSite(c['site_id'] as String))
                      PopupMenuButton<String>(
                        tooltip: 'Actions',
                        icon: const Icon(Icons.more_horiz, size: 18),
                        onSelected: (v) async {
                          switch (v) {
                            case 'modifier':
                              await _editer(c);
                            case 'refermer':
                              await _refermer(c);
                            case 'rouvrir':
                              await _modifier('classes', c['id'] as String, {'fermee': 0});
                            case 'supprimer':
                              if (await _confirmer(context, 'Supprimer la classe ${c['nom']} ?')) {
                                await _supprimer('classes', c['id'] as String);
                              }
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'modifier', child: Text('Modifier')),
                          if (c['fermee'] == 1)
                            const PopupMenuItem(value: 'rouvrir', child: Text('Rouvrir'))
                          else
                            const PopupMenuItem(value: 'refermer', child: Text('Refermer')),
                          // Une classe qui a eu des élèves reste dans l'historique : on la referme.
                          if ((c['inscriptions_toutes'] as int? ?? 0) == 0)
                            const PopupMenuItem(value: 'supprimer', child: Text('Supprimer')),
                        ],
                      )
                    else
                      const SizedBox(),
                  ],
              ],
              onTap: (i) => _e.gereSite(classes[i]['site_id'] as String) ? _editer(classes[i]) : null,
            ),
            const SizedBox(height: 10),
            Text('Une classe qui a eu des élèves ne se supprime pas : on la referme, après avoir réparti ses élèves.',
                style: TextStyle(fontSize: 12, color: gris)),
          ]);
        });
}
