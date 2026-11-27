part of 'configuration.dart';

/// Évaluations › Calendrier › Programme de la classe.
///
/// Chaque enseignant choisit ses épreuves (une ou deux par mois, à la date, l'heure
/// et la durée qu'il veut) et les communique au directeur, qui les enregistre ici :
/// une évaluation (« Évaluation de novembre »), une classe, toutes ses matières en
/// lignes. Le nom de l'évaluation est une étiquette : ses dates réelles sont celles
/// de sa fenêtre (par exemple du 08/11 au 07/12). Chaque case s'enregistre aussitôt.
class ProgrammeClasseScreen extends StatefulWidget {
  const ProgrammeClasseScreen({super.key, required this.espace, this.classeId, this.sessionId});

  final Espace espace;
  final String? classeId;
  final String? sessionId;

  @override
  State<ProgrammeClasseScreen> createState() => _ProgrammeClasseScreenState();
}

class _ProgrammeClasseScreenState extends State<ProgrammeClasseScreen> {
  String? _classe;
  String? _session;
  String? _heure; // la dernière heure et la dernière durée saisies : proposées à la suivante
  int _duree = 0;

  Espace get _e => widget.espace;
  bool get _planifie => _e.fondateur || _e.droits.contains('planifier_evaluations');

  @override
  void initState() {
    super.initState();
    _classe = widget.classeId;
    _session = widget.sessionId;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Requete(
          'SELECT * FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1',
          parametres: [_e.orgId],
          builder: (context, annees) {
            if (annees.isEmpty) return _vide("Créez d'abord l'année scolaire (Paramètres).");
            final annee = annees.first;
            return Requete(
              '''SELECT c.id, c.nom, c.niveau_id, n.cycle FROM classes c JOIN niveaux n ON n.id = c.niveau_id
                 WHERE c.annee_id = ? AND c.fermee = 0 ORDER BY n.ordre, c.nom''',
              parametres: [annee['id']],
              builder: (context, classes) => Requete(
                '''SELECT s.*, t.unique_par_periode, t.poids, p.cycle, p.bareme
                     FROM sessions_evaluation s JOIN types_evaluation t ON t.id = s.type_id JOIN periodes_evaluation p ON p.id = s.periode_id
                    WHERE p.annee_id = ? ORDER BY s.debut, s.ordre''',
                parametres: [annee['id']],
                builder: (context, sessions) {
                  if (classes.isEmpty) return _vide('Aucune classe cette année.');
                  final classe = classes.firstWhere((c) => c['id'] == _classe, orElse: () => classes.first);
                  final siennes = [for (final s in sessions) if (s['cycle'] == classe['cycle']) s];
                  if (siennes.isEmpty) {
                    return _cadre(context, null, [
                      const SizedBox(height: 24),
                      _vide("Aucune évaluation pour ce cycle : ajoutez-les dans Paramètres › Périodes et évaluations."),
                    ], classes, siennes, classe);
                  }
                  final session = siennes.firstWhere((s) => s['id'] == _session, orElse: () => _sessionParDefaut(siennes));
                  return Requete(
                    '''SELECT m.id, m.nom, m.coefficient,
                         (SELECT group_concat(pe.nom_complet, ', ') FROM enseignements ens JOIN personnel pe ON pe.id = ens.personnel_id
                           WHERE ens.classe_id = ? AND ens.matiere_id = m.id AND (ens.fin IS NULL OR ens.fin >= date('now'))) AS enseignants
                       FROM matieres m WHERE m.niveau_id = ? ORDER BY m.nom''',
                    parametres: [classe['id'], classe['niveau_id']],
                    builder: (context, matieres) => Requete(
                      '''SELECT ev.*, (SELECT count(*) FROM notes n WHERE n.evaluation_id = ev.id) AS notes
                           FROM evaluations ev WHERE ev.classe_id = ? ORDER BY ev.date_evaluation, ev.heure''',
                      parametres: [classe['id']],
                      builder: (context, epreuves) => _cadre(
                          context, session, _corps(context, classe, session, matieres, epreuves), classes, siennes, classe,
                          epreuves: epreuves, matieres: matieres),
                    ),
                  );
                },
              ),
            );
          },
        ),
      );

  /// L'évaluation proposée d'abord : celle en cours, sinon la prochaine, sinon la dernière.
  Map<String, Object?> _sessionParDefaut(List<Map<String, Object?>> sessions) {
    final auj = _date(DateTime.now());
    final ouvertes = sessions.where((s) => s['statut'] == 'ouverte').toList();
    final liste = ouvertes.isEmpty ? sessions : ouvertes;
    return liste.where((s) => '${s['debut']}'.compareTo(auj) <= 0 && '${s['fin']}'.compareTo(auj) >= 0).firstOrNull ??
        liste.where((s) => '${s['debut']}'.compareTo(auj) > 0).firstOrNull ??
        liste.last;
  }

  bool _estComposition(Map<String, Object?> s) => s['unique_par_periode'] == 1;

  static String _coef(Object? c) => noteLisible(((c as num?) ?? 1).toDouble()).replaceAll(',00', '');

  // --- Le cadre : même marges que les autres pages --------------------------------------------

  Widget _cadre(BuildContext context, Map<String, Object?>? session, List<Widget> corps, Lignes classes, List<Map<String, Object?>> sessions,
      Map<String, Object?> classe,
      {Lignes epreuves = const [], Lignes matieres = const []}) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final telephone = MediaQuery.sizeOf(context).width < 700;
    final faites = session == null ? 0 : matieres.where((m) => epreuves.any((e) => e['session_id'] == session['id'] && e['matiere_id'] == m['id'])).length;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (Navigator.of(context).canPop())
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: IconButton(tooltip: 'Retour', icon: const Icon(Icons.arrow_back, size: 18), onPressed: () => Navigator.of(context).maybePop()),
                ),
              Expanded(
                child: EnTetePage(
                  titre: 'Programme de la classe',
                  sousTitre: session == null
                      ? '${classe['nom']}'
                      : '${classe['nom']} · du ${_dateLisible(session['debut'])} au ${_dateLisible(session['fin'])} · notes sur ${session['bareme']}',
                  actions: [
                    if (session != null)
                      OutlinedButton.icon(
                        onPressed: () => _imprimer(classe, session, epreuves, matieres),
                        icon: const Icon(Icons.print_outlined, size: 16),
                        label: const Text('Imprimer'),
                      ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _MenuClasse(
                largeur: telephone ? 150 : 180,
                valeur: classe['id'] as String,
                choix: {for (final c in classes) c['id'] as String: '${c['nom']}'},
                onChanged: (v) => setState(() {
                  _classe = v;
                  // Même cycle : on garde l'évaluation choisie.
                  final cycle = classes.firstWhere((c) => c['id'] == v)['cycle'];
                  if (cycle != classe['cycle']) _session = null;
                }),
              ),
              if (session != null)
                _MenuClasse(
                  largeur: telephone ? 220 : 280,
                  valeur: session['id'] as String,
                  choix: {for (final s in sessions) s['id'] as String: '${s['libelle']}${s['statut'] == 'cloturee' ? ' (clôturée)' : ''}'},
                  onChanged: (v) => setState(() => _session = v),
                ),
              if (session != null && matieres.isNotEmpty)
                Etat('$faites / ${matieres.length} matières programmées', ton: faites == matieres.length ? Ton.regle : Ton.attente),
            ]),
            const SizedBox(height: 12),
            ...corps,
            if (session != null) ...[
              const SizedBox(height: 10),
              Text(
                  "« ${session['libelle']} » est un nom : ses épreuves se placent du ${_dateLisible(session['debut'])} au ${_dateLisible(session['fin'])}. "
                  "Touchez une case pour fixer la date, l'heure et la durée ; tout s'enregistre aussitôt.",
                  style: TextStyle(fontSize: 12, color: gris)),
            ],
          ]),
        ),
      ),
    );
  }

  // --- Les matières et leurs épreuves --------------------------------------------------------

  List<Widget> _corps(BuildContext context, Map<String, Object?> classe, Map<String, Object?> session, Lignes matieres, Lignes epreuves) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    if (matieres.isEmpty) return [_vide('Aucune matière pour ce niveau (Paramètres › Matières).')];
    final compo = _estComposition(session);
    final modifiable = _planifie && session['statut'] == 'ouverte';
    final telephone = MediaQuery.sizeOf(context).width < 700;
    // Le nombre d'épreuves de la classe par jour (toutes évaluations confondues) : plus de deux, c'est beaucoup.
    final parJour = <String, int>{};
    for (final e in epreuves) {
      parJour.update('${e['date_evaluation']}', (n) => n + 1, ifAbsent: () => 1);
    }
    final cases = compo ? 1 : 2;

    List<Widget> creneaux(Map<String, Object?> m) {
      final siennes = [for (final e in epreuves) if (e['session_id'] == session['id'] && e['matiere_id'] == m['id']) e];
      return [
        for (var i = 0; i < math.max(cases, siennes.length); i++)
          _Creneau(
            epreuve: i < siennes.length ? siennes[i] : null,
            numero: i + 1,
            charge: i < siennes.length && (parJour['${siennes[i]['date_evaluation']}'] ?? 0) > 2,
            // La 2e case s'ouvre une fois la 1re remplie.
            onTap: !modifiable || (i > siennes.length) ? null : () => _editer(classe, session, m, i < siennes.length ? siennes[i] : null, siennes),
          ),
      ];
    }

    Widget etat(Map<String, Object?> m) {
      final n = epreuves.where((e) => e['session_id'] == session['id'] && e['matiere_id'] == m['id']).length;
      return n == 0 ? const Etat('À programmer', ton: Ton.attente) : Etat(n == 1 ? 'Programmée' : '$n épreuves', ton: Ton.regle);
    }

    Widget nom(Map<String, Object?> m) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('${m['nom']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          Text(m['enseignants'] == null ? 'coef ${_coef(m['coefficient'])}' : '${m['enseignants']} · coef ${_coef(m['coefficient'])}',
              overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
        ]);

    if (telephone) {
      return [
        for (final m in matieres)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [Expanded(child: nom(m)), etat(m)]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: creneaux(m)),
            ]),
          ),
      ];
    }
    return [
      Tableau(
        colonnes: [
          const ColonneTableau('Matière', flex: 3),
          ColonneTableau(compo ? 'Composition' : '1re épreuve', flex: 3),
          if (!compo) const ColonneTableau('2e épreuve (si besoin)', flex: 3),
          const ColonneTableau('État', largeur: 130),
        ],
        lignes: [
          for (final m in matieres)
            [
              nom(m),
              ...(() {
                final c = creneaux(m);
                // Plus de deux épreuves (rare) : les suivantes rejoignent la 2e colonne.
                return compo ? [c.first] : [c[0], c.length > 2 ? Wrap(spacing: 6, runSpacing: 6, children: c.sublist(1)) : c[1]];
              })(),
              etat(m),
            ],
        ],
      ),
    ];
  }

  // --- Fixer une épreuve ---------------------------------------------------------------------

  Future<void> _editer(Map<String, Object?> classe, Map<String, Object?> session, Map<String, Object?> matiere, Map<String, Object?>? ev,
      List<Map<String, Object?>> siennes) async {
    final messager = ScaffoldMessenger.of(context);
    final debut = DateTime.parse('${session['debut']}'), fin = DateTime.parse('${session['fin']}');
    DateTime dansLaFenetre(DateTime d) => d.isBefore(debut) ? debut : (d.isAfter(fin) ? fin : d);
    final auj = DateTime.now();
    var jour = ev != null
        ? DateTime.parse('${ev['date_evaluation']}')
        : dansLaFenetre(siennes.isNotEmpty ? DateTime.parse('${siennes.last['date_evaluation']}').add(const Duration(days: 7)) : DateTime(auj.year, auj.month, auj.day));
    String? heure = ev == null ? _heure : ev['heure'] as String?;
    var duree = ev == null ? _duree : (ev['duree_min'] as int? ?? 0);
    if (!_durees.containsKey(duree)) duree = 0;
    var retirer = false;
    final ok = await _formulaire(context, '${matiere['nom']} · ${classe['nom']}', (maj) => [
          Text('${session['libelle']} · du ${_dateLisible(session['debut'])} au ${_dateLisible(session['fin'])}',
              style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          InkWell(
            onTap: () async {
              final x = await _choisirDate(context, jour, premier: debut, dernier: fin);
              if (x != null) maj(() => jour = x);
            },
            child: InputDecorator(
                decoration: _champ('Date'),
                child: Text('${const ['Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche'][jour.weekday - 1]} ${_dateLisible(_date(jour))}')),
          ),
          Row(children: [
            Expanded(
              child: InkWell(
                onTap: () async {
                  final p = heure?.split(':');
                  final t = await showTimePicker(
                    context: context,
                    initialTime: p == null ? const TimeOfDay(hour: 8, minute: 0) : TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1])),
                  );
                  if (t != null) maj(() => heure = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
                },
                child: InputDecorator(
                  decoration: _champ('Heure (facultatif)'),
                  child: Row(children: [
                    Expanded(child: Text(heure == null ? '—' : heureLisible(heure, null))),
                    if (heure != null) InkWell(onTap: () => maj(() => heure = null), child: const Icon(Icons.close, size: 18)),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: _liste('Durée', duree, _durees, (v) => maj(() => duree = v))),
          ]),
          if (jour.weekday == DateTime.sunday) const Text('Attention : un dimanche.', style: TextStyle(color: Couleurs.attente)),
          if (ev != null && (ev['notes'] as int? ?? 0) == 0)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: retirer,
              onChanged: (v) => maj(() => retirer = v ?? false),
              title: const Text('Retirer cette épreuve'),
            ),
          if (ev != null && (ev['notes'] as int? ?? 0) > 0)
            Text('${ev['notes']} note(s) déjà saisie(s) : on peut la déplacer, pas la retirer.',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ], valider: () => ev == null ? 'Programmer' : 'Enregistrer');
    if (!ok) return;
    final m0 = _maintenant();
    try {
      if (ev != null && retirer) {
        await _supprimer('evaluations', ev['id'] as String);
        return;
      }
      setState(() {
        _heure = heure;
        _duree = duree;
      });
      if (ev != null) {
        await _modifier('evaluations', ev['id'] as String, {
          'date_evaluation': _date(jour),
          'heure': heure,
          'duree_min': duree == 0 ? null : duree,
          // Dates annoncées : la date prévue reste celle du calendrier.
          if (session['calendrier'] == 'publie' && ev['date_prevue'] == null) 'date_prevue': ev['date_evaluation'],
        });
        return;
      }
      await db.execute(
          '''INSERT INTO evaluations (id, organisation_id, periode_id, session_id, classe_id, matiere_id, type_id, date_evaluation,
               heure, duree_min, date_prevue, cree_par, created_at, updated_at)
             VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [_e.orgId, session['periode_id'], session['id'], classe['id'], matiere['id'], session['type_id'], _date(jour), heure,
            duree == 0 ? null : duree, session['calendrier'] == 'publie' ? _date(jour) : null, monId, m0, m0]);
    } catch (_) {
      messager.showSnackBar(const SnackBar(content: Text("L'épreuve n'a pas pu être enregistrée.")));
    }
  }

  Future<void> _imprimer(Map<String, Object?> classe, Map<String, Object?> session, Lignes epreuves, Lignes matieres) async {
    final nomMatiere = {for (final m in matieres) m['id']: '${m['nom']}'};
    final profs = {for (final m in matieres) m['id']: '${m['enseignants'] ?? ''}'};
    final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [_e.orgId]);
    final pdf = await calendriersEvaluationsPdf(
      ecole: Map.of(ecole),
      titre: '${session['libelle']}',
      fenetre: 'du ${_dateLisible(session['debut'])} au ${_dateLisible(session['fin'])}',
      classes: [
        (
          '${classe['nom']}',
          [
            for (final ev in epreuves)
              if (ev['session_id'] == session['id'])
                (
                  date: _dateLisible(ev['date_evaluation']),
                  heure: heureLisible(ev['heure'], ev['duree_min']),
                  matiere: nomMatiere[ev['matiere_id']] ?? '',
                  type: _estComposition(session) ? 'Composition' : 'Évaluation',
                  enseignant: profs[ev['matiere_id']] ?? '',
                ),
          ],
        ),
      ],
      images: await _imagesEcole(_e.orgId),
      pied: session['calendrier'] == 'publie'
          ? 'Calendrier publié le ${_dateLisible(session['publie_le'])}. En cas de report, la nouvelle date vous sera communiquée.'
          : 'Calendrier provisoire.',
    );
    await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Programme ${classe['nom']} ${session['libelle']}');
  }
}

/// Une case d'épreuve : vide (« Fixer la date »), ou la date, l'heure et la durée.
class _Creneau extends StatelessWidget {
  const _Creneau({required this.epreuve, required this.numero, required this.charge, required this.onTap});

  final Map<String, Object?>? epreuve;
  final int numero;
  final bool charge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final ev = epreuve;
    if (ev == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: onTap == null
            ? Text('—', style: TextStyle(color: gris))
            : OutlinedButton.icon(
                onPressed: onTap,
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: numero == 1 ? schema.onSurface : gris),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Fixer la date'),
              ),
      );
    }
    final d = DateTime.parse('${ev['date_evaluation']}');
    final heure = heureLisible(ev['heure'], ev['duree_min']);
    final notes = ev['notes'] as int? ?? 0;
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: Couleurs.doux(context),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('${const ['Lun.', 'Mar.', 'Mer.', 'Jeu.', 'Ven.', 'Sam.', 'Dim.'][d.weekday - 1]} ${_dateLisible(ev['date_evaluation']).substring(0, 5)}',
                    style: styleMono.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
                if (heure.isNotEmpty) Text(heure, style: TextStyle(fontSize: 12, color: gris)),
              ]),
              if (notes > 0) ...[
                const SizedBox(width: 8),
                Tooltip(message: '$notes note(s) saisie(s)', child: Icon(Icons.check_circle_outline, size: 16, color: Couleurs.regle)),
              ],
              if (charge) ...[
                const SizedBox(width: 6),
                const Tooltip(message: 'Plus de deux épreuves ce jour-là dans la classe', child: Icon(Icons.warning_amber_rounded, size: 16, color: Couleurs.attente)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
