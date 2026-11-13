part of 'configuration.dart';

/// La saisie des notes en tableau, comme le carnet de notes papier : une ligne par
/// élève, une colonne par épreuve de la matière (évaluations, compositions), la
/// moyenne de la matière à droite. On tape dans la case ; Entrée descend, Tab va à
/// droite, les flèches haut et bas changent d'élève. Codes : a (absent), aj (absent
/// justifié), d (dispensé), nc (non concerné) ; en maternelle A, EC, NA.
class _CarnetNotes extends StatefulWidget {
  const _CarnetNotes({
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
  final Map<String, Object?>? session;
  final Lignes sessions;
  final bool peutSaisir;

  @override
  State<_CarnetNotes> createState() => _CarnetNotesState();
}

class _CarnetNotesState extends State<_CarnetNotes> {
  String? _matiereId;
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

  Map<String, Object?> get _classe => widget.classe;
  Map<String, Object?> get _periode => widget.periode;
  int get _bareme => _periode['bareme'] as int? ?? 20;
  bool get _parAcquis => _periode['nature'] == 'appreciations';

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT id, nom, coefficient FROM matieres WHERE niveau_id = ? ORDER BY nom',
        parametres: [_classe['niveau_id']],
        builder: (context, matieres) {
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          if (matieres.isEmpty) {
            return Text('Aucune matière pour ce niveau : ajoutez-les dans Paramètres › Matières.', style: TextStyle(color: gris));
          }
          final matiere = matieres.firstWhere((m) => m['id'] == _matiereId, orElse: () => matieres.first);
          return Requete(
            '''SELECT ev.*, t.libelle AS type, t.poids, t.compte, s.libelle AS session, s.statut AS statut_session
               FROM evaluations ev JOIN types_evaluation t ON t.id = ev.type_id
               LEFT JOIN sessions_evaluation s ON s.id = ev.session_id
               WHERE ev.classe_id = ? AND ev.periode_id = ? AND ev.matiere_id = ? AND (? IS NULL OR ev.session_id = ?)
               ORDER BY ev.date_evaluation, ev.created_at''',
            parametres: [_classe['id'], _periode['id'], matiere['id'], widget.session?['id'], widget.session?['id']],
            builder: (context, epreuves) => Requete(
              '''SELECT e.id, e.nom, e.prenoms, e.matricule FROM inscriptions i JOIN eleves e ON e.id = i.eleve_id
                 WHERE i.classe_id = ? AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant') ORDER BY e.nom, e.prenoms''',
              parametres: [_classe['id']],
              builder: (context, eleves) => Requete(
                '''SELECT n.evaluation_id, n.eleve_id, n.valeur, n.etat, n.acquis FROM notes n
                   JOIN evaluations ev ON ev.id = n.evaluation_id
                   WHERE ev.classe_id = ? AND ev.periode_id = ? AND ev.matiere_id = ?''',
                parametres: [_classe['id'], _periode['id'], matiere['id']],
                builder: (context, notes) => Requete(
                  "SELECT coalesce((SELECT absences FROM regles_notes WHERE organisation_id = ?), 'justifie_exclu') AS absences",
                  parametres: [widget.espace.orgId],
                  builder: (context, r) =>
                      _contenu(context, matieres, matiere, epreuves, eleves, notes, '${r.first['absences']}'),
                ),
              ),
            ),
          );
        },
      );

  /// Le champ d'une case, tenu à jour avec la base sauf pendant qu'on y tape.
  TextEditingController _champDe(String cle, String texte) {
    final c = _champs.putIfAbsent(cle, () => TextEditingController(text: texte));
    final enCours = _focus[cle]?.hasFocus ?? false;
    if (!enCours && !_erreurs.containsKey(cle) && c.text != texte) c.text = texte;
    return c;
  }

  Future<void> _taper(String evaluationId, String eleveId, String cle, String texte) async {
    final lu = _lireCase(texte, _bareme, parAcquis: _parAcquis);
    if (lu.erreur != null) {
      setState(() => _erreurs[cle] = lu.erreur!);
      return;
    }
    if (_erreurs.containsKey(cle)) setState(() => _erreurs.remove(cle));
    await _ecrireNote(widget.espace.orgId, evaluationId, eleveId, _bareme, valeur: lu.valeur, acquis: lu.acquis, etat: lu.etat);
  }

  void _aller(Lignes eleves, Lignes epreuves, int ligne, int colonne) {
    if (ligne < 0 || ligne >= eleves.length || colonne < 0 || colonne >= epreuves.length) return;
    _focus['${epreuves[colonne]['id']}|${eleves[ligne]['id']}']?.requestFocus();
  }

  Widget _contenu(BuildContext context, Lignes matieres, Map<String, Object?> matiere, Lignes epreuves, Lignes eleves, Lignes notes,
      String absences) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    final parCase = {for (final n in notes) '${n['evaluation_id']}|${n['eleve_id']}': n};
    const largeurNom = 230.0, largeurCase = 96.0, largeurMoy = 96.0;

    // La moyenne de l'élève dans la matière (toutes les épreuves affichées, pondérées par leur type).
    double? moyenneEleve(String eleve) => moyenneMatiere([
          for (final ev in epreuves)
            if (parCase['${ev['id']}|$eleve'] case final n?)
              NoteCalcul(
                valeur: (n['valeur'] as num?)?.toDouble(),
                etat: '${n['etat']}',
                poids: (ev['poids'] as num? ?? 1).toDouble(),
                compte: ev['compte'] == 1,
              ),
        ], absences: absences);

    final nouvelle = _Evaluations(
      espace: widget.espace,
      classe: _classe,
      periode: _periode,
      session: widget.session,
      sessions: widget.sessions,
      peutSaisir: widget.peutSaisir,
    );

    Widget enTete(Map<String, Object?> ev) {
      final ferme = ev['statut_session'] == 'cloturee';
      final poids = (ev['poids'] as num? ?? 1).toDouble();
      return SizedBox(
        width: largeurCase,
        child: PopupMenuButton<String>(
          tooltip: 'Épreuve du ${_dateLisible(ev['date_evaluation'])}',
          onSelected: (v) async {
            if (v == 'detail') {
              await Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => _SaisieNotesScreen(espace: widget.espace, evaluationId: ev['id'] as String)));
            } else if (v == 'remise') {
              await db.execute('UPDATE evaluations SET remise_le = ?, remise_par = ?, updated_at = ? WHERE id = ?',
                  [ev['remise_le'] == null ? _maintenant() : null, ev['remise_le'] == null ? monId : null, _maintenant(), ev['id']]);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'detail', child: _ItemMenu(Icons.open_in_new, 'Saisie détaillée, historique, correction')),
            if (widget.peutSaisir || widget.espace.droits.contains('saisir_notes'))
              PopupMenuItem(
                value: 'remise',
                child: _ItemMenu(ev['remise_le'] == null ? Icons.task_alt : Icons.undo,
                    ev['remise_le'] == null ? 'J\'ai terminé : remettre les notes' : 'Annuler la remise'),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (ferme) Icon(Icons.lock_outline, size: 12, color: gris),
                if (ev['remise_le'] != null) const Icon(Icons.task_alt, size: 12, color: Couleurs.regle),
                const SizedBox(width: 2),
                Text(_dateLisible(ev['date_evaluation']).substring(0, 5), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
              Text('${ev['type']}${poids != 1 ? ' ×${noteLisible(poids).replaceAll(',00', '')}' : ''}',
                  overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: ev['compte'] == 1 ? gris : Couleurs.attente)),
              if (widget.session == null)
                Text('${ev['session'] ?? 'hors session'}', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: gris)),
            ]),
          ),
        ),
      );
    }

    Widget caseNote(int ligne, int colonne) {
      final ev = epreuves[colonne];
      final el = eleves[ligne];
      final cle = '${ev['id']}|${el['id']}';
      final n = parCase[cle];
      final texte = _texteCase(n?['etat'], n?['valeur'], n?['acquis']);
      final c = _champDe(cle, texte);
      final f = _focus.putIfAbsent(cle, FocusNode.new);
      final modifiable = widget.peutSaisir && ev['statut_session'] != 'cloturee';
      final v = (n?['valeur'] as num?)?.toDouble();
      final etat = n?['etat'] as String?;
      final couleur = etat == null
          ? null
          : etat == 'note'
              ? (n?['acquis'] != null
                  ? switch (n?['acquis']) { 'acquis' => Couleurs.regle, 'en_cours' => Couleurs.attente, _ => Couleurs.retard }
                  : (v != null && v < _bareme / 2 ? Couleurs.retard : null))
              : (etat == 'absent' ? Couleurs.retard : gris);
      return Container(
        width: largeurCase,
        height: 44,
        decoration: BoxDecoration(
          color: etat == null ? Couleurs.attenteFond.withValues(alpha: .35) : null,
          border: Border(left: BorderSide(color: bordure)),
        ),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, e) {
            if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
            if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
              _aller(eleves, epreuves, ligne + 1, colonne);
              return KeyEventResult.handled;
            }
            if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
              _aller(eleves, epreuves, ligne - 1, colonne);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Tooltip(
            message: _erreurs[cle] ?? '',
            child: TextField(
              controller: c,
              focusNode: f,
              enabled: modifiable,
              textAlign: TextAlign.center,
              textInputAction: TextInputAction.next,
              onChanged: (t) => _taper(ev['id'] as String, el['id'] as String, cle, t),
              onSubmitted: (_) => _aller(eleves, epreuves, ligne + 1, colonne),
              style: _chiffresDep.copyWith(
                  fontSize: 15,
                  fontWeight: etat == 'note' ? FontWeight.w600 : FontWeight.w400,
                  color: _erreurs.containsKey(cle) ? Couleurs.retard : couleur),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: schema.primary, width: 1.5)),
                errorBorder: const OutlineInputBorder(borderSide: BorderSide(color: Couleurs.retard)),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                hintText: modifiable ? '·' : '',
                hintStyle: TextStyle(color: gris.withValues(alpha: .5)),
              ),
            ),
          ),
        ),
      );
    }

    // Le bas de chaque colonne : moyenne de l'épreuve et notes saisies.
    Widget pied(Map<String, Object?> ev) {
      final siennes = [for (final el in eleves) parCase['${ev['id']}|${el['id']}']].whereType<Map<String, Object?>>().toList();
      final valeurs = [for (final n in siennes) if (n['etat'] == 'note' && n['valeur'] != null) (n['valeur'] as num).toDouble()];
      final moy = valeurs.isEmpty ? null : valeurs.reduce((a, b) => a + b) / valeurs.length;
      final saisies = siennes.where((n) => n['etat'] != 'non_note').length;
      return Container(
        width: largeurCase,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: BoxDecoration(border: Border(left: BorderSide(color: bordure))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Text(_parAcquis ? '—' : noteLisible(moy), style: _chiffresDep.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
          Text('$saisies / ${eleves.length}',
              style: TextStyle(fontSize: 11, color: saisies >= eleves.length ? Couleurs.regle : Couleurs.attente)),
        ]),
      );
    }

    final tableau = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: bordure)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // En-tête : les épreuves, puis la moyenne de la matière.
            Container(
              color: Couleurs.doux(context).withValues(alpha: .5),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                SizedBox(
                    width: largeurNom,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Text('Élève', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: gris)),
                    )),
                for (final ev in epreuves) enTete(ev),
                if (!_parAcquis)
                  SizedBox(
                    width: largeurMoy,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text('Moyenne', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: gris)),
                    ),
                  ),
                if (widget.peutSaisir)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: TextButton.icon(
                      onPressed: () => nouvelle._nouvelle(context, matiereChoisie: matiere['id'] as String, ouvrirSaisie: false),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Nouvelle épreuve'),
                    ),
                  ),
              ]),
            ),
            for (var i = 0; i < eleves.length; i++)
              Container(
                decoration: BoxDecoration(border: Border(top: BorderSide(color: bordure))),
                child: Row(children: [
                  SizedBox(
                    width: largeurNom,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12, right: 8),
                      child: Row(children: [
                        SizedBox(width: 24, child: Text('${i + 1}', style: TextStyle(fontSize: 11, color: gris))),
                        Expanded(
                          child: Text('${eleves[i]['nom']} ${eleves[i]['prenoms']}',
                              overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        ),
                      ]),
                    ),
                  ),
                  for (var j = 0; j < epreuves.length; j++) caseNote(i, j),
                  if (!_parAcquis)
                    Container(
                      width: largeurMoy,
                      height: 44,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(border: Border(left: BorderSide(color: bordure))),
                      child: Builder(builder: (context) {
                        final m = moyenneEleve(eleves[i]['id'] as String);
                        return Text(noteLisible(m),
                            style: _chiffresDep.copyWith(
                                fontSize: 15, fontWeight: FontWeight.w700, color: m != null && m < _bareme / 2 ? Couleurs.retard : null));
                      }),
                    ),
                ]),
              ),
            Container(
              decoration: BoxDecoration(color: Couleurs.doux(context).withValues(alpha: .5), border: Border(top: BorderSide(color: bordure))),
              child: Row(children: [
                SizedBox(
                    width: largeurNom,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Text('Moyenne · saisies', style: TextStyle(fontSize: 12, color: gris)),
                    )),
                for (final ev in epreuves) pied(ev),
              ]),
            ),
          ]),
        ),
      ),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // La matière : un onglet par matière, le carnet de cette matière dessous.
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Segments<String>(
          valeur: matiere['id'] as String,
          choix: {
            for (final m in matieres)
              m['id'] as String: '${m['nom']} · coef. ${noteLisible((m['coefficient'] as num? ?? 1).toDouble()).replaceAll(',00', '')}',
          },
          onChanged: (v) => setState(() {
            _matiereId = v;
            _erreurs.clear();
          }),
        ),
      ),
      const SizedBox(height: 12),
      if (epreuves.isEmpty)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: bordure)),
          child: Row(children: [
            Expanded(
              child: Text('Aucune épreuve de ${matiere['nom']} ${widget.session == null ? 'sur cette période' : 'dans cette session'}.',
                  style: TextStyle(color: gris)),
            ),
            if (widget.peutSaisir)
              FilledButton.icon(
                onPressed: () => nouvelle._nouvelle(context, matiereChoisie: matiere['id'] as String, ouvrirSaisie: false),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Nouvelle épreuve'),
              ),
          ]),
        )
      else
        tableau,
      const SizedBox(height: 10),
      Text(
          _parAcquis
              ? 'Tapez A (acquis), EC (en cours) ou NA (non acquis) ; abs pour un absent. Entrée descend, Tab passe à droite.'
              : 'Tapez la note sur $_bareme, ou un code : a = absent (0), aj = absent justifié, d = dispensé, nc = non concerné. '
                  'Entrée descend, Tab passe à droite, flèches haut et bas. Le titre d\'une colonne : remise, historique, correction.',
          style: TextStyle(fontSize: 12, color: gris)),
    ]);
  }
}

/// Téléphone : un élève à la fois, avec un pavé de chiffres. Après chaque note,
/// l'élève suivant arrive ; « Liste » montre toute la classe.
class _SaisiePaveScreen extends StatefulWidget {
  const _SaisiePaveScreen({required this.espace, required this.evaluationId});

  final Espace espace;
  final String evaluationId;

  @override
  State<_SaisiePaveScreen> createState() => _SaisiePaveScreenState();
}

class _SaisiePaveScreenState extends State<_SaisiePaveScreen> {
  int _index = 0;
  String _tape = '';
  String? _erreur;

  @override
  Widget build(BuildContext context) => Requete(
        '''SELECT ev.*, m.nom AS matiere, t.libelle AS type, c.nom AS classe, p.bareme, p.nature, p.statut AS statut_periode,
             s.libelle AS session, s.statut AS statut_session
           FROM evaluations ev JOIN matieres m ON m.id = ev.matiere_id JOIN types_evaluation t ON t.id = ev.type_id
           JOIN classes c ON c.id = ev.classe_id JOIN periodes_evaluation p ON p.id = ev.periode_id
           LEFT JOIN sessions_evaluation s ON s.id = ev.session_id
           WHERE ev.id = ?''',
        parametres: [widget.evaluationId],
        builder: (context, l) {
          if (l.isEmpty) return const Scaffold(body: Center(child: Text('Épreuve introuvable.')));
          final ev = l.first;
          return Requete(
            '''SELECT e.id, e.nom, e.prenoms, e.matricule, n.valeur, n.etat, n.acquis
               FROM inscriptions i JOIN eleves e ON e.id = i.eleve_id
               LEFT JOIN notes n ON n.eleve_id = e.id AND n.evaluation_id = ?
               WHERE i.classe_id = ? AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')
               ORDER BY e.nom, e.prenoms''',
            parametres: [widget.evaluationId, ev['classe_id']],
            builder: (context, eleves) => _contenu(context, ev, eleves),
          );
        },
      );

  Future<void> _enregistrer(Map<String, Object?> ev, Lignes eleves, {String? etat, double? valeur, String? acquis}) async {
    if (eleves.isEmpty) return;
    await _ecrireNote(widget.espace.orgId, widget.evaluationId, eleves[_index]['id'] as String, ev['bareme'] as int? ?? 20,
        valeur: valeur, acquis: acquis, etat: etat);
    if (!mounted) return;
    setState(() {
      _tape = '';
      _erreur = null;
      if (_index < eleves.length - 1) _index++;
    });
  }

  Future<void> _valider(Map<String, Object?> ev, Lignes eleves) async {
    if (_tape.isEmpty) {
      // Rien tapé : on passe à l'élève suivant sans rien changer.
      if (_index < eleves.length - 1) setState(() => _index++);
      return;
    }
    final lu = _lireCase(_tape, ev['bareme'] as int? ?? 20);
    if (lu.erreur != null) {
      setState(() => _erreur = lu.erreur);
      return;
    }
    await _enregistrer(ev, eleves, etat: lu.etat, valeur: lu.valeur);
  }

  Widget _contenu(BuildContext context, Map<String, Object?> ev, Lignes eleves) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bareme = ev['bareme'] as int? ?? 20;
    final parAcquis = ev['nature'] == 'appreciations';
    final aLeDroit = widget.espace.fondateur ||
        widget.espace.droits.contains('saisir_notes') ||
        widget.espace.droits.contains('planifier_evaluations');
    final ouverte = aLeDroit && ev['statut_periode'] == 'ouverte' && ev['statut_session'] != 'cloturee';
    if (_index >= eleves.length) _index = eleves.isEmpty ? 0 : eleves.length - 1;
    final saisies = eleves.where((e) => e['etat'] != null && e['etat'] != 'non_note').length;
    final el = eleves.isEmpty ? null : eleves[_index];
    final actuel = el == null ? '' : _texteCase(el['etat'], el['valeur'], el['acquis']);

    void liste() => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (feuille) => SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .7,
              child: ListView(children: [
                for (var i = 0; i < eleves.length; i++)
                  ListTile(
                    dense: true,
                    selected: i == _index,
                    leading: Text('${i + 1}', style: TextStyle(color: gris)),
                    title: Text('${eleves[i]['nom']} ${eleves[i]['prenoms']}'),
                    trailing: Text(_texteCase(eleves[i]['etat'], eleves[i]['valeur'], eleves[i]['acquis']).isEmpty
                        ? '—'
                        : _texteCase(eleves[i]['etat'], eleves[i]['valeur'], eleves[i]['acquis'])),
                    onTap: () {
                      Navigator.pop(feuille);
                      setState(() {
                        _index = i;
                        _tape = '';
                        _erreur = null;
                      });
                    },
                  ),
              ]),
            ),
          ),
        );

    Widget touche(String t, {VoidCallback? appui, Color? fond, Widget? icone}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: SizedBox(
              height: 54,
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                    backgroundColor: fond, padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                onPressed: ouverte ? appui : null,
                child: icone ?? Text(t, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        );
    void taper(String c) => setState(() {
          _erreur = null;
          if (c == ',' && _tape.contains(',')) return;
          if (_tape.length < 5) _tape += c;
        });

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text('${ev['matiere']} · ${ev['classe']}', style: const TextStyle(fontSize: 17)),
        actions: [
          IconButton(tooltip: 'Liste de la classe', icon: const Icon(Icons.format_list_numbered), onPressed: liste),
          IconButton(
            tooltip: 'Saisie détaillée, historique, remise',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => _SaisieNotesScreen(espace: widget.espace, evaluationId: widget.evaluationId))),
          ),
        ],
      ),
      body: el == null
          ? const Center(child: Text('Aucun élève dans la classe.'))
          : SafeArea(
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('${ev['type']} du ${_dateLisible(ev['date_evaluation'])} · ${ev['session'] ?? 'hors session'}',
                        style: TextStyle(fontSize: 12, color: gris)),
                    const SizedBox(height: 6),
                    Row(children: [
                      Text('$saisies / ${eleves.length} saisies', style: TextStyle(fontSize: 12, color: gris)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: eleves.isEmpty ? 0 : saisies / eleves.length,
                            minHeight: 4,
                            backgroundColor: Couleurs.doux(context),
                            color: saisies >= eleves.length ? Couleurs.regle : Couleurs.attente,
                          ),
                        ),
                      ),
                    ]),
                  ]),
                ),
                // L'élève en cours, en grand ; glisser pour changer d'élève.
                Expanded(
                  child: GestureDetector(
                    onHorizontalDragEnd: (d) {
                      final v = d.primaryVelocity ?? 0;
                      if (v.abs() < 200) return;
                      setState(() {
                        _tape = '';
                        _erreur = null;
                        if (v < 0 && _index < eleves.length - 1) _index++;
                        if (v > 0 && _index > 0) _index--;
                      });
                    },
                    child: Container(
                      color: Colors.transparent,
                      width: double.infinity,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text('${_index + 1} / ${eleves.length}', style: TextStyle(fontSize: 13, color: gris)),
                        const SizedBox(height: 8),
                        Initiales('${el['nom']} ${el['prenoms']}', taille: 56),
                        const SizedBox(height: 10),
                        Text('${el['nom']} ${el['prenoms']}',
                            textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                        Text('${el['matricule']}', style: styleMono.copyWith(fontSize: 12, color: gris)),
                        const SizedBox(height: 14),
                        Text(
                          _tape.isNotEmpty ? _tape : (actuel.isEmpty ? (parAcquis ? '—' : '— / $bareme') : actuel),
                          style: _chiffresDep.copyWith(
                              fontSize: 40,
                              fontWeight: FontWeight.w700,
                              color: _erreur != null ? Couleurs.retard : (_tape.isEmpty && actuel.isEmpty ? gris : null)),
                        ),
                        if (_erreur != null) Text(_erreur!, style: const TextStyle(color: Couleurs.retard)),
                        if (!ouverte)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text('Lecture seule : session ou période clôturée (correction : saisie détaillée).',
                                textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: gris)),
                          ),
                      ]),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Column(children: [
                    Row(children: [
                      touche('', icone: const Icon(Icons.chevron_left), appui: _index > 0 ? () => setState(() => _index--) : null),
                      touche('', icone: const Icon(Icons.chevron_right),
                          appui: _index < eleves.length - 1 ? () => setState(() => _index++) : null),
                    ]),
                    if (parAcquis)
                      Row(children: [
                        touche('Acquis', fond: Couleurs.regleFond, appui: () => _enregistrer(ev, eleves, etat: 'note', acquis: 'acquis')),
                        touche('En cours', fond: Couleurs.attenteFond, appui: () => _enregistrer(ev, eleves, etat: 'note', acquis: 'en_cours')),
                        touche('Non acquis', fond: Couleurs.retardFond, appui: () => _enregistrer(ev, eleves, etat: 'note', acquis: 'non_acquis')),
                      ])
                    else ...[
                      for (final ligne in const [['7', '8', '9'], ['4', '5', '6'], ['1', '2', '3']])
                        Row(children: [for (final c in ligne) touche(c, appui: () => taper(c))]),
                      Row(children: [
                        touche(',', appui: () => taper(',')),
                        touche('0', appui: () => taper('0')),
                        touche('', icone: const Icon(Icons.backspace_outlined),
                            appui: () => setState(() => _tape = _tape.isEmpty ? '' : _tape.substring(0, _tape.length - 1))),
                      ]),
                      Row(children: [
                        touche('', fond: schema.primary, icone: Text('Valider', style: TextStyle(fontSize: 18, color: schema.onPrimary)),
                            appui: () => _valider(ev, eleves)),
                      ]),
                    ],
                    // Les cas sans note.
                    Wrap(spacing: 6, runSpacing: 6, alignment: WrapAlignment.center, children: [
                      for (final (cle, libelle) in const [
                        ('absent', 'Absent'),
                        ('absent_justifie', 'Abs. justifié'),
                        ('dispense', 'Dispensé'),
                        ('non_concerne', 'Non concerné'),
                      ])
                        ActionChip(label: Text(libelle), onPressed: ouverte ? () => _enregistrer(ev, eleves, etat: cle) : null),
                      if (actuel.isNotEmpty)
                        ActionChip(
                          avatar: const Icon(Icons.clear, size: 16),
                          label: const Text('Effacer'),
                          onPressed: ouverte
                              ? () async {
                                  await _ecrireNote(widget.espace.orgId, widget.evaluationId, el['id'] as String, bareme);
                                  if (mounted) setState(() => _tape = '');
                                }
                              : null,
                        ),
                    ]),
                  ]),
                ),
              ]),
            ),
    );
  }
}
