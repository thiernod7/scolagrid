part of 'configuration.dart';

/// Évaluations › Calendrier : on y place les évaluations de l'année.
///
/// 1. Paramètres fixe les sessions (« Évaluation d'octobre » du 1er au 31…).
/// 2. Ici, la direction ajoute les évaluations : une ou plusieurs classes, une
///    matière, un jour (et, pour une composition, l'heure et la durée). La
///    session et la nature se déduisent de la date.
/// 3. Dans « Saisie des notes », les colonnes sont prêtes : on remplit les
///    notes, à partir du jour de chaque épreuve.
/// « Valider et publier » fige le calendrier d'une session pour les enseignants ;
/// une épreuve déplacée ensuite garde sa date prévue (serveur : migration 045).

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
const _moisAbreges = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
const _joursCalendrier = ['Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dim.'];
const _couleurEval = Color(0xFF2F72C4), _couleurCompo = Color(0xFFC2410C);

/// Une composition (une par période et par matière) : orange ; une évaluation : bleu.
bool _estCompo(Map<String, Object?> s) => s['unique_par_periode'] == 1;

/// Tout ce que le calendrier lit, une fois.
class _DonneesCalendrier {
  _DonneesCalendrier(this.annee, this.classes, this.sessions, this.epreuves, this.services, this.matieres);

  final Map<String, Object?> annee;
  final Lignes classes, sessions, epreuves, services, matieres;

  late final classeParId = {for (final c in classes) c['id'] as String: c};
  late final enseignants = {for (final s in services) '${s['classe_id']}|${s['matiere_id']}': s['enseignants'] as String?};

  /// La session (ouverte) qui couvre ce jour pour ce cycle.
  Map<String, Object?>? sessionDu(String jour, Object? cycle) => sessions
      .where((s) => s['cycle'] == cycle && '${s['debut']}'.compareTo(jour) <= 0 && '${s['fin']}'.compareTo(jour) >= 0)
      .firstOrNull;
}

class CalendrierEvaluationsScreen extends StatefulWidget {
  const CalendrierEvaluationsScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<CalendrierEvaluationsScreen> createState() => _CalendrierEvaluationsScreenState();
}

enum _Vue { mois, semaine, liste }

class _CalendrierEvaluationsScreenState extends State<CalendrierEvaluationsScreen> {
  DateTime _jour = DateTime.now(); // un jour du mois (ou de la semaine) affiché
  _Vue _vue = _Vue.mois;
  String _classe = '';
  String _cycle = '';
  String? _sessionId;

  Espace get _e => widget.espace;
  bool get _planifie => _e.fondateur || _e.droits.contains('planifier_evaluations');

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT * FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1',
        parametres: [_e.orgId],
        builder: (context, annees) {
          if (annees.isEmpty) return _Page(titre: 'Calendrier des évaluations', corps: _vide("Créez d'abord l'année scolaire (Paramètres)."));
          final annee = annees.first;
          return avecMesCours(
            _e,
            (cours) => Requete(
              '''SELECT c.id, c.nom, c.niveau_id, n.nom AS niveau, n.cycle, n.ordre FROM classes c JOIN niveaux n ON n.id = c.niveau_id
                 WHERE c.annee_id = ? AND c.fermee = 0 ORDER BY n.ordre, c.nom''',
              parametres: [annee['id']],
              builder: (context, classes) => Requete(
                '''SELECT s.*, t.libelle AS type, t.unique_par_periode, t.poids, p.cycle, p.libelle AS periode, p.bareme, p.statut AS statut_periode
                     FROM sessions_evaluation s JOIN types_evaluation t ON t.id = s.type_id JOIN periodes_evaluation p ON p.id = s.periode_id
                    WHERE p.annee_id = ? ORDER BY s.debut, p.cycle, s.ordre''',
                parametres: [annee['id']],
                builder: (context, sessions) => Requete(
                  '''SELECT ev.id, ev.classe_id, ev.matiere_id, ev.session_id, ev.date_evaluation, ev.date_prevue, ev.heure, ev.duree_min,
                       m.nom AS matiere, (SELECT count(*) FROM notes n WHERE n.evaluation_id = ev.id) AS notes
                     FROM evaluations ev JOIN matieres m ON m.id = ev.matiere_id JOIN classes c ON c.id = ev.classe_id
                    WHERE c.annee_id = ? ORDER BY ev.date_evaluation, ev.heure''',
                  parametres: [annee['id']],
                  builder: (context, epreuves) => Requete(
                    '''SELECT c.id AS classe_id, m.id AS matiere_id, m.nom AS matiere,
                         (SELECT group_concat(pe.nom_complet, ', ') FROM enseignements ens JOIN personnel pe ON pe.id = ens.personnel_id
                           WHERE ens.classe_id = c.id AND ens.matiere_id = m.id AND (ens.fin IS NULL OR ens.fin >= date('now'))) AS enseignants
                       FROM classes c JOIN matieres m ON m.niveau_id = c.niveau_id JOIN niveaux n ON n.id = c.niveau_id
                      WHERE c.annee_id = ? AND c.fermee = 0 ORDER BY n.ordre, c.nom, m.nom''',
                    parametres: [annee['id']],
                    builder: (context, services) => Requete(
                      'SELECT m.id, m.nom, m.niveau_id FROM matieres m WHERE m.organisation_id = ? ORDER BY m.nom',
                      parametres: [_e.orgId],
                      builder: (context, matieres) {
                        // Un enseignant : ses classes seulement, en lecture.
                        final mesClasses = cours?.classes;
                        final d = _DonneesCalendrier(
                          annee,
                          mesClasses == null ? classes : classes.where((c) => mesClasses.contains(c['id'])).toList(),
                          sessions,
                          mesClasses == null ? epreuves : epreuves.where((e) => cours!.voit(e['classe_id'], e['matiere_id'])).toList(),
                          mesClasses == null ? services : services.where((s) => cours!.voit(s['classe_id'], s['matiere_id'])).toList(),
                          matieres,
                        );
                        return _contenu(context, d, cours == null && _planifie);
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );

  // --- Les filtres ---------------------------------------------------------------------

  /// Le cycle affiché : celui de la classe choisie, sinon celui choisi.
  String _cycleActif(_DonneesCalendrier d) => _classe.isNotEmpty ? '${d.classeParId[_classe]?['cycle'] ?? ''}' : _cycle;

  bool _garde(_DonneesCalendrier d, Object? classeId) {
    if (_classe.isNotEmpty) return classeId == _classe;
    if (_cycle.isEmpty) return true;
    return d.classeParId[classeId]?['cycle'] == _cycle;
  }

  /// Les sessions qui couvrent un jour, pour les cycles affichés.
  List<Map<String, Object?>> _sessionsDu(_DonneesCalendrier d, String jour) {
    final cycle = _cycleActif(d);
    return d.sessions
        .where((s) => (cycle.isEmpty || s['cycle'] == cycle) && '${s['debut']}'.compareTo(jour) <= 0 && '${s['fin']}'.compareTo(jour) >= 0)
        .toList();
  }

  // --- La page -------------------------------------------------------------------------

  Widget _contenu(BuildContext context, _DonneesCalendrier d, bool modifie) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final largeur = MediaQuery.sizeOf(context).width;
    final telephone = largeur < 700;
    final vue = telephone ? _Vue.liste : _vue;
    final cycles = <String, String>{for (final c in d.classes) '${c['cycle']}': nomsCycles[c['cycle']] ?? '${c['cycle']}'};

    // La période affichée : le mois (grille), la semaine (semaine, et liste sur téléphone).
    final lundi = DateTime(_jour.year, _jour.month, _jour.day - (_jour.weekday - 1));
    final premierMois = DateTime(_jour.year, _jour.month, 1);
    final debutGrille = DateTime(premierMois.year, premierMois.month, 1 - (premierMois.weekday - 1));
    final finMois = DateTime(_jour.year, _jour.month + 1, 0);
    final titre = vue == _Vue.mois || (vue == _Vue.liste && !telephone)
        ? '${_moisNoms[_jour.month - 1][0].toUpperCase()}${_moisNoms[_jour.month - 1].substring(1)} ${_jour.year}'
        : '${lundi.day} ${_moisAbreges[lundi.month - 1]} – ${lundi.add(const Duration(days: 6)).day} ${_moisAbreges[lundi.add(const Duration(days: 6)).month - 1]}';
    void decaler(int sens) => setState(() {
          _jour = vue == _Vue.mois || (vue == _Vue.liste && !telephone)
              ? DateTime(_jour.year, _jour.month + sens, 1)
              : _jour.add(Duration(days: 7 * sens));
        });

    final outils = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Container(
        decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Précédent', onPressed: () => decaler(-1), icon: const Icon(Icons.chevron_left)),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 120),
            child: Text(titre, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          IconButton(tooltip: 'Suivant', onPressed: () => decaler(1), icon: const Icon(Icons.chevron_right)),
        ]),
      ),
      OutlinedButton(onPressed: () => setState(() => _jour = DateTime.now()), child: const Text("Aujourd'hui")),
      if (!telephone)
        Segments<_Vue>(
          valeur: _vue,
          choix: const {_Vue.mois: 'Mois', _Vue.semaine: 'Semaine', _Vue.liste: 'Liste'},
          onChanged: (v) => setState(() => _vue = v),
        ),
      _MenuClasse(
        largeur: telephone ? 150 : 190,
        valeur: _classe,
        choix: {'': 'Toutes les classes', for (final c in d.classes) c['id'] as String: '${c['nom']}'},
        onChanged: (v) => setState(() => _classe = v),
      ),
      if (cycles.length > 1 && _classe.isEmpty)
        _MenuClasse(
          largeur: 170,
          valeur: _cycle,
          choix: {'': 'Tous les cycles', ...cycles},
          onChanged: (v) => setState(() => _cycle = v),
        ),
      if (modifie)
        FilledButton.icon(
          onPressed: () => ajouterEvaluation(context, _e, d, classeId: _classe.isEmpty ? null : _classe),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Ajouter une évaluation'),
        ),
    ]);

    // La légende : les sessions de la période affichée.
    final debutVue = vue == _Vue.mois ? _date(premierMois) : _date(lundi);
    final finVue = vue == _Vue.mois ? _date(finMois) : _date(lundi.add(const Duration(days: 6)));
    final cycle = _cycleActif(d);
    final visibles = d.sessions
        .where((s) => (cycle.isEmpty || s['cycle'] == cycle) && '${s['debut']}'.compareTo(finVue) <= 0 && '${s['fin']}'.compareTo(debutVue) >= 0)
        .toList();
    final legende = Wrap(spacing: 16, runSpacing: 6, children: [
      for (final s in visibles)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(color: _estCompo(s) ? _couleurCompo : _couleurEval, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 6),
          Text('${s['libelle']}${cycles.length > 1 ? ' (${nomsCycles[s['cycle']] ?? s['cycle']})' : ''} · '
              '${_jourCourt(s['debut'])} → ${_jourCourt(s['fin'])}', style: TextStyle(fontSize: 12, color: gris)),
        ]),
      if (visibles.isEmpty) Text('Aucune évaluation sur cette période.', style: TextStyle(fontSize: 12, color: gris)),
    ]);

    final Widget corps = switch (vue) {
      _Vue.mois => _grilleMois(context, d, debutGrille, premierMois.month, modifie),
      _Vue.semaine => _grilleSemaine(context, d, lundi, modifie),
      _Vue.liste => _liste(context, d, telephone ? lundi : premierMois, telephone ? lundi.add(const Duration(days: 6)) : finMois, modifie),
    };

    // La session choisie (panneau de droite) : celle choisie, sinon la première à venir de la vue.
    final aujourdhui = _date(DateTime.now());
    final session = d.sessions.where((s) => s['id'] == _sessionId).firstOrNull ??
        visibles.where((s) => '${s['fin']}'.compareTo(aujourdhui) >= 0).firstOrNull ??
        visibles.firstOrNull;
    final avecPanneau = largeur >= 1150 && session != null;

    // Le même cadre que les autres pages (Élèves, Familles, Caisse…) : 1600 px au plus,
    // 16 px de marge (12 sur téléphone), le titre dans la page.
    return Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: Padding(
            padding: EdgeInsets.all(telephone ? 12 : 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EnTetePage(titre: telephone ? 'Calendrier' : 'Calendrier des évaluations', sousTitre: '${d.annee['libelle']}'),
          const SizedBox(height: 12),
          outils,
          const SizedBox(height: 10),
          legende,
          const SizedBox(height: 10),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: corps),
              if (avecPanneau) ...[
                const SizedBox(width: 16),
                SizedBox(width: 320, child: _panneau(context, d, session, visibles, modifie)),
              ],
            ]),
          ),
          if (!avecPanneau && session != null && modifie && !telephone) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (context) => SizedBox(height: 560, child: _panneau(context, d, session, visibles, modifie)),
                ),
                icon: const Icon(Icons.checklist, size: 18),
                label: Text('${session['libelle']} : reste à programmer'),
              ),
            ),
          ],
        ]),
          ),
        ),
      ),
    );
  }

  String _jourCourt(Object? iso) {
    final x = DateTime.tryParse('$iso');
    return x == null ? '' : '${x.day} ${_moisAbreges[x.month - 1]}';
  }

  /// Les épreuves d'un jour, regroupées : « 7ème (3) · Maths » quand plusieurs classes
  /// d'un même niveau ont la même matière à la même heure.
  List<({String texte, bool compo, List<Map<String, Object?>> epreuves})> _puces(_DonneesCalendrier d, String jour) {
    final groupes = <String, List<Map<String, Object?>>>{};
    for (final e in d.epreuves) {
      if (e['date_evaluation'] != jour || !_garde(d, e['classe_id'])) continue;
      final c = d.classeParId[e['classe_id']];
      groupes.putIfAbsent('${c?['niveau_id']}|${e['matiere_id']}|${e['heure'] ?? ''}', () => []).add(e);
    }
    return [
      for (final g in groupes.values)
        (
          texte: [
            g.length > 1 ? '${d.classeParId[g.first['classe_id']]?['niveau']} (${g.length})' : '${d.classeParId[g.first['classe_id']]?['nom']}',
            '${g.first['matiere']}',
            if (heureLisible(g.first['heure'], null).isNotEmpty) heureLisible(g.first['heure'], null),
          ].join(' · '),
          compo: _estCompo(d.sessions.where((s) => s['id'] == g.first['session_id']).firstOrNull ?? const {}),
          epreuves: g,
        ),
    ];
  }

  Widget _puce(BuildContext context, _DonneesCalendrier d, ({String texte, bool compo, List<Map<String, Object?>> epreuves}) p, bool modifie) =>
      Material(
        color: p.compo ? const Color(0x1FC2410C) : const Color(0x1F2F72C4),
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => _ouvrirPuce(context, d, p.epreuves, modifie),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Text(p.texte,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, height: 1.25, color: p.compo ? const Color(0xFF9A3412) : const Color(0xFF1E4F8C))),
          ),
        ),
      );

  /// Une puce : l'épreuve (à modifier), ou la liste des classes regroupées.
  Future<void> _ouvrirPuce(BuildContext context, _DonneesCalendrier d, List<Map<String, Object?>> epreuves, bool modifie) async {
    Map<String, Object?>? ev = epreuves.length == 1 ? epreuves.first : null;
    ev ??= await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final e in epreuves)
            ListTile(
              title: Text('${d.classeParId[e['classe_id']]?['nom']} · ${e['matiere']}'),
              subtitle: Text([_dateLisible(e['date_evaluation']), heureLisible(e['heure'], e['duree_min'])].where((x) => x.isNotEmpty).join(' · ')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(context, e),
            ),
        ]),
      ),
    );
    if (ev == null || !context.mounted) return;
    if (modifie) {
      await ajouterEvaluation(context, _e, d, ev: ev);
    } else {
      final enseignant = d.enseignants['${ev['classe_id']}|${ev['matiere_id']}'];
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${d.classeParId[ev!['classe_id']]?['nom']} · ${ev['matiere']}'),
          content: Text([
            _dateLisible(ev['date_evaluation']),
            if (heureLisible(ev['heure'], ev['duree_min']).isNotEmpty) heureLisible(ev['heure'], ev['duree_min']),
            if (enseignant != null) enseignant,
          ].join(' · ')),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer'))],
        ),
      );
    }
  }

  /// Le bandeau de session en haut d'un jour (couleur, nom au premier jour visible).
  Widget _bandeau(_DonneesCalendrier d, DateTime jour, bool premierDeLaLigne) {
    final s = _sessionsDu(d, _date(jour)).firstOrNull;
    if (s == null || jour.weekday == DateTime.sunday) return const SizedBox(height: 16);
    final veille = _sessionsDu(d, _date(jour.subtract(const Duration(days: 1)))).firstOrNull;
    final debut = premierDeLaLigne || veille?['id'] != s['id'];
    return Container(
      height: 16,
      color: _estCompo(s) ? _couleurCompo : _couleurEval,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.centerLeft,
      child: debut
          ? Text('${s['libelle']}', maxLines: 1, overflow: TextOverflow.clip, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white))
          : null,
    );
  }

  Widget _caseJour(BuildContext context, _DonneesCalendrier d, DateTime jour, {required bool dansLeMois, required bool premierDeLaLigne,
      required bool modifie, int? maxPuces}) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final iso = _date(jour);
    final aujourdhui = iso == _date(DateTime.now());
    final puces = _puces(d, iso);
    final classesDuJour = <Object?, int>{};
    for (final e in d.epreuves.where((e) => e['date_evaluation'] == iso && _garde(d, e['classe_id']))) {
      classesDuJour[e['classe_id']] = (classesDuJour[e['classe_id']] ?? 0) + 1;
    }
    final charge = classesDuJour.values.any((n) => n >= 3);
    final montrees = maxPuces == null ? puces : puces.take(maxPuces).toList();
    return Material(
      color: jour.weekday == DateTime.sunday ? Couleurs.doux(context).withValues(alpha: .5) : Theme.of(context).colorScheme.surface,
      child: InkWell(
        onTap: modifie && jour.weekday != DateTime.sunday ? () => ajouterEvaluation(context, _e, d, date: jour, classeId: _classe.isEmpty ? null : _classe) : null,
        child: Container(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: .6)))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _bandeau(d, jour, premierDeLaLigne),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 6, 2),
              child: Row(children: [
                Container(
                  padding: aujourdhui ? const EdgeInsets.symmetric(horizontal: 7, vertical: 1) : EdgeInsets.zero,
                  decoration: aujourdhui ? BoxDecoration(color: Theme.of(context).colorScheme.onSurface, borderRadius: BorderRadius.circular(10)) : null,
                  child: Text(dansLeMois || maxPuces == null ? '${jour.day}' : '${jour.day} ${_moisAbreges[jour.month - 1]}',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: aujourdhui ? Theme.of(context).colorScheme.surface : (dansLeMois ? null : gris.withValues(alpha: .6)))),
                ),
                const Spacer(),
                if (charge)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: Couleurs.attenteFond, borderRadius: BorderRadius.circular(4)),
                    child: const Text('chargé', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Couleurs.attente)),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(5, 0, 5, 5),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final p in montrees) Padding(padding: const EdgeInsets.only(bottom: 3), child: _puce(context, d, p, modifie)),
                if (montrees.length < puces.length)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text('+ ${puces.length - montrees.length} autre(s)', style: TextStyle(fontSize: 11, color: gris)),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _enTeteJours(BuildContext context) => Container(
        color: Couleurs.doux(context).withValues(alpha: .5),
        child: Row(children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              flex: i == 6 ? 5 : 10,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Text(_joursCalendrier[i],
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ),
        ]),
      );

  Widget _cadre(BuildContext context, Widget enfant) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Theme.of(context).dividerColor)),
        child: enfant,
      );

  Widget _grilleMois(BuildContext context, _DonneesCalendrier d, DateTime debutGrille, int mois, bool modifie) {
    final semaines = <List<DateTime>>[];
    var j = debutGrille;
    do {
      semaines.add([for (var i = 0; i < 7; i++) DateTime(j.year, j.month, j.day + i)]);
      j = DateTime(j.year, j.month, j.day + 7);
    } while (j.month == mois);
    return _cadre(
      context,
      Column(children: [
        _enTeteJours(context),
        Expanded(
          child: ListView(children: [
            for (final s in semaines)
              Container(
                constraints: const BoxConstraints(minHeight: 112),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: .6)))),
                child: IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (var i = 0; i < 7; i++)
                      Expanded(
                        flex: i == 6 ? 5 : 10,
                        child: _caseJour(context, d, s[i], dansLeMois: s[i].month == mois, premierDeLaLigne: i == 0, modifie: modifie, maxPuces: 3),
                      ),
                  ]),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _grilleSemaine(BuildContext context, _DonneesCalendrier d, DateTime lundi, bool modifie) => _cadre(
        context,
        Column(children: [
          _enTeteJours(context),
          Expanded(
            child: SingleChildScrollView(
              child: IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      flex: i == 6 ? 5 : 10,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 420),
                        child: _caseJour(context, d, lundi.add(Duration(days: i)), dansLeMois: true, premierDeLaLigne: i == 0, modifie: modifie),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ]),
      );

  /// Jour par jour (téléphone, ou vue « Liste ») : seulement les jours qui ont des épreuves.
  Widget _liste(BuildContext context, _DonneesCalendrier d, DateTime debut, DateTime fin, bool modifie) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final jours = <String, List<Map<String, Object?>>>{};
    for (final e in d.epreuves) {
      final j = '${e['date_evaluation']}';
      if (j.compareTo(_date(debut)) < 0 || j.compareTo(_date(fin)) > 0 || !_garde(d, e['classe_id'])) continue;
      jours.putIfAbsent(j, () => []).add(e);
    }
    if (jours.isEmpty) {
      return Center(child: Text('Aucune évaluation sur cette période.', style: TextStyle(color: gris)));
    }
    const noms = ['LUNDI', 'MARDI', 'MERCREDI', 'JEUDI', 'VENDREDI', 'SAMEDI', 'DIMANCHE'];
    return ListView(children: [
      for (final e in jours.entries)
        Builder(builder: (context) {
          final jour = DateTime.parse(e.key);
          final s = _sessionsDu(d, e.key).firstOrNull;
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Text('${noms[jour.weekday - 1]} ${jour.day} ${_moisNoms[jour.month - 1].toUpperCase()}',
                    style: TextStyle(fontSize: 12, letterSpacing: .6, fontWeight: FontWeight.w600, color: gris)),
                if (s != null) ...[
                  const SizedBox(width: 8),
                  Text('${s['libelle']}', style: TextStyle(fontSize: 12, color: _estCompo(s) ? _couleurCompo : _couleurEval)),
                ],
              ]),
              const SizedBox(height: 6),
              for (final ev in e.value)
                Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    onTap: () => _ouvrirPuce(context, d, [ev], modifie),
                    leading: SizedBox(
                      width: 64,
                      child: Text(heureLisible(ev['heure'], null).isEmpty ? '—' : heureLisible(ev['heure'], null),
                          style: TextStyle(fontWeight: FontWeight.w600, color: s != null && _estCompo(s) ? const Color(0xFF9A3412) : const Color(0xFF1E4F8C))),
                    ),
                    title: Text('${ev['matiere']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text([
                      if (_classe.isEmpty) '${d.classeParId[ev['classe_id']]?['nom']}',
                      if (ev['duree_min'] != null) heureLisible('00:00', ev['duree_min']).replaceFirst('0 h 00 (', '').replaceFirst(')', ''),
                      if (d.enseignants['${ev['classe_id']}|${ev['matiere_id']}'] != null) d.enseignants['${ev['classe_id']}|${ev['matiere_id']}']!,
                      if (ev['date_prevue'] != null && ev['date_prevue'] != ev['date_evaluation']) 'prévue le ${_jourCourt(ev['date_prevue'])}',
                    ].join(' · ')),
                  ),
                ),
            ]),
          );
        }),
    ]);
  }

  // --- Le panneau de la session ------------------------------------------------------

  Widget _panneau(BuildContext context, _DonneesCalendrier d, Map<String, Object?> s, Lignes visibles, bool modifie) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final aujourdhui = _date(DateTime.now());
    // Ce qui reste à programmer : chaque matière de chaque classe du cycle sans épreuve dans la session.
    final faites = {for (final e in d.epreuves.where((e) => e['session_id'] == s['id'])) '${e['classe_id']}|${e['matiere_id']}'};
    final attendues = d.services.where((x) => d.classeParId[x['classe_id']]?['cycle'] == s['cycle'] && _garde(d, x['classe_id'])).toList();
    final reste = attendues.where((x) => !faites.contains('${x['classe_id']}|${x['matiere_id']}')).toList();
    final total = attendues.length, programmees = total - reste.length;
    final enRetard = s['calendrier'] != 'publie' && s['programmation_avant'] != null && '${s['programmation_avant']}'.compareTo(aujourdhui) < 0;
    final etat = s['calendrier'] == 'publie'
        ? Etat('Publié le ${_jourCourt(s['publie_le'])}', ton: Ton.regle, icone: Icons.verified_outlined)
        : Etat(
            s['programmation_avant'] == null ? 'En préparation' : 'En préparation · avant le ${_dateLisible(s['programmation_avant']).substring(0, 5)}',
            ton: enRetard ? Ton.retard : Ton.attente);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Theme.of(context).dividerColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Session', style: TextStyle(fontSize: 12, color: gris)),
        if (visibles.length > 1)
          _MenuClasse(
            largeur: 288,
            valeur: s['id'] as String,
            choix: {
              for (final x in [s, ...visibles.where((v) => v['id'] != s['id'])])
                x['id'] as String: '${x['libelle']}${nomsCycles.length > 1 ? ' · ${nomsCycles[x['cycle']] ?? x['cycle']}' : ''}',
            },
            onChanged: (v) => setState(() => _sessionId = v),
          )
        else
          Text('${s['libelle']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        Text('${nomsCycles[s['cycle']] ?? s['cycle']} · du ${_jourCourt(s['debut'])} au ${_jourCourt(s['fin'])} · ${s['type']}, poids ${noteLisible((s['poids'] as num? ?? 1).toDouble()).replaceAll(',00', '')}',
            style: TextStyle(fontSize: 13, color: gris)),
        const SizedBox(height: 10),
        Align(alignment: Alignment.centerLeft, child: etat),
        const SizedBox(height: 12),
        Row(children: [
          const Expanded(child: Text('Matières programmées', style: TextStyle(fontSize: 13))),
          Text('$programmees / $total', style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: total == 0 ? 0 : programmees / total,
            minHeight: 6,
            backgroundColor: Couleurs.doux(context),
            color: _estCompo(s) ? _couleurCompo : _couleurEval,
          ),
        ),
        const SizedBox(height: 14),
        Text('RESTE À PROGRAMMER (${reste.length})', style: TextStyle(fontSize: 12, letterSpacing: .6, fontWeight: FontWeight.w600, color: gris)),
        const SizedBox(height: 4),
        Expanded(
          child: reste.isEmpty
              ? Padding(padding: const EdgeInsets.only(top: 8), child: Text('Tout est programmé.', style: TextStyle(color: gris)))
              : ListView(children: [
                  for (final r in reste)
                    Container(
                      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: .5)))),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${d.classeParId[r['classe_id']]?['nom']} · ${r['matiere']}', style: const TextStyle(fontWeight: FontWeight.w500)),
                            Text(r['enseignants'] == null ? "pas d'enseignant" : '${r['enseignants']}',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: r['enseignants'] == null ? Couleurs.attente : gris)),
                          ]),
                        ),
                        if (modifie && s['statut'] == 'ouverte')
                          TextButton(
                            onPressed: () => ajouterEvaluation(context, _e, d,
                                classeId: r['classe_id'] as String,
                                matiereId: r['matiere_id'] as String,
                                date: _dateDans(s)),
                            child: const Text('Programmer'),
                          ),
                      ]),
                    ),
                ]),
        ),
        const SizedBox(height: 10),
        if (modifie && s['statut'] == 'ouverte' && s['calendrier'] != 'publie')
          FilledButton(onPressed: () => _publier(s, reste.length), child: const Text('Valider et publier'))
        else if (modifie && s['statut'] == 'ouverte')
          TextButton.icon(
            onPressed: () async {
              if (await _confirmer(context, 'Rouvrir la préparation de « ${s['libelle']} » ?')) {
                await _modifier('sessions_evaluation', s['id'] as String, {'calendrier': 'preparation', 'publie_le': null, 'publie_par': null});
              }
            },
            icon: const Icon(Icons.lock_open, size: 16),
            label: const Text('Rouvrir la préparation'),
          ),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: () => _imprimer(d, s),
          icon: const Icon(Icons.print_outlined, size: 16),
          label: const Text('Imprimer le calendrier par classe'),
        ),
      ]),
    );
  }

  /// Une date dans la session : aujourd'hui s'il y est, sinon son premier jour.
  DateTime _dateDans(Map<String, Object?> s) {
    final debut = DateTime.parse('${s['debut']}'), fin = DateTime.parse('${s['fin']}');
    final auj = DateTime.now();
    return auj.isBefore(debut) || auj.isAfter(fin) ? debut : DateTime(auj.year, auj.month, auj.day);
  }

  Future<void> _publier(Map<String, Object?> s, int manquantes) async {
    final ok = await _confirmer(
        context,
        '${manquantes > 0 ? '$manquantes matière(s) ne sont pas encore programmées. ' : ''}'
        'Publier le calendrier de « ${s['libelle']} » ? Il devient définitif pour les enseignants ; '
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

  Future<void> _imprimer(_DonneesCalendrier d, Map<String, Object?> s) async {
    final classes = [for (final c in d.classes) if (c['cycle'] == s['cycle'] && _garde(d, c['id'])) c];
    final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [_e.orgId]);
    final pdf = await calendriersEvaluationsPdf(
      ecole: Map.of(ecole),
      titre: '${s['libelle']}',
      fenetre: 'du ${_dateLisible(s['debut'])} au ${_dateLisible(s['fin'])}',
      classes: [
        for (final c in classes)
          (
            '${c['nom']}',
            [
              for (final ev in d.epreuves)
                if (ev['session_id'] == s['id'] && ev['classe_id'] == c['id'])
                  (
                    date: _dateLisible(ev['date_evaluation']),
                    heure: heureLisible(ev['heure'], ev['duree_min']),
                    matiere: '${ev['matiere']}',
                    type: '${s['type']}',
                    enseignant: d.enseignants['${ev['classe_id']}|${ev['matiere_id']}'] ?? '',
                  ),
            ],
          ),
      ],
      images: await _imagesEcole(_e.orgId),
      pied: s['calendrier'] == 'publie'
          ? 'Calendrier publié le ${_dateLisible(s['publie_le'])}. En cas de report, la nouvelle date vous sera communiquée.'
          : 'Calendrier provisoire.',
    );
    await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Calendrier ${s['libelle']}');
  }
}

/// Les noms des cycles (alias lisible dans ce fichier).
Map<String, String> get nomsCycles => cycles;

/// Ajouter une évaluation (ou la modifier : [ev]). Plusieurs classes d'un même
/// niveau d'un coup ; la session et la nature se déduisent de la date.
Future<void> ajouterEvaluation(BuildContext context, Espace espace, _DonneesCalendrier d,
    {DateTime? date, String? classeId, String? matiereId, Map<String, Object?>? ev}) async {
  final messager = ScaffoldMessenger.of(context);
  if (d.classes.isEmpty) {
    messager.showSnackBar(const SnackBar(content: Text('Aucune classe cette année.')));
    return;
  }
  final debutAnnee = DateTime.tryParse('${d.annee['debut']}') ?? DateTime(DateTime.now().year, 9, 1);
  final finAnnee = DateTime.tryParse('${d.annee['fin']}') ?? DateTime(DateTime.now().year + 1, 7, 31);
  final premiere = d.classeParId[ev?['classe_id'] ?? classeId] ?? d.classes.first;
  var niveau = premiere['niveau_id'] as String;
  final choisies = <String>{if (ev != null) ev['classe_id'] as String else if (classeId != null) classeId};
  List<Map<String, Object?>> matieresDu(String n) => d.matieres.where((m) => m['niveau_id'] == n).toList();
  var matiere = (ev?['matiere_id'] ?? matiereId ?? matieresDu(niveau).firstOrNull?['id']) as String?;
  var jour = ev != null ? DateTime.parse('${ev['date_evaluation']}') : (date ?? DateTime.now());
  if (jour.isBefore(debutAnnee)) jour = debutAnnee;
  if (jour.isAfter(finAnnee)) jour = finAnnee;
  String? heure = ev?['heure'] as String?;
  var duree = ev?['duree_min'] as int? ?? 0;
  if (!_durees.containsKey(duree)) duree = 0;
  var supprimer = false;
  final niveaux = <String, String>{for (final c in d.classes) c['niveau_id'] as String: '${c['niveau']}'};

  Map<String, Object?>? session() => d.sessionDu(_date(jour), d.classes.firstWhere((c) => c['niveau_id'] == niveau)['cycle']);

  final ok = await _formulaire(context, ev == null ? 'Ajouter une évaluation' : 'Modifier l\'évaluation', (maj) {
    final s = session();
    final classesNiveau = d.classes.where((c) => c['niveau_id'] == niveau).toList();
    final matieres = matieresDu(niveau);
    final memeJour = <String>[
      for (final c in choisies)
        if (d.epreuves.where((e) => e['classe_id'] == c && e['date_evaluation'] == _date(jour) && e['id'] != ev?['id']).length >= 2)
          '${d.classeParId[c]?['nom']}',
    ];
    final profs = <String>[
      for (final c in choisies)
        if (matiere != null && d.enseignants['$c|$matiere'] != null) '${d.enseignants['$c|$matiere']} (${d.classeParId[c]?['nom']})',
    ];
    return [
      if (ev == null) ...[
        if (niveaux.length > 1)
          _liste('Niveau', niveau, niveaux, (v) => maj(() {
                niveau = v;
                choisies.clear();
                matiere = matieresDu(v).firstOrNull?['id'] as String?;
              })),
        const Text('Classes', style: TextStyle(fontWeight: FontWeight.w600)),
        const Text("Plusieurs classes d'un coup : même matière, même date.", style: TextStyle(fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in classesNiveau)
            FilterChip(
              label: Text('${c['nom']}'),
              selected: choisies.contains(c['id']),
              onSelected: (v) => maj(() => v ? choisies.add(c['id'] as String) : choisies.remove(c['id'])),
            ),
        ]),
        const SizedBox(height: 10),
        if (matieres.isEmpty)
          const Text('Aucune matière pour ce niveau (Paramètres › Matières).')
        else
          _liste('Matière', matiere ?? matieres.first['id'] as String, {for (final m in matieres) m['id'] as String: '${m['nom']}'},
              (v) => maj(() => matiere = v)),
      ] else
        Text('${d.classeParId[ev['classe_id']]?['nom']} · ${ev['matiere']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      InkWell(
        onTap: () async {
          final x = await _choisirDate(context, jour, premier: debutAnnee, dernier: finAnnee);
          if (x != null) maj(() => jour = x);
        },
        child: InputDecorator(
            decoration: _champ('Date'),
            child: Text('${const ['Lun.', 'Mar.', 'Mer.', 'Jeu.', 'Ven.', 'Sam.', 'Dim.'][jour.weekday - 1]} ${_dateLisible(_date(jour))}')),
      ),
      const SizedBox(height: 8),
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
      const SizedBox(height: 10),
      // Ce que l'app déduit de la date.
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: s == null ? Couleurs.retardFond : (_estCompo(s) ? const Color(0x1FC2410C) : const Color(0x1F2F72C4)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: s == null
            ? const Text('Aucune évaluation ne couvre cette date pour ce niveau : ajoutez-la dans Paramètres › Périodes et évaluations.',
                style: TextStyle(color: Couleurs.retard))
            : Text(
                '${s['libelle']} (du ${_dateLisible(s['debut']).substring(0, 5)} au ${_dateLisible(s['fin']).substring(0, 5)}) · '
                '${s['type']}, poids ${noteLisible((s['poids'] as num? ?? 1).toDouble()).replaceAll(',00', '')} · notes sur ${s['bareme']}'
                '${s['statut'] != 'ouverte' ? ' · session clôturée' : ''}',
                style: TextStyle(color: _estCompo(s) ? const Color(0xFF9A3412) : const Color(0xFF1E4F8C))),
      ),
      if (jour.weekday == DateTime.sunday)
        const Padding(padding: EdgeInsets.only(top: 6), child: Text('Attention : un dimanche.', style: TextStyle(color: Couleurs.attente))),
      if (memeJour.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('${memeJour.join(', ')} : déjà 2 épreuves ou plus ce jour-là.', style: const TextStyle(color: Couleurs.attente)),
        ),
      if (profs.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 6), child: Text('Enseignant(s) : ${profs.join(', ')}', style: const TextStyle(fontSize: 13))),
      if (ev != null && (ev['notes'] as int? ?? 0) == 0)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: supprimer,
          onChanged: (v) => maj(() => supprimer = v ?? false),
          title: const Text('Retirer cette évaluation du calendrier'),
        ),
    ];
  }, valider: () => ev == null ? 'Ajouter' : 'Enregistrer');
  if (!ok) return;
  if (supprimer && ev != null) {
    await _supprimer('evaluations', ev['id'] as String);
    return;
  }
  final s = session();
  if (s == null || s['statut'] != 'ouverte') {
    messager.showSnackBar(const SnackBar(content: Text('Aucune évaluation ouverte ne couvre cette date pour ce niveau.')));
    return;
  }
  final m0 = _maintenant();
  try {
    if (ev != null) {
      await _modifier('evaluations', ev['id'] as String, {
        'date_evaluation': _date(jour),
        'heure': heure,
        'duree_min': duree == 0 ? null : duree,
        'session_id': s['id'],
        'periode_id': s['periode_id'],
        'type_id': s['type_id'],
        // Publiée : la date prévue reste celle du calendrier.
        if (s['calendrier'] == 'publie' && ev['date_prevue'] == null) 'date_prevue': ev['date_evaluation'],
      });
      return;
    }
    final m = matiere ?? matieresDu(niveau).firstOrNull?['id'] as String?;
    if (choisies.isEmpty || m == null) {
      messager.showSnackBar(const SnackBar(content: Text('Choisissez au moins une classe et une matière.')));
      return;
    }
    var ajoutees = 0, deja = 0;
    await db.writeTransaction((tx) async {
      for (final c in choisies) {
        // Une composition : une seule par période et par matière.
        if (_estCompo(s) &&
            await tx.getOptional('SELECT 1 FROM evaluations WHERE periode_id = ? AND classe_id = ? AND matiere_id = ? AND type_id = ?',
                    [s['periode_id'], c, m, s['type_id']]) !=
                null) {
          deja++;
          continue;
        }
        await tx.execute(
            '''INSERT INTO evaluations (id, organisation_id, periode_id, session_id, classe_id, matiere_id, type_id, date_evaluation,
                 heure, duree_min, date_prevue, cree_par, created_at, updated_at)
               VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
            [espace.orgId, s['periode_id'], s['id'], c, m, s['type_id'], _date(jour), heure, duree == 0 ? null : duree,
              s['calendrier'] == 'publie' ? _date(jour) : null, monId, m0, m0]);
        ajoutees++;
      }
    });
    messager.showSnackBar(SnackBar(
        content: Text('${ajoutees > 0 ? 'Évaluation ajoutée pour $ajoutees classe(s).' : ''}'
            '${deja > 0 ? ' $deja classe(s) avaient déjà cette composition.' : ''}')));
  } catch (_) {
    messager.showSnackBar(const SnackBar(content: Text("L'évaluation n'a pas pu être enregistrée.")));
  }
}
