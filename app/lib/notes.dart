part of 'configuration.dart';

/// Notes et bulletins (lot 1) : par classe et par période, les évaluations
/// (matière, type, date), la saisie des notes élève par élève, les moyennes et
/// les rangs, le bulletin de période en PDF, la clôture de la période.

const _etatsNote = {
  'absent_justifie': 'Absent justifié',
  'absent': 'Absent (compte 0)',
  'dispense': 'Dispensé',
  'non_concerne': 'Non concerné',
  'non_note': 'Non noté',
};
const _etatsCourts = {
  'absent_justifie': 'Abs. justifié',
  'absent': 'Absent · 0',
  'dispense': 'Dispensé',
  'non_concerne': 'Non concerné',
  'non_note': 'Non noté',
};

/// Une note par élève et par évaluation : le même identifiant sur tous les postes,
/// pour que deux saisies hors ligne de la même case se remplacent au lieu de se refuser.
String _idNote(String evaluation, String eleve) {
  final h = sha256.convert(utf8.encode('$evaluation|$eleve')).toString();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-a${h.substring(17, 20)}-${h.substring(20, 32)}';
}

/// Périodes proposées pour un cycle : une (maternelle), trois trimestres
/// (primaire), deux semestres (collège, lycée), dates réparties sur l'année.
List<(String, DateTime, DateTime)> _periodesParDefaut(String cycle, DateTime debut, DateTime fin) {
  final noms = switch (cycle) {
    'maternelle' => ['Année'],
    'primaire' => ['1er trimestre', '2e trimestre', '3e trimestre'],
    _ => ['1er semestre', '2e semestre'],
  };
  final jours = fin.difference(debut).inDays + 1;
  return [
    for (var i = 0; i < noms.length; i++)
      (
        noms[i],
        debut.add(Duration(days: (jours * i / noms.length).round())),
        i == noms.length - 1 ? fin : debut.add(Duration(days: (jours * (i + 1) / noms.length).round() - 1)),
      ),
  ];
}

/// « On saisit hors ligne, on ne publie pas hors ligne » (spécification §10) :
/// le rang, les bulletins et les clôtures attendent que tout soit synchronisé.
Future<bool> _synchronise() async {
  final statut = db.currentStatus;
  if (!statut.connected || statut.lastSyncedAt == null) return false;
  return (await db.getUploadQueueStats()).count == 0;
}

/// Prévient et refuse quand le poste n'est pas à jour avec le serveur.
Future<bool> _toutEstSynchronise(BuildContext context) async {
  final messager = ScaffoldMessenger.of(context);
  if (await _synchronise()) return true;
  messager.showSnackBar(const SnackBar(
      content: Text('Connectez-vous à internet et attendez la fin de l\'envoi des notes : '
          'une clôture vaut pour tous les postes, elle se fait synchronisé.')));
  return false;
}

/// Reconstruit son contenu selon l'état de la synchronisation (connecté, envois en attente).
class _SelonSynchro extends StatelessWidget {
  const _SelonSynchro({required this.builder});

  final Widget Function(BuildContext context, bool synchronise) builder;

  @override
  Widget build(BuildContext context) => StreamBuilder(
        stream: db.statusStream,
        builder: (context, _) => FutureBuilder<bool>(
          future: _synchronise(),
          builder: (context, s) => builder(context, s.data ?? false),
        ),
      );
}

const _moisNoms = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];

/// Les sessions proposées pour une période : une « Évaluation de (mois) » par mois,
/// puis la composition sur les deux dernières semaines. Même découpage que le
/// serveur (scolagrid.sessions_par_defaut, migration 041).
List<(String, DateTime, DateTime, bool)> _sessionsParDefaut(String periode, DateTime debut, DateTime fin, {required bool avecCompo}) {
  final r = <(String, DateTime, DateTime, bool)>[];
  DateTime jour(DateTime d, int plus) => DateTime(d.year, d.month, d.day + plus);
  final debutCompo = avecCompo && fin.difference(debut).inDays >= 40 ? jour(fin, -13) : jour(fin, 1);
  var curseur = debut;
  while (curseur.isBefore(debutCompo)) {
    var finMois = DateTime(curseur.year, curseur.month + 1, 0);
    final veille = jour(debutCompo, -1);
    if (finMois.isAfter(veille)) finMois = veille;
    // Un reste de moins d'une semaine rejoint le mois précédent.
    if (r.isNotEmpty && finMois.difference(curseur).inDays < 6 && finMois == veille) {
      final d = r.removeLast();
      r.add((d.$1, d.$2, finMois, false));
      break;
    }
    final nom = _moisNoms[curseur.month - 1];
    r.add(('Évaluation ${'ao'.contains(nom[0]) ? "d'" : 'de '}$nom', curseur, finMois, false));
    curseur = jour(finMois, 1);
  }
  if (!debutCompo.isAfter(fin)) r.add(('Composition du ${periode.toLowerCase()}', debutCompo, fin, true));
  return r;
}

/// Crée les sessions par défaut des périodes ouvertes qui n'en ont pas encore.
Future<void> _preparerSessions(dynamic tx, String orgId, Iterable<Map<String, Object?>> periodes) async {
  final eval = await tx.getOptional("SELECT id FROM types_evaluation WHERE organisation_id = ? AND actif = 1 AND libelle = 'Évaluation'", [orgId]);
  if (eval == null) return;
  final compo = await tx.getOptional("SELECT id FROM types_evaluation WHERE organisation_id = ? AND actif = 1 AND libelle = 'Composition'", [orgId]);
  final m0 = _maintenant();
  for (final p in periodes) {
    if (p['statut'] != 'ouverte') continue;
    if (await tx.getOptional('SELECT 1 FROM sessions_evaluation WHERE periode_id = ?', [p['id']]) != null) continue;
    final sessions = _sessionsParDefaut('${p['libelle']}', DateTime.parse('${p['debut']}'), DateTime.parse('${p['fin']}'), avecCompo: compo != null);
    for (var i = 0; i < sessions.length; i++) {
      final (libelle, d, f, estCompo) = sessions[i];
      await tx.execute(
          '''INSERT INTO sessions_evaluation (id, organisation_id, periode_id, type_id, libelle, debut, fin, ordre, statut, created_at, updated_at)
             VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, 'ouverte', ?, ?)''',
          [orgId, p['id'], estCompo ? compo!['id'] : eval['id'], libelle, _date(d), _date(f), i + 1, m0, m0]);
    }
  }
}

/// Premier usage : les types d'évaluation de l'école et les périodes des cycles de l'année.
Future<void> _preparerNotes(String orgId, Map<String, Object?> annee) async {
  final m0 = _maintenant();
  await db.writeTransaction((tx) async {
    final types = await tx.getAll('SELECT id FROM types_evaluation WHERE organisation_id = ?', [orgId]);
    if (types.isEmpty) {
      for (final (libelle, poids, compte, unique, ordre) in const [
        ('Évaluation', 1, 1, 0, 1),
        ('Composition', 2, 1, 1, 2),
        ('Examen blanc', 1, 0, 0, 3),
      ]) {
        await tx.execute(
            '''INSERT INTO types_evaluation (id, organisation_id, libelle, poids, compte, unique_par_periode, ordre, actif, created_at, updated_at)
               VALUES (uuid(), ?, ?, ?, ?, ?, ?, 1, ?, ?)''',
            [orgId, libelle, poids, compte, unique, ordre, m0, m0]);
      }
    }
    final debut = DateTime.parse('${annee['debut']}');
    final fin = DateTime.parse('${annee['fin']}');
    final cycles = await tx.getAll(
        '''SELECT DISTINCT n.cycle FROM classes c JOIN niveaux n ON n.id = c.niveau_id
           WHERE c.annee_id = ? AND n.cycle IS NOT NULL''', [annee['id']]);
    for (final c in cycles) {
      final cycle = '${c['cycle']}';
      final deja = await tx.getOptional('SELECT 1 FROM periodes_evaluation WHERE annee_id = ? AND cycle = ?', [annee['id'], cycle]);
      if (deja != null) continue;
      final periodes = _periodesParDefaut(cycle, debut, fin);
      for (var i = 0; i < periodes.length; i++) {
        final (libelle, d, f) = periodes[i];
        await tx.execute(
            '''INSERT INTO periodes_evaluation (id, organisation_id, annee_id, cycle, ordre, libelle, debut, fin, bareme, nature, statut,
                 created_at, updated_at)
               VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?, 'ouverte', ?, ?)''',
            [orgId, annee['id'], cycle, i + 1, libelle, _date(d), _date(f), cycle == 'primaire' ? 10 : 20,
              cycle == 'maternelle' ? 'appreciations' : 'numerique', m0, m0]);
      }
    }
    // Les sessions (mensuelles, puis la composition) de chaque période qui n'en a pas.
    await _preparerSessions(tx, orgId, await tx.getAll('SELECT * FROM periodes_evaluation WHERE annee_id = ?', [annee['id']]));
  });
}

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  String? _classeId;
  String? _periodeId;
  String? _sessionId; // null : toute la période
  int _onglet = 0; // 0 évaluations, 1 résultats, 2 fin d'année

  Espace get _e => widget.espace;
  bool get _planifie => _e.fondateur || _e.droits.contains('planifier_evaluations');
  bool get _saisit => _planifie || _e.droits.contains('saisir_notes');

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Requete(
          'SELECT * FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1',
          parametres: [_e.orgId],
          builder: (context, annees) {
            if (annees.isEmpty) return const Center(child: Text("Créez d'abord l'année scolaire (Paramètres)."));
            final annee = annees.first;
            return Requete(
              '''SELECT c.id, c.nom, c.niveau_id, n.cycle, n.ordre,
                   (SELECT count(*) FROM inscriptions i WHERE i.classe_id = c.id
                      AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')) AS effectif
                 FROM classes c JOIN niveaux n ON n.id = c.niveau_id
                 WHERE c.annee_id = ? ORDER BY n.ordre, c.nom''',
              parametres: [annee['id']],
              builder: (context, classes) => Requete(
                'SELECT * FROM periodes_evaluation WHERE annee_id = ? ORDER BY cycle, ordre',
                parametres: [annee['id']],
                builder: (context, periodes) => Requete(
                  '''SELECT s.*, t.libelle AS type FROM sessions_evaluation s
                       JOIN types_evaluation t ON t.id = s.type_id JOIN periodes_evaluation p ON p.id = s.periode_id
                     WHERE p.annee_id = ? ORDER BY s.debut, s.ordre''',
                  parametres: [annee['id']],
                  builder: (context, sessions) => _contenu(context, annee, classes, periodes, sessions),
                ),
              ),
            );
          },
        ),
      );

  Widget _contenu(BuildContext context, Map<String, Object?> annee, Lignes classes, Lignes toutesPeriodes, Lignes toutesSessions) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final telephone = MediaQuery.sizeOf(context).width < 640;
    if (classes.isEmpty) return const Center(child: Text('Aucune classe cette année.'));
    final classe = classes.firstWhere((c) => c['id'] == _classeId, orElse: () => classes.first);
    final cycle = '${classe['cycle'] ?? ''}';
    final periodes = toutesPeriodes.where((p) => p['cycle'] == cycle).toList();
    final aujourdhui = _date(DateTime.now());
    final periode = periodes.firstWhere((p) => p['id'] == _periodeId,
        orElse: () => periodes.firstWhere(
            (p) => '${p['debut']}'.compareTo(aujourdhui) <= 0 && '${p['fin']}'.compareTo(aujourdhui) >= 0,
            orElse: () => periodes.isEmpty ? const <String, Object?>{} : periodes.first));
    final close = periode['statut'] == 'cloturee';
    // Les sessions de la période ; aucune choisie : toute la période (bulletin officiel).
    final sessions = toutesSessions.where((x) => x['periode_id'] == periode['id']).toList();
    final session = sessions.where((x) => x['id'] == _sessionId).firstOrNull;
    final sessionClose = session != null && session['statut'] == 'cloturee';

    final enTete = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      const Text('Notes', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -.2)),
      const SizedBox(width: 4),
      _MenuClasse(
        valeur: classe['id'] as String,
        choix: {for (final c in classes) c['id'] as String: '${c['nom']} · ${c['effectif']} él.'},
        onChanged: (v) => setState(() {
          _classeId = v;
          _periodeId = null;
          _sessionId = null;
        }),
      ),
      if (periodes.isNotEmpty)
        Segments<String>(
          valeur: periode['id'] as String,
          choix: {for (final p in periodes) p['id'] as String: '${p['libelle']}${p['statut'] == 'cloturee' ? ' · close' : ''}'},
          onChanged: (v) => setState(() {
            _periodeId = v;
            _sessionId = null;
          }),
        ),
      if (_planifie)
        PopupMenuButton<String>(
          tooltip: 'Périodes, types, clôture',
          icon: const Icon(Icons.more_horiz),
          onSelected: (v) async {
            if (v == 'reglages') {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ReglagesNotesScreen(espace: _e, annee: annee)));
            } else if (v == 'cloturer' && periode.isNotEmpty) {
              await _cloturer(periode, !close);
            } else if (v == 'session' && session != null) {
              await _cloturerSession(session, !sessionClose);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'reglages', child: _ItemMenu(Icons.tune, 'Périodes, sessions et types d\'évaluation')),
            if (session != null && !close)
              PopupMenuItem(
                value: 'session',
                child: _ItemMenu(sessionClose ? Icons.lock_open : Icons.lock_outline,
                    sessionClose ? 'Rouvrir la session' : 'Clôturer la session'),
              ),
            if (periode.isNotEmpty)
              PopupMenuItem(
                value: 'cloturer',
                child: _ItemMenu(close ? Icons.lock_open : Icons.lock_outline,
                    close ? 'Rouvrir ${periode['libelle']}' : 'Clôturer ${periode['libelle']}'),
              ),
          ],
        ),
    ]);

    final Widget corps;
    if (periodes.isEmpty) {
      corps = Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Couleurs.infoFond, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Les périodes du ${cycles[cycle] ?? cycle} ne sont pas encore créées.', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text('Par défaut : 3 trimestres au primaire (notes sur 10), 2 semestres au collège et au lycée (sur 20), '
              'et les types Évaluation (poids 1), Composition (poids 2), Examen blanc (hors moyenne). Tout reste modifiable.'),
          const SizedBox(height: 12),
          if (_planifie)
            FilledButton.icon(
              onPressed: () => _preparerNotes(_e.orgId, annee),
              icon: const Icon(Icons.auto_fix_high, size: 16),
              label: const Text('Créer les périodes et les types par défaut'),
            )
          else
            const Text('La direction (droit « Planifier les évaluations ») doit les créer.'),
        ]),
      );
    } else {
      String jj(Object? d) => _dateLisible(d).substring(0, 5);
      corps = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // La session : une fenêtre de la période (« Évaluation d'octobre »), ou toute la période.
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _MenuClasse(
            largeur: telephone ? double.infinity : 320,
            valeur: session?['id'] as String? ?? '',
            choix: {
              '': 'Toute la période (bulletin officiel)',
              for (final x in sessions)
                x['id'] as String: '${x['libelle']} · ${jj(x['debut'])} → ${jj(x['fin'])}${x['statut'] == 'cloturee' ? ' · close' : ''}',
            },
            onChanged: (v) => setState(() => _sessionId = v.isEmpty ? null : v),
          ),
          OutlinedButton.icon(
            onPressed: () => _calendrier(classe, periode, session),
            icon: const Icon(Icons.calendar_month_outlined, size: 16),
            label: const Text('Calendrier'),
          ),
          if (sessions.isEmpty && _planifie && !close)
            OutlinedButton.icon(
              onPressed: () => db.writeTransaction((tx) => _preparerSessions(tx, _e.orgId, [periode])),
              icon: const Icon(Icons.auto_fix_high, size: 16),
              label: const Text('Créer les sessions (mensuelles + composition)'),
            ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Segments<int>(
              valeur: _onglet,
              choix: const {0: 'Évaluations', 1: 'Résultats', 2: 'Fin d\'année'},
              onChanged: (v) => setState(() => _onglet = v)),
          const Spacer(),
          if (close)
            const Etat('Période clôturée', ton: Ton.neutre, icone: Icons.lock_outline)
          else if (sessionClose)
            const Etat('Session clôturée', ton: Ton.neutre, icone: Icons.lock_outline),
        ]),
        const SizedBox(height: 12),
        if (_onglet == 2)
          _FinAnnee(espace: _e, annee: annee, classe: classe, periodes: periodes, peutDecider: _planifie)
        else if (_onglet == 0)
          _Evaluations(
              espace: _e, classe: classe, periode: periode, session: session, sessions: sessions, peutSaisir: _saisit && !close && !sessionClose)
        else
          _Resultats(
              espace: _e, annee: annee, classe: classe, periode: periode, session: session, peutSaisir: _saisit && !close && !sessionClose),
      ]);
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
          enTete,
          if (periode.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('${periode['libelle']} : du ${_dateLisible(periode['debut'])} au ${_dateLisible(periode['fin'])} · '
                '${periode['nature'] == 'appreciations' ? 'acquis : acquis, en cours, non acquis (pas de moyenne)' : 'notes sur ${periode['bareme']}'}',
                style: TextStyle(fontSize: 12, color: gris)),
          ],
          const SizedBox(height: 16),
          corps,
        ]),
      ),
    );
  }

  Future<void> _cloturer(Map<String, Object?> periode, bool cloturer) async {
    if (!await _toutEstSynchronise(context)) return;
    if (!mounted) return;
    final ok = await _confirmer(
        context,
        cloturer
            ? 'Clôturer « ${periode['libelle']} » ? Les notes et évaluations seront figées ; les bulletins restent imprimables. '
                'Seul le fondateur pourra rouvrir.'
            : 'Rouvrir « ${periode['libelle']} » ? Les notes redeviennent modifiables : les bulletins déjà remis pourraient changer.');
    if (!ok) return;
    await _modifier('periodes_evaluation', periode['id'] as String, {'statut': cloturer ? 'cloturee' : 'ouverte'});
  }

  /// Clôturer une session fige ses notes : ses bulletins (mensuels) peuvent sortir.
  Future<void> _cloturerSession(Map<String, Object?> session, bool cloturer) async {
    if (!await _toutEstSynchronise(context)) return;
    if (!mounted) return;
    final ok = await _confirmer(
        context,
        cloturer
            ? 'Clôturer « ${session['libelle']} » ? Ses notes seront figées et ses bulletins de session prêts à imprimer. '
                'La période, elle, reste ouverte.'
            : 'Rouvrir « ${session['libelle']} » ? Ses notes redeviennent modifiables : les bulletins de session déjà remis pourraient changer.');
    if (!ok) return;
    await _modifier('sessions_evaluation', session['id'] as String, {'statut': cloturer ? 'cloturee' : 'ouverte'});
  }

  /// Le calendrier des évaluations de la classe (session ou période), à afficher en classe.
  Future<void> _calendrier(Map<String, Object?> classe, Map<String, Object?> periode, Map<String, Object?>? session) async {
    final epreuves = await db.getAll('''
        SELECT ev.date_evaluation, m.nom AS matiere, t.libelle AS type, coalesce(pe.nom_complet, '') AS enseignant
        FROM evaluations ev JOIN matieres m ON m.id = ev.matiere_id JOIN types_evaluation t ON t.id = ev.type_id
        LEFT JOIN personnes pe ON pe.id = ev.cree_par
        WHERE ev.classe_id = ? AND ev.periode_id = ? AND (? IS NULL OR ev.session_id = ?)
        ORDER BY ev.date_evaluation, m.nom''', [classe['id'], periode['id'], session?['id'], session?['id']]);
    final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [_e.orgId]);
    final source = session ?? periode;
    final pdf = await calendrierEvaluationsPdf(
      ecole: Map.of(ecole),
      classe: '${classe['nom']}',
      titre: '${source['libelle']}',
      fenetre: 'du ${_dateLisible(source['debut'])} au ${_dateLisible(source['fin'])}',
      epreuves: [
        for (final e in epreuves)
          (date: _dateLisible(e['date_evaluation']), matiere: '${e['matiere']}', type: '${e['type']}', enseignant: '${e['enseignant']}'),
      ],
      images: await _imagesEcole(_e.orgId),
    );
    await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Calendrier ${classe['nom']} ${source['libelle']}');
  }
}

/// Les évaluations de la classe sur la période, et la création d'une évaluation.
class _Evaluations extends StatelessWidget {
  const _Evaluations({
    required this.espace,
    required this.classe,
    required this.periode,
    required this.session,
    required this.sessions,
    required this.peutSaisir,
  });

  final Espace espace;
  final Map<String, Object?> classe;
  final Map<String, Object?> periode;
  /// La session affichée (null : toute la période).
  final Map<String, Object?>? session;
  final Lignes sessions;
  final bool peutSaisir;

  Future<void> _nouvelle(BuildContext context, {String? matiereChoisie}) async {
    final messager = ScaffoldMessenger.of(context);
    final matieres = {
      for (final m in await db.getAll('SELECT id, nom FROM matieres WHERE niveau_id = ? ORDER BY nom', [classe['niveau_id']]))
        m['id'] as String: '${m['nom']}',
    };
    final types = await db.getAll('SELECT * FROM types_evaluation WHERE organisation_id = ? AND actif = 1 ORDER BY ordre', [espace.orgId]);
    if (!context.mounted) return;
    if (matieres.isEmpty) {
      messager.showSnackBar(const SnackBar(content: Text('Aucune matière pour ce niveau : ajoutez-les dans Paramètres › Matières.')));
      return;
    }
    if (types.isEmpty) {
      messager.showSnackBar(const SnackBar(content: Text("Aucun type d'évaluation : la direction doit les créer.")));
      return;
    }
    var matiere = matiereChoisie != null && matieres.containsKey(matiereChoisie) ? matiereChoisie : matieres.keys.first;
    var type = types.first['id'] as String;
    // La session : celle affichée, sinon celle qui couvre aujourd'hui, sinon la première ouverte.
    // « Hors session » (rare) reste possible, en dernier.
    final ouvertes = sessions.where((x) => x['statut'] == 'ouverte').toList();
    final aujourdhui = _date(DateTime.now());
    String sessionId = (session != null && session!['statut'] == 'ouverte')
        ? session!['id'] as String
        : (ouvertes.where((x) => '${x['debut']}'.compareTo(aujourdhui) <= 0 && '${x['fin']}'.compareTo(aujourdhui) >= 0).firstOrNull ??
                ouvertes.firstOrNull)?['id'] as String? ??
            '';
    Map<String, Object?>? laSession() => sessions.where((x) => x['id'] == sessionId).firstOrNull;
    DateTime dateDans(Map<String, Object?>? x) {
      final d = DateTime.now();
      if (x == null) return d;
      final debut = DateTime.parse('${x['debut']}'), fin = DateTime.parse('${x['fin']}');
      return d.isBefore(debut) ? debut : (d.isAfter(fin) ? fin : d);
    }
    var date = dateDans(laSession());
    final libelle = TextEditingController();
    String jj(Object? d) => _dateLisible(d).substring(0, 5);
    final ok = await _formulaire(context, 'Nouvelle évaluation · ${classe['nom']}', (maj) => [
          _liste('Matière', matiere, matieres, (v) => maj(() => matiere = v)),
          _liste('Session', sessionId, {
            for (final x in ouvertes) x['id'] as String: '${x['libelle']} · ${jj(x['debut'])} → ${jj(x['fin'])}',
            '': 'Hors session (rare : rattachée à la période)',
          }, (v) => maj(() {
            sessionId = v;
            date = dateDans(laSession());
          })),
          // Hors session seulement : le type se choisit (sinon c'est celui de la session).
          if (sessionId.isEmpty)
            _liste('Type', type, {
              for (final t in types)
                t['id'] as String: '${t['libelle']} · poids ${noteLisible((t['poids'] as num).toDouble()).replaceAll(',00', '')}'
                    '${t['compte'] == 1 ? '' : ' · hors moyenne'}',
            }, (v) => maj(() => type = v))
          else
            Text('Nature : ${laSession()?['type'] ?? ''} · date dans la fenêtre de la session',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          InkWell(
            onTap: () async {
              final x = laSession();
              final d = await _choisirDate(context, date,
                  premier: DateTime.parse('${(x ?? periode)['debut']}'), dernier: DateTime.parse('${(x ?? periode)['fin']}'));
              if (d != null) maj(() => date = d);
            },
            child: InputDecorator(
              decoration: _champ('Date').copyWith(suffixIcon: const Icon(Icons.event_outlined, size: 18)),
              child: Text(_dateLisible(_date(date))),
            ),
          ),
          TextField(controller: libelle, decoration: _champ('Libellé (facultatif)', aide: 'Par exemple : chapitre 3, fractions')),
        ], valider: () => 'Créer et saisir les notes');
    if (!ok) return;
    final laS = laSession();
    if (laS != null) type = laS['type_id'] as String;
    final t = types.firstWhere((x) => x['id'] == type, orElse: () => types.first);
    // Trop d'épreuves le même jour dans la classe : on prévient, sans bloquer.
    final memeJour = (await db.get('SELECT count(*) AS n FROM evaluations WHERE classe_id = ? AND date_evaluation = ?',
        [classe['id'], _date(date)]))['n'] as int? ?? 0;
    if (memeJour >= 2 && context.mounted) {
      if (!await _confirmer(context,
          '$memeJour évaluations sont déjà prévues le ${_dateLisible(_date(date))} en ${classe['nom']}. Maintenir cette date ?')) {
        return;
      }
    }
    if (t['unique_par_periode'] == 1) {
      final deja = await db.getOptional(
          'SELECT 1 FROM evaluations WHERE periode_id = ? AND classe_id = ? AND matiere_id = ? AND type_id = ?',
          [periode['id'], classe['id'], matiere, type]);
      if (deja != null) {
        messager.showSnackBar(SnackBar(content: Text('« ${t['libelle']} » : une seule par période et par matière.')));
        return;
      }
    }
    final id = (await db.get('SELECT uuid() AS id'))['id'] as String;
    final m0 = _maintenant();
    await db.execute(
        '''INSERT INTO evaluations (id, organisation_id, periode_id, session_id, classe_id, matiere_id, type_id, date_evaluation, libelle,
             cree_par, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [id, espace.orgId, periode['id'], laS?['id'], classe['id'], matiere, type, _date(date),
          libelle.text.trim().isEmpty ? null : libelle.text.trim(), monId, m0, m0]);
    if (context.mounted) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _SaisieNotesScreen(espace: espace, evaluationId: id)));
    }
  }

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT id, nom, coefficient FROM matieres WHERE niveau_id = ? ORDER BY nom',
        parametres: [classe['niveau_id']],
        builder: (context, matieres) => Requete(
          '''SELECT ev.*, t.libelle AS type, t.compte, t.poids, s.libelle AS session, s.statut AS statut_session,
               coalesce((SELECT r.delai_remise_jours FROM regles_notes r WHERE r.organisation_id = ev.organisation_id), 15) AS delai,
               (SELECT count(*) FROM notes n WHERE n.evaluation_id = ev.id AND n.etat <> 'non_note') AS saisies,
               (SELECT avg(n.valeur) FROM notes n WHERE n.evaluation_id = ev.id AND n.etat = 'note') AS moyenne
             FROM evaluations ev JOIN types_evaluation t ON t.id = ev.type_id
             LEFT JOIN sessions_evaluation s ON s.id = ev.session_id
             WHERE ev.classe_id = ? AND ev.periode_id = ? AND (? IS NULL OR ev.session_id = ?)
             ORDER BY ev.date_evaluation, ev.created_at''',
          parametres: [classe['id'], periode['id'], session?['id'], session?['id']],
          builder: (context, evaluations) => _contenu(context, matieres, evaluations),
        ),
      );

  Widget _contenu(BuildContext context, Lignes matieres, Lignes evaluations) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    final telephone = MediaQuery.sizeOf(context).width < 640;
    final effectif = classe['effectif'] as int? ?? 0;
    final bareme = periode['bareme'] as int? ?? 20;
    final aCompleter = evaluations.where((e) => (e['saisies'] as int? ?? 0) < effectif).length;
    if (matieres.isEmpty) {
      return Text('Aucune matière pour ce niveau : ajoutez-les dans Paramètres › Matières.', style: TextStyle(color: gris));
    }

    Widget ligneEvaluation(Map<String, Object?> ev) {
      final saisies = ev['saisies'] as int? ?? 0;
      final complet = effectif > 0 && saisies >= effectif;
      final moy = (ev['moyenne'] as num?)?.toDouble();
      return InkWell(
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => _SaisieNotesScreen(espace: espace, evaluationId: ev['id'] as String))),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            SizedBox(
              width: telephone ? 52 : 92,
              child: Text(telephone ? '${_dateLisible(ev['date_evaluation'])}'.substring(0, 5) : _dateLisible(ev['date_evaluation']),
                  style: _chiffresDep.copyWith(fontSize: 13, color: gris)),
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${ev['libelle'] ?? ev['type']}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                Text(
                    [
                      // La session dit « quand », le type dit la nature et le poids.
                      if (session == null) '${ev['session'] ?? 'Hors session'}',
                      '${ev['type']}',
                      if ((ev['poids'] as num? ?? 1) != 1) 'poids ${noteLisible((ev['poids'] as num).toDouble()).replaceAll(',00', '')}',
                      if (ev['compte'] != 1) 'hors moyenne',
                      if (ev['statut_session'] == 'cloturee') 'session close',
                    ].join(' · '),
                    style: TextStyle(fontSize: 12, color: gris)),
                // La remise des notes : rendue, attendue, ou en retard (délai de l'école après l'épreuve).
                Builder(builder: (context) {
                  if (ev['remise_le'] != null) {
                    return const Text('notes remises', style: TextStyle(fontSize: 11, color: Couleurs.regle));
                  }
                  final date = DateTime.tryParse('${ev['date_evaluation']}');
                  final delai = ev['delai'] as int? ?? 15;
                  final retard = date == null ? 0 : DateTime.now().difference(date).inDays - delai;
                  return Text(retard > 0 ? 'remise en retard de $retard jour(s)' : 'notes à remettre',
                      style: TextStyle(fontSize: 11, color: retard > 0 ? Couleurs.retard : Couleurs.attente));
                }),
              ]),
            ),
            SizedBox(
              width: telephone ? 64 : 120,
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('$saisies / $effectif', style: TextStyle(fontSize: 12, color: complet ? Couleurs.regle : Couleurs.attente)),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: effectif == 0 ? 0 : (saisies / effectif).clamp(0, 1).toDouble(),
                    minHeight: 4,
                    backgroundColor: Couleurs.doux(context),
                    color: complet ? Couleurs.regle : Couleurs.attente,
                  ),
                ),
              ]),
            ),
            SizedBox(
              width: telephone ? 56 : 96,
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(noteLisible(moy), style: _chiffresDep.copyWith(fontSize: 14, fontWeight: FontWeight.w600,
                    color: moy == null ? gris : (moy < bareme / 2 ? Couleurs.retard : null))),
                if (!telephone) Text('moy. classe', style: TextStyle(fontSize: 11, color: gris)),
              ]),
            ),
            Icon(Icons.chevron_right, size: 18, color: gris),
          ]),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Text(
              '${evaluations.length} évaluation(s) · $effectif élève(s)'
              '${aCompleter > 0 ? ' · $aCompleter à compléter' : ''}',
              style: TextStyle(fontSize: 14, color: aCompleter > 0 ? Couleurs.attente : gris)),
        ),
        if (peutSaisir)
          FilledButton.icon(onPressed: () => _nouvelle(context), icon: const Icon(Icons.add, size: 16), label: const Text('Nouvelle évaluation')),
      ]),
      const SizedBox(height: 12),
      // Une carte par matière : ses évaluations dans l'ordre, la saisie et la moyenne de chacune.
      for (final m in matieres)
        Builder(builder: (context) {
          final siennes = evaluations.where((e) => e['matiere_id'] == m['id']).toList();
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: bordure)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                color: Couleurs.doux(context).withValues(alpha: .5),
                child: Row(children: [
                  Expanded(
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: '${m['nom']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      TextSpan(
                          text: '  coef. ${noteLisible((m['coefficient'] as num? ?? 1).toDouble()).replaceAll(',00', '')}'
                              ' · ${siennes.length} évaluation(s)',
                          style: TextStyle(fontSize: 12, color: gris)),
                      if (session?['epreuves_attendues'] != null && siennes.length < (session!['epreuves_attendues'] as int))
                        TextSpan(
                            text: ' · ${session!['epreuves_attendues']} attendue(s)',
                            style: const TextStyle(fontSize: 12, color: Couleurs.attente, fontWeight: FontWeight.w600)),
                    ])),
                  ),
                  if (peutSaisir)
                    TextButton.icon(
                      onPressed: () => _nouvelle(context, matiereChoisie: m['id'] as String),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Ajouter'),
                    ),
                ]),
              ),
              if (siennes.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text(session == null ? 'Aucune évaluation sur cette période.' : 'Aucune évaluation dans cette session.',
                      style: TextStyle(fontSize: 13, color: gris)),
                ),
              for (var i = 0; i < siennes.length; i++) ...[
                if (i > 0) Divider(height: 1, color: bordure),
                ligneEvaluation(siennes[i]),
              ],
            ]),
          );
        }),
    ]);
  }
}

/// Choix de la classe : un menu sans case vide (toujours une classe choisie).
class _MenuClasse extends StatelessWidget {
  const _MenuClasse({required this.valeur, required this.choix, required this.onChanged, this.largeur = 210});

  final double largeur;

  final String valeur;
  final Map<String, String> choix;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return Container(
      height: 36,
      width: largeur,
      padding: const EdgeInsets.only(left: 12, right: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
        color: schema.surface,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: valeur,
          isExpanded: true,
          isDense: true,
          icon: Icon(Icons.keyboard_arrow_down, size: 18, color: schema.onSurfaceVariant),
          style: TextStyle(fontFamily: policeTexte, fontSize: 14, color: schema.onSurface),
          items: [for (final c in choix.entries) DropdownMenuItem(value: c.key, child: Text(c.value, overflow: TextOverflow.ellipsis))],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

/// La saisie des notes d'une évaluation : un élève par ligne, enregistré au fil de la frappe.
class _SaisieNotesScreen extends StatefulWidget {
  const _SaisieNotesScreen({required this.espace, required this.evaluationId});

  final Espace espace;
  final String evaluationId;

  @override
  State<_SaisieNotesScreen> createState() => _SaisieNotesScreenState();
}

class _SaisieNotesScreenState extends State<_SaisieNotesScreen> {
  /// Session clôturée : une correction demande un motif, gardé dans l'historique.
  String? _motif;
  final _champs = <String, TextEditingController>{};
  final _focus = <String, FocusNode>{};
  final _erreurs = <String, String>{};

  @override
  void dispose() {
    for (final c in _champs.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _enregistrer(Map<String, Object?> ev, String eleveId, {double? valeur, String? acquis, required String etat}) async {
    final id = _idNote(widget.evaluationId, eleveId);
    final existe = await db.getOptional('SELECT 1 FROM notes WHERE id = ?', [id]);
    final m0 = _maintenant();
    if (existe != null) {
      await db.execute('UPDATE notes SET valeur = ?, acquis = ?, etat = ?, motif = ?, saisi_par = ?, updated_at = ? WHERE id = ?',
          [etat == 'note' ? valeur : null, etat == 'note' ? acquis : null, etat, _motif, monId, m0, id]);
    } else {
      await db.execute(
          '''INSERT INTO notes (id, organisation_id, evaluation_id, eleve_id, valeur, acquis, etat, motif, bareme, saisi_par, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [id, widget.espace.orgId, widget.evaluationId, eleveId, etat == 'note' ? valeur : null, etat == 'note' ? acquis : null, etat,
            _motif, ev['bareme'], monId, m0, m0]);
    }
  }

  /// Lit la note tapée (virgule ou point) ; vide : on retire la note.
  Future<void> _valeurTapee(Map<String, Object?> ev, String eleveId, String texte) async {
    final t = texte.trim().replaceAll(',', '.');
    final bareme = (ev['bareme'] as int? ?? 20).toDouble();
    if (t.isEmpty) {
      setState(() => _erreurs.remove(eleveId));
      await db.execute('DELETE FROM notes WHERE id = ?', [_idNote(widget.evaluationId, eleveId)]);
      return;
    }
    final v = double.tryParse(t);
    if (v == null || v < 0 || v > bareme) {
      setState(() => _erreurs[eleveId] = 'Entre 0 et ${bareme.toInt()}');
      return;
    }
    setState(() => _erreurs.remove(eleveId));
    await _enregistrer(ev, eleveId, valeur: v, etat: 'note');
  }

  @override
  Widget build(BuildContext context) => Requete(
        '''SELECT ev.*, m.nom AS matiere, t.libelle AS type, c.nom AS classe, p.libelle AS periode, p.bareme, p.statut AS statut_periode,
             s.libelle AS session, s.statut AS statut_session, p.nature
           FROM evaluations ev JOIN matieres m ON m.id = ev.matiere_id JOIN types_evaluation t ON t.id = ev.type_id
           JOIN classes c ON c.id = ev.classe_id JOIN periodes_evaluation p ON p.id = ev.periode_id
           LEFT JOIN sessions_evaluation s ON s.id = ev.session_id
           WHERE ev.id = ?''',
        parametres: [widget.evaluationId],
        builder: (context, l) {
          if (l.isEmpty) return const Scaffold(body: Center(child: Text('Évaluation introuvable.')));
          final ev = l.first;
          final aLeDroit = widget.espace.fondateur ||
              widget.espace.droits.contains('saisir_notes') ||
              widget.espace.droits.contains('planifier_evaluations');
          // Session clôturée (période ouverte) : correction possible, avec un motif.
          final corrigeable = aLeDroit && ev['statut_periode'] == 'ouverte' && ev['statut_session'] == 'cloturee';
          final ouverte = aLeDroit && ev['statut_periode'] == 'ouverte' && (ev['statut_session'] != 'cloturee' || _motif != null);
          return Scaffold(
            appBar: AppBar(
              titleSpacing: 0,
              title: Text('${ev['matiere']} · ${ev['classe']}', style: const TextStyle(fontSize: 17)),
              actions: [
                IconButton(
                  tooltip: 'Historique des modifications',
                  icon: const Icon(Icons.history),
                  onPressed: () => _historique(context, ev),
                ),
                if (ouverte && ev['statut_session'] != 'cloturee')
                  PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'supprimer' &&
                          await _confirmer(context, 'Supprimer cette évaluation et toutes ses notes ?') &&
                          context.mounted) {
                        Navigator.of(context).pop();
                        await _supprimer('evaluations', widget.evaluationId);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'supprimer', child: _ItemMenu(Icons.delete_outline, "Supprimer l'évaluation", couleur: Couleurs.retard)),
                    ],
                  ),
              ],
            ),
            body: Requete(
              '''SELECT e.id, e.nom, e.prenoms, e.matricule, n.valeur, n.etat, n.acquis
                 FROM inscriptions i JOIN eleves e ON e.id = i.eleve_id
                 LEFT JOIN notes n ON n.eleve_id = e.id AND n.evaluation_id = ?
                 WHERE i.classe_id = ? AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')
                 ORDER BY e.nom, e.prenoms''',
              parametres: [widget.evaluationId, ev['classe_id']],
              builder: (context, eleves) => _lignes(context, ev, eleves, ouverte, corrigeable: corrigeable, aLeDroit: aLeDroit),
            ),
          );
        },
      );

  /// Toutes les modifications des notes de l'épreuve : avant, après, qui, quand, motif.
  Future<void> _historique(BuildContext context, Map<String, Object?> ev) async {
    final l = await db.getAll('''
        SELECT h.*, e.nom, e.prenoms, p.nom_complet AS auteur FROM notes_historique h
        JOIN eleves e ON e.id = h.eleve_id LEFT JOIN personnes p ON p.id = h.par
        WHERE h.evaluation_id = ? ORDER BY h.le DESC''', [widget.evaluationId]);
    if (!context.mounted) return;
    String valeur(Object? v, Object? etat, Object? acquis) => etat == null
        ? '—'
        : etat == 'supprimee'
            ? 'effacée'
            : etat == 'note'
                ? (acquis != null ? niveauxAcquis['$acquis'] ?? '$acquis' : noteLisible((v as num?)?.toDouble()))
                : _etatsCourts['$etat'] ?? '$etat';
    await showDialog<void>(
      context: context,
      builder: (dialogue) => AlertDialog(
        title: const Text('Historique des modifications'),
        content: SizedBox(
          width: 480,
          child: l.isEmpty
              ? const Text('Aucune modification : les notes sont telles que saisies la première fois.')
              : ListView(shrinkWrap: true, children: [
                  for (final h in l)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${h['nom']} ${h['prenoms']} : ${valeur(h['avant_valeur'], h['avant_etat'], h['avant_acquis'])}'
                          ' → ${valeur(h['apres_valeur'], h['apres_etat'], h['apres_acquis'])}'),
                      subtitle: Text([
                        _dateLisible(h['le']),
                        if (h['auteur'] != null) 'par ${h['auteur']}',
                        if (h['motif'] != null) 'motif : ${h['motif']}',
                      ].join(' · ')),
                    ),
                ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogue), child: const Text('Fermer'))],
      ),
    );
  }

  /// La remise : l'enseignant déclare sa saisie terminée (indicateur pour la direction).
  Future<void> _remettre(Map<String, Object?> ev, bool remettre) async {
    await db.execute('UPDATE evaluations SET remise_le = ?, remise_par = ?, updated_at = ? WHERE id = ?',
        [remettre ? _maintenant() : null, remettre ? monId : null, _maintenant(), widget.evaluationId]);
  }

  /// Corriger une note d'une session clôturée : le motif vaut pour toute la correction.
  Future<void> _demanderMotif() async {
    final c = TextEditingController();
    final ok = await _formulaire(context, 'Corriger une note (session clôturée)', (_) => [
          const Text('Les bulletins de cette session sont peut-être déjà sortis : la correction est tracée avec son motif.'),
          TextField(controller: c, autofocus: true, maxLength: 200, decoration: _champ('Motif', aide: 'Par exemple : erreur de report de la copie')),
        ], valider: () => 'Corriger');
    if (ok && c.text.trim().length >= 3) setState(() => _motif = c.text.trim());
  }

  Widget _lignes(BuildContext context, Map<String, Object?> ev, Lignes eleves, bool ouverte,
      {bool corrigeable = false, bool aLeDroit = false}) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bareme = ev['bareme'] as int? ?? 20;
    final saisies = eleves.where((e) => e['etat'] != null && e['etat'] != 'non_note').length;
    final valeurs = [for (final e in eleves) if (e['etat'] == 'note' && e['valeur'] != null) (e['valeur'] as num).toDouble()];
    final moy = valeurs.isEmpty ? null : valeurs.reduce((a, b) => a + b) / valeurs.length;
    final ordre = [for (final e in eleves) e['id'] as String];
    // Maternelle : on observe des acquis, pas de chiffre (ni moyenne, ni rang).
    final parAcquis = ev['nature'] == 'appreciations';
    int combien(String a) => eleves.where((e) => e['etat'] == 'note' && e['acquis'] == a).length;

    Widget repere(String libelle, String valeur, {Color? couleur}) =>
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(libelle, style: TextStyle(fontSize: 12, color: gris)),
          Text(valeur, style: _chiffresDep.copyWith(fontSize: 18, fontWeight: FontWeight.w600, color: couleur)),
        ]);

    // En haut : où en est la saisie, et les repères de l'évaluation.
    final bandeau = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: Theme.of(context).dividerColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${ev['type']} du ${_dateLisible(ev['date_evaluation'])}${ev['libelle'] != null ? ' · ${ev['libelle']}' : ''}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        Text('${ev['session'] ?? 'Hors session'} · ${ev['periode']} · ${parAcquis ? 'acquis (maternelle)' : 'notes sur $bareme'}'
            '${ev['statut_session'] == 'cloturee' ? ' · session clôturée' : ''}',
            style: TextStyle(fontSize: 13, color: gris)),
        const SizedBox(height: 12),
        Wrap(spacing: 28, runSpacing: 10, children: [
          repere('Saisies', '$saisies / ${eleves.length}', couleur: saisies >= eleves.length ? Couleurs.regle : Couleurs.attente),
          if (parAcquis) ...[
            repere('Acquis', '${combien('acquis')}', couleur: Couleurs.regle),
            repere('En cours', '${combien('en_cours')}', couleur: Couleurs.attente),
            repere('Non acquis', '${combien('non_acquis')}', couleur: Couleurs.retard),
          ] else ...[
            repere('Moyenne', noteLisible(moy), couleur: moy != null && moy < bareme / 2 ? Couleurs.retard : null),
            repere('Plus haute', noteLisible(valeurs.isEmpty ? null : valeurs.reduce((a, b) => a > b ? a : b))),
            repere('Plus basse', noteLisible(valeurs.isEmpty ? null : valeurs.reduce((a, b) => a < b ? a : b))),
          ],
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: eleves.isEmpty ? 0 : saisies / eleves.length,
            minHeight: 4,
            backgroundColor: Couleurs.doux(context),
            color: saisies >= eleves.length ? Couleurs.regle : Couleurs.attente,
          ),
        ),
        const SizedBox(height: 10),
        // La remise : un indicateur pour la direction, pas un verrou.
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (ev['remise_le'] != null)
            Etat('Notes remises le ${_dateLisible(ev['remise_le'])}', ton: Ton.regle, icone: Icons.task_alt)
          else
            const Etat('Notes pas encore remises', ton: Ton.attente),
          if (aLeDroit)
            TextButton(
              onPressed: () => _remettre(ev, ev['remise_le'] == null),
              child: Text(ev['remise_le'] == null ? 'J\'ai terminé : remettre les notes' : 'Annuler la remise'),
            ),
          if (corrigeable && _motif == null)
            OutlinedButton.icon(
              onPressed: _demanderMotif,
              icon: const Icon(Icons.edit_note, size: 16),
              label: const Text('Corriger une note (motif)'),
            ),
          if (_motif != null) Etat('Correction : $_motif', ton: Ton.attente, icone: Icons.edit_note),
        ]),
        if (!ouverte) ...[
          const SizedBox(height: 10),
          Etat(corrigeable ? 'Session clôturée : corrigez avec un motif' : 'Lecture seule : période clôturée ou pas de droit de saisie',
              icone: Icons.lock_outline),
        ] else ...[
          const SizedBox(height: 8),
          Text(
              parAcquis
                  ? 'Choisissez pour chaque enfant : acquis, en cours ou non acquis. Tout s\'enregistre seul, même sans internet.'
                  : 'Tapez la note puis Entrée pour passer à l\'élève suivant. Tout s\'enregistre seul, même sans internet. '
                      'Le menu ⋮ : absent, dispensé, non concerné.',
              style: TextStyle(fontSize: 12, color: gris)),
        ],
      ]),
    );

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
          bandeau,
          const SizedBox(height: 12),
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: Theme.of(context).dividerColor)),
            child: Column(children: [
              for (var i = 0; i < eleves.length; i++)
                Builder(builder: (context) {
                  final e = eleves[i];
                  final id = e['id'] as String;
                  final etat = e['etat'] as String? ?? 'non_note';
                  final v = (e['valeur'] as num?)?.toDouble();
                  final c = _champs.putIfAbsent(id, () => TextEditingController(text: v == null ? '' : noteLisible(v).replaceAll(',00', '')));
                  final f = _focus.putIfAbsent(id, FocusNode.new);
                  final basse = etat == 'note' && v != null && v < bareme / 2;
                  return Container(
                    padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                    decoration: BoxDecoration(
                      border: i == 0 ? null : Border(top: BorderSide(color: Theme.of(context).dividerColor)),
                    ),
                    child: Row(children: [
                      SizedBox(width: 26, child: Text('${i + 1}', style: TextStyle(fontSize: 12, color: gris))),
                      Initiales('${e['nom']} ${e['prenoms']}', taille: 32),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${e['nom']} ${e['prenoms']}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                          Text('${e['matricule']}', style: styleMono.copyWith(fontSize: 11, color: gris)),
                        ]),
                      ),
                      if (etat != 'note' && etat != 'non_note')
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Etat(_etatsCourts[etat] ?? etat, ton: etat == 'absent' ? Ton.retard : Ton.neutre),
                        )
                      else if (parAcquis)
                        // Trois choix d'un geste : acquis, en cours, non acquis.
                        Wrap(spacing: 4, children: [
                          for (final (cle, court, couleur) in const [
                            ('acquis', 'A', Couleurs.regle),
                            ('en_cours', 'EC', Couleurs.attente),
                            ('non_acquis', 'NA', Couleurs.retard),
                          ])
                            Tooltip(
                              message: niveauxAcquis[cle]!,
                              child: ChoiceChip(
                                label: Text(court),
                                selected: etat == 'note' && e['acquis'] == cle,
                                selectedColor: couleur.withValues(alpha: .18),
                                labelStyle: TextStyle(fontWeight: FontWeight.w600, color: etat == 'note' && e['acquis'] == cle ? couleur : null),
                                visualDensity: VisualDensity.compact,
                                onSelected: ouverte ? (_) => _enregistrer(ev, id, etat: 'note', acquis: cle) : null,
                              ),
                            ),
                        ])
                      else
                        SizedBox(
                          width: 104,
                          child: TextField(
                            controller: c,
                            focusNode: f,
                            enabled: ouverte,
                            textAlign: TextAlign.right,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            textInputAction: i < eleves.length - 1 ? TextInputAction.next : TextInputAction.done,
                            onChanged: (t) => _valeurTapee(ev, id, t),
                            onSubmitted: (_) {
                              // Entrée : l'élève suivant qui attend une note.
                              for (var k = i + 1; k < ordre.length; k++) {
                                final suivant = _focus[ordre[k]];
                                if (suivant != null && suivant.context != null) {
                                  suivant.requestFocus();
                                  return;
                                }
                              }
                            },
                            style: _chiffresDep.copyWith(fontSize: 17, fontWeight: FontWeight.w600, color: basse ? Couleurs.retard : null),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '—',
                              border: const OutlineInputBorder(),
                              suffixText: '/$bareme',
                              errorText: _erreurs[id],
                              errorMaxLines: 2,
                            ),
                          ),
                        ),
                      if (ouverte)
                        PopupMenuButton<String>(
                          tooltip: 'Absent, dispensé…',
                          icon: Icon(Icons.more_vert, size: 18, color: gris),
                          onSelected: (x) async {
                            if (x == 'note') {
                              await db.execute('DELETE FROM notes WHERE id = ?', [_idNote(widget.evaluationId, id)]);
                              c.clear();
                            } else {
                              c.clear();
                              await _enregistrer(ev, id, etat: x);
                            }
                          },
                          itemBuilder: (_) => [
                            if (etat != 'note' && etat != 'non_note') const PopupMenuItem(value: 'note', child: Text('Saisir une note')),
                            for (final x in _etatsNote.entries) PopupMenuItem(value: x.key, child: Text(x.value)),
                          ],
                        )
                      else
                        const SizedBox(width: 12),
                    ]),
                  );
                }),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Une ligne du bulletin : une matière.
typedef _LigneBulletin = ({String matiere, double coef, double? moyenne, int? rang});

/// Les résultats de la classe sur la période : moyennes par matière, moyenne
/// générale, rang ; bulletins en PDF ; appréciation de chaque élève.
class _Resultats extends StatelessWidget {
  const _Resultats({
    required this.espace,
    required this.annee,
    required this.classe,
    required this.periode,
    required this.session,
    required this.peutSaisir,
  });

  final Espace espace;
  final Map<String, Object?> annee;
  final Map<String, Object?> classe;
  final Map<String, Object?> periode;
  /// Résultats d'une session (suivi mensuel) ; null : la période (bulletin officiel).
  /// La période repart toujours de TOUTES ses notes, jamais des moyennes de session.
  final Map<String, Object?>? session;
  final bool peutSaisir;

  @override
  Widget build(BuildContext context) => Requete(
        '''SELECT e.id, e.nom, e.prenoms, e.matricule, e.sexe, a.texte AS appreciation
           FROM inscriptions i JOIN eleves e ON e.id = i.eleve_id
           LEFT JOIN appreciations a ON a.eleve_id = e.id AND a.periode_id = ?
           WHERE i.classe_id = ? AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')
           ORDER BY e.nom, e.prenoms''',
        parametres: [periode['id'], classe['id']],
        builder: (context, eleves) => Requete(
          'SELECT id, nom, coefficient FROM matieres WHERE niveau_id = ? ORDER BY nom',
          parametres: [classe['niveau_id']],
          builder: (context, matieres) => Requete(
            '''SELECT n.eleve_id, n.valeur, n.etat, n.acquis, ev.matiere_id, ev.date_evaluation, t.poids, t.compte
               FROM notes n JOIN evaluations ev ON ev.id = n.evaluation_id JOIN types_evaluation t ON t.id = ev.type_id
               WHERE ev.classe_id = ? AND ev.periode_id = ? AND (? IS NULL OR ev.session_id = ?)''',
            parametres: [classe['id'], periode['id'], session?['id'], session?['id']],
            builder: (context, notes) => Requete(
              // Les règles de l'école (traitement de l'absence) et les mentions du cycle.
              '''SELECT 'regle' AS sorte, absences AS libelle, NULL AS minimum FROM regles_notes WHERE organisation_id = ?
                 UNION ALL
                 SELECT 'mention', libelle, minimum FROM mentions_notes WHERE organisation_id = ? AND cycle = ?''',
              parametres: [espace.orgId, espace.orgId, classe['cycle']],
              builder: (context, reglages) => _SelonSynchro(
                builder: (context, synchronise) => _contenu(context, eleves, matieres, notes, reglages, synchronise),
              ),
            ),
          ),
        ),
      );

  Widget _contenu(BuildContext context, Lignes eleves, Lignes matieres, Lignes notes, Lignes reglages, bool synchronise) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    final telephone = MediaQuery.sizeOf(context).width < 640;
    final bareme = periode['bareme'] as int? ?? 20;
    final absences = reglages.where((r) => r['sorte'] == 'regle').map((r) => '${r['libelle']}').firstOrNull ?? 'justifie_exclu';
    final seuils = [
      for (final r in reglages)
        if (r['sorte'] == 'mention') (minimum: (r['minimum'] as num).toDouble(), libelle: '${r['libelle']}'),
    ];
    final mentions = seuils.isEmpty ? mentionsParDefaut(bareme) : seuils;
    if (periode['nature'] == 'appreciations') return _acquis(context, eleves, matieres, notes);

    // Moyennes par élève et par matière, à partir de toutes les notes.
    final parEleveMatiere = <String, List<NoteCalcul>>{};
    for (final n in notes) {
      parEleveMatiere.putIfAbsent('${n['eleve_id']}|${n['matiere_id']}', () => []).add(NoteCalcul(
            valeur: (n['valeur'] as num?)?.toDouble(),
            etat: '${n['etat']}',
            poids: (n['poids'] as num? ?? 1).toDouble(),
            compte: n['compte'] == 1,
          ));
    }
    final moy = <String, Map<String, double?>>{}; // élève → matière → moyenne
    final generale = <String, double?>{};
    for (final e in eleves) {
      final id = e['id'] as String;
      moy[id] = {
        for (final m in matieres) m['id'] as String: moyenneMatiere(parEleveMatiere['$id|${m['id']}'] ?? const [], absences: absences),
      };
      generale[id] = moyenneGenerale([
        for (final m in matieres) (moy[id]![m['id']], (m['coefficient'] as num? ?? 1).toDouble()),
      ]);
    }
    // Hors ligne ou envois en attente : pas de rang (un rang provisoire faux est pire que pas de rang).
    final rang = synchronise ? rangs(generale) : <String, int>{};
    final rangMatiere = {
      for (final m in matieres) m['id'] as String: rangs({for (final e in eleves) e['id'] as String: moy[e['id']]![m['id']]}),
    };
    final avecMoyenne = generale.values.whereType<double>().toList();
    final moyClasse = avecMoyenne.isEmpty ? null : avecMoyenne.reduce((a, b) => a + b) / avecMoyenne.length;
    final plusForte = avecMoyenne.isEmpty ? null : avecMoyenne.reduce((a, b) => a > b ? a : b);
    final plusFaible = avecMoyenne.isEmpty ? null : avecMoyenne.reduce((a, b) => a < b ? a : b);

    // Sous la moyenne (la moitié du barème) : en rouge.
    Color? couleurNote(double? v) => v != null && v < bareme / 2 ? Couleurs.retard : null;

    List<_LigneBulletin> lignes(String eleveId) => [
          for (final m in matieres)
            (
              matiere: '${m['nom']}',
              coef: (m['coefficient'] as num? ?? 1).toDouble(),
              moyenne: moy[eleveId]![m['id']],
              rang: rangMatiere[m['id']]![eleveId],
            ),
        ];

    Future<void> imprimer(List<Map<String, Object?>> qui) async {
      final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [espace.orgId]);
      final pdf = await bulletinsPdf(
        ecole: Map.of(ecole),
        annee: '${annee['libelle']}',
        classe: '${classe['nom']}',
        periode: session == null ? '${periode['libelle']}' : '${session!['libelle']}',
        session: session != null,
        mentions: mentions,
        bareme: bareme,
        effectif: eleves.length,
        moyenneClasse: moyClasse,
        plusForte: plusForte,
        plusFaible: plusFaible,
        bulletins: [
          for (final e in qui)
            (
              nom: '${e['nom']} ${e['prenoms']}',
              matricule: '${e['matricule']}',
              lignes: [for (final l in lignes(e['id'] as String)) (matiere: l.matiere, coef: l.coef, moyenne: l.moyenne, rang: l.rang)],
              moyenne: generale[e['id']],
              rang: rang[e['id']],
              appreciation: e['appreciation'] as String?,
            ),
        ],
        images: await _imagesEcole(espace.orgId),
      );
      await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Bulletins ${classe['nom']} ${(session ?? periode)['libelle']}');
    }

    Future<void> apprecier(Map<String, Object?> e) async {
      final c = TextEditingController(text: '${e['appreciation'] ?? ''}');
      final ok = await _formulaire(context, 'Appréciation · ${e['nom']} ${e['prenoms']}', (_) => [
            TextField(
              controller: c,
              autofocus: true,
              maxLines: 3,
              maxLength: 400,
              textCapitalization: TextCapitalization.sentences,
              decoration: _champ('Appréciation du bulletin', aide: 'Par exemple : bon trimestre, des efforts en mathématiques'),
            ),
          ]);
      if (!ok) return;
      final texte = c.text.trim();
      final existe = await db.getOptional('SELECT id FROM appreciations WHERE periode_id = ? AND eleve_id = ?', [periode['id'], e['id']]);
      if (existe != null) {
        if (texte.isEmpty) return;
        await _modifier('appreciations', existe['id'] as String, {'texte': texte, 'par': monId});
      } else if (texte.isNotEmpty) {
        await _inserer('appreciations', {
          'organisation_id': espace.orgId,
          'periode_id': periode['id'],
          'eleve_id': e['id'],
          'texte': texte,
          'par': monId,
        });
      }
    }

    final ordre = [...eleves]..sort((a, b) {
        final ra = rang[a['id']], rb = rang[b['id']];
        if (ra == null && rb == null) return nomSimplifie('${a['nom']}').compareTo(nomSimplifie('${b['nom']}'));
        if (ra == null) return 1;
        if (rb == null) return -1;
        return ra.compareTo(rb);
      });

    final entete = Wrap(spacing: 24, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final (libelle, valeur) in [
        ('Moyenne de la classe', noteLisible(moyClasse)),
        ('Plus forte', noteLisible(plusForte)),
        ('Plus faible', noteLisible(plusFaible)),
        ('Élèves classés', '${avecMoyenne.length} / ${eleves.length}'),
      ])
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(libelle, style: TextStyle(fontSize: 12, color: gris)),
          Text(valeur, style: _chiffresDep.copyWith(fontSize: 16, fontWeight: FontWeight.w600)),
        ]),
      FilledButton.icon(
        onPressed: eleves.isEmpty || !synchronise ? null : () => imprimer(ordre),
        icon: const Icon(Icons.print_outlined, size: 16),
        label: Text(session == null ? 'Bulletins de la classe' : 'Bulletins de la session'),
      ),
    ]);

    Widget actions(Map<String, Object?> e) => PopupMenuButton<String>(
          tooltip: 'Bulletin, appréciation',
          icon: const Icon(Icons.more_horiz, size: 18),
          onSelected: (v) => v == 'bulletin' ? imprimer([e]) : apprecier(e),
          itemBuilder: (_) => [
            if (synchronise) const PopupMenuItem(value: 'bulletin', child: _ItemMenu(Icons.print_outlined, 'Imprimer son bulletin')),
            // L'appréciation est celle du bulletin de période (le bulletin de session n'en a pas).
            if (peutSaisir && session == null)
              const PopupMenuItem(value: 'appreciation', child: _ItemMenu(Icons.rate_review_outlined, 'Appréciation')),
          ],
        );

    if (matieres.isEmpty) {
      return Text('Aucune matière pour ce niveau : ajoutez-les dans Paramètres › Matières.', style: TextStyle(color: gris));
    }

    final Widget tableau;
    if (telephone) {
      tableau = Column(children: [
        for (final e in ordre)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text('${e['nom']} ${e['prenoms']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                  Text(noteLisible(generale[e['id']]),
                      style: _chiffresDep.copyWith(fontSize: 16, fontWeight: FontWeight.w700, color: couleurNote(generale[e['id']]))),
                  const SizedBox(width: 6),
                  Etat(rangLisible(rang[e['id']])),
                  actions(e),
                ]),
                Wrap(spacing: 12, runSpacing: 4, children: [
                  for (final m in matieres)
                    Text('${m['nom']} ${noteLisible(moy[e['id']]![m['id']])}', style: TextStyle(fontSize: 12, color: gris)),
                ]),
                if (e['appreciation'] != null)
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text('« ${e['appreciation']} »', style: const TextStyle(fontSize: 12))),
              ]),
            ),
          ),
      ]);
    } else {
      const largeurCol = 104.0;
      Widget c(double l, Widget w, {bool droite = true}) => SizedBox(
          width: l,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(alignment: droite ? Alignment.centerRight : Alignment.centerLeft, child: w),
          ));
      const entete = TextStyle(fontSize: 12, fontWeight: FontWeight.w600);
      // La colonne des noms prend la place libre : le tableau remplit son cadre.
      tableau = LayoutBuilder(builder: (context, contraintes) {
        final fixe = 48.0 + (matieres.length + 1) * largeurCol + 48 + 2 + 16;
        final largeurNom = (contraintes.maxWidth - fixe).clamp(220.0, double.infinity);
        return Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: bordure)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bordure))),
              child: Row(children: [
                c(48, const Text('Rang', style: entete)),
                c(largeurNom, const Text('Élève', style: entete), droite: false),
                // Le nom de la matière sur deux lignes, son coefficient dessous.
                for (final m in matieres)
                  c(
                      largeurCol,
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text('${m['nom']}', maxLines: 2, textAlign: TextAlign.right, overflow: TextOverflow.ellipsis, style: entete),
                        Text('coef. ${noteLisible((m['coefficient'] as num? ?? 1).toDouble()).replaceAll(',00', '')}',
                            style: TextStyle(fontSize: 11, color: gris)),
                      ])),
                c(largeurCol, const Text('Moyenne', style: entete)),
                const SizedBox(width: 48),
              ]),
            ),
            for (final e in ordre)
              Container(
                padding: const EdgeInsets.fromLTRB(8, 14, 8, 14),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bordure))),
                child: Row(children: [
                  c(48, Text(rangLisible(rang[e['id']]), style: const TextStyle(fontSize: 13))),
                  c(
                      largeurNom,
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${e['nom']} ${e['prenoms']}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        if (e['appreciation'] != null)
                          Text('« ${e['appreciation']} »', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: gris)),
                      ]),
                      droite: false),
                  for (final m in matieres)
                    c(largeurCol, Text(noteLisible(moy[e['id']]![m['id']]), style: _chiffresDep.copyWith(fontSize: 13, color: couleurNote(moy[e['id']]![m['id']])))),
                  c(largeurCol,
                      Text(noteLisible(generale[e['id']]), style: _chiffresDep.copyWith(fontSize: 14, fontWeight: FontWeight.w700, color: couleurNote(generale[e['id']])))),
                  SizedBox(width: 48, child: actions(e)),
                ]),
              ),
          ]),
        ),
      );
      });
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!synchronise)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Couleurs.attenteFond, borderRadius: BorderRadius.circular(8)),
          child: const Text('Poste pas à jour (hors ligne ou notes en attente d\'envoi) : les moyennes sont celles de ce poste, '
              'le rang et les bulletins attendent la synchronisation, pour ne rien publier de faux.'),
        ),
      entete,
      const SizedBox(height: 6),
      Text(
          session == null
              ? 'Moyennes sur $bareme. Chaque matière : toutes ses notes de la période (toutes sessions), pondérées par le type '
                  '(composition ×2) ; la moyenne générale tient compte des coefficients. Une matière sans note ne compte pas.'
              : 'Résultats de « ${session!['libelle']} » (suivi) sur $bareme : seulement les notes de cette session. '
                  'Le bulletin officiel reste celui de la période, calculé sur toutes ses notes.',
          style: TextStyle(fontSize: 12, color: gris)),
      const SizedBox(height: 10),
      tableau,
    ]);
  }
}

extension on _Resultats {
  /// Maternelle : un tableau d'acquis (dernière observation de chaque domaine),
  /// sans moyenne ni rang ; le bulletin est un tableau d'acquis.
  Widget _acquis(BuildContext context, Lignes eleves, Lignes matieres, Lignes notes) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    String? acquisDe(String eleve, String matiere) => acquisRetenu([
          for (final n in notes)
            if (n['eleve_id'] == eleve && n['matiere_id'] == matiere && n['etat'] == 'note')
              (date: '${n['date_evaluation']}', acquis: n['acquis'] as String?),
        ]);
    Widget pastille(String? a) => a == null
        ? Text('—', style: TextStyle(color: gris))
        : Etat(switch (a) { 'acquis' => 'Acquis', 'en_cours' => 'En cours', _ => 'Non acquis' },
            ton: switch (a) { 'acquis' => Ton.regle, 'en_cours' => Ton.attente, _ => Ton.retard });

    Future<void> imprimer(List<Map<String, Object?>> qui) async {
      final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [espace.orgId]);
      final pdf = await bulletinsAcquisPdf(
        ecole: Map.of(ecole),
        annee: '${annee['libelle']}',
        classe: '${classe['nom']}',
        periode: '${(session ?? periode)['libelle']}',
        effectif: eleves.length,
        bulletins: [
          for (final e in qui)
            (
              nom: '${e['nom']} ${e['prenoms']}',
              matricule: '${e['matricule']}',
              lignes: [for (final m in matieres) (domaine: '${m['nom']}', acquis: acquisDe(e['id'] as String, m['id'] as String))],
              appreciation: e['appreciation'] as String?,
            ),
        ],
        images: await _imagesEcole(espace.orgId),
      );
      await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Bulletins ${classe['nom']} ${(session ?? periode)['libelle']}');
    }

    if (matieres.isEmpty) {
      return Text('Aucun domaine (matière) pour ce niveau : ajoutez-les dans Paramètres › Matières.', style: TextStyle(color: gris));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Text('Maternelle : pour chaque domaine, la dernière observation de la période. Pas de moyenne ni de rang.',
              style: TextStyle(fontSize: 13, color: gris)),
        ),
        FilledButton.icon(
          onPressed: eleves.isEmpty ? null : () => imprimer(eleves),
          icon: const Icon(Icons.print_outlined, size: 16),
          label: const Text('Bulletins de la classe'),
        ),
      ]),
      const SizedBox(height: 12),
      Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: bordure)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bordure))),
              child: Row(children: [
                const SizedBox(width: 220, child: Text('Élève', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                for (final m in matieres)
                  SizedBox(
                      width: 130,
                      child: Text('${m['nom']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                const SizedBox(width: 48),
              ]),
            ),
            for (final e in eleves)
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bordure))),
                child: Row(children: [
                  SizedBox(
                      width: 220,
                      child: Text('${e['nom']} ${e['prenoms']}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
                  for (final m in matieres)
                    SizedBox(width: 130, child: Align(alignment: Alignment.centerLeft, child: pastille(acquisDe(e['id'] as String, m['id'] as String)))),
                  SizedBox(
                    width: 48,
                    child: IconButton(
                      tooltip: 'Imprimer son bulletin',
                      icon: const Icon(Icons.print_outlined, size: 18),
                      onPressed: () => imprimer([e]),
                    ),
                  ),
                ]),
              ),
          ]),
        ),
      ),
    ]);
  }
}

/// Périodes (par cycle) et types d'évaluation : réglés par la direction.
class _ReglagesNotesScreen extends StatelessWidget {
  const _ReglagesNotesScreen({required this.espace, required this.annee});

  final Espace espace;
  final Map<String, Object?> annee;

  Future<void> _periode(BuildContext context, Map<String, Object?> p) async {
    final libelle = TextEditingController(text: '${p['libelle']}');
    var debut = DateTime.parse('${p['debut']}');
    var fin = DateTime.parse('${p['fin']}');
    var bareme = p['bareme'] as int? ?? 20;
    var nature = '${p['nature'] ?? 'numerique'}';
    Widget date(String titre, DateTime v, ValueChanged<DateTime> change) => InkWell(
          onTap: () async {
            final d = await _choisirDate(context, v, premier: DateTime(v.year - 1), dernier: DateTime(v.year + 2));
            if (d != null) change(d);
          },
          child: InputDecorator(decoration: _champ(titre), child: Text(_dateLisible(_date(v)))),
        );
    final ok = await _formulaire(context, 'Période · ${cycles[p['cycle']] ?? p['cycle']}', (maj) => [
          TextField(controller: libelle, decoration: _champ('Nom')),
          Row(children: [
            Expanded(child: date('Début', debut, (d) => maj(() => debut = d))),
            const SizedBox(width: 12),
            Expanded(child: date('Fin', fin, (d) => maj(() => fin = d))),
          ]),
          _liste('Évaluation', nature, const {'numerique': 'Notes chiffrées', 'appreciations': 'Acquis (maternelle) : sans moyenne ni rang'},
              (v) => maj(() => nature = v)),
          if (nature == 'numerique') _liste('Notes sur', bareme, const {10: '10', 20: '20'}, (v) => maj(() => bareme = v)),
          const Text('Le barème et la façon d\'évaluer ne changent plus dès qu\'une note est saisie dans la période.',
              style: TextStyle(fontSize: 12)),
        ]);
    if (!ok || libelle.text.trim().length < 2 || fin.isBefore(debut)) return;
    // Les périodes couvrent l'année sans trou ni chevauchement (spécification §2.5) :
    // déplacer une limite décale la période voisine, et leurs sessions suivent.
    final messager = ScaffoldMessenger.of(context);
    final aDebut = DateTime.parse('${annee['debut']}'), aFin = DateTime.parse('${annee['fin']}');
    if (debut.isBefore(aDebut) || fin.isAfter(aFin)) {
      messager.showSnackBar(SnackBar(content: Text('La période doit rester dans l\'année (${_dateLisible(annee['debut'])} – ${_dateLisible(annee['fin'])}).')));
      return;
    }
    final voisines = await db.getAll('SELECT * FROM periodes_evaluation WHERE annee_id = ? AND cycle = ? AND id <> ? ORDER BY ordre',
        [annee['id'], p['cycle'], p['id']]);
    final avant = voisines.where((x) => (x['ordre'] as int) < (p['ordre'] as int)).lastOrNull;
    final apres = voisines.where((x) => (x['ordre'] as int) > (p['ordre'] as int)).firstOrNull;
    DateTime jour(DateTime d, int plus) => DateTime(d.year, d.month, d.day + plus);
    for (final (voisine, nouveauDebut, nouvelleFin) in [
      if (avant != null) (avant, DateTime.parse('${avant['debut']}'), jour(debut, -1)),
      if (apres != null) (apres, jour(fin, 1), DateTime.parse('${apres['fin']}')),
    ]) {
      if (nouvelleFin.isBefore(nouveauDebut)) {
        messager.showSnackBar(SnackBar(content: Text('« ${voisine['libelle']} » disparaîtrait : changez d\'abord ses dates.')));
        return;
      }
      if (voisine['statut'] == 'cloturee' &&
          (_date(nouveauDebut) != '${voisine['debut']}' || _date(nouvelleFin) != '${voisine['fin']}')) {
        messager.showSnackBar(SnackBar(content: Text('« ${voisine['libelle']} » est clôturée : ses dates ne bougent plus.')));
        return;
      }
    }
    final m0 = _maintenant();
    await db.writeTransaction((tx) async {
      Future<void> poser(String id, DateTime d, DateTime f, [Map<String, Object?> autres = const {}]) async {
        await tx.execute('UPDATE periodes_evaluation SET debut = ?, fin = ?, updated_at = ? WHERE id = ?', [_date(d), _date(f), m0, id]);
        for (final e in autres.entries) {
          await tx.execute('UPDATE periodes_evaluation SET ${e.key} = ? WHERE id = ?', [e.value, id]);
        }
        // Les sessions restent dans leur période : on rogne celles qui débordent.
        await tx.execute("UPDATE sessions_evaluation SET debut = ?, updated_at = ? WHERE periode_id = ? AND debut < ? AND fin >= ? AND statut = 'ouverte'",
            [_date(d), m0, id, _date(d), _date(d)]);
        await tx.execute("UPDATE sessions_evaluation SET fin = ?, updated_at = ? WHERE periode_id = ? AND fin > ? AND debut <= ? AND statut = 'ouverte'",
            [_date(f), m0, id, _date(f), _date(f)]);
      }
      await poser(p['id'] as String, debut, fin, {'libelle': libelle.text.trim(), 'bareme': bareme, 'nature': nature});
      if (avant != null) await poser(avant['id'] as String, DateTime.parse('${avant['debut']}'), jour(debut, -1));
      if (apres != null) await poser(apres['id'] as String, jour(fin, 1), DateTime.parse('${apres['fin']}'));
    });
  }

  /// Une session : son nom, sa nature (type), sa fenêtre dans la période, et le
  /// nombre d'épreuves attendu par matière (facultatif : alerte, jamais blocage).
  Future<void> _session(BuildContext context, Map<String, Object?> p, Map<String, Object?>? x, Lignes types) async {
    final messager = ScaffoldMessenger.of(context);
    final libelle = TextEditingController(text: '${x?['libelle'] ?? ''}');
    final attendues = TextEditingController(text: '${x?['epreuves_attendues'] ?? ''}');
    final actifs = [for (final t in types) if (t['actif'] == 1) t];
    if (actifs.isEmpty) return;
    var type = (x?['type_id'] ?? actifs.first['id']) as String;
    final pDebut = DateTime.parse('${p['debut']}'), pFin = DateTime.parse('${p['fin']}');
    var debut = x == null ? pDebut : DateTime.parse('${x['debut']}');
    var fin = x == null ? pFin : DateTime.parse('${x['fin']}');
    final epreuves = x == null
        ? 0
        : (await db.get('SELECT count(*) AS n FROM evaluations WHERE session_id = ?', [x['id']]))['n'] as int? ?? 0;
    if (!context.mounted) return;
    Widget date(String titre, DateTime v, ValueChanged<DateTime> change) => InkWell(
          onTap: () async {
            final d = await _choisirDate(context, v, premier: pDebut, dernier: pFin);
            if (d != null) change(d);
          },
          child: InputDecorator(decoration: _champ(titre), child: Text(_dateLisible(_date(v)))),
        );
    final ok = await _formulaire(context, x == null ? 'Nouvelle session · ${p['libelle']}' : 'Session · ${p['libelle']}', (maj) => [
          TextField(controller: libelle, decoration: _champ('Nom', aide: 'Par exemple : Évaluation de novembre, Composition du 1er trimestre')),
          if (epreuves == 0)
            _liste('Nature', type, {for (final t in actifs) t['id'] as String: '${t['libelle']}'}, (v) => maj(() => type = v))
          else
            Text('Nature : ${types.firstWhere((t) => t['id'] == type, orElse: () => const {'libelle': ''})['libelle']} '
                '($epreuves épreuve(s) déjà placée(s))'),
          Row(children: [
            Expanded(child: date('Début de la fenêtre', debut, (d) => maj(() => debut = d))),
            const SizedBox(width: 12),
            Expanded(child: date('Fin', fin, (d) => maj(() => fin = d))),
          ]),
          TextField(
              controller: attendues,
              keyboardType: TextInputType.number,
              decoration: _champ('Épreuves attendues par matière (facultatif)', aide: 'En deçà, une alerte pour la direction, sans blocage')),
        ]);
    if (!ok) return;
    final n = int.tryParse(attendues.text.trim());
    if (libelle.text.trim().length < 2 || fin.isBefore(debut)) {
      messager.showSnackBar(const SnackBar(content: Text('Nom ou dates incorrects.')));
      return;
    }
    if (debut.isBefore(pDebut) || fin.isAfter(pFin)) {
      messager.showSnackBar(const SnackBar(content: Text('La session doit rester dans la période.')));
      return;
    }
    final valeurs = {
      'libelle': libelle.text.trim(),
      'type_id': type,
      'debut': _date(debut),
      'fin': _date(fin),
      'epreuves_attendues': n != null && n >= 1 && n <= 10 ? n : null,
    };
    if (x == null) {
      final ordre = (await db.get('SELECT coalesce(max(ordre), 0) + 1 AS o FROM sessions_evaluation WHERE periode_id = ?', [p['id']]))['o'];
      await _inserer('sessions_evaluation', {...valeurs, 'organisation_id': espace.orgId, 'periode_id': p['id'], 'ordre': ordre, 'statut': 'ouverte'});
    } else {
      await _modifier('sessions_evaluation', x['id'] as String, valeurs);
    }
  }

  /// Les règles de l'école : absences, délai de remise, moyenne annuelle, seuils de passage.
  Future<void> _regles(BuildContext context, Map<String, Object?>? r) async {
    final messager = ScaffoldMessenger.of(context);
    var absences = '${r?['absences'] ?? 'justifie_exclu'}';
    var annuelle = '${r?['moyenne_annuelle'] ?? 'simple'}';
    final delai = TextEditingController(text: '${r?['delai_remise_jours'] ?? 15}');
    final poids = TextEditingController(text: '${r?['poids_derniere'] ?? 2}');
    String nb(Object? v, num defaut) => noteLisible(((v as num?) ?? defaut).toDouble()).replaceAll(',00', '');
    final seuil10 = TextEditingController(text: nb(r?['seuil_passage_10'], 5));
    final seuil20 = TextEditingController(text: nb(r?['seuil_passage_20'], 10));
    final ok = await _formulaire(context, 'Règles de calcul', (maj) => [
          const Text('Absences', style: TextStyle(fontWeight: FontWeight.w600)),
          for (final e in traitementsAbsence.entries)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(absences == e.key ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 20),
              onTap: () => maj(() => absences = e.key),
              title: Text(e.value),
            ),
          TextField(
              controller: delai,
              keyboardType: TextInputType.number,
              decoration: _champ('Délai de remise des notes (jours après l\'épreuve)', aide: 'Au-delà : alerte pour la direction, sans blocage')),
          _liste('Moyenne annuelle', annuelle, const {'simple': 'Simple (moyenne des périodes)', 'ponderee': 'Pondérée : la dernière période pèse plus'},
              (v) => maj(() => annuelle = v)),
          if (annuelle == 'ponderee')
            TextField(controller: poids, keyboardType: TextInputType.number, decoration: _champ('Poids de la dernière période', aide: '2 : elle compte double')),
          Row(children: [
            Expanded(child: TextField(controller: seuil10, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _champ('Passage (sur 10)'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: seuil20, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _champ('Passage (sur 20)'))),
          ]),
          const Text('Le calcul propose « Admis » ou « Redouble » ; le conseil décide.', style: TextStyle(fontSize: 12)),
        ]);
    if (!ok) return;
    final d = int.tryParse(delai.text.trim());
    final w = int.tryParse(poids.text.trim());
    final s10 = double.tryParse(seuil10.text.trim().replaceAll(',', '.'));
    final s20 = double.tryParse(seuil20.text.trim().replaceAll(',', '.'));
    if (d == null || d < 1 || d > 90 || w == null || w < 1 || w > 5 || s10 == null || s10 < 0 || s10 > 10 || s20 == null || s20 < 0 || s20 > 20) {
      messager.showSnackBar(const SnackBar(content: Text('Délai entre 1 et 90 jours, poids entre 1 et 5, seuils dans leur barème.')));
      return;
    }
    final valeurs = {
      'absences': absences,
      'delai_remise_jours': d,
      'moyenne_annuelle': annuelle,
      'poids_derniere': w,
      'seuil_passage_10': s10,
      'seuil_passage_20': s20,
    };
    if (r == null) {
      await _inserer('regles_notes', {...valeurs, 'organisation_id': espace.orgId});
    } else {
      await _modifier('regles_notes', r['id'] as String, valeurs);
    }
  }

  /// Les mentions d'un cycle, dans son barème (sur 10 au primaire, sur 20 ensuite).
  Future<void> _mentions(BuildContext context, String cycle, int bareme, Lignes actuelles) async {
    final messager = ScaffoldMessenger.of(context);
    final depart = actuelles.isEmpty
        ? mentionsParDefaut(bareme)
        : [for (final m in actuelles) (minimum: (m['minimum'] as num).toDouble(), libelle: '${m['libelle']}')];
    final tries = [...depart]..sort((a, b) => b.minimum.compareTo(a.minimum));
    final libelles = [for (var i = 0; i < 5; i++) TextEditingController(text: i < tries.length ? tries[i].libelle : '')];
    final minimums = [
      for (var i = 0; i < 5; i++) TextEditingController(text: i < tries.length ? noteLisible(tries[i].minimum).replaceAll(',00', '') : ''),
    ];
    final ok = await _formulaire(context, 'Mentions · ${cycles[cycle] ?? cycle} (sur $bareme)', (_) => [
          for (var i = 0; i < 5; i++)
            Row(children: [
              Expanded(flex: 3, child: TextField(controller: libelles[i], decoration: _champ('Mention ${i + 1}'))),
              const SizedBox(width: 10),
              Expanded(
                  flex: 2,
                  child: TextField(
                      controller: minimums[i],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: _champ('À partir de'))),
            ]),
          Text('Laissez une ligne vide pour l\'enlever. Le dernier seuil (souvent 0 : « Insuffisant ») couvre tout le reste.',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]);
    if (!ok) return;
    final nouvelles = <SeuilMention>[];
    for (var i = 0; i < 5; i++) {
      final l = libelles[i].text.trim();
      final v = double.tryParse(minimums[i].text.trim().replaceAll(',', '.'));
      if (l.isEmpty && minimums[i].text.trim().isEmpty) continue;
      if (l.length < 2 || v == null || v < 0 || v > bareme || nouvelles.any((x) => x.minimum == v)) {
        messager.showSnackBar(SnackBar(content: Text('Mention ${i + 1} : un nom et un seuil entre 0 et $bareme, différent des autres.')));
        return;
      }
      nouvelles.add((minimum: v, libelle: l));
    }
    final m0 = _maintenant();
    await db.writeTransaction((tx) async {
      await tx.execute('DELETE FROM mentions_notes WHERE organisation_id = ? AND cycle = ?', [espace.orgId, cycle]);
      for (var i = 0; i < nouvelles.length; i++) {
        await tx.execute(
            '''INSERT INTO mentions_notes (id, organisation_id, cycle, minimum, libelle, ordre, created_at, updated_at)
               VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?)''',
            [espace.orgId, cycle, nouvelles[i].minimum, nouvelles[i].libelle, i + 1, m0, m0]);
      }
    });
  }

  Future<void> _type(BuildContext context, Map<String, Object?>? t) async {
    final libelle = TextEditingController(text: '${t?['libelle'] ?? ''}');
    final poids = TextEditingController(text: t == null ? '1' : noteLisible((t['poids'] as num).toDouble()).replaceAll(',00', ''));
    var compte = t == null || t['compte'] == 1;
    var unique = t != null && t['unique_par_periode'] == 1;
    var actif = t == null || t['actif'] == 1;
    final ok = await _formulaire(context, t == null ? "Nouveau type d'évaluation" : "Type d'évaluation", (maj) => [
          TextField(controller: libelle, decoration: _champ('Nom', aide: 'Par exemple : Exposé, Travail pratique')),
          TextField(
              controller: poids,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _champ('Poids dans la matière', aide: 'Composition : 2 ; évaluation : 1')),
          SwitchListTile(contentPadding: EdgeInsets.zero, value: compte, onChanged: (v) => maj(() => compte = v), title: const Text('Compte dans la moyenne')),
          SwitchListTile(
              contentPadding: EdgeInsets.zero, value: unique, onChanged: (v) => maj(() => unique = v), title: const Text('Une seule par période et par matière')),
          if (t != null)
            SwitchListTile(contentPadding: EdgeInsets.zero, value: actif, onChanged: (v) => maj(() => actif = v), title: const Text('Proposé à la saisie')),
        ]);
    final p = double.tryParse(poids.text.replaceAll(',', '.'));
    if (!ok || libelle.text.trim().length < 2 || p == null || p <= 0 || p > 10) return;
    final valeurs = {
      'libelle': libelle.text.trim(),
      'poids': p,
      'compte': compte ? 1 : 0,
      'unique_par_periode': unique ? 1 : 0,
      'actif': actif ? 1 : 0,
    };
    if (t == null) {
      await _inserer('types_evaluation', {...valeurs, 'organisation_id': espace.orgId, 'ordre': 9});
    } else {
      await _modifier('types_evaluation', t['id'] as String, valeurs);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text("Périodes, sessions et types d'évaluation"), titleSpacing: 0),
        body: Requete(
          'SELECT * FROM periodes_evaluation WHERE annee_id = ? ORDER BY cycle, ordre',
          parametres: [annee['id']],
          builder: (context, periodes) => Requete(
            'SELECT * FROM types_evaluation WHERE organisation_id = ? ORDER BY ordre, libelle',
            parametres: [espace.orgId],
            builder: (context, types) => Requete(
              '''SELECT s.*, t.libelle AS type, (SELECT count(*) FROM evaluations e WHERE e.session_id = s.id) AS epreuves
                 FROM sessions_evaluation s JOIN types_evaluation t ON t.id = s.type_id
                 JOIN periodes_evaluation p ON p.id = s.periode_id WHERE p.annee_id = ? ORDER BY s.debut, s.ordre''',
              parametres: [annee['id']],
              builder: (context, sessions) => Requete(
                '''SELECT 'regle' AS sorte, id, absences AS libelle, NULL AS cycle, NULL AS minimum FROM regles_notes WHERE organisation_id = ?
                   UNION ALL
                   SELECT 'mention', id, libelle, cycle, minimum FROM mentions_notes WHERE organisation_id = ?''',
                parametres: [espace.orgId, espace.orgId],
                builder: (context, reglages) {
              final gris = Theme.of(context).colorScheme.onSurfaceVariant;
              final parCycle = <String, List<Map<String, Object?>>>{};
              for (final p in periodes) {
                parCycle.putIfAbsent('${p['cycle']}', () => []).add(p);
              }
              return ListView(padding: const EdgeInsets.all(16), children: [
                Text('PÉRIODES · ${annee['libelle']}', style: TextStyle(fontSize: 12, letterSpacing: .6, color: gris)),
                const SizedBox(height: 6),
                if (periodes.isEmpty)
                  FilledButton.icon(
                    onPressed: () => _preparerNotes(espace.orgId, annee),
                    icon: const Icon(Icons.auto_fix_high, size: 16),
                    label: const Text('Créer les périodes et types par défaut'),
                  ),
                for (final e in parCycle.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(cycles[e.key] ?? e.key, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  for (final p in e.value) ...[
                    Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        dense: true,
                        title: Text('${p['libelle']}'),
                        subtitle: Text('du ${_dateLisible(p['debut'])} au ${_dateLisible(p['fin'])} · '
                            '${p['nature'] == 'appreciations' ? 'acquis (sans moyenne)' : 'notes sur ${p['bareme']}'}'),
                        trailing: p['statut'] == 'cloturee' ? const Etat('Clôturée', icone: Icons.lock_outline) : const Icon(Icons.edit_outlined, size: 18),
                        onTap: p['statut'] == 'cloturee' ? null : () => _periode(context, p),
                      ),
                    ),
                    // Ses sessions : les fenêtres où les matières placent leurs épreuves.
                    Padding(
                      padding: const EdgeInsets.only(left: 16, bottom: 10),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (final x in sessions.where((x) => x['periode_id'] == p['id']))
                          InkWell(
                            onTap: p['statut'] == 'cloturee' ? null : () => _session(context, p, x, types),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(children: [
                                Icon(x['statut'] == 'cloturee' ? Icons.lock_outline : Icons.subdirectory_arrow_right, size: 16, color: gris),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text.rich(TextSpan(children: [
                                    TextSpan(text: '${x['libelle']}', style: const TextStyle(fontSize: 13)),
                                    TextSpan(
                                        text: '  ${x['type']} · du ${_dateLisible(x['debut'])} au ${_dateLisible(x['fin'])}'
                                            ' · ${x['epreuves']} épreuve(s)'
                                            '${x['epreuves_attendues'] != null ? ' · ${x['epreuves_attendues']} attendue(s) par matière' : ''}',
                                        style: TextStyle(fontSize: 12, color: gris)),
                                  ])),
                                ),
                                if (p['statut'] != 'cloturee' && x['epreuves'] == 0)
                                  IconButton(
                                    tooltip: 'Supprimer cette session',
                                    visualDensity: VisualDensity.compact,
                                    icon: Icon(Icons.delete_outline, size: 18, color: gris),
                                    onPressed: () async {
                                      if (await _confirmer(context, 'Supprimer « ${x['libelle']} » ?')) {
                                        await _supprimer('sessions_evaluation', x['id'] as String);
                                      }
                                    },
                                  ),
                              ]),
                            ),
                          ),
                        if (p['statut'] != 'cloturee')
                          Wrap(spacing: 8, children: [
                            TextButton.icon(
                              onPressed: () => _session(context, p, null, types),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('Ajouter une session'),
                            ),
                            if (!sessions.any((x) => x['periode_id'] == p['id']))
                              TextButton.icon(
                                onPressed: () => db.writeTransaction((tx) => _preparerSessions(tx, espace.orgId, [p])),
                                icon: const Icon(Icons.auto_fix_high, size: 16),
                                label: const Text('Sessions par défaut (mensuelles + composition)'),
                              ),
                          ]),
                      ]),
                    ),
                  ],
                ],
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(child: Text("TYPES D'ÉVALUATION", style: TextStyle(fontSize: 12, letterSpacing: .6, color: gris))),
                  TextButton.icon(onPressed: () => _type(context, null), icon: const Icon(Icons.add, size: 16), label: const Text('Ajouter')),
                ]),
                for (final t in types)
                  Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      dense: true,
                      title: Text('${t['libelle']}${t['actif'] == 1 ? '' : ' (retiré)'}'),
                      subtitle: Text([
                        'poids ${noteLisible((t['poids'] as num).toDouble()).replaceAll(',00', '')}',
                        if (t['compte'] != 1) 'hors moyenne',
                        if (t['unique_par_periode'] == 1) 'une par période',
                      ].join(' · ')),
                      trailing: const Icon(Icons.edit_outlined, size: 18),
                      onTap: () => _type(context, t),
                    ),
                  ),
                const SizedBox(height: 12),
                Text('Le poids joue entre les notes d\'une même matière ; le coefficient (Paramètres › Matières) entre les matières. '
                    'La session dit quand (une fenêtre), le type dit la nature et le poids.',
                    style: TextStyle(fontSize: 12, color: gris)),
                const SizedBox(height: 20),
                Text('RÈGLES DE CALCUL', style: TextStyle(fontSize: 12, letterSpacing: .6, color: gris)),
                const SizedBox(height: 6),
                Requete(
                  'SELECT * FROM regles_notes WHERE organisation_id = ?',
                  parametres: [espace.orgId],
                  builder: (context, l) {
                    final r = l.isEmpty ? null : Map<String, Object?>.from(l.first);
                    final absences = '${r?['absences'] ?? 'justifie_exclu'}';
                    String nb(Object? v, num defaut) => noteLisible(((v as num?) ?? defaut).toDouble()).replaceAll(',00', '');
                    return Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        dense: true,
                        title: const Text('Absences, remise des notes, fin d\'année'),
                        subtitle: Text([
                          traitementsAbsence[absences] ?? absences,
                          'remise sous ${r?['delai_remise_jours'] ?? 15} jours',
                          r?['moyenne_annuelle'] == 'ponderee'
                              ? 'moyenne annuelle pondérée (dernière ×${r?['poids_derniere'] ?? 2})'
                              : 'moyenne annuelle simple',
                          'passage ${nb(r?['seuil_passage_10'], 5)}/10 et ${nb(r?['seuil_passage_20'], 10)}/20',
                        ].join(' · ')),
                        trailing: const Icon(Icons.edit_outlined, size: 18),
                        onTap: () => _regles(context, r),
                      ),
                    );
                  },
                ),
                // Les mentions de chaque cycle noté (la maternelle n'a pas de mention).
                for (final e in parCycle.entries)
                  if (e.value.any((p) => p['nature'] != 'appreciations'))
                    Builder(builder: (context) {
                      final bareme = e.value.firstWhere((p) => p['nature'] != 'appreciations')['bareme'] as int? ?? 20;
                      final siennes = [for (final r in reglages) if (r['sorte'] == 'mention' && r['cycle'] == e.key) r];
                      final seuils = siennes.isEmpty
                          ? mentionsParDefaut(bareme)
                          : ([for (final r in siennes) (minimum: (r['minimum'] as num).toDouble(), libelle: '${r['libelle']}')]
                            ..sort((a, b) => b.minimum.compareTo(a.minimum)));
                      return Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          dense: true,
                          title: Text('Mentions · ${cycles[e.key] ?? e.key} (sur $bareme)${siennes.isEmpty ? ' · par défaut' : ''}'),
                          subtitle: Text(seuils.map((x) => '${x.libelle} ≥ ${noteLisible(x.minimum).replaceAll(',00', '')}').join(' · ')),
                          trailing: const Icon(Icons.edit_outlined, size: 18),
                          onTap: () => _mentions(context, e.key, bareme, siennes),
                        ),
                      );
                    }),
              ]);
                },
              ),
            ),
          ),
        ),
      );
}
