part of 'configuration.dart';

/// Le calendrier d'une session se prépare avant qu'elle commence : pour chaque
/// classe, chaque matière reçoit sa date (et, pour une composition, son heure et
/// sa durée). La direction le remplit d'après ce que les professeurs lui
/// remettent (un professeur peut aussi programmer ses matières lui-même), puis
/// le valide et le publie : les dates sont alors figées pour les enseignants,
/// et une épreuve déplacée garde sa date prévue (serveur : migration 045).

/// « 8 h 00 (2 h) », ou rien sans heure.
String heureLisible(Object? heure, Object? duree) {
  final h = '${heure ?? ''}';
  if (h.isEmpty || h == 'null') return '';
  final p = h.split(':');
  final d = duree is int ? duree : int.tryParse('${duree ?? ''}');
  String texte(int m) => m < 60 ? '$m min' : '${m ~/ 60} h${m % 60 == 0 ? '' : ' ${(m % 60).toString().padLeft(2, '0')}'}';
  final texteDuree = d == null ? '' : ' (${texte(d)})';
  return '${int.parse(p[0])} h ${p[1]}$texteDuree';
}

const _durees = {0: 'Sans durée', 60: '1 h', 90: '1 h 30', 120: '2 h', 180: '3 h', 240: '4 h'};

class ProgrammationScreen extends StatefulWidget {
  const ProgrammationScreen({super.key, required this.espace, required this.sessionId, this.cours});

  final Espace espace;
  final String sessionId;

  /// Un enseignant : ses classes et ses matières seulement.
  final MesCours? cours;

  @override
  State<ProgrammationScreen> createState() => _ProgrammationScreenState();
}

class _ProgrammationScreenState extends State<ProgrammationScreen> {
  String _classe = '';
  bool _aProgrammer = false;

  Espace get _e => widget.espace;
  bool get _planifie => _e.fondateur || _e.droits.contains('planifier_evaluations');

  @override
  Widget build(BuildContext context) => Requete(
        '''SELECT s.*, t.libelle AS type, t.unique_par_periode, p.cycle, p.annee_id, p.libelle AS periode, p.statut AS statut_periode
             FROM sessions_evaluation s JOIN types_evaluation t ON t.id = s.type_id JOIN periodes_evaluation p ON p.id = s.periode_id
            WHERE s.id = ?''',
        parametres: [widget.sessionId],
        builder: (context, l) {
          if (l.isEmpty) return _Page(titre: 'Programmer', corps: _vide('Session introuvable.'));
          final s = l.first;
          return Requete(
            '''SELECT c.id AS classe_id, c.nom AS classe, n.ordre, m.id AS matiere_id, m.nom AS matiere,
                 (SELECT group_concat(pe.nom_complet, ', ') FROM enseignements ens JOIN personnel pe ON pe.id = ens.personnel_id
                   WHERE ens.classe_id = c.id AND ens.matiere_id = m.id AND (ens.fin IS NULL OR ens.fin >= ?)) AS enseignants
               FROM classes c JOIN niveaux n ON n.id = c.niveau_id JOIN matieres m ON m.niveau_id = c.niveau_id
              WHERE c.annee_id = ? AND n.cycle = ? AND c.fermee = 0 ORDER BY n.ordre, c.nom, m.nom''',
            parametres: [s['debut'], s['annee_id'], s['cycle']],
            builder: (context, lignes) => Requete(
              '''SELECT ev.id, ev.classe_id, ev.matiere_id, ev.date_evaluation, ev.date_prevue, ev.heure, ev.duree_min,
                   (SELECT count(*) FROM notes n WHERE n.evaluation_id = ev.id) AS notes
                 FROM evaluations ev WHERE ev.session_id = ? ORDER BY ev.date_evaluation, ev.heure''',
              parametres: [widget.sessionId],
              builder: (context, epreuves) => _contenu(context, s, lignes, epreuves),
            ),
          );
        },
      );

  /// Ce que je peux changer dans cette ligne (classe, matière).
  bool _modifiable(Map<String, Object?> s, Map<String, Object?> ligne) {
    if (s['statut'] != 'ouverte' || s['statut_periode'] != 'ouverte') return false;
    if (_planifie) return true;
    if (s['calendrier'] == 'publie') return false;
    return _e.droits.contains('saisir_notes') && (widget.cours?.saisit(ligne['classe_id'], ligne['matiere_id']) ?? false);
  }

  Widget _contenu(BuildContext context, Map<String, Object?> s, Lignes toutes, Lignes epreuves) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final cours = widget.cours;
    final lignes = cours == null ? toutes : toutes.where((l) => cours.voit(l['classe_id'], l['matiere_id'])).toList();
    final parService = <String, List<Map<String, Object?>>>{};
    for (final e in epreuves) {
      parService.putIfAbsent('${e['classe_id']}|${e['matiere_id']}', () => []).add(e);
    }
    final aujourdhui = _date(DateTime.now());
    final manquantes = [for (final l in lignes) if (!parService.containsKey('${l['classe_id']}|${l['matiere_id']}')) l];
    final enRetard = s['calendrier'] == 'preparation' && s['programmation_avant'] != null && '${s['programmation_avant']}'.compareTo(aujourdhui) < 0;
    final classes = <String, String>{for (final l in lignes) l['classe_id'] as String: '${l['classe']}'};
    final visibles = lignes
        .where((l) => (_classe.isEmpty || l['classe_id'] == _classe) && (!_aProgrammer || !parService.containsKey('${l['classe_id']}|${l['matiere_id']}')))
        .toList();
    final parClasse = <String, List<Map<String, Object?>>>{};
    for (final l in visibles) {
      parClasse.putIfAbsent(l['classe_id'] as String, () => []).add(l);
    }
    // Les professeurs qui n'ont pas encore remis leurs dates.
    final retardataires = <String>{
      for (final l in manquantes) ...'${l['enseignants'] ?? ''}'.split(', ').where((n) => n.isNotEmpty && n != 'null'),
    };

    final etat = switch (s['calendrier']) {
      'publie' => Etat('Publié le ${_dateLisible(s['publie_le'])}', ton: Ton.regle, icone: Icons.verified_outlined),
      'preparation' => Etat(
          s['programmation_avant'] == null ? 'En préparation' : 'En préparation · à programmer avant le ${_dateLisible(s['programmation_avant'])}',
          ton: enRetard ? Ton.retard : Ton.attente,
          icone: Icons.edit_calendar_outlined),
      _ => const Etat('Calendrier libre', icone: Icons.event_outlined),
    };

    return _Page(
      titre: 'Programmer · ${s['libelle']}',
      corps: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
        Text('${s['periode']} · ${s['type']} · du ${_dateLisible(s['debut'])} au ${_dateLisible(s['fin'])}', style: TextStyle(color: gris)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          etat,
          Text('${lignes.length - manquantes.length} / ${lignes.length} matières programmées',
              style: TextStyle(fontWeight: FontWeight.w600, color: manquantes.isEmpty ? Couleurs.regle : null)),
        ]),
        if (enRetard && retardataires.isNotEmpty && cours == null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Couleurs.retardFond, borderRadius: BorderRadius.circular(8)),
            child: Text('Date limite passée. Pas encore remis : ${retardataires.join(', ')}.',
                style: const TextStyle(fontSize: 13, color: Couleurs.retard)),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (classes.length > 1)
            _MenuClasse(
              largeur: 220,
              valeur: _classe,
              choix: {'': 'Toutes les classes', ...classes},
              onChanged: (v) => setState(() => _classe = v),
            ),
          FilterChip(
            label: Text('À programmer (${manquantes.length})'),
            selected: _aProgrammer,
            onSelected: (v) => setState(() => _aProgrammer = v),
          ),
          OutlinedButton.icon(
            onPressed: () => _imprimer(s, lignes, epreuves),
            icon: const Icon(Icons.print_outlined, size: 16),
            label: const Text('Imprimer'),
          ),
          if (_planifie && s['statut'] == 'ouverte' && s['calendrier'] == 'preparation')
            FilledButton.icon(
              onPressed: () => _publier(s, manquantes.length),
              icon: const Icon(Icons.verified_outlined, size: 16),
              label: const Text('Valider et publier'),
            ),
          if (_planifie && s['statut'] == 'ouverte' && s['calendrier'] == 'publie')
            TextButton.icon(
              onPressed: () async {
                if (await _confirmer(context, 'Rouvrir la préparation ? Les professeurs pourront de nouveau changer leurs dates.')) {
                  await _modifier('sessions_evaluation', s['id'] as String, {'calendrier': 'preparation', 'publie_le': null, 'publie_par': null});
                }
              },
              icon: const Icon(Icons.lock_open, size: 16),
              label: const Text('Rouvrir la préparation'),
            ),
        ]),
        const SizedBox(height: 6),
        Text(
            s['calendrier'] == 'publie'
                ? 'Publié : seule la direction des études ajoute ou déplace une épreuve ; une épreuve déplacée garde sa date prévue.'
                : "Les professeurs remettent leurs dates à la direction, qui les saisit ici (ou les professeurs, pour leurs matières). "
                    'Les notes se saisissent à partir du jour de chaque épreuve.',
            style: TextStyle(fontSize: 12, color: gris)),
        const SizedBox(height: 12),
        if (parClasse.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(lignes.isEmpty ? 'Aucune classe ni matière pour ce cycle.' : 'Tout est programmé.',
                textAlign: TextAlign.center, style: TextStyle(color: gris)),
          ),
        for (final e in parClasse.entries) _carteClasse(context, s, e.value, parService, epreuves),
      ]),
    );
  }

  Widget _carteClasse(BuildContext context, Map<String, Object?> s, Lignes lignes, Map<String, List<Map<String, Object?>>> parService, Lignes epreuves) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final classeId = lignes.first['classe_id'];
    // Les journées chargées de la classe : deux épreuves ou plus le même jour.
    final parJour = <String, int>{};
    for (final ev in epreuves.where((x) => x['classe_id'] == classeId)) {
      parJour['${ev['date_evaluation']}'] = (parJour['${ev['date_evaluation']}'] ?? 0) + 1;
    }
    final charges = parJour.entries.where((x) => x.value >= 3).map((x) => '${x.value} le ${_dateLisible(x.key).substring(0, 5)}').toList();
    final unique = s['unique_par_periode'] == 1;
    final attendues = s['epreuves_attendues'] as int?;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('${lignes.first['classe']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            if (charges.isNotEmpty) Etat('Journée chargée : ${charges.join(', ')}', ton: Ton.attente),
          ]),
          const SizedBox(height: 4),
          for (final l in lignes)
            Builder(builder: (context) {
              final siennes = parService['${l['classe_id']}|${l['matiere_id']}'] ?? const [];
              final modifiable = _modifiable(s, l);
              final encore = !unique && (attendues == null || siennes.length < attendues);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SizedBox(
                    width: 200,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${l['matiere']}', style: const TextStyle(fontWeight: FontWeight.w500)),
                      Text(l['enseignants'] == null ? 'pas d\'enseignant' : '${l['enseignants']}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: l['enseignants'] == null ? Couleurs.attente : gris)),
                    ]),
                  ),
                  for (final ev in siennes)
                    ActionChip(
                      avatar: const Icon(Icons.event, size: 16),
                      label: Text([
                        _dateLisible(ev['date_evaluation']).substring(0, 5),
                        if (heureLisible(ev['heure'], ev['duree_min']).isNotEmpty) heureLisible(ev['heure'], ev['duree_min']),
                        if (ev['date_prevue'] != null && ev['date_prevue'] != ev['date_evaluation'])
                          'prévue le ${_dateLisible(ev['date_prevue']).substring(0, 5)}',
                      ].join(' · ')),
                      onPressed: modifiable ? () => _programmer(s, l, ev) : null,
                    ),
                  if (siennes.isEmpty)
                    modifiable
                        ? FilledButton.tonalIcon(
                            onPressed: () => _programmer(s, l, null),
                            icon: const Icon(Icons.edit_calendar_outlined, size: 16),
                            label: const Text('Programmer'),
                          )
                        : const Etat('À programmer', ton: Ton.attente)
                  else if (modifiable && encore)
                    IconButton(
                      tooltip: 'Ajouter une épreuve',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _programmer(s, l, null),
                      icon: const Icon(Icons.add_circle_outline, size: 20),
                    ),
                ]),
              );
            }),
        ]),
      ),
    );
  }

  /// Fixer (ou changer) la date, l'heure et la durée d'une épreuve.
  Future<void> _programmer(Map<String, Object?> s, Map<String, Object?> l, Map<String, Object?>? ev) async {
    final messager = ScaffoldMessenger.of(context);
    final debut = DateTime.parse('${s['debut']}'), fin = DateTime.parse('${s['fin']}');
    var date = ev == null ? debut : DateTime.parse('${ev['date_evaluation']}');
    String? heure = ev?['heure'] as String?;
    var duree = ev?['duree_min'] as int? ?? 0;
    if (!_durees.containsKey(duree)) duree = 0;
    var supprimer = false;
    final compo = s['unique_par_periode'] == 1;
    final ok = await _formulaire(context, '${l['matiere']} · ${l['classe']}', (maj) => [
          Text('${s['libelle']} : du ${_dateLisible(s['debut'])} au ${_dateLisible(s['fin'])}', style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          InkWell(
            onTap: () async {
              final d = await _choisirDate(context, date, premier: debut, dernier: fin);
              if (d != null) maj(() => date = d);
            },
            child: InputDecorator(decoration: _champ('Date'), child: Text(_dateLisible(_date(date)))),
          ),
          if (date.weekday == DateTime.sunday)
            const Padding(padding: EdgeInsets.only(top: 4), child: Text('Attention : un dimanche.', style: TextStyle(color: Couleurs.attente))),
          const SizedBox(height: 8),
          InkWell(
            onTap: () async {
              final p = heure?.split(':');
              final t = await showTimePicker(
                context: context,
                initialTime: p == null ? const TimeOfDay(hour: 8, minute: 0) : TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1])),
              );
              if (t != null) maj(() => heure = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
            },
            child: InputDecorator(
              decoration: _champ(compo ? 'Heure de début' : 'Heure (facultatif)'),
              child: Row(children: [
                Expanded(child: Text(heure == null ? '—' : heureLisible(heure, null))),
                if (heure != null) InkWell(onTap: () => maj(() => heure = null), child: const Icon(Icons.close, size: 18)),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          _liste('Durée', duree, _durees, (v) => maj(() => duree = v)),
          if (ev != null && (ev['notes'] as int? ?? 0) == 0)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: supprimer,
              onChanged: (v) => maj(() => supprimer = v ?? false),
              title: const Text('Retirer cette épreuve du calendrier'),
            ),
        ], valider: () => 'Enregistrer');
    if (!ok || !mounted) return;
    if (supprimer && ev != null) {
      await _supprimer('evaluations', ev['id'] as String);
      return;
    }
    // Une journée déjà chargée pour la classe : on prévient, sans bloquer.
    final memeJour = (await db.get('SELECT count(*) AS n FROM evaluations WHERE classe_id = ? AND date_evaluation = ? AND id <> ?',
        [l['classe_id'], _date(date), ev?['id'] ?? '']))['n'] as int? ?? 0;
    if (memeJour >= 2 && mounted) {
      if (!await _confirmer(context, '$memeJour épreuves sont déjà prévues le ${_dateLisible(_date(date))} en ${l['classe']}. Maintenir ?')) return;
    }
    final m0 = _maintenant();
    try {
      if (ev == null) {
        await db.execute(
            '''INSERT INTO evaluations (id, organisation_id, periode_id, session_id, classe_id, matiere_id, type_id, date_evaluation,
                 heure, duree_min, date_prevue, cree_par, created_at, updated_at)
               VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
            [_e.orgId, s['periode_id'], s['id'], l['classe_id'], l['matiere_id'], s['type_id'], _date(date), heure, duree == 0 ? null : duree,
              s['calendrier'] == 'publie' ? _date(date) : null, monId, m0, m0]);
      } else {
        await _modifier('evaluations', ev['id'] as String, {
          'date_evaluation': _date(date),
          'heure': heure,
          'duree_min': duree == 0 ? null : duree,
          // Publié : la date prévue reste celle du calendrier.
          if (s['calendrier'] == 'publie' && ev['date_prevue'] == null) 'date_prevue': ev['date_evaluation'],
        });
      }
    } catch (_) {
      messager.showSnackBar(const SnackBar(content: Text("L'épreuve n'a pas pu être enregistrée.")));
    }
  }

  Future<void> _publier(Map<String, Object?> s, int manquantes) async {
    final ok = await _confirmer(
        context,
        '${manquantes > 0 ? '$manquantes matière(s) ne sont pas encore programmées. ' : ''}'
        'Publier le calendrier de « ${s['libelle']} » ? Les dates seront figées pour les professeurs ; '
        'la direction des études pourra encore déplacer une épreuve (la date prévue restera visible).');
    if (!ok) return;
    final m0 = _maintenant();
    await db.writeTransaction((tx) async {
      await tx.execute('UPDATE sessions_evaluation SET calendrier = ?, publie_le = ?, publie_par = ?, updated_at = ? WHERE id = ?',
          ['publie', m0, monId, m0, s['id']]);
      await tx.execute('UPDATE evaluations SET date_prevue = date_evaluation, updated_at = ? WHERE session_id = ? AND date_prevue IS NULL',
          [m0, s['id']]);
    });
  }

  Future<void> _imprimer(Map<String, Object?> s, Lignes lignes, Lignes epreuves) async {
    final noms = {for (final l in lignes) '${l['classe_id']}|${l['matiere_id']}': (l['matiere'], l['enseignants'])};
    final classes = <String, String>{
      for (final l in lignes)
        if (_classe.isEmpty || l['classe_id'] == _classe) l['classe_id'] as String: '${l['classe']}',
    };
    final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [_e.orgId]);
    final pdf = await calendriersEvaluationsPdf(
      ecole: Map.of(ecole),
      titre: '${s['libelle']}',
      fenetre: 'du ${_dateLisible(s['debut'])} au ${_dateLisible(s['fin'])}',
      classes: [
        for (final c in classes.entries)
          (
            c.value,
            [
              for (final ev in epreuves)
                if (ev['classe_id'] == c.key && noms.containsKey('${ev['classe_id']}|${ev['matiere_id']}'))
                  (
                    date: _dateLisible(ev['date_evaluation']),
                    heure: heureLisible(ev['heure'], ev['duree_min']),
                    matiere: '${noms['${ev['classe_id']}|${ev['matiere_id']}']!.$1}',
                    type: '${s['type']}',
                    enseignant: '${noms['${ev['classe_id']}|${ev['matiere_id']}']!.$2 ?? ''}',
                  ),
            ],
          ),
      ],
      images: await _imagesEcole(_e.orgId),
      pied: s['calendrier'] == 'publie'
          ? 'Calendrier publié le ${_dateLisible(s['publie_le'])}. En cas de report, la nouvelle date vous sera communiquée.'
          : 'Calendrier provisoire (en préparation).',
    );
    await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Calendrier ${s['libelle']}');
  }
}
