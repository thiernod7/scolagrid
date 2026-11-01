part of 'configuration.dart';

/// Tableau de bord, comme la maquette : en-tête avec la période, puis
/// « Finances » (recouvrement, encaissé, arriérés, élèves en retard, deux
/// graphiques) et « Effectifs » (inscrits, nouvelles, départs, personnel,
/// deux graphiques). Tout est calculé sur le poste, à partir des données
/// synchronisées, avec les mêmes règles que la caisse (réductions comprises).

const _moisCourts = ['Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Juin', 'Juil', 'Août', 'Sep', 'Oct', 'Nov', 'Déc'];
const _moisLongs = [
  'janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
];

enum Periode { mois, trimestre, annee }

/// Un élève qui doit des échéances passées.
class _EnRetard {
  _EnRetard(this.eleveId, this.nom, this.classe, this.montant, this.jours);

  final String eleveId;
  final String nom;
  final String classe;
  final int montant;
  final int jours;
}

class _Mesures {
  String? annee;
  int du = 0;
  int regle = 0;
  int arrieres = 0;
  int moins30 = 0;
  int de30a60 = 0;
  int plus60 = 0;
  final retards = <_EnRetard>[];
  int encaisse = 0;
  int? encaissePrecedent;
  final parMois = <(String, int)>[];
  final parMode = <String, int>{};
  int inscrits = 0;
  int nouvelles = 0;
  int departs = 0;
  int attente = 0;
  int filles = 0;
  int garcons = 0;
  int sexeInconnu = 0;
  final parNiveau = <(String, String?, int)>[];
  int personnel = 0;

  /// Élèves à qui manque une pièce obligatoire : (id, nom, classe, pièces manquantes).
  final incomplets = <(String, String, String, List<String>)>[];

  /// Retiré de la scolarité pour des arrivées en cours d'année.
  int retraitsArrivee = 0;

  /// Ce que coûtent les réductions cette année, en tout et par réduction, et
  /// combien d'élèves en ont une.
  int reductions = 0;
  final reductionsParRegle = <String, int>{};
  int eleveReduits = 0;

  /// Changements que le serveur a refusés sur ce poste.
  final refus = <Map<String, Object?>>[];

  /// Remboursements autorisés de vive voix : à confirmer, dont en retard.
  int aConfirmer = 0;
  int confirmationsEnRetard = 0;
}

Future<_Mesures> _mesurer(String o, Periode periode) async {
  final m = _Mesures();
  m.refus.addAll([for (final r in await db.getAll('SELECT * FROM refus_serveur ORDER BY quand DESC LIMIT 50')) Map.of(r)]);
  final annee = await db.getOptional('SELECT * FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1', [o]);
  m.personnel = (await db.get("SELECT count(*) AS n FROM personnel WHERE organisation_id = ? AND statut = 'actif'", [o]))['n']
          as int? ??
      0;
  final aujourdhui = DateTime.now();
  final jour = DateTime(aujourdhui.year, aujourdhui.month, aujourdhui.day);

  // Encaissé : la période choisie et la précédente, de même longueur.
  final (debut, fin) = switch (periode) {
    Periode.mois => (DateTime(jour.year, jour.month), DateTime(jour.year, jour.month + 1)),
    Periode.trimestre => (DateTime(jour.year, jour.month - 2), DateTime(jour.year, jour.month + 1)),
    Periode.annee => (
        DateTime.tryParse('${annee?['debut']}') ?? DateTime(jour.month >= 9 ? jour.year : jour.year - 1, 9),
        DateTime(jour.year, jour.month + 1)
      ),
  };
  final duree = fin.difference(debut);
  final debutPrecedent = periode == Periode.annee ? DateTime(debut.year - 1, debut.month, debut.day) : DateTime(debut.year, debut.month - (periode == Periode.mois ? 1 : 3));
  final finPrecedente = periode == Periode.annee ? debutPrecedent.add(duree) : debut;
  final recus = await db.getAll(
      """SELECT date_effective, mode, total_gnf FROM encaissements
         WHERE organisation_id = ? AND statut = 'valide' AND confirmation <> 'rejete'""",
      [o]);
  DateTime? premier;
  var precedent = 0;
  for (final r in recus) {
    final d = DateTime.tryParse('${r['date_effective']}');
    if (d == null) continue;
    final t = r['total_gnf'] as int? ?? 0;
    if (premier == null || d.isBefore(premier)) premier = d;
    if (!d.isBefore(debut) && d.isBefore(fin)) {
      m.encaisse += t;
      m.parMode[r['mode'] as String] = (m.parMode[r['mode']] ?? 0) + t;
    }
    if (!d.isBefore(debutPrecedent) && d.isBefore(finPrecedente)) precedent += t;
  }
  // Pas de référence si l'école n'encaissait pas encore à ce moment-là.
  m.encaissePrecedent = premier != null && !premier.isAfter(debutPrecedent) ? precedent : null;

  if (annee == null) return m;
  m.annee = annee['libelle'] as String?;

  // Encaissements par mois de l'année scolaire (dix mois depuis la rentrée).
  final rentree = DateTime.tryParse('${annee['debut']}') ?? DateTime(jour.month >= 9 ? jour.year : jour.year - 1, 9);
  for (var i = 0; i < 10; i++) {
    final a = DateTime(rentree.year, rentree.month + i);
    final b = DateTime(rentree.year, rentree.month + i + 1);
    var t = 0;
    for (final r in recus) {
      final d = DateTime.tryParse('${r['date_effective']}');
      if (d != null && !d.isBefore(a) && d.isBefore(b)) t += r['total_gnf'] as int? ?? 0;
    }
    m.parMois.add((_moisCourts[a.month - 1], t));
  }

  // Les inscriptions de l'année.
  final inscriptions = await db.getAll('''
      SELECT i.id, i.eleve_id, i.site_id, i.type_admission, i.statut, i.date_effective,
             i.arrivee_mode, i.arrivee_retrait_gnf, e.pieces_dossier,
             c.niveau_id, c.nom AS classe, n.nom AS niveau, n.cycle, n.ordre, e.sexe, e.nom, e.prenoms
      FROM inscriptions i JOIN classes c ON c.id = i.classe_id JOIN niveaux n ON n.id = c.niveau_id
      JOIN eleves e ON e.id = i.eleve_id
      WHERE i.organisation_id = ? AND i.annee_id = ?
      ORDER BY n.ordre''', [o, annee['id']]);
  const sortis = {'annule', 'exclu', 'transfert_sortant'};
  final actives = inscriptions.where((i) => !sortis.contains(i['statut'])).toList();
  m.inscrits = actives.length;
  m.nouvelles = actives.where((i) => i['type_admission'] != 'reinscription').length;
  m.departs = inscriptions.where((i) => i['statut'] == 'transfert_sortant' || i['statut'] == 'exclu').length;
  m.attente = actives.where((i) => i['statut'] == 'en_attente').length;
  final niveaux = <String, (String, String?, int)>{};
  for (final i in actives) {
    switch (i['sexe']) {
      case 'F':
        m.filles++;
      case 'M':
        m.garcons++;
      default:
        m.sexeInconnu++;
    }
    final k = i['niveau_id'] as String;
    final n = niveaux[k];
    niveaux[k] = (n?.$1 ?? '${i['niveau']}', i['cycle'] as String?, (n?.$3 ?? 0) + 1);
  }
  m.parNiveau.addAll(niveaux.values);

  // Dossiers incomplets : une pièce obligatoire qui concerne l'élève manque.
  final pieces = (await piecesDe(o)).where((p) => p.obligatoire).toList();
  if (pieces.isNotEmpty) {
    for (final i in actives) {
      final fournies = '${i['pieces_dossier'] ?? ''}'.split(',').toSet();
      final manquantes = [
        for (final p in pieces)
          if (p.concerne(i['type_admission'] as String?, i['cycle'] as String?) && !fournies.contains(p.code)) p.libelle,
      ];
      if (manquantes.isNotEmpty) {
        m.incomplets.add((i['eleve_id'] as String, '${i['nom']} ${i['prenoms']}', '${i['classe']}', manquantes));
      }
    }
  }

  // Ce qui est dû, réglé et en retard : mêmes calculs que la caisse.
  final frais = await db.getAll('SELECT * FROM frais WHERE annee_id = ?', [annee['id']]);
  final echeances = <String, List<({String libelle, int montant, DateTime dateLimite})>>{};
  for (final e in await db.getAll('SELECT * FROM echeances WHERE organisation_id = ? ORDER BY ordre', [o])) {
    echeances.putIfAbsent(e['frais_id'] as String, () => []).add(
        (libelle: e['libelle'] as String, montant: e['montant_gnf'] as int, dateLimite: DateTime.parse('${e['date_limite']}')));
  }
  final souscrits = {
    for (final s in await db.getAll('SELECT inscription_id, frais_id FROM souscriptions WHERE organisation_id = ? AND actif = 1', [o]))
      '${s['inscription_id']}|${s['frais_id']}',
  };
  final payes = <String, int>{};
  for (final p in await db.getAll('''
      SELECT l.inscription_id, l.frais_id, sum(l.montant_gnf) AS t FROM lignes_encaissement l
      JOIN encaissements e ON e.id = l.encaissement_id AND e.statut = 'valide' AND e.confirmation <> 'rejete'
      WHERE l.organisation_id = ? GROUP BY l.inscription_id, l.frais_id''', [o])) {
    payes['${p['inscription_id']}|${p['frais_id']}'] = p['t'] as int? ?? 0;
  }
  for (final r in await db.getAll('''
      SELECT inscription_id, frais_id, sum(montant_gnf) AS t FROM remboursements
      WHERE organisation_id = ? AND statut = 'verse' GROUP BY inscription_id, frais_id''', [o])) {
    final k = '${r['inscription_id']}|${r['frais_id']}';
    payes[k] = (payes[k] ?? 0) - (r['t'] as int? ?? 0);
  }
  final amenagees = <String, List<({String libelle, int montant, DateTime dateLimite})>>{};
  for (final e in await db.getAll('SELECT * FROM echeances_eleves WHERE organisation_id = ? ORDER BY ordre', [o])) {
    amenagees.putIfAbsent('${e['inscription_id']}|${e['frais_id']}', () => []).add(
        (libelle: e['libelle'] as String, montant: e['montant_gnf'] as int, dateLimite: DateTime.parse('${e['date_limite']}')));
  }
  final org = await db.get(
      'SELECT reductions_cumul, reductions_plafond, delai_grace_jours FROM organisations WHERE id = ?', [o]);
  final grace = (org['delai_grace_jours'] as int?) ?? 7;
  final finAnnee = DateTime.tryParse('${annee['fin']}') ?? DateTime(rentree.year + 1, 6, 30);
  final cumul = org['reductions_cumul'] == 1;
  final plafond = (org['reductions_plafond'] as int?) ?? 100;
  final regles = [
    for (final r in await db.getAll('SELECT * FROM regles_reduction WHERE organisation_id = ? AND actif = 1 ORDER BY created_at', [o]))
      Regle(
        id: r['id'] as String,
        type: r['type'] as String,
        libelle: r['libelle'] as String,
        pourcentage: r['pourcentage'] == 1,
        valeur: r['valeur'] as num,
        portee: r['portee'] as String,
        nbEnfants: r['nb_enfants'] as int?,
      ),
  ];
  final attribuees = <String, Set<String>>{};
  for (final r in await db.getAll('SELECT inscription_id, regle_id FROM reductions_eleves WHERE organisation_id = ? AND actif = 1', [o])) {
    attribuees.putIfAbsent(r['inscription_id'] as String, () => {}).add(r['regle_id'] as String);
  }
  final payeurDe = {
    for (final p in await db.getAll(
        'SELECT eleve_id, contact_id FROM eleves_contacts WHERE organisation_id = ? AND responsable_financier = 1', [o]))
      p['eleve_id'] as String: p['contact_id'] as String,
  };
  final enfants = <String, int>{};
  for (final i in actives) {
    final c = payeurDe[i['eleve_id']];
    if (c != null) enfants[c] = (enfants[c] ?? 0) + 1;
  }

  for (final i in actives) {
    final entree = i['type_admission'] == 'reinscription' ? 'reinscription' : 'inscription';
    final applicables = reductionsApplicables(
      regles: regles,
      attribuees: attribuees[i['id']] ?? const {},
      enfantsDuPayeur: enfants[payeurDe[i['eleve_id']]] ?? 1,
      cumul: cumul,
    );
    final arrivee = DateTime.tryParse('${i['date_effective']}') ?? jour;
    var retard = 0;
    var plusVieux = 0;
    var retraitNegocie = i['arrivee_mode'] == 'negocie' ? (i['arrivee_retrait_gnf'] as int? ?? 0) : 0;
    var reduitIci = false;
    final siens = fraisRetenus([
      for (final f in frais)
        if ((f['site_id'] == null || f['site_id'] == i['site_id']) &&
            (f['niveau_id'] == null || f['niveau_id'] == i['niveau_id']) &&
            (f['type_frais'] == entree ||
                f['type_frais'] == 'scolarite' ||
                (f['type_frais'] == 'optionnel' && (f['examen'] == 1 || souscrits.contains('${i['id']}|${f['id']}')))))
          Map<String, Object?>.from(f),
    ]);
    for (final f in siens) {
      final type = f['type_frais'] as String? ?? 'optionnel';
      final total = f['montant_gnf'] as int;
      final reduction = reductionSurFrais(typeFrais: type, total: total, applicables: applicables, cumul: cumul, plafond: plafond);
      if (reduction > 0) {
        reduitIci = true;
        m.reductions += reduction;
        // Réparti entre les réductions de l'élève, au prorata de ce que chacune donnerait seule.
        final parts = [for (final x in applicables.where((x) => x.couvre(type))) (x.libelle, x.montantSur(total))];
        final somme = parts.fold<int>(0, (acc, p) => acc + p.$2);
        for (final (libelle, part) in parts) {
          if (somme > 0) m.reductionsParRegle[libelle] = (m.reductionsParRegle[libelle] ?? 0) + (reduction * part / somme).round();
        }
      }
      var retrait = 0;
      if (type == 'scolarite') {
        if (i['arrivee_mode'] == 'mois') {
          retrait = retraitMoisArrivee(total: total - reduction, rentree: rentree, fin: finAnnee, arrivee: arrivee);
        } else if (retraitNegocie > 0) {
          retrait = retraitNegocie < total - reduction ? retraitNegocie : total - reduction;
          retraitNegocie -= retrait;
        }
      }
      final s = situationFrais(
        id: f['id'] as String,
        libelle: f['libelle'] as String,
        type: type,
        total: total,
        echeances: amenagees['${i['id']}|${f['id']}'] ?? echeances[f['id']] ?? const [],
        arrivee: arrivee,
        dejaPaye: payes['${i['id']}|${f['id']}'] ?? 0,
        reduction: reduction,
        retrait: retrait,
        grace: grace,
      );
      m.retraitsArrivee += s.retrait;
      m.du += s.total;
      m.regle += s.paye;
      for (final e in s.echeances) {
        if (!e.enRetard(jour)) continue;
        final jours = jour.difference(e.dateLimite).inDays;
        retard += e.reste;
        if (jours > plusVieux) plusVieux = jours;
        if (jours < 30) {
          m.moins30 += e.reste;
        } else if (jours <= 60) {
          m.de30a60 += e.reste;
        } else {
          m.plus60 += e.reste;
        }
      }
    }
    if (reduitIci) m.eleveReduits++;
    if (retard > 0) {
      m.arrieres += retard;
      m.retards.add(_EnRetard(i['eleve_id'] as String, '${i['nom']} ${i['prenoms']}', '${i['classe']}', retard, plusVieux));
    }
  }
  m.retards.sort((a, b) => b.montant.compareTo(a.montant));
  final delai = ((await db.get('SELECT delai_confirmation_heures AS h FROM organisations WHERE id = ?', [o]))['h'] as int?) ?? 48;
  for (final r in await db.getAll(
      "SELECT autorise_le FROM remboursements WHERE organisation_id = ? AND confirmation = 'attendue'", [o])) {
    m.aConfirmer++;
    final le = DateTime.tryParse('${r['autorise_le']}');
    if (le != null && DateTime.now().toUtc().difference(le.toUtc()).inHours >= delai) m.confirmationsEnRetard++;
  }
  return m;
}

/// Le tableau de bord. Les gestes (inscrire, encaisser, changer de rubrique)
/// viennent du cadre de l'application.
class TableauDeBord extends StatefulWidget {
  const TableauDeBord({
    super.key,
    required this.espace,
    required this.organisation,
    required this.voitFinances,
    required this.peutInscrire,
    required this.peutEncaisser,
    required this.aFaire,
    required this.inscrire,
    required this.importer,
    required this.encaisser,
    this.pied = const [],
  });

  final Espace espace;
  final Map<String, Object?> organisation;
  final bool voitFinances;
  final bool peutInscrire;
  final bool peutEncaisser;

  /// Lignes « À faire » (réglages manquants, inscriptions en attente…).
  final List<Widget> aFaire;
  final VoidCallback inscrire;
  final VoidCallback importer;
  final VoidCallback encaisser;

  /// Ce qui suit les chiffres (sites, poste, installation).
  final List<Widget> pied;

  @override
  State<TableauDeBord> createState() => _TableauDeBordState();
}

class _TableauDeBordState extends State<TableauDeBord> {
  Periode _periode = Periode.mois;
  String? _cle;
  Future<_Mesures>? _resultat;

  Future<_Mesures> _calcul(String cle) {
    if (cle != _cle || _resultat == null) {
      _cle = cle;
      _resultat = _mesurer(widget.espace.orgId, _periode);
    }
    return _resultat!;
  }

  String get _libellePeriode {
    final a = DateTime.now();
    return switch (_periode) {
      Periode.mois => '${_moisLongs[a.month - 1][0].toUpperCase()}${_moisLongs[a.month - 1].substring(1)} ${a.year}',
      Periode.trimestre => '3 derniers mois',
      Periode.annee => 'Année scolaire',
    };
  }

  String get _vsPrecedent => switch (_periode) {
        Periode.mois => 'vs ${_moisLongs[(DateTime.now().month + 10) % 12]}',
        Periode.trimestre => 'vs 3 mois précédents',
        Periode.annee => "vs l'an dernier à date",
      };

  static const _tablesLisibles = {
    'lignes_encaissement': 'Ligne de reçu',
    'encaissements': 'Reçu',
    'clotures_caisse': 'Clôture de caisse',
    'impressions_documents': 'Impression de document',
    'inscriptions': 'Inscription',
    'eleves': 'Élève',
    'remboursements': 'Remboursement',
    'reductions_eleves': 'Réduction',
    'classes': 'Classe',
    'frais': 'Frais',
  };

  Future<void> _voirRefus(List<Map<String, Object?>> refus) async {
    final effacer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Refusés par le serveur'),
        content: SizedBox(
          width: 520,
          child: ListView(shrinkWrap: true, children: [
            const Text("Ces changements faits sur ce poste n'ont pas été acceptés (droits, règle de l'école, doublon). "
                'Ils ne sont pas enregistrés : refaites-les si besoin, ou signalez-les.', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            for (final r in refus)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${_tablesLisibles[r['table_nom']] ?? r['table_nom']} · ${_dateLisible(r['quand'])}'),
                subtitle: Text('${r['message'] ?? ''} (${r['code'] ?? ''})'),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Effacer la liste')),
          FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text('Fermer')),
        ],
      ),
    );
    if (effacer == true) {
      await db.execute('DELETE FROM refus_serveur');
      if (mounted) setState(() {});
    }
  }

  void _voirArrieres(List<_EnRetard> retards) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _ArrieresScreen(espace: widget.espace, retards: retards)));

  @override
  Widget build(BuildContext context) {
    final o = widget.espace.orgId;
    return Scaffold(
      body: Requete(
        // Ce qui fait bouger les chiffres : paiements, inscriptions, frais…
        '''SELECT (SELECT count(*) FROM encaissements WHERE organisation_id = ?) AS a,
                  (SELECT max(updated_at) FROM encaissements WHERE organisation_id = ?) AS b,
                  (SELECT max(updated_at) FROM inscriptions WHERE organisation_id = ?) AS c,
                  (SELECT count(*) FROM inscriptions WHERE organisation_id = ?) AS d,
                  (SELECT max(updated_at) FROM frais WHERE organisation_id = ?) AS e,
                  (SELECT max(updated_at) FROM reductions_eleves WHERE organisation_id = ?) AS f,
                  (SELECT count(*) FROM refus_serveur) AS z,
                  (SELECT max(updated_at) FROM remboursements WHERE organisation_id = ?) AS g,
                  (SELECT count(*) FROM personnel WHERE organisation_id = ?) AS h''',
        parametres: [o, o, o, o, o, o, o, o],
        builder: (context, cle) => FutureBuilder<_Mesures>(
          // On ne recalcule que si les données ou la période ont changé.
          future: _calcul('${cle.first.values.join('|')}|$_periode'),
          builder: (context, s) {
            if (s.hasError) return Center(child: Text('Calcul impossible : ${s.error}'));
            if (!s.hasData) return const Center(child: CircularProgressIndicator());
            return _contenu(context, s.data!);
          },
        ),
      ),
    );
  }

  Widget _contenu(BuildContext context, _Mesures m) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final telephone = MediaQuery.sizeOf(context).width < 640;
    final recouvrement = m.du == 0 ? 0.0 : m.regle * 100 / m.du;
    final cible = (widget.organisation['seuil_recouvrement'] as int?) ?? 70;
    final seuil = recouvrement >= cible ? NiveauSeuil.bon : (recouvrement >= cible - 10 ? NiveauSeuil.vigilance : NiveauSeuil.alerte);
    double? variation(int a, int? b) => b == null || b == 0 ? (b == 0 && a == 0 ? 0 : null) : (a - b) * 100 / b;

    final enTete = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 10,
      children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 12, children: [
          Text('${widget.organisation['nom']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -.3)),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text('$_libellePeriode${m.annee == null ? '' : ' · ${m.annee}'}', style: TextStyle(fontSize: 14, color: gris)),
          ),
        ]),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (widget.voitFinances)
            Segments<Periode>(
              valeur: _periode,
              choix: const {Periode.mois: 'Mois', Periode.trimestre: 'Trimestre', Periode.annee: 'Année'},
              onChanged: (p) => setState(() => _periode = p),
            ),
          if (widget.peutEncaisser)
            OutlinedButton.icon(
                onPressed: widget.encaisser, icon: const Icon(Icons.point_of_sale_outlined, size: 16), label: const Text('Encaisser')),
          if (widget.peutInscrire)
            FilledButton.icon(
                onPressed: widget.inscrire, icon: const Icon(Icons.person_add_alt, size: 16), label: const Text('Nouvelle inscription')),
        ]),
      ],
    );

    Widget deux(Widget a, Widget b) => LayoutBuilder(
          builder: (context, c) => c.maxWidth >= 1000
              // Les deux cartes ont la même hauteur fixe : pas besoin de mesurer.
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 2, child: a),
                  const SizedBox(width: 12),
                  Expanded(child: b),
                ])
              : Column(children: [a, const SizedBox(height: 12), b]),
        );

    final cycles = <String?>[];
    for (final n in m.parNiveau) {
      if (!cycles.contains(n.$2)) cycles.add(n.$2);
    }
    const couleursCycles = [Color(0xFF86B6EF), Viz.bleu, Viz.orange, Viz.vert, Viz.violet];
    Color couleurCycle(String? c) => couleursCycles[cycles.indexOf(c) % couleursCycles.length];

    return ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            enTete,
            const SizedBox(height: 20),
            if (m.inscrits == 0 && widget.peutInscrire) ...[
              _PremierJour(importer: widget.importer, inscrire: widget.inscrire),
              const SizedBox(height: 20),
            ],
            if (widget.aFaire.isNotEmpty || m.incomplets.isNotEmpty || m.refus.isNotEmpty || (widget.voitFinances && m.aConfirmer > 0)) ...[
              const TitreSection('À faire'),
              Container(
                decoration: BoxDecoration(
                  color: schema.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: schema.outlineVariant),
                ),
                child: Column(children: [
                  if (m.refus.isNotEmpty) ...[
                    InkWell(
                      onTap: () => _voirRefus(m.refus),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(children: [
                          Etat('${m.refus.length}', ton: Ton.retard),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text('changement(s) refusé(s) par le serveur sur ce poste : à vérifier',
                                style: TextStyle(fontSize: 14, color: Couleurs.retard)),
                          ),
                          Icon(Icons.chevron_right, size: 16, color: gris),
                        ]),
                      ),
                    ),
                    if (widget.aFaire.isNotEmpty || m.incomplets.isNotEmpty || (widget.voitFinances && m.aConfirmer > 0))
                      Divider(height: 1, color: schema.outlineVariant),
                  ],
                  for (var i = 0; i < widget.aFaire.length; i++) ...[
                    if (i > 0) Divider(height: 1, color: schema.outlineVariant),
                    widget.aFaire[i],
                  ],
                  if (m.incomplets.isNotEmpty) ...[
                    if (widget.aFaire.isNotEmpty) Divider(height: 1, color: schema.outlineVariant),
                    InkWell(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => _DossiersIncompletsScreen(espace: widget.espace, dossiers: m.incomplets))),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(children: [
                          Etat('${m.incomplets.length}', ton: Ton.attente),
                          const SizedBox(width: 12),
                          const Expanded(child: Text('dossier(s) incomplet(s) : pièce obligatoire manquante', style: TextStyle(fontSize: 14))),
                          Icon(Icons.chevron_right, size: 16, color: gris),
                        ]),
                      ),
                    ),
                  ],
                  if (widget.voitFinances && m.aConfirmer > 0) ...[
                    if (widget.aFaire.isNotEmpty || m.incomplets.isNotEmpty) Divider(height: 1, color: schema.outlineVariant),
                    InkWell(
                      onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => RemboursementsScreen(espace: widget.espace))),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(children: [
                          Etat('${m.aConfirmer}', ton: m.confirmationsEnRetard > 0 ? Ton.retard : Ton.attente),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                                'remboursement(s) autorisé(s) de vive voix à confirmer'
                                '${m.confirmationsEnRetard > 0 ? ' — ${m.confirmationsEnRetard} hors délai' : ''}',
                                style: TextStyle(fontSize: 14, color: m.confirmationsEnRetard > 0 ? Couleurs.retard : null)),
                          ),
                          Icon(Icons.chevron_right, size: 16, color: gris),
                        ]),
                      ),
                    ),
                  ],
                ]),
              ),
              const SizedBox(height: 24),
            ],
            if (widget.voitFinances) ...[
              const TitreSection('Finances'),
              GrilleCartes(larges: const {0}, cartes: [
                CarteKpi(
                  vedette: true,
                  titre: 'Taux de recouvrement',
                  aide: "Part de ce qui est dû pour l'année qui a déjà été payé (réductions déduites).",
                  valeur: m.du == 0 ? '—' : pourcent(recouvrement),
                  seuil: m.du == 0 ? null : seuil,
                  texteSeuil: 'seuil $cible %',
                  barre: m.du == 0 ? null : recouvrement,
                  detail: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${gnf(m.regle)} / ${gnf(m.du)}', style: TextStyle(fontSize: 14, color: gris)),
                      if (m.retraitsArrivee > 0)
                        Text('dont ${gnf(m.retraitsArrivee)} retirés pour des arrivées en cours d\'année',
                            style: TextStyle(fontSize: 12, color: gris)),
                    ]),
                  ),
                  onTap: () => _voirArrieres(m.retards),
                ),
                CarteKpi(
                  titre: 'Encaissé sur la période',
                  valeur: gnf(m.encaisse),
                  comparaisons: [Comparaison(_vsPrecedent, variation(m.encaisse, m.encaissePrecedent))],
                  detail: m.parMode.isEmpty
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                              m.parMode.entries.map((e) => '${modesPaiement[e.key] ?? e.key} ${millions(e.value)}').join(' · '),
                              style: TextStyle(fontSize: 12, color: gris)),
                        ),
                ),
                CarteKpi(
                  titre: 'Total des arriérés',
                  aide: 'Échéances dont la date est passée et qui ne sont pas payées.',
                  valeur: gnf(m.arrieres),
                  seuil: m.arrieres > 0 ? NiveauSeuil.alerte : null,
                  onTap: () => _voirArrieres(m.retards),
                ),
                CarteKpi(
                  titre: 'Élèves en retard de paiement',
                  aide: 'Élèves qui ont au moins une échéance passée non payée.',
                  valeur: '${m.retards.length}',
                  detail: m.inscrits == 0
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('sur ${m.inscrits} inscrits', style: TextStyle(fontSize: 14, color: gris)),
                        ),
                  onTap: () => _voirArrieres(m.retards),
                ),
                CarteKpi(
                  titre: 'Coût des réductions',
                  aide: "Ce que l'école renonce à percevoir cette année : fratrie, enfants du personnel, bourses…",
                  valeur: gnf(m.reductions),
                  detail: m.reductions == 0
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${m.eleveReduits} élève(s)${m.du + m.reductions > 0 ? ' · ${pourcent(m.reductions * 100 / (m.du + m.reductions))} du brut' : ''}',
                                style: TextStyle(fontSize: 14, color: gris)),
                            for (final e in (m.reductionsParRegle.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(4))
                              Text('${e.key} : ${millions(e.value)}', style: TextStyle(fontSize: 12, color: gris)),
                          ]),
                        ),
                ),
              ]),
              const SizedBox(height: 12),
              deux(
                CarteGraphique(
                  titre: 'Encaissements par mois',
                  indice: m.annee,
                  legende: [EntreeLegende(Viz.bleu, m.annee ?? 'Année en cours')],
                  enfant: GraphBarres(
                    format: millions,
                    barres: [for (final (mois, t) in m.parMois) Barre(mois, t, infobulle: '$mois : ${gnf(t)}')],
                  ),
                ),
                CarteGraphique(
                  titre: 'Ancienneté des arriérés',
                  indice: gnf(m.arrieres),
                  enfant: GraphBarresH(
                    format: millions,
                    barres: [
                      Barre('moins de 30 j', m.moins30, couleur: Viz.rampe[0], infobulle: gnf(m.moins30)),
                      Barre('30 à 60 j', m.de30a60, couleur: Viz.rampe[1], infobulle: gnf(m.de30a60)),
                      Barre('plus de 60 j', m.plus60, couleur: Viz.rampe[2], infobulle: gnf(m.plus60)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
            const TitreSection('Effectifs'),
            GrilleCartes(cartes: [
              CarteKpi(
                titre: 'Élèves inscrits',
                valeur: '${m.inscrits}',
                detail: m.attente == 0
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Align(alignment: Alignment.centerLeft, child: Etat('${m.attente} en attente', ton: Ton.attente)),
                      ),
              ),
              CarteKpi(titre: 'Nouvelles inscriptions', aide: 'Premières inscriptions et transferts entrants.', valeur: '${m.nouvelles}'),
              CarteKpi(titre: 'Départs / transferts sortants', valeur: '${m.departs}'),
              CarteKpi(titre: 'Personnel — effectif', valeur: '${m.personnel}'),
            ]),
            const SizedBox(height: 12),
            deux(
              CarteGraphique(
                titre: 'Répartition par niveau',
                legende: [for (final c in cycles) EntreeLegende(couleurCycle(c), c ?? 'Sans cycle')],
                enfant: m.parNiveau.isEmpty
                    ? Center(child: Text('Aucun élève inscrit.', style: TextStyle(fontSize: 14, color: gris)))
                    : GraphBarres(barres: [
                        for (final (niveau, cycle, n) in m.parNiveau)
                          Barre(niveau, n, couleur: couleurCycle(cycle), infobulle: '$niveau : $n élève(s)'),
                      ]),
              ),
              CarteGraphique(
                titre: 'Filles et garçons',
                indice: '${m.inscrits} élèves',
                enfant: GraphAnneau(parts: [
                  Barre('Filles', m.filles, couleur: Viz.orange),
                  Barre('Garçons', m.garcons, couleur: Viz.bleu),
                  if (m.sexeInconnu > 0) Barre('Non renseigné', m.sexeInconnu, couleur: gris.withValues(alpha: .4)),
                ]),
              ),
            ),
            if (widget.pied.isNotEmpty) ...[
              const SizedBox(height: 24),
              const TitreSection('Établissement'),
              ...widget.pied,
            ],
            const SizedBox(height: 24),
          ]),
        ),
      ),
    ]);
  }
}

/// Le premier jour : aucun élève. Ce n'est pas une panne ; voici par où commencer.
class _PremierJour extends StatelessWidget {
  const _PremierJour({required this.importer, required this.inscrire});

  final VoidCallback importer;
  final VoidCallback inscrire;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Couleurs.infoFond,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Couleurs.info.withValues(alpha: .35)),
        ),
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Couleurs.info, fontSize: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Aucun élève inscrit pour l\'instant.', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('Les chiffres ci-dessous resteront à zéro tant que personne n\'est inscrit : c\'est normal, ce '
                'n\'est pas une panne. Commencez par vos élèves ; la caisse et le reste en découlent.'),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(onPressed: importer, child: const Text("Importer ma liste d'élèves")),
              OutlinedButton(onPressed: inscrire, child: const Text('Inscrire un élève')),
            ]),
            const SizedBox(height: 10),
            const Text("L'import accepte la liste de l'an dernier comme celle de cette année. Une ligne incomplète "
                '(date de naissance manquante) est acceptée : on complète plus tard.', style: TextStyle(fontSize: 12)),
          ]),
        ),
      );
}

/// Les élèves qui doivent des échéances passées, du plus gros montant au plus petit.
class _ArrieresScreen extends StatelessWidget {
  const _ArrieresScreen({required this.espace, required this.retards});

  final Espace espace;
  final List<_EnRetard> retards;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final total = retards.fold(0, (s, r) => s + r.montant);
    const entete = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);
    return Scaffold(
      appBar: AppBar(title: const Text('Arriérés')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text('${retards.length} élève(s) · ${gnf(total)} en retard', style: TextStyle(fontSize: 14, color: gris)),
            const SizedBox(height: 12),
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: schema.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: schema.outlineVariant),
              ),
              child: Column(children: [
                Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: schema.outlineVariant))),
                  child: const Row(children: [
                    Expanded(child: Text('Élève', style: entete)),
                    SizedBox(width: 120, child: Text('Classe', style: entete)),
                    SizedBox(width: 110, child: Text('Retard', style: entete)),
                    SizedBox(width: 150, child: Text('Montant', textAlign: TextAlign.right, style: entete)),
                  ]),
                ),
                if (retards.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text('Aucun arriéré : toutes les échéances passées sont payées.', style: TextStyle(color: gris)),
                  ),
                for (final r in retards)
                  InkWell(
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: espace, eleveId: r.eleveId))),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: schema.outlineVariant))),
                      child: Row(children: [
                        Expanded(child: Text(r.nom, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
                        SizedBox(width: 120, child: Text(r.classe, style: const TextStyle(fontSize: 14))),
                        SizedBox(
                          width: 110,
                          child: Text(r.jours < 1 ? "aujourd'hui" : '${r.jours} j',
                              style: TextStyle(fontSize: 14, color: r.jours > 60 ? Couleurs.retard : gris)),
                        ),
                        SizedBox(
                          width: 150,
                          child: Text(gnf(r.montant),
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Couleurs.retard)),
                        ),
                      ]),
                    ),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Les élèves dont il manque une pièce obligatoire.
class _DossiersIncompletsScreen extends StatelessWidget {
  const _DossiersIncompletsScreen({required this.espace, required this.dossiers});

  final Espace espace;
  final List<(String, String, String, List<String>)> dossiers;

  @override
  Widget build(BuildContext context) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    return _Page(
      titre: 'Dossiers incomplets',
      corps: ListView(padding: const EdgeInsets.all(16), children: [
        Text('${dossiers.length} élève(s) · touchez un élève pour cocher ses pièces sur sa fiche.', style: TextStyle(fontSize: 13, color: gris)),
        const SizedBox(height: 8),
        for (final (id, nom, classe, manquantes) in dossiers)
          Card(
            child: ListTile(
              title: Text(nom),
              subtitle: Text('$classe · manque : ${manquantes.join(', ')}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: espace, eleveId: id))),
            ),
          ),
      ]),
    );
  }
}
