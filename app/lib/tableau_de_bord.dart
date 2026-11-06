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

/// Une case de l'état de recouvrement : ce qui était dû, ce qui est payé, en retard ou non.
typedef _CaseRecouvrement = ({int du, int paye, bool retard});

/// Un élève dans l'état de recouvrement de sa classe, colonne par colonne
/// (inscription, chaque tranche de scolarité, autres frais).
class _LigneRecouvrement {
  _LigneRecouvrement(this.eleveId, this.nom, this.matricule, this.classeId, this.classe, this.ordre);

  final String eleveId;
  final String nom;
  final String matricule;
  final String classeId;
  final String classe;
  final int ordre;
  final cases = <String, _CaseRecouvrement>{};
  int du = 0;
  int paye = 0;
  int retard = 0;

  int get reste => du - paye;

  void ajouter(String colonne, int du, int paye, bool retard) {
    final c = cases[colonne];
    cases[colonne] = (du: (c?.du ?? 0) + du, paye: (c?.paye ?? 0) + paye, retard: (c?.retard ?? false) || retard);
  }
}

class _Mesures {
  String? annee;

  /// État de recouvrement : une ligne par élève inscrit, et l'ordre des colonnes
  /// (clé de tri : inscription d'abord, puis les tranches par date, puis le reste).
  final recouvrement = <_LigneRecouvrement>[];
  final colonnesRecouvrement = <String, (int, DateTime?)>{};
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

  /// Postes activés hors direction, en attente de validation.
  int postesAValider = 0;

  /// Remboursements autorisés de vive voix : à confirmer, dont en retard.
  int aConfirmer = 0;
  int confirmationsEnRetard = 0;

  /// Par élève (inscription de l'année) : ce qu'il doit, ce qui est payé, ce qui est en retard.
  final soldes = <String, ({int du, int paye, int retard})>{};
}

/// Ce que doit chaque élève cette année (mêmes calculs que la caisse) : pour les familles.
Future<Map<String, ({int du, int paye, int retard})>> soldesDesEleves(String org) async =>
    (await _mesurer(org, Periode.annee)).soldes;

Future<_Mesures> _mesurer(String o, Periode periode) async {
  final m = _Mesures();
  m.refus.addAll([for (final r in await db.getAll('SELECT * FROM refus_serveur ORDER BY quand DESC LIMIT 50')) Map.of(r)]);
  m.postesAValider = (await db.get("SELECT count(*) AS n FROM postes WHERE organisation_id = ? AND statut = 'a_valider'", [o]))['n']
          as int? ??
      0;
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
      SELECT i.id, i.eleve_id, i.site_id, i.classe_id, i.type_admission, i.statut, i.date_effective,
             i.arrivee_mode, i.arrivee_retrait_gnf, e.pieces_dossier,
             c.niveau_id, c.nom AS classe, n.nom AS niveau, n.cycle, n.ordre, e.sexe, e.nom, e.prenoms, e.matricule
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
    var duIci = 0;
    var payeIci = 0;
    final ligne = _LigneRecouvrement(i['eleve_id'] as String, '${i['nom']} ${i['prenoms']}', '${i['matricule'] ?? ''}',
        i['classe_id'] as String, '${i['classe']}', i['ordre'] as int? ?? 0);
    final siens = fraisRetenus([
      for (final f in frais)
        if ((f['site_id'] == null || f['site_id'] == i['site_id']) &&
            (f['niveau_id'] == null || f['niveau_id'] == i['niveau_id']) &&
            (f['type_frais'] == entree ||
                f['type_frais'] == 'scolarite' ||
                autreFraisDu(f, classeId: i['classe_id'] as String?, souscrit: souscrits.contains('${i['id']}|${f['id']}'))))
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
      duIci += s.total;
      payeIci += s.paye;
      // L'état de recouvrement : l'inscription, chaque tranche, et les autres frais ensemble.
      if (type == 'scolarite') {
        for (final e in s.echeances) {
          ligne.ajouter(e.libelle, e.montant, e.paye, e.enRetard(jour));
          final k = m.colonnesRecouvrement[e.libelle];
          if (k == null || (k.$2 != null && e.dateLimite.isBefore(k.$2!))) m.colonnesRecouvrement[e.libelle] = (1, e.dateLimite);
        }
      } else {
        final col = type == 'optionnel' ? 'Autres frais' : 'Inscription';
        ligne.ajouter(col, s.total, s.paye, s.echeances.any((e) => e.enRetard(jour)));
        m.colonnesRecouvrement.putIfAbsent(col, () => (type == 'optionnel' ? 2 : 0, null));
      }
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
    m.soldes[i['eleve_id'] as String] = (du: duIci, paye: payeIci, retard: retard);
    ligne
      ..du = duIci
      ..paye = payeIci
      ..retard = retard;
    m.recouvrement.add(ligne);
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
    this.ouvrir,
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

  /// Ouvre une rubrique depuis une tuile : 'caisse', 'recouvrement', 'eleves'.
  final ValueChanged<String>? ouvrir;

  /// Ce qui suit les chiffres (sites, poste, installation).
  final List<Widget> pied;

  @override
  State<TableauDeBord> createState() => _TableauDeBordState();
}

class _TableauDeBordState extends State<TableauDeBord> {
  Periode _periode = Periode.mois;
  bool _toutAFaire = false;
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
                title: Text([
                  _tablesLisibles[r['table_nom']] ?? r['table_nom'],
                  if (r['qui'] != null) r['qui'],
                  _dateLisible(r['quand']),
                ].join(' · ')),
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
                  (SELECT max(updated_at) FROM postes) AS w,
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
    final largeur = MediaQuery.sizeOf(context).width;
    final telephone = largeur < 640;
    final recouvrement = m.du == 0 ? 0.0 : m.regle * 100 / m.du;
    final cible = (widget.organisation['seuil_recouvrement'] as int?) ?? 70;
    // Sous le seuil : orange (vigilance), pas une alarme rouge.
    final seuil = recouvrement >= cible ? NiveauSeuil.bon : NiveauSeuil.vigilance;
    double? variation(int a, int? b) => b == null || b == 0 ? (b == 0 && a == 0 ? 0 : null) : (a - b) * 100 / b;
    void ouvrir(String r) => widget.ouvrir?.call(r);

    // En-tête ------------------------------------------------------------------
    final periode = Segments<Periode>(
      valeur: _periode,
      choix: const {Periode.mois: 'Mois', Periode.trimestre: 'Trimestre', Periode.annee: 'Année'},
      onChanged: (p) => setState(() => _periode = p),
    );
    final enTete = telephone
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${widget.organisation['nom']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            Text('$_libellePeriode${m.annee == null ? '' : ' · ${m.annee}'}', style: TextStyle(fontSize: 13, color: gris)),
            if (widget.voitFinances) ...[const SizedBox(height: 10), Align(alignment: Alignment.centerLeft, child: periode)],
            if (widget.peutInscrire || widget.peutEncaisser) ...[
              const SizedBox(height: 10),
              Row(children: [
                if (widget.peutInscrire)
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: FilledButton.icon(
                          onPressed: widget.inscrire, icon: const Icon(Icons.person_add_alt, size: 18), label: const Text('Inscrire')),
                    ),
                  ),
                if (widget.peutInscrire && widget.peutEncaisser) const SizedBox(width: 8),
                if (widget.peutEncaisser)
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: FilledButton.tonalIcon(
                          onPressed: widget.encaisser, icon: const Icon(Icons.point_of_sale_outlined, size: 18), label: const Text('Encaisser')),
                    ),
                  ),
              ]),
            ],
          ])
        : Wrap(
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
                if (widget.voitFinances) periode,
                if (widget.peutEncaisser)
                  OutlinedButton.icon(
                      onPressed: widget.encaisser, icon: const Icon(Icons.point_of_sale_outlined, size: 16), label: const Text('Encaisser')),
                if (widget.peutInscrire)
                  FilledButton.icon(
                      onPressed: widget.inscrire, icon: const Icon(Icons.person_add_alt, size: 16), label: const Text('Nouvelle inscription')),
              ]),
            ],
          );

    // À faire ------------------------------------------------------------------
    Widget ligne(Widget etat, String texte, VoidCallback onTap, {Color? couleur}) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              etat,
              const SizedBox(width: 12),
              Expanded(child: Text(texte, style: TextStyle(fontSize: 14, color: couleur))),
              Icon(Icons.chevron_right, size: 16, color: gris),
            ]),
          ),
        );
    final aFaire = <Widget>[
      if (m.refus.isNotEmpty)
        ligne(Etat('${m.refus.length}', ton: Ton.retard), 'changement(s) refusé(s) par le serveur sur ce poste : à vérifier',
            () => _voirRefus(m.refus), couleur: Couleurs.retard),
      if (widget.espace.gestionnaire && m.postesAValider > 0)
        ligne(Etat('${m.postesAValider}', ton: Ton.attente), 'poste(s) à valider : activés par le personnel',
            () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PostesScreen(espace: widget.espace)))),
      ...widget.aFaire,
      if (m.incomplets.isNotEmpty)
        ligne(Etat('${m.incomplets.length}', ton: Ton.attente), 'dossier(s) incomplet(s) : pièce obligatoire manquante',
            () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _DossiersIncompletsScreen(espace: widget.espace, dossiers: m.incomplets)))),
      if (widget.voitFinances && m.aConfirmer > 0)
        ligne(
            Etat('${m.aConfirmer}', ton: m.confirmationsEnRetard > 0 ? Ton.retard : Ton.attente),
            'remboursement(s) autorisé(s) de vive voix à confirmer'
                '${m.confirmationsEnRetard > 0 ? ' — ${m.confirmationsEnRetard} hors délai' : ''}',
            () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => RemboursementsScreen(espace: widget.espace))),
            couleur: m.confirmationsEnRetard > 0 ? Couleurs.retard : null),
    ];
    // Sur téléphone : les trois premiers, le reste sur demande.
    final aFaireVisibles = telephone && !_toutAFaire && aFaire.length > 3 ? aFaire.take(3).toList() : aFaire;
    final carte = BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: schema.outlineVariant));
    final blocAFaire = aFaire.isEmpty
        ? null
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const TitreSection('À faire'),
            Container(
              decoration: carte,
              child: Column(children: [
                for (var i = 0; i < aFaireVisibles.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: schema.outlineVariant),
                  aFaireVisibles[i],
                ],
                if (aFaireVisibles.length < aFaire.length) ...[
                  Divider(height: 1, color: schema.outlineVariant),
                  TextButton(
                    onPressed: () => setState(() => _toutAFaire = true),
                    child: Text('Voir tout (${aFaire.length})'),
                  ),
                ],
              ]),
            ),
          ]);

    // Les quatre tuiles -----------------------------------------------------------
    final tuiles = GrilleCartes(cartes: [
      if (widget.voitFinances) ...[
        CarteKpi(
          titre: 'Encaissé',
          aide: 'Total des reçus sur la période choisie.',
          valeur: gnf(m.encaisse),
          comparaisons: [Comparaison(_vsPrecedent, variation(m.encaisse, m.encaissePrecedent))],
          detail: m.parMode.isEmpty
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(m.parMode.entries.map((e) => '${modesPaiement[e.key] ?? e.key} ${millions(e.value)}').join(' · '),
                      style: TextStyle(fontSize: 12, color: gris)),
                ),
          onTap: () => ouvrir('caisse'),
        ),
        CarteKpi(
          titre: 'Recouvrement',
          aide: "Part de ce qui est dû pour l'année qui a déjà été payé (réductions déduites).",
          valeur: m.du == 0 ? '—' : pourcent(recouvrement),
          seuil: m.du == 0 ? null : seuil,
          texteSeuil: 'seuil $cible %',
          barre: m.du == 0 ? null : recouvrement,
          detail: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${millions(m.regle)} réglés sur ${millions(m.du)}', style: TextStyle(fontSize: 12, color: gris)),
              if (m.reductions > 0)
                Text('réductions : ${millions(m.reductions)} (${m.eleveReduits} élève(s))', style: TextStyle(fontSize: 12, color: gris)),
            ]),
          ),
          onTap: () => ouvrir('recouvrement'),
        ),
        CarteKpi(
          titre: 'Arriérés',
          aide: 'Échéances dont la date (et le délai de grâce) est passée et qui ne sont pas payées.',
          valeur: gnf(m.arrieres),
          seuil: m.arrieres > 0 ? NiveauSeuil.vigilance : null,
          detail: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(m.retards.isEmpty ? 'aucun élève en retard' : '${m.retards.length} élève(s) en retard',
                style: TextStyle(fontSize: 12, color: gris)),
          ),
          onTap: () => _voirArrieres(m.retards),
        ),
      ],
      CarteKpi(
        titre: 'Élèves inscrits',
        valeur: '${m.inscrits}',
        detail: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${m.nouvelles} nouveau(x) · ${m.departs} départ(s)', style: TextStyle(fontSize: 12, color: gris)),
            Text('${m.filles} fille(s) · ${m.garcons} garçon(s)', style: TextStyle(fontSize: 12, color: gris)),
            if (m.attente > 0) ...[const SizedBox(height: 4), Etat('${m.attente} en attente', ton: Ton.attente)],
          ]),
        ),
        onTap: () => ouvrir('eleves'),
      ),
    ]);

    // Recouvrement par classe : les cinq classes les plus en retard ------------------
    final parClasse = <String, (String, int, int)>{};
    for (final l in m.recouvrement) {
      final c = parClasse[l.classeId];
      parClasse[l.classeId] = (l.classe, (c?.$2 ?? 0) + l.du, (c?.$3 ?? 0) + l.paye);
    }
    final classes = parClasse.values.where((c) => c.$2 > 0).toList()..sort((a, b) => (a.$3 / a.$2).compareTo(b.$3 / b.$2));
    final blocClasses = Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: carte,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Text('Recouvrement par classe', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
          if (widget.ouvrir != null) TextButton(onPressed: () => ouvrir('recouvrement'), child: const Text('Voir tout')),
        ]),
        Text('Les classes les moins à jour', style: TextStyle(fontSize: 12, color: gris)),
        const SizedBox(height: 8),
        if (classes.isEmpty) Text('Aucun montant dû pour le moment.', style: TextStyle(fontSize: 13, color: gris)),
        for (final (classe, du, paye) in classes.take(5))
          Padding(
            padding: const EdgeInsets.only(bottom: 10, right: 8),
            child: Row(children: [
              SizedBox(width: 72, child: Text(classe, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: (paye / du).clamp(0, 1).toDouble(),
                    minHeight: 6,
                    backgroundColor: Couleurs.doux(context),
                    color: paye * 100 / du >= cible ? Couleurs.regle : Couleurs.attente,
                  ),
                ),
              ),
              SizedBox(
                  width: 48,
                  child: Text('${(paye * 100 / du).round()} %', textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
              SizedBox(
                  width: telephone ? 70 : 96,
                  child: Text(millions(du - paye), textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: gris))),
            ]),
          ),
      ]),
    );

    final graphique = CarteGraphique(
      titre: 'Encaissements par mois',
      indice: m.annee,
      legende: [EntreeLegende(Viz.bleu, m.annee ?? 'Année en cours')],
      enfant: GraphBarres(
        format: millions,
        barres: [for (final (mois, t) in m.parMois) Barre(mois, t, infobulle: '$mois : ${gnf(t)}')],
      ),
    );
    // Sans arriéré, un simple bandeau au lieu d'un graphique vide.
    final anciennete = m.arrieres == 0
        ? Container(
            padding: const EdgeInsets.all(16),
            decoration: carte,
            child: Row(children: [
              const Icon(Icons.check_circle_outline, size: 18, color: Couleurs.regle),
              const SizedBox(width: 10),
              Expanded(child: Text('Aucun arriéré : toutes les échéances passées sont payées.', style: TextStyle(fontSize: 13, color: gris))),
            ]),
          )
        : CarteGraphique(
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
    );
    // Aujourd'hui : la caisse du jour (même calcul que la clôture).
    final aujourdhui = widget.peutEncaisser || widget.voitFinances
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const TitreSection("Aujourd'hui"),
            _CaisseDuJour(orgId: widget.espace.orgId, toute: widget.voitFinances),
          ])
        : null;

    // Effectifs ------------------------------------------------------------------
    final cycles = <String?>[];
    for (final n in m.parNiveau) {
      if (!cycles.contains(n.$2)) cycles.add(n.$2);
    }
    const couleursCycles = [Color(0xFF86B6EF), Viz.bleu, Viz.orange, Viz.vert, Viz.violet];
    Color couleurCycle(String? c) => couleursCycles[cycles.indexOf(c) % couleursCycles.length];
    final niveaux = CarteGraphique(
      titre: 'Répartition par niveau',
      legende: [for (final c in cycles) EntreeLegende(couleurCycle(c), c ?? 'Sans cycle')],
      enfant: m.parNiveau.isEmpty
          ? Center(child: Text('Aucun élève inscrit.', style: TextStyle(fontSize: 14, color: gris)))
          : GraphBarres(barres: [
              for (final (niveau, cycle, n) in m.parNiveau) Barre(niveau, n, couleur: couleurCycle(cycle), infobulle: '$niveau : $n élève(s)'),
            ]),
    );
    final sexes = CarteGraphique(
      titre: 'Filles et garçons',
      indice: '${m.inscrits} élèves · ${m.personnel} personnel',
      enfant: GraphAnneau(parts: [
        Barre('Filles', m.filles, couleur: Viz.orange),
        Barre('Garçons', m.garcons, couleur: Viz.bleu),
        if (m.sexeInconnu > 0) Barre('Non renseigné', m.sexeInconnu, couleur: gris.withValues(alpha: .4)),
      ]),
    );
    Widget deux(Widget a, Widget b) => LayoutBuilder(
          builder: (context, c) => c.maxWidth >= 1000
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 2, child: a),
                  const SizedBox(width: 12),
                  Expanded(child: b),
                ])
              : Column(children: [a, const SizedBox(height: 12), b]),
        );
    const espace = SizedBox(height: 20);

    final large = largeur >= 1100;
    final corps = <Widget>[
      enTete,
      espace,
      if (m.inscrits == 0 && widget.peutInscrire) ...[_PremierJour(importer: widget.importer, inscrire: widget.inscrire), espace],
      if (large) ...[
        tuiles,
        espace,
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            flex: 2,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (widget.voitFinances) ...[graphique, const SizedBox(height: 12), blocClasses, espace],
              const TitreSection('Effectifs'),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 3, child: niveaux),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: sexes),
              ]),
            ]),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (aujourdhui != null) ...[aujourdhui, espace],
              if (blocAFaire != null) ...[blocAFaire, espace],
              if (widget.voitFinances) anciennete,
            ]),
          ),
        ]),
      ] else ...[
        if (aujourdhui != null) ...[aujourdhui, const SizedBox(height: 12)],
        tuiles,
        espace,
        if (blocAFaire != null) ...[blocAFaire, espace],
        if (widget.voitFinances) ...[blocClasses, const SizedBox(height: 12), graphique, const SizedBox(height: 12), anciennete, espace],
        const TitreSection('Effectifs'),
        deux(niveaux, sexes),
      ],
      if (widget.pied.isNotEmpty) ...[espace, const TitreSection('Établissement'), ...widget.pied],
      espace,
    ];

    return ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: corps),
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
