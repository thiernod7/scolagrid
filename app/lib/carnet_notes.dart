part of 'configuration.dart';

/// Le carnet de notes, à la manière des logiciels scolaires répandus : à gauche
/// « mes classes et matières » avec ce qui reste à compléter ; au centre le carnet
/// de la matière (une ligne par élève, une colonne par épreuve, les sessions en
/// bandeaux au-dessus, la moyenne à droite, la moyenne de la classe en bas) ; à
/// droite le panneau de l'épreuve choisie. On tape dans la case : Entrée descend,
/// Tab va à droite, flèches haut et bas ; codes a, aj, d, nc (maternelle A, EC, NA).
class _CarnetNotes extends StatefulWidget {
  const _CarnetNotes({
    required this.espace,
    required this.annee,
    required this.classe,
    required this.periode,
    required this.session,
    required this.sessions,
    required this.peutSaisir,
    this.cours,
  });

  final Espace espace;
  final Map<String, Object?> annee;
  final Map<String, Object?> classe;
  final Map<String, Object?> periode;
  final Map<String, Object?>? session;
  final Lignes sessions;
  final bool peutSaisir;

  /// Un enseignant : ses matières seulement (null : toutes).
  final MesCours? cours;

  @override
  State<_CarnetNotes> createState() => _CarnetNotesState();
}

class _CarnetNotesState extends State<_CarnetNotes> {
  String? _matiereId;
  String? _epreuveId;
  String _cherche = '';
  final _champs = <String, TextEditingController>{};
  final _focus = <String, FocusNode>{};
  final _erreurs = <String, String>{};

  /// Ce que la base contient pour chaque case (pour n'enregistrer que ce qui a changé).
  final _enBase = <String, String>{};

  static const _largeurNomMin = 180.0, _largeurCase = 112.0, _largeurTotal = 104.0, _largeurMoy = 124.0, _hauteurLigne = 56.0;

  /// La case où l'on tape : enregistrée si l'on change de classe ou de période sans la quitter.
  Future<void> Function()? _enCours;

  @override
  void didUpdateWidget(_CarnetNotes ancien) {
    super.didUpdateWidget(ancien);
    if (ancien.classe['id'] != widget.classe['id'] || ancien.periode['id'] != widget.periode['id']) {
      _enCours?.call();
      _enCours = null;
    }
  }

  @override
  void dispose() {
    _enCours?.call();
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
        // Les matières de la classe choisie, avec ce qui reste à saisir sur la période.
        '''SELECT m.id AS matiere_id, m.nom AS matiere, m.coefficient,
             (SELECT count(*) FROM evaluations ev WHERE ev.classe_id = ? AND ev.periode_id = ? AND ev.matiere_id = m.id) AS epreuves,
             (SELECT coalesce(sum(? - (SELECT count(*) FROM notes x WHERE x.evaluation_id = ev.id AND x.etat <> 'non_note')), 0)
              FROM evaluations ev WHERE ev.classe_id = ? AND ev.periode_id = ? AND ev.matiere_id = m.id) AS manquantes
           FROM matieres m WHERE m.niveau_id = ? ORDER BY m.nom''',
        parametres: [
          _classe['id'], _periode['id'], _classe['effectif'] ?? 0, _classe['id'], _periode['id'], _classe['niveau_id'],
        ],
        builder: (context, toutes) {
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          final cours = widget.cours;
          final miennes = cours == null ? toutes : toutes.where((m) => cours.voit(_classe['id'], m['matiere_id'])).toList();
          if (miennes.isEmpty) {
            return Text('Aucune matière pour ce niveau : ajoutez-les dans Paramètres › Matières.', style: TextStyle(color: gris));
          }
          final matiere = miennes.firstWhere((m) => m['matiere_id'] == _matiereId, orElse: () => miennes.first);
          return Requete(
            '''SELECT ev.*, t.libelle AS type, t.poids, t.compte, t.unique_par_periode, s.libelle AS session, s.statut AS statut_session
               FROM evaluations ev JOIN types_evaluation t ON t.id = ev.type_id
               LEFT JOIN sessions_evaluation s ON s.id = ev.session_id
               WHERE ev.classe_id = ? AND ev.periode_id = ? AND ev.matiere_id = ? AND (? IS NULL OR ev.session_id = ?)
               ORDER BY ev.date_evaluation, ev.created_at''',
            parametres: [_classe['id'], _periode['id'], matiere['matiere_id'], widget.session?['id'], widget.session?['id']],
            builder: (context, epreuves) => Requete(
              '''SELECT e.id, e.nom, e.prenoms, e.matricule FROM inscriptions i JOIN eleves e ON e.id = i.eleve_id
                 WHERE i.classe_id = ? AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant') ORDER BY e.nom, e.prenoms''',
              parametres: [_classe['id']],
              builder: (context, eleves) => Requete(
                '''SELECT n.evaluation_id, n.eleve_id, n.valeur, n.etat, n.acquis FROM notes n
                   JOIN evaluations ev ON ev.id = n.evaluation_id
                   WHERE ev.classe_id = ? AND ev.periode_id = ? AND ev.matiere_id = ?''',
                parametres: [_classe['id'], _periode['id'], matiere['matiere_id']],
                builder: (context, notes) => Requete(
                  "SELECT coalesce((SELECT absences FROM regles_notes WHERE organisation_id = ?), 'justifie_exclu') AS absences",
                  parametres: [widget.espace.orgId],
                  builder: (context, r) => _contenu(context, miennes, matiere, epreuves, eleves, notes, '${r.first['absences']}'),
                ),
              ),
            ),
          );
        },
      );

  /// Le champ d'une case, tenu à jour avec la base sauf pendant qu'on y tape.
  TextEditingController _champDe(String cle, String texte) {
    _enBase[cle] = texte;
    final c = _champs.putIfAbsent(cle, () => TextEditingController(text: texte));
    final enCours = _focus[cle]?.hasFocus ?? false;
    if (!enCours && !_erreurs.containsKey(cle) && c.text != texte) c.text = texte;
    return c;
  }

  /// Pendant la frappe : on signale seulement une saisie impossible (rien n'est écrit).
  void _taper(String cle, String texte) {
    final erreur = _lireCase(texte, _bareme, parAcquis: _parAcquis).erreur;
    if (erreur != _erreurs[cle]) setState(() => erreur == null ? _erreurs.remove(cle) : _erreurs[cle] = erreur);
  }

  /// En quittant la case (Entrée, Tab, flèche, clic ailleurs) : on enregistre une
  /// seule fois, et seulement si la note a changé. La saisie reste fluide.
  Future<void> _enregistrer(String evaluationId, String eleveId, String cle) async {
    final texte = _champs[cle]?.text.trim() ?? '';
    if (texte == (_enBase[cle] ?? '').trim()) return;
    final bareme = _bareme, parAcquis = _parAcquis, orgId = widget.espace.orgId;
    final lu = _lireCase(texte, bareme, parAcquis: parAcquis);
    if (lu.erreur != null) return;
    _enBase[cle] = texte;
    await _ecrireNote(orgId, evaluationId, eleveId, bareme, valeur: lu.valeur, acquis: lu.acquis, etat: lu.etat);
  }

  void _aller(Lignes eleves, Lignes epreuves, int ligne, int colonne) {
    if (ligne < 0 || ligne >= eleves.length || colonne < 0 || colonne >= epreuves.length) return;
    _focus['${epreuves[colonne]['id']}|${eleves[ligne]['id']}']?.requestFocus();
  }

  String _court(Object? date) {
    final d = DateTime.tryParse('$date');
    if (d == null) return '';
    const mois = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
    return '${d.day.toString().padLeft(2, '0')} ${mois[d.month - 1]}';
  }

  Widget _contenu(BuildContext context, Lignes services, Map<String, Object?> matiere, Lignes epreuves, Lignes eleves, Lignes notes,
      String absences) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    // Largeur d'une colonne d'épreuve, ajustée à la place disponible (voir plus bas).
    var largeurCase = _largeurCase;
    // Saisir ici : le droit, et pour un enseignant, cette matière dans cette classe.
    final saisir = widget.peutSaisir && (widget.cours?.saisit(_classe['id'], matiere['matiere_id']) ?? true);
    final parCase = {for (final n in notes) '${n['evaluation_id']}|${n['eleve_id']}': n};
    final choisie = epreuves.where((e) => e['id'] == _epreuveId).firstOrNull ??
        epreuves.where((e) => eleves.any((el) => parCase['${e['id']}|${el['id']}'] == null)).firstOrNull ??
        epreuves.lastOrNull;
    String nb(num v) => noteLisible(v.toDouble()).replaceAll(',00', '');
    bool compo(Map<String, Object?> e) => e['unique_par_periode'] == 1 || '${e['type']}'.toLowerCase().contains('compo');

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
    final moyennes = {for (final el in eleves) el['id'] as String: moyenneEleve(el['id'] as String)};
    final totaux = {
      for (final el in eleves)
        el['id'] as String: totalMatiere([
          for (final ev in epreuves)
            if (parCase['${ev['id']}|${el['id']}'] case final n?)
              NoteCalcul(
                valeur: (n['valeur'] as num?)?.toDouble(),
                etat: '${n['etat']}',
                poids: (ev['poids'] as num? ?? 1).toDouble(),
                compte: ev['compte'] == 1,
              ),
        ], _bareme, absences: absences),
    };
    final avecMoy = moyennes.values.whereType<double>().toList();
    final moyClasse = avecMoy.isEmpty ? null : avecMoy.reduce((a, b) => a + b) / avecMoy.length;

    ({double? moy, int saisies, double? haut, double? bas, List<String> manquent}) stats(Map<String, Object?> ev) {
      final valeurs = <double>[];
      var saisies = 0;
      final manquent = <String>[];
      for (final el in eleves) {
        final n = parCase['${ev['id']}|${el['id']}'];
        if (n == null || n['etat'] == 'non_note') {
          manquent.add('${el['nom']} ${el['prenoms']}');
          continue;
        }
        saisies++;
        if (n['etat'] == 'note' && n['valeur'] != null) valeurs.add((n['valeur'] as num).toDouble());
      }
      return (
        moy: valeurs.isEmpty ? null : valeurs.reduce((a, b) => a + b) / valeurs.length,
        saisies: saisies,
        haut: valeurs.isEmpty ? null : valeurs.reduce((a, b) => a > b ? a : b),
        bas: valeurs.isEmpty ? null : valeurs.reduce((a, b) => a < b ? a : b),
        manquent: manquent,
      );
    }

    // --- À gauche : mes classes et matières ---------------------------------------------
    final q = nomSimplifie(_cherche);
    final rail = Container(
      width: 270,
      decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: bordure)),
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 36,
          child: TextField(
            onChanged: (v) => setState(() => _cherche = v),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              prefixIcon: Icon(Icons.search, size: 18, color: gris),
              prefixIconConstraints: const BoxConstraints(minWidth: 36),
              hintText: 'Chercher une matière',
              hintStyle: TextStyle(fontSize: 13, color: gris),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 6),
          child: Text('MATIÈRES · ${'${_classe['nom']}'.toUpperCase()}', style: TextStyle(fontSize: 11, letterSpacing: .6, fontWeight: FontWeight.w600, color: gris)),
        ),
        for (final s in services)
          if (q.isEmpty || nomSimplifie('${s['matiere']}').contains(q))
            Builder(builder: (context) {
              final actif = s['matiere_id'] == matiere['matiere_id'];
              final ep = s['epreuves'] as int? ?? 0;
              final manque = s['manquantes'] as int? ?? 0;
              return Material(
                color: actif ? Couleurs.doux(context) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus(); // enregistre la case en cours
                    setState(() {
                      _matiereId = s['matiere_id'] as String;
                      _epreuveId = null;
                      _erreurs.clear();
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${s['matiere']}',
                              overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          Text(
                              ep == 0
                                  ? 'aucune épreuve'
                                  : '$ep épreuve${ep > 1 ? 's' : ''} · ${manque > 0 ? '$manque à compléter' : 'à jour'}',
                              style: TextStyle(fontSize: 12, color: gris)),
                        ]),
                      ),
                      if (ep > 0)
                        Container(
                          constraints: const BoxConstraints(minWidth: 22),
                          height: 22,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                              color: manque > 0 ? Couleurs.attenteFond : Couleurs.regleFond, borderRadius: BorderRadius.circular(11)),
                          child: manque > 0
                              ? Text('$manque', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Couleurs.attente))
                              : const Icon(Icons.check, size: 14, color: Couleurs.regle),
                        ),
                    ]),
                  ),
                ),
              );
            }),
      ]),
    );

    // --- Au centre : le carnet ----------------------------------------------------------
    final bareme = _parAcquis ? 'acquis' : 'sur $_bareme';
    Widget enTete(Map<String, Object?> ev) {
      final actif = ev['id'] == choisie?['id'];
      final poids = (ev['poids'] as num? ?? 1).toDouble();
      return InkWell(
        onTap: () => setState(() => _epreuveId = ev['id'] as String),
        child: Container(
          width: largeurCase,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: actif ? Couleurs.infoFond : null,
            border: Border(left: BorderSide(color: bordure), bottom: BorderSide(color: actif ? Couleurs.info : Colors.transparent, width: 2)),
          ),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (ev['statut_session'] == 'cloturee') Icon(Icons.lock_outline, size: 12, color: gris),
              if (ev['remise_le'] != null) const Icon(Icons.task_alt, size: 12, color: Couleurs.regle),
              Flexible(
                child: Text(compo(ev) ? 'Composition' : '${ev['type']}',
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ]),
            Text(
                '${_court(ev['date_evaluation'])}${'${ev['date_evaluation']}'.compareTo(_date(DateTime.now())) > 0 ? ' · à venir' : ''}'
                '${heureLisible(ev['heure'], null).isEmpty ? '' : ' · ${heureLisible(ev['heure'], null)}'}',
                style: TextStyle(fontSize: 12, color: gris)),
            Text('$bareme${poids != 1 ? ' · ×${nb(poids)}' : ''}${ev['compte'] == 1 ? '' : ' · hors moy.'}',
                style: TextStyle(fontSize: 11, color: gris)),
          ]),
        ),
      );
    }

    // Les bandeaux de session : ils regroupent les colonnes de la même session.
    // « Évaluation d'octobre » s'affiche « Octobre » (le nom complet au survol).
    String courtSession(String l) {
      final c = l.replaceFirst(RegExp(r"^Évaluation (de |d')"), '');
      return c.isEmpty ? l : c[0].toUpperCase() + c.substring(1);
    }
    final bandeaux = <({String libelle, int n, bool compo})>[];
    for (final ev in epreuves) {
      final libelle = '${ev['session'] ?? 'Hors session'}';
      if (bandeaux.isNotEmpty && bandeaux.last.libelle == libelle) {
        final d = bandeaux.removeLast();
        bandeaux.add((libelle: d.libelle, n: d.n + 1, compo: d.compo));
      } else {
        bandeaux.add((libelle: libelle, n: 1, compo: compo(ev)));
      }
    }

    Widget caseNote(int ligne, int colonne) {
      final ev = epreuves[colonne];
      final el = eleves[ligne];
      final cle = '${ev['id']}|${el['id']}';
      final n = parCase[cle];
      final c = _champDe(cle, _texteCase(n?['etat'], n?['valeur'], n?['acquis']));
      final f = _focus.putIfAbsent(cle, FocusNode.new);
      // Les notes se saisissent à partir du jour de l'épreuve.
      final modifiable = saisir && ev['statut_session'] != 'cloturee' && '${ev['date_evaluation']}'.compareTo(_date(DateTime.now())) <= 0;
      final v = (n?['valeur'] as num?)?.toDouble();
      final etat = n?['etat'] as String?;
      final actif = ev['id'] == choisie?['id'];
      final couleur = etat == null
          ? null
          : etat == 'note'
              ? (n?['acquis'] != null
                  ? switch (n?['acquis']) { 'acquis' => Couleurs.regle, 'en_cours' => Couleurs.attente, _ => Couleurs.retard }
                  : (v != null && v < _bareme / 2 ? Couleurs.retard : null))
              : (etat == 'absent' ? Couleurs.retard : gris);
      return Container(
        width: largeurCase,
        height: _hauteurLigne,
        decoration: BoxDecoration(
          // Case vide : teintée (orange dans l'épreuve choisie) pour voir tout de suite ce qui manque.
          color: etat == null
              ? (actif ? Couleurs.attenteFond : Couleurs.doux(context).withValues(alpha: .6))
              : (actif ? const Color(0x0D2F72C4) : null),
          border: Border(left: BorderSide(color: bordure)),
        ),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (dedans) {
            Future<void> enregistrer() => _enregistrer(ev['id'] as String, el['id'] as String, cle);
            if (!dedans) {
              _enCours = null;
              enregistrer();
              return;
            }
            _enCours = enregistrer;
            if (_epreuveId != ev['id']) setState(() => _epreuveId = ev['id'] as String);
          },
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
              onChanged: (t) => _taper(cle, t),
              onSubmitted: (_) {
                _enregistrer(ev['id'] as String, el['id'] as String, cle);
                _aller(eleves, epreuves, ligne + 1, colonne);
              },
              style: _chiffresDep.copyWith(
                  fontSize: 17,
                  fontWeight: etat == 'note' ? FontWeight.w600 : FontWeight.w500,
                  color: _erreurs.containsKey(cle) ? Couleurs.retard : couleur),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                focusedBorder: const OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: Couleurs.info, width: 2)),
                contentPadding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
        ),
      );
    }

    Widget pied(Map<String, Object?> ev) {
      final st = stats(ev);
      final complet = st.saisies >= eleves.length;
      return Container(
        width: largeurCase,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(border: Border(left: BorderSide(color: bordure))),
        child: Column(children: [
          Text(_parAcquis ? '—' : noteLisible(st.moy), style: _chiffresDep.copyWith(fontSize: 14, fontWeight: FontWeight.w700)),
          Text(st.saisies == 0 ? 'pas commencée' : '${st.saisies} / ${eleves.length} saisies',
              style: TextStyle(fontSize: 11, color: st.saisies == 0 ? gris : (complet ? Couleurs.regle : Couleurs.attente))),
        ]),
      );
    }

    Widget carnetDe(double nomL) => Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: bordure)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Bandeaux de session.
            Container(
              color: Couleurs.doux(context).withValues(alpha: .5),
              child: Row(children: [
                SizedBox(width: nomL),
                for (final b in bandeaux)
                  Container(
                    width: largeurCase * b.n,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: b.libelle == 'Hors session' ? null : (b.compo ? Couleurs.attenteFond : Couleurs.infoFond),
                      border: Border(left: BorderSide(color: bordure)),
                    ),
                    child: Tooltip(
                      message: b.libelle,
                      child: Text(courtSession(b.libelle),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: b.libelle == 'Hors session' ? gris : (b.compo ? Couleurs.attente : Couleurs.info))),
                    ),
                  ),
                Container(width: _largeurTotal + _largeurMoy, height: 30, decoration: BoxDecoration(border: Border(left: BorderSide(color: bordure)))),
              ]),
            ),
            // En-têtes des épreuves.
            Container(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: bordure), bottom: BorderSide(color: bordure))),
              child: IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(
                    width: nomL,
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 0, 10),
                        child: Text('Élève', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: gris)),
                      ),
                    ),
                  ),
                  for (final ev in epreuves) enTete(ev),
                  Container(
                    width: _largeurTotal,
                    padding: const EdgeInsets.fromLTRB(14, 0, 10, 10),
                    decoration: BoxDecoration(border: Border(left: BorderSide(color: schema.onSurface, width: 2))),
                    alignment: Alignment.bottomLeft,
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Total', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                      Text(_parAcquis ? '' : 'des notes', style: TextStyle(fontSize: 11, color: gris)),
                    ]),
                  ),
                  Container(
                    width: _largeurMoy,
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                    decoration: BoxDecoration(border: Border(left: BorderSide(color: bordure))),
                    alignment: Alignment.bottomLeft,
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Moyenne', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                      Text(widget.session == null ? 'de la période' : 'de la session', style: TextStyle(fontSize: 11, color: gris)),
                    ]),
                  ),
                ]),
              ),
            ),
            // Une ligne par élève.
            for (var i = 0; i < eleves.length; i++)
              Container(
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bordure.withValues(alpha: .6)))),
                child: Row(children: [
                  SizedBox(
                    width: nomL,
                    height: _hauteurLigne,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(children: [
                        Initiales('${eleves[i]['nom']} ${eleves[i]['prenoms']}', taille: 32),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text('${eleves[i]['nom']} ${eleves[i]['prenoms']}',
                              overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        ),
                      ]),
                    ),
                  ),
                  for (var j = 0; j < epreuves.length; j++) caseNote(i, j),
                  Container(
                    width: _largeurTotal,
                    height: _hauteurLigne,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(border: Border(left: BorderSide(color: schema.onSurface, width: 2))),
                    child: _parAcquis || totaux[eleves[i]['id']] == null
                        ? Text('—', style: TextStyle(color: gris))
                        : Text.rich(TextSpan(children: [
                            TextSpan(text: nb(totaux[eleves[i]['id']]!.total), style: _chiffresDep.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
                            TextSpan(text: ' / ${nb(totaux[eleves[i]['id']]!.sur)}', style: _chiffresDep.copyWith(fontSize: 12, color: gris)),
                          ])),
                  ),
                  Container(
                    width: _largeurMoy,
                    height: _hauteurLigne,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(color: Couleurs.doux(context).withValues(alpha: .35), border: Border(left: BorderSide(color: bordure))),
                    child: Text(_parAcquis ? '—' : noteLisible(moyennes[eleves[i]['id']]),
                        style: _chiffresDep.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: (moyennes[eleves[i]['id']] ?? _bareme.toDouble()) < _bareme / 2 ? Couleurs.retard : null)),
                  ),
                ]),
              ),
            // Moyenne de la classe.
            Container(
              color: Couleurs.doux(context).withValues(alpha: .5),
              child: Row(children: [
                SizedBox(
                  width: nomL,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text('Moyenne de la classe', style: TextStyle(fontSize: 13, color: gris)),
                  ),
                ),
                for (final ev in epreuves) pied(ev),
                Container(
                  width: _largeurTotal,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  decoration: BoxDecoration(border: Border(left: BorderSide(color: schema.onSurface, width: 2))),
                  child: const Text(''),
                ),
                Container(
                  width: _largeurMoy,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(border: Border(left: BorderSide(color: bordure))),
                  child: Text(_parAcquis ? '—' : noteLisible(moyClasse), style: _chiffresDep.copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );

    // --- À droite : l'épreuve choisie ----------------------------------------------------
    Widget chiffre(String libelle, String valeur, {Color? couleur}) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(border: Border.all(color: bordure), borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(libelle, style: TextStyle(fontSize: 11, color: gris)),
              Text(valeur, style: _chiffresDep.copyWith(fontSize: 18, fontWeight: FontWeight.w700, color: couleur)),
            ]),
          ),
        );
    Widget panneau(Map<String, Object?> ev) {
      final st = stats(ev);
      final ferme = ev['statut_session'] == 'cloturee';
      return Container(
        width: 290,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: bordure)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Épreuve choisie', style: TextStyle(fontSize: 12, color: gris)),
          Text('${compo(ev) ? 'Composition' : ev['type']} du ${_dateLisible(ev['date_evaluation']).substring(0, 5)}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          Text(
              [
                '${ev['session'] ?? 'Hors session'}',
                bareme,
                'poids ${nb((ev['poids'] as num? ?? 1))}',
                if (ev['libelle'] != null) '${ev['libelle']}',
              ].join(' · '),
              style: TextStyle(fontSize: 13, color: gris)),
          const SizedBox(height: 14),
          Row(children: [
            chiffre('Moyenne', _parAcquis ? '—' : noteLisible(st.moy)),
            const SizedBox(width: 8),
            chiffre('Saisies', '${st.saisies} / ${eleves.length}', couleur: st.saisies >= eleves.length ? Couleurs.regle : Couleurs.attente),
          ]),
          if (!_parAcquis) ...[
            const SizedBox(height: 8),
            Row(children: [
              chiffre('Plus haute', st.haut == null ? '—' : nb(st.haut!)),
              const SizedBox(width: 8),
              chiffre('Plus basse', st.bas == null ? '—' : nb(st.bas!)),
            ]),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: st.manquent.isEmpty ? Couleurs.regleFond : Couleurs.attenteFond, borderRadius: BorderRadius.circular(8)),
            child: Text(
                st.manquent.isEmpty
                    ? 'Toutes les notes sont saisies.'
                    : st.manquent.length <= 3
                        ? 'Il manque la note de ${st.manquent.join(', ')}.'
                        : 'Il manque ${st.manquent.length} notes (${st.manquent.take(2).join(', ')}…).',
                style: TextStyle(fontSize: 13, color: st.manquent.isEmpty ? Couleurs.regle : Couleurs.attente)),
          ),
          if (ferme) ...[
            const SizedBox(height: 8),
            const Etat('Session clôturée : correction avec motif', icone: Icons.lock_outline),
          ],
          const SizedBox(height: 14),
          if (ev['remise_le'] != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Etat('Notes remises le ${_dateLisible(ev['remise_le'])}', ton: Ton.regle, icone: Icons.task_alt),
            ),
          if (saisir)
            FilledButton(
              onPressed: () => db.execute('UPDATE evaluations SET remise_le = ?, remise_par = ?, updated_at = ? WHERE id = ?',
                  [ev['remise_le'] == null ? _maintenant() : null, ev['remise_le'] == null ? monId : null, _maintenant(), ev['id']]),
              child: Text(ev['remise_le'] == null ? 'J\'ai terminé : remettre les notes' : 'Annuler la remise'),
            ),
          const SizedBox(height: 6),
          TextButton.icon(
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => _SaisieNotesScreen(espace: widget.espace, evaluationId: ev['id'] as String))),
            icon: const Icon(Icons.history, size: 18),
            label: Text(ferme ? 'Corriger (motif), historique' : 'Historique, saisie détaillée'),
          ),
          if (saisir && !ferme)
            TextButton.icon(
              style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: Couleurs.retard),
              onPressed: () async {
                if (await _confirmer(context, 'Supprimer cette épreuve et toutes ses notes ?')) {
                  await _supprimer('evaluations', ev['id'] as String);
                  if (mounted) setState(() => _epreuveId = null);
                }
              },
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Supprimer l\'épreuve'),
            ),
        ]),
      );
    }

    final enTeteMatiere = Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${_classe['nom']} · ${eleves.length} élève${eleves.length > 1 ? 's' : ''} · coefficient ${nb(matiere['coefficient'] as num? ?? 1)}',
              style: TextStyle(fontSize: 13, color: gris)),
          Text('${matiere['matiere']}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -.3)),
        ]),
      ),
      // Les épreuves viennent du calendrier (Évaluations › Calendrier) : ici, on remplit les notes.
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.event_note_outlined, size: 16, color: gris),
        const SizedBox(width: 6),
        Text('Épreuves programmées dans Évaluations › Calendrier', style: TextStyle(fontSize: 13, color: gris)),
      ]),
    ]);

    final centre = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      enTeteMatiere,
      const SizedBox(height: 14),
      if (epreuves.isEmpty)
        Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: bordure)),
          child: Column(children: [
            Icon(Icons.edit_note, size: 32, color: gris),
            const SizedBox(height: 8),
            Text('Aucune évaluation programmée en ${matiere['matiere']} ${widget.session == null ? 'sur cette période' : 'dans cette session'}.',
                style: TextStyle(color: gris)),
            const SizedBox(height: 4),
            Text('Les épreuves se programment dans Évaluations › Calendrier ; elles apparaissent ici.', style: TextStyle(fontSize: 12, color: gris)),
          ]),
        )
      else
        // La colonne des noms s'élargit : total et moyenne restent collés à droite, comme sur un bulletin.
        // Les colonnes d'épreuves se resserrent (jusqu'à 84 px) pour que tout tienne ; au-delà, on fait défiler.
        LayoutBuilder(builder: (context, c) {
          final dispo = c.maxWidth - 2 - _largeurTotal - _largeurMoy;
          largeurCase = ((dispo - _largeurNomMin) / epreuves.length).clamp(84.0, _largeurCase).floorToDouble();
          return carnetDe(math.max(_largeurNomMin, dispo - epreuves.length * largeurCase).floorToDouble());
        }),
      const SizedBox(height: 12),
      Wrap(spacing: 18, runSpacing: 6, children: [
        Text.rich(TextSpan(style: TextStyle(fontSize: 12, color: gris), children: const [
          TextSpan(text: 'Tapez la note puis '),
          TextSpan(text: 'Entrée', style: TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: ' : élève suivant'),
        ])),
        Text.rich(TextSpan(style: TextStyle(fontSize: 12, color: gris), children: const [
          TextSpan(text: 'Tab', style: TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: ' : épreuve suivante'),
        ])),
        Text(
            _parAcquis ? 'A acquis · EC en cours · NA non acquis · abs absent' : 'a absent (0) · aj absent justifié · d dispensé · nc non concerné',
            style: TextStyle(fontSize: 12, color: gris)),
        const Text('● Enregistré sur ce poste', style: TextStyle(fontSize: 12, color: Couleurs.regle)),
      ]),
    ]);

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      rail,
      const SizedBox(width: 16),
      Expanded(child: centre),
      if (choisie != null) ...[
        const SizedBox(width: 16),
        panneau(choisie),
      ],
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
        '''SELECT ev.*, (SELECT count(*) FROM enseignements ens JOIN personnel pe ON pe.id = ens.personnel_id
                WHERE pe.user_id = ? AND ens.classe_id = ev.classe_id AND ens.matiere_id = ev.matiere_id
                  AND ens.debut <= date('now') AND (ens.fin IS NULL OR date(ens.fin, '+7 day') >= date('now'))) AS j_enseigne,
            m.nom AS matiere, t.libelle AS type, c.nom AS classe, p.bareme, p.nature, p.statut AS statut_periode,
             s.libelle AS session, s.statut AS statut_session
           FROM evaluations ev JOIN matieres m ON m.id = ev.matiere_id JOIN types_evaluation t ON t.id = ev.type_id
           JOIN classes c ON c.id = ev.classe_id JOIN periodes_evaluation p ON p.id = ev.periode_id
           LEFT JOIN sessions_evaluation s ON s.id = ev.session_id
           WHERE ev.id = ?''',
        parametres: [monId, widget.evaluationId],
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
        widget.espace.droits.contains('planifier_evaluations') ||
        (widget.espace.droits.contains('saisir_notes') && (ev['j_enseigne'] as int? ?? 0) > 0);
    final aVenir = '${ev['date_evaluation']}'.compareTo(_date(DateTime.now())) > 0;
    final ouverte = aLeDroit && ev['statut_periode'] == 'ouverte' && ev['statut_session'] != 'cloturee' && !aVenir;
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
                        // Un repère : l'élève d'avant et sa note, pour ne pas se perdre.
                        if (_index > 0 && _erreur == null)
                          Text(
                              'Précédent : ${eleves[_index - 1]['nom']} ${eleves[_index - 1]['prenoms']} · '
                              '${_texteCase(eleves[_index - 1]['etat'], eleves[_index - 1]['valeur'], eleves[_index - 1]['acquis']).isEmpty ? 'sans note' : _texteCase(eleves[_index - 1]['etat'], eleves[_index - 1]['valeur'], eleves[_index - 1]['acquis'])}',
                              style: TextStyle(fontSize: 12, color: gris)),
                        if (!ouverte)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                                aVenir
                                    ? 'Épreuve du ${_dateLisible(ev['date_evaluation'])} : les notes se saisissent à partir de ce jour.'
                                    : 'Lecture seule : session ou période clôturée (correction : saisie détaillée).',
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
                        touche('', fond: schema.primary, icone: Text('Valider · élève suivant', style: TextStyle(fontSize: 18, color: schema.onPrimary)),
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
