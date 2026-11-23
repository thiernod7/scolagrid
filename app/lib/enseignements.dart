part of 'configuration.dart';

/// Qui enseigne quoi : une personne, une matière, une classe, du début à la fin
/// (vide : jusqu'à la fin de l'année). On termine un enseignement, on ne l'efface
/// pas (les notes déjà saisies restent valables) ; un remplaçant temporaire est un
/// enseignement de plus, avec une date de fin. Le serveur applique les mêmes
/// règles (migration 044) : l'app n'affiche que ce qu'il acceptera.

/// Ne voit que ses classes et ses matières : qui saisit des notes sans être de la
/// direction des études, du tableau de bord ou du secrétariat.
bool restreintAuxCours(Espace e) =>
    !(e.fondateur ||
        e.droits.contains('planifier_evaluations') ||
        e.droits.contains('consulter_tableau_bord') ||
        e.droits.contains('gerer_inscriptions'));

/// Mes enseignements et les classes dont je suis professeur principal.
class MesCours {
  const MesCours(this.lignes, this.classesPP);

  final Lignes lignes;
  final Set<String> classesPP;

  Set<String> get classes => {for (final l in lignes) l['classe_id'] as String, ...classesPP};

  /// Je vois cette matière dans cette classe (la mienne, ou toute ma classe de professeur principal).
  bool voit(Object? classe, Object? matiere) =>
      classesPP.contains(classe) || lignes.any((l) => l['classe_id'] == classe && l['matiere_id'] == matiere);

  /// J'y saisis aujourd'hui (7 jours de grâce après la fin, comme le serveur).
  bool saisit(Object? classe, Object? matiere) {
    final aujourdhui = _date(DateTime.now());
    final limite = _date(DateTime.now().subtract(const Duration(days: 7)));
    return lignes.any((l) =>
        l['classe_id'] == classe &&
        l['matiere_id'] == matiere &&
        '${l['debut']}'.compareTo(aujourdhui) <= 0 &&
        (l['fin'] == null || '${l['fin']}'.compareTo(limite) >= 0));
  }
}

/// Construit [suite] avec mes cours si je suis restreint (enseignant), sinon avec null.
Widget avecMesCours(Espace e, Widget Function(MesCours? cours) suite) {
  if (!restreintAuxCours(e)) return suite(null);
  return Requete(
    '''SELECT ens.classe_id, ens.matiere_id, ens.debut, ens.fin FROM enseignements ens
         JOIN personnel p ON p.id = ens.personnel_id WHERE p.user_id = ? AND p.organisation_id = ?''',
    parametres: [monId, e.orgId],
    builder: (context, lignes) => Requete(
      '''SELECT c.id FROM classes c JOIN personnel p ON p.id = c.professeur_principal_id
           WHERE p.user_id = ? AND p.organisation_id = ?''',
      parametres: [monId, e.orgId],
      builder: (context, pp) => suite(MesCours(lignes, {for (final c in pp) c['id'] as String})),
    ),
  );
}

// Direction : affecter, terminer, remplacer --------------------------------------------

/// Affecter une personne : une classe, ses matières (« maître de la classe » : toutes),
/// la date de début, et éventuellement un remplacement temporaire jusqu'à une date.
Future<void> affecterEnseignant(BuildContext context, Espace espace,
    {String? personnelId, String? classeId, String? matiereId}) async {
  final messager = ScaffoldMessenger.of(context);
  final annee = await db.getOptional('SELECT * FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1', [espace.orgId]);
  if (annee == null) {
    messager.showSnackBar(const SnackBar(content: Text("Créez d'abord l'année scolaire.")));
    return;
  }
  final classes = await db.getAll(
      '''SELECT c.id, c.nom, c.niveau_id, c.professeur_principal_id, n.cycle FROM classes c JOIN niveaux n ON n.id = c.niveau_id
         WHERE c.annee_id = ? AND c.fermee = 0 ORDER BY n.ordre, c.nom''',
      [annee['id']]);
  final personnes = await db.getAll(
      '''SELECT p.id, p.nom_complet,
           (SELECT count(*) FROM affectations a WHERE a.personnel_id = p.id AND a.actif = 1 AND a.fonction = 'enseignant') AS enseignant
         FROM personnel p WHERE p.organisation_id = ? AND p.statut = 'actif' ORDER BY enseignant DESC, p.nom_complet''',
      [espace.orgId]);
  if (!context.mounted) return;
  if (classes.isEmpty || personnes.isEmpty) {
    messager.showSnackBar(SnackBar(content: Text(classes.isEmpty ? 'Aucune classe cette année.' : 'Aucune fiche du personnel.')));
    return;
  }
  var personne = personnelId ?? (personnes.first['id'] as String);
  var classe = classeId ?? (classes.first['id'] as String);
  final choisies = <String>{if (matiereId != null) matiereId};
  var principal = false;
  var remplacement = false;
  final heures = TextEditingController();
  var debut = DateTime.now();
  final finAnnee = DateTime.tryParse('${annee['fin']}') ?? DateTime.now().add(const Duration(days: 180));
  var fin = DateTime.now().add(const Duration(days: 30));
  if (fin.isAfter(finAnnee)) fin = finAnnee;
  var matieres = <Map<String, Object?>>[];
  Future<void> chargerMatieres() async {
    final c = classes.firstWhere((x) => x['id'] == classe);
    matieres = await db.getAll('SELECT id, nom FROM matieres WHERE niveau_id = ? ORDER BY nom', [c['niveau_id']]);
    choisies.removeWhere((m) => !matieres.any((x) => x['id'] == m));
  }

  await chargerMatieres();
  if (!context.mounted) return;
  Widget date(String titre, DateTime v, ValueChanged<DateTime> change) => InkWell(
        onTap: () async {
          final d = await _choisirDate(context, v, premier: DateTime(v.year - 1), dernier: DateTime(v.year + 2));
          if (d != null) change(d);
        },
        child: InputDecorator(decoration: _champ(titre), child: Text(_dateLisible(_date(v)))),
      );
  final ok = await _formulaire(context, 'Affecter un enseignant', (maj) {
    final c = classes.firstWhere((x) => x['id'] == classe);
    final primaire = '${c['cycle']}' == 'primaire' || '${c['cycle']}' == 'maternelle';
    final toutes = matieres.isNotEmpty && choisies.length == matieres.length;
    return [
      _liste('Enseignant', personne, {for (final p in personnes) p['id'] as String: '${p['nom_complet']}'}, (v) => maj(() => personne = v)),
      _liste('Classe', classe, {for (final x in classes) x['id'] as String: '${x['nom']}'}, (v) async {
        classe = v;
        await chargerMatieres();
        maj(() {});
      }),
      const SizedBox(height: 4),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: toutes,
        onChanged: (v) => maj(() {
          if (v == true) {
            choisies.addAll(matieres.map((m) => m['id'] as String));
            if (primaire) principal = true;
          } else {
            choisies.clear();
          }
        }),
        title: Text(primaire ? 'Maître de la classe (toutes les matières)' : 'Toutes les matières'),
        subtitle: primaire ? const Text('Décochez ensuite celles confiées à un autre (anglais…)') : null,
      ),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final m in matieres)
          FilterChip(
            label: Text('${m['nom']}'),
            selected: choisies.contains(m['id']),
            onSelected: (v) => maj(() => v ? choisies.add(m['id'] as String) : choisies.remove(m['id'])),
          ),
      ]),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: principal,
        onChanged: (v) => maj(() => principal = v),
        title: const Text('Professeur principal de la classe'),
        subtitle: const Text('Voit toutes les notes de la classe, ne saisit que les siennes'),
      ),
      const SizedBox(height: 4),
      TextField(
        controller: heures,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: _champ('Heures par semaine (par matière)', aide: "Pour la paie à l'heure : 6 h de maths par semaine…"),
      ),
      date('À partir du', debut, (v) => maj(() => debut = v)),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: remplacement,
        onChanged: (v) => maj(() => remplacement = v),
        title: const Text('Remplacement temporaire'),
        subtitle: const Text("Le titulaire garde ses matières ; le remplaçant saisit jusqu'à la date de fin"),
      ),
      if (remplacement) date("Jusqu'au", fin, (v) => maj(() => fin = v)),
    ];
  }, valider: () => 'Affecter');
  if (!ok) return;
  if (choisies.isEmpty || (remplacement && fin.isBefore(debut))) {
    messager.showSnackBar(SnackBar(
        content: Text(choisies.isEmpty ? 'Choisissez au moins une matière.' : 'La date de fin doit suivre celle du début.')));
    return;
  }
  final m0 = _maintenant();
  await db.writeTransaction((tx) async {
    for (final m in choisies) {
      // Déjà affecté à cette matière, en cours : on ne double pas.
      final deja = await tx.getOptional(
          'SELECT id FROM enseignements WHERE personnel_id = ? AND classe_id = ? AND matiere_id = ? AND (fin IS NULL OR fin >= ?)',
          [personne, classe, m, _date(debut)]);
      if (deja != null) continue;
      await tx.execute(
          '''INSERT INTO enseignements (id, organisation_id, personnel_id, classe_id, matiere_id, debut, fin, remplacant, heures_semaine,
               created_at, updated_at)
             VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [espace.orgId, personne, classe, m, _date(debut), remplacement ? _date(fin) : null, remplacement ? 1 : 0,
            double.tryParse(heures.text.replaceAll(',', '.')), m0, m0]);
    }
    if (principal) {
      await tx.execute('UPDATE classes SET professeur_principal_id = ?, updated_at = ? WHERE id = ?', [personne, m0, classe]);
    }
  });
}

/// Terminer un enseignement (départ, changement) : il reste dans l'historique.
Future<void> terminerEnseignement(BuildContext context, Map<String, Object?> e) async {
  var fin = DateTime.now();
  final ok = await _formulaire(context, 'Terminer cet enseignement', (maj) => [
        Text('${e['matiere'] ?? ''} · ${e['classe'] ?? ''} : ${e['nom'] ?? ''}'),
        const SizedBox(height: 8),
        const Text("Ses notes déjà saisies restent valables. Après cette date, il ne saisit plus dans cette matière."),
        const SizedBox(height: 12),
        InkWell(
          onTap: () async {
            final d = await _choisirDate(context, fin, premier: DateTime(fin.year - 1), dernier: DateTime(fin.year + 1));
            if (d != null) maj(() => fin = d);
          },
          child: InputDecorator(decoration: _champ('Dernier jour'), child: Text(_dateLisible(_date(fin)))),
        ),
      ]);
  if (!ok) return;
  final debut = '${e['debut']}';
  if (_date(fin).compareTo(debut) < 0) {
    // Commencé après cette date : c'était une erreur, on l'enlève.
    await _supprimer('enseignements', e['id'] as String);
    return;
  }
  await _modifier('enseignements', e['id'] as String, {'fin': _date(fin)});
}

/// Les enseignements d'une fiche du personnel (bloc de sa fiche).
class EnseignementsFiche extends StatelessWidget {
  const EnseignementsFiche({super.key, required this.espace, required this.fiche, required this.peutModifier});

  final Espace espace;
  final Map<String, Object?> fiche;
  final bool peutModifier;

  @override
  Widget build(BuildContext context) => Requete(
        '''SELECT ens.*, c.nom AS classe, m.nom AS matiere, n.ordre,
             (c.professeur_principal_id = ens.personnel_id) AS principal
           FROM enseignements ens JOIN classes c ON c.id = ens.classe_id JOIN matieres m ON m.id = ens.matiere_id
           JOIN niveaux n ON n.id = c.niveau_id JOIN annees_scolaires a ON a.id = c.annee_id AND a.en_cours = 1
           WHERE ens.personnel_id = ? ORDER BY n.ordre, c.nom, m.nom''',
        parametres: [fiche['id']],
        builder: (context, lignes) {
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          final aujourdhui = _date(DateTime.now());
          final parClasse = <String, List<Map<String, Object?>>>{};
          for (final l in lignes) {
            parClasse.putIfAbsent('${l['classe']}', () => []).add(l);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('ENSEIGNEMENTS', style: TextStyle(fontSize: 12, letterSpacing: .6, color: gris))),
              if (peutModifier)
                TextButton.icon(
                  onPressed: () => affecterEnseignant(context, espace, personnelId: fiche['id'] as String),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Affecter'),
                ),
            ]),
            if (lignes.isEmpty)
              Text("Aucune classe confiée cette année : sans affectation, il ne peut saisir aucune note.",
                  style: TextStyle(fontSize: 13, color: gris)),
            for (final e in parClasse.entries)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(e.key, style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (e.value.any((l) => l['principal'] == 1)) ...[
                        const SizedBox(width: 8),
                        const Etat('Professeur principal', ton: Ton.info),
                      ],
                    ]),
                    for (final l in e.value)
                      Builder(builder: (context) {
                        final termine = l['fin'] != null && '${l['fin']}'.compareTo(aujourdhui) < 0;
                        return Row(children: [
                          Expanded(
                            child: Text.rich(TextSpan(children: [
                              TextSpan(text: '${l['matiere']}', style: TextStyle(color: termine ? gris : null)),
                              TextSpan(
                                  text: [
                                    '',
                                    if (l['remplacant'] == 1) 'remplacement',
                                    if (l['heures_semaine'] != null) '${noteLisible((l['heures_semaine'] as num).toDouble()).replaceAll(',00', '')} h/sem.',
                                    if (l['fin'] != null) '${termine ? 'terminé le' : "jusqu'au"} ${_dateLisible(l['fin'])}'
                                    else 'depuis le ${_dateLisible(l['debut'])}',
                                  ].join(' · '),
                                  style: TextStyle(fontSize: 12, color: gris)),
                            ])),
                          ),
                          if (peutModifier && !termine)
                            IconButton(
                              tooltip: 'Heures par semaine',
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.schedule, size: 18, color: gris),
                              onPressed: () async {
                                final champ = TextEditingController(
                                    text: l['heures_semaine'] == null ? '' : noteLisible((l['heures_semaine'] as num).toDouble()).replaceAll(',00', ''));
                                final ok = await _formulaire(context, '${l['matiere']} · ${l['classe']}', (maj) => [
                                      TextField(
                                          controller: champ,
                                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                          decoration: _champ('Heures par semaine')),
                                    ]);
                                if (!ok) return;
                                final h = double.tryParse(champ.text.replaceAll(',', '.'));
                                await _modifier('enseignements', l['id'] as String, {'heures_semaine': h != null && h > 0 ? h : null});
                              },
                            ),
                          if (peutModifier && !termine)
                            IconButton(
                              tooltip: 'Terminer',
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.event_busy_outlined, size: 18, color: gris),
                              onPressed: () => terminerEnseignement(context, {...l, 'nom': fiche['nom_complet']}),
                            ),
                        ]);
                      }),
                  ]),
                ),
              ),
          ]);
        },
      );
}

/// Paramètres › Évaluations › Enseignants par classe : chaque matière et son
/// enseignant, les matières sans enseignant en orange.
class EnseignantsParClasseScreen extends StatelessWidget {
  const EnseignantsParClasseScreen({super.key, required this.espace});

  final Espace espace;

  bool get _modifie => espace.gestionnaire || espace.gereMatieres;

  /// Reprendre les enseignements de l'année passée (classes de même nom), à corriger ensuite.
  Future<void> _reprendre(BuildContext context, Map<String, Object?> annee) async {
    final messager = ScaffoldMessenger.of(context);
    final avant = await db.getOptional(
        'SELECT id, libelle FROM annees_scolaires WHERE organisation_id = ? AND id <> ? AND debut < ? ORDER BY debut DESC LIMIT 1',
        [espace.orgId, annee['id'], annee['debut']]);
    if (avant == null) {
      messager.showSnackBar(const SnackBar(content: Text("Pas d'année précédente.")));
      return;
    }
    if (!context.mounted ||
        !await _confirmer(context,
            "Reprendre les enseignants de ${avant['libelle']} ? Chaque enseignant retrouve la même matière dans la classe de même nom. Vous corrigerez ensuite.")) {
      return;
    }
    final m0 = _maintenant();
    final debut = '${annee['debut']}';
    final n = await db.writeTransaction((tx) async {
      final anciens = await tx.getAll(
          '''SELECT ens.personnel_id, ens.matiere_id, c.nom AS classe, c.niveau_id FROM enseignements ens
               JOIN classes c ON c.id = ens.classe_id JOIN personnel p ON p.id = ens.personnel_id
             WHERE c.annee_id = ? AND ens.remplacant = 0 AND p.statut = 'actif' ''',
          [avant['id']]);
      var n = 0;
      for (final a in anciens) {
        final c = await tx.getOptional('SELECT id FROM classes WHERE annee_id = ? AND nom = ? AND niveau_id = ?', [annee['id'], a['classe'], a['niveau_id']]);
        if (c == null) continue;
        final deja = await tx.getOptional('SELECT 1 FROM enseignements WHERE classe_id = ? AND matiere_id = ? AND personnel_id = ?',
            [c['id'], a['matiere_id'], a['personnel_id']]);
        if (deja != null) continue;
        await tx.execute(
            '''INSERT INTO enseignements (id, organisation_id, personnel_id, classe_id, matiere_id, debut, remplacant, created_at, updated_at)
               VALUES (uuid(), ?, ?, ?, ?, ?, 0, ?, ?)''',
            [espace.orgId, a['personnel_id'], c['id'], a['matiere_id'], debut, m0, m0]);
        n++;
      }
      return n;
    });
    messager.showSnackBar(SnackBar(content: Text(n == 0 ? 'Rien à reprendre.' : '$n enseignement(s) repris.')));
  }

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT * FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1',
        parametres: [espace.orgId],
        builder: (context, annees) {
          if (annees.isEmpty) return _Page(titre: 'Enseignants par classe', corps: _vide("Créez d'abord l'année scolaire."));
          final annee = annees.first;
          return Requete(
            '''SELECT c.id AS classe_id, c.nom AS classe, n.ordre, m.id AS matiere_id, m.nom AS matiere,
                 c.professeur_principal_id AS pp, (SELECT nom_complet FROM personnel WHERE id = c.professeur_principal_id) AS nom_pp,
                 (SELECT group_concat(p.nom_complet || CASE WHEN ens.remplacant = 1 THEN ' (remplaçant)' ELSE '' END, ', ')
                    FROM enseignements ens JOIN personnel p ON p.id = ens.personnel_id
                   WHERE ens.classe_id = c.id AND ens.matiere_id = m.id
                     AND ens.debut <= date('now') AND (ens.fin IS NULL OR ens.fin >= date('now'))) AS enseignants
               FROM classes c JOIN niveaux n ON n.id = c.niveau_id JOIN matieres m ON m.niveau_id = c.niveau_id
               WHERE c.annee_id = ? AND c.fermee = 0 ORDER BY n.ordre, c.nom, m.nom''',
            parametres: [annee['id']],
            builder: (context, lignes) {
              final gris = Theme.of(context).colorScheme.onSurfaceVariant;
              final parClasse = <String, List<Map<String, Object?>>>{};
              for (final l in lignes) {
                parClasse.putIfAbsent(l['classe_id'] as String, () => []).add(l);
              }
              final trous = lignes.where((l) => l['enseignants'] == null).toList();
              return _Page(
                titre: 'Enseignants par classe',
                ajouter: _modifie ? () => affecterEnseignant(context, espace) : null,
                libelleAjouter: 'Affecter',
                corps: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: trous.isEmpty ? Couleurs.regleFond : Couleurs.attenteFond, borderRadius: BorderRadius.circular(8)),
                    child: Text(
                        trous.isEmpty
                            ? 'Chaque matière de chaque classe a son enseignant.'
                            : '${trous.length} matière(s) sans enseignant : personne ne peut y saisir de notes (sauf la direction des études).',
                        style: TextStyle(fontSize: 13, color: trous.isEmpty ? Couleurs.regle : Couleurs.attente)),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                      child: Text("Un enseignant ne voit et ne saisit que ses classes et ses matières. Touchez une matière pour l'affecter.",
                          style: TextStyle(fontSize: 12, color: gris)),
                    ),
                    if (_modifie)
                      TextButton.icon(
                        onPressed: () => _reprendre(context, annee),
                        icon: const Icon(Icons.history, size: 16),
                        label: const Text("Reprendre l'année passée"),
                      ),
                  ]),
                  const SizedBox(height: 8),
                  for (final e in parClasse.entries)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(children: [
                            Expanded(child: Text('${e.value.first['classe']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                            Text(e.value.first['nom_pp'] == null ? 'pas de professeur principal' : 'Prof. principal : ${e.value.first['nom_pp']}',
                                style: TextStyle(fontSize: 12, color: gris)),
                          ]),
                          const SizedBox(height: 4),
                          for (final l in e.value)
                            InkWell(
                              onTap: _modifie
                                  ? () => affecterEnseignant(context, espace, classeId: l['classe_id'] as String, matiereId: l['matiere_id'] as String)
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 5),
                                child: Row(children: [
                                  SizedBox(width: 180, child: Text('${l['matiere']}', overflow: TextOverflow.ellipsis)),
                                  Expanded(
                                    child: l['enseignants'] == null
                                        ? const Text('personne', style: TextStyle(color: Couleurs.attente, fontWeight: FontWeight.w600))
                                        : Text('${l['enseignants']}', overflow: TextOverflow.ellipsis),
                                  ),
                                ]),
                              ),
                            ),
                        ]),
                      ),
                    ),
                ]),
              );
            },
          );
        },
      );
}
