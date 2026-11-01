part of 'configuration.dart';

/// Formulaire d'inscription. D'abord : « l'élève est-il déjà connu ? » (pour
/// éviter les doublons). Ensuite, une colonne de sections numérotées
/// (identité, contacts, pièces, classe, frais) et, à droite, le récapitulatif
/// avec les boutons. Sur téléphone, le récapitulatif passe en bas.

/// Une pièce que l'école demande, pour certaines admissions et certains cycles.
class PieceDossier {
  const PieceDossier(this.code, this.libelle, {this.admissions, this.cycles, this.obligatoire = false});

  final String code;
  final String libelle;

  /// null : toutes les admissions (nouvelle, réinscription, transfert).
  final Set<String>? admissions;

  /// null : tous les cycles.
  final Set<String>? cycles;
  final bool obligatoire;

  bool concerne(String? admission, String? cycle) =>
      (admissions == null || admission == null || admissions!.contains(admission)) &&
      (cycles == null || cycle == null || cycles!.contains(cycle));
}

/// Liste proposée tant que l'école n'a pas réglé la sienne.
const piecesStandard = [
  PieceDossier('acte_naissance', 'Extrait de naissance', admissions: {'nouvelle', 'transfert'}, obligatoire: true),
  PieceDossier('photo', "Photo d'identité"),
  PieceDossier('vaccination', 'Carnet de vaccination', cycles: {'maternelle', 'primaire'}),
  PieceDossier('bulletin', 'Bulletin précédent', admissions: {'transfert', 'reinscription'}),
  PieceDossier('certificat_scolarite', 'Certificat de scolarité', admissions: {'transfert'}),
  PieceDossier('residence', 'Certificat de résidence'),
];

/// Les pièces de l'école (la liste standard si elle n'a rien réglé).
Future<List<PieceDossier>> piecesDe(String orgId) async {
  final l = await db.getAll('SELECT * FROM pieces_dossier WHERE organisation_id = ? AND actif = 1 ORDER BY ordre, libelle', [orgId]);
  if (l.isEmpty) return piecesStandard;
  Set<String>? ens(Object? v) => v == null || '$v'.isEmpty ? null : '$v'.split(',').toSet();
  return [
    for (final p in l)
      PieceDossier(p['code'] as String, p['libelle'] as String,
          admissions: ens(p['admissions']), cycles: ens(p['cycles']), obligatoire: p['obligatoire'] == 1),
  ];
}

/// Range les pièces cochées : d'abord dans l'ordre de la liste, puis les autres.
String? piecesEnTexte(Iterable<String> cochees, List<PieceDossier> liste) {
  final c = cochees.toSet();
  final r = [...liste.map((p) => p.code).where(c.contains), ...c.where((x) => !liste.any((p) => p.code == x))];
  return r.isEmpty ? null : r.join(',');
}

/// Un parent saisi dans le formulaire : nouveau, ou déjà connu (frère ou sœur inscrit).
class _Parent {
  _Parent({
    this.contactId,
    required this.nom,
    this.telephone,
    required this.lien,
    this.profession,
    this.adresse,
    this.tuteur = false,
    this.payeur = false,
  });

  final String? contactId;
  final String nom;
  final String? telephone;
  final String lien;
  final String? profession;
  final String? adresse;
  bool tuteur;
  bool payeur;
}

/// Inscrire un nouvel élève, ou réinscrire un élève existant (eleveId).
class InscrireScreen extends StatefulWidget {
  const InscrireScreen({super.key, required this.espace, this.eleveId});

  final Espace espace;
  final String? eleveId;

  @override
  State<InscrireScreen> createState() => _InscrireScreenState();
}

class _InscrireScreenState extends State<InscrireScreen> {
  final _form = GlobalKey<FormState>();
  final _recherche = TextEditingController();
  final _nom = TextEditingController();
  final _prenoms = TextEditingController();
  final _lieu = TextEditingController(text: 'Conakry');
  final _nationalite = TextEditingController(text: 'Guinéenne');
  final _quartier = TextEditingController();
  final _matriculeEtat = TextEditingController();
  final _allergies = TextEditingController();
  final _sante = TextEditingController();
  final _ecolePrecedente = TextEditingController();
  String? _sexe;
  DateTime? _naissance;
  DateTime _dateEffective = DateTime.now();
  final DateTime _dateSaisie = DateTime.now();
  // Arrivée en cours d'année : année complète, à partir du mois d'arrivée, ou montant négocié.
  String _arrivee = 'mois';
  final _scolariteNegociee = TextEditingController();
  final _motifArrivee = TextEditingController();
  String _type = 'nouvelle';
  String? _niveau;
  String? _classe;
  final _parents = <_Parent>[];
  final _pieces = <String>{};
  List<PieceDossier> _listePieces = piecesStandard;
  PhotoPrete? _photo;
  bool _envoi = false;
  bool _pret = false;
  bool _choisi = false;
  bool _peutEncaisser = false;

  /// Réinscription : l'inscription précédente (niveau, dernier niveau ?), le
  /// nombre de redoublements déjà faits et la limite de l'école.
  Map<String, Object?>? _precedente;
  int _redoublements = 0;
  int _redoublementsMax = 1;

  Map<String, Object?>? _annee;
  Lignes _classes = [];
  Lignes _frais = [];
  List<Regle> _regles = [];
  bool _cumul = false;
  int _plafond = 100;
  Map<String, Object?>? _existant;
  String? _photoExistante;
  Lignes _trouves = [];
  Lignes _freres = [];
  List<(Map<String, Object?>, Alerte)> _suspects = [];
  Timer? _attente;

  bool get _reinscription => widget.eleveId != null;

  @override
  void initState() {
    super.initState();
    _charger();
    for (final c in [_nom, _prenoms]) {
      c.addListener(_surSaisie);
    }
  }

  @override
  void dispose() {
    _attente?.cancel();
    super.dispose();
  }

  /// Après chaque frappe : on rafraîchit le récapitulatif, puis on cherche les
  /// fiches ressemblantes quand la saisie s'arrête.
  void _surSaisie() {
    setState(() {});
    _attente?.cancel();
    _attente = Timer(const Duration(milliseconds: 500), _verifierDoublons);
  }

  Future<void> _charger() async {
    final o = widget.espace.orgId;
    final annee = await db.getOptional('SELECT * FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1', [o]);
    final sites = await _sitesOuJInscris(o);
    final classes = annee == null
        ? <Map<String, Object?>>[]
        : (await db.getAll('''SELECT c.*, s.code AS code_site, s.nom AS site, n.nom AS niveau, n.ordre AS ordre_niveau, n.cycle AS cycle,
                 (SELECT count(*) FROM inscriptions i WHERE i.classe_id = c.id
                  AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')) AS effectif
               FROM classes c JOIN niveaux n ON n.id = c.niveau_id JOIN sites s ON s.id = c.site_id
               WHERE c.annee_id = ? AND c.fermee = 0 ORDER BY n.ordre, c.nom, s.created_at''', [annee['id']]))
            .where((c) => sites.containsKey(c['site_id']))
            .map((c) => Map<String, Object?>.from(c))
            .toList();
    final frais = annee == null
        ? <Map<String, Object?>>[]
        : (await db.getAll('SELECT * FROM frais WHERE annee_id = ? ORDER BY created_at', [annee['id']]))
            .map((f) => Map<String, Object?>.from(f))
            .toList();
    final org = await db.get(
        'SELECT reductions_cumul, reductions_plafond, arrivee_par_defaut, redoublements_max FROM organisations WHERE id = ?', [o]);
    final regles = [
      for (final r in await db.getAll(
          'SELECT * FROM regles_reduction WHERE organisation_id = ? AND actif = 1 ORDER BY created_at', [o]))
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
    final peutEncaisser = await jAiLeDroitQuelquePart(o, 'encaisser');
    final listePieces = await piecesDe(o);

    Map<String, Object?>? existant;
    Map<String, Object?>? precedente;
    var redoublements = 0;
    String? photo;
    final parents = <_Parent>[];
    if (widget.eleveId != null) {
      existant = await db.getOptional('SELECT * FROM eleves WHERE id = ?', [widget.eleveId]);
      final p = await db.getOptional('''
          SELECT i.id, i.statut, c.niveau_id, n.nom AS niveau, n.ordre, n.niveau_final, a.libelle AS annee
          FROM inscriptions i JOIN classes c ON c.id = i.classe_id JOIN niveaux n ON n.id = c.niveau_id
          JOIN annees_scolaires a ON a.id = i.annee_id
          WHERE i.eleve_id = ? AND i.annee_id IS NOT ? AND i.statut <> 'annule'
          ORDER BY a.debut DESC LIMIT 1''', [widget.eleveId, annee?['id']]);
      precedente = p == null ? null : Map<String, Object?>.from(p);
      redoublements = ((await db.get('SELECT count(*) AS n FROM inscriptions WHERE eleve_id = ? AND redoublant = 1',
          [widget.eleveId]))['n'] as int?) ?? 0;
      photo = (await db.getOptional('SELECT updated_at FROM photos_eleves WHERE eleve_id = ?', [widget.eleveId]))?['updated_at']
          as String?;
      for (final p in await db.getAll(
          '''SELECT ec.*, ct.nom_complet, ct.telephone, ct.profession, ct.adresse FROM eleves_contacts ec
             JOIN contacts ct ON ct.id = ec.contact_id WHERE ec.eleve_id = ? ORDER BY ec.tuteur_principal DESC''',
          [widget.eleveId])) {
        parents.add(_Parent(
          contactId: p['contact_id'] as String,
          nom: '${p['nom_complet']}',
          telephone: p['telephone'] as String?,
          lien: '${p['lien']}',
          profession: p['profession'] as String?,
          adresse: p['adresse'] as String?,
          tuteur: p['tuteur_principal'] == 1,
          payeur: p['responsable_financier'] == 1,
        ));
      }
    }
    if (!mounted) return;
    setState(() {
      _annee = annee;
      _classes = classes;
      _frais = frais;
      _regles = regles;
      _cumul = org['reductions_cumul'] == 1;
      _plafond = (org['reductions_plafond'] as int?) ?? 100;
      _arrivee = org['arrivee_par_defaut'] as String? ?? 'mois';
      _peutEncaisser = peutEncaisser;
      _precedente = precedente;
      _redoublements = redoublements;
      _redoublementsMax = (org['redoublements_max'] as int?) ?? 1;
      // Réinscription : on propose le niveau au-dessus de celui de l'an dernier.
      if (precedente != null && precedente['niveau_final'] != 1) {
        final suivant = classes.where((c) => (c['ordre_niveau'] as int? ?? 0) > (precedente!['ordre'] as int? ?? 0)).firstOrNull;
        if (suivant != null) {
          _niveau = suivant['niveau_id'] as String;
          final dansNiveau = classes.where((x) => x['niveau_id'] == _niveau).toList();
          if (dansNiveau.length == 1) _classe = dansNiveau.first['id'] as String;
        }
      }
      _listePieces = listePieces;
      _existant = existant;
      _photoExistante = photo;
      _parents.addAll(parents);
      if (existant != null) {
        _type = 'reinscription';
        _choisi = true;
        _pieces.addAll('${existant['pieces_dossier'] ?? ''}'.split(',').where((c) => c.isNotEmpty));
      }
      _pret = true;
    });
    _majFratrie();
  }

  // Étape 1 : l'élève est-il déjà connu ? -------------------------------------

  Future<void> _chercher() async {
    final q = _recherche.text.trim();
    if (q.length < 2 || _annee == null) {
      setState(() => _trouves = []);
      return;
    }
    final motif = '%$q%';
    final r = await db.getAll('''
        SELECT e.id, e.nom, e.prenoms, e.matricule, e.date_naissance,
          (SELECT updated_at FROM photos_eleves p WHERE p.eleve_id = e.id) AS photo_maj,
          i.statut, c.nom AS classe
        FROM eleves e
        LEFT JOIN inscriptions i ON i.eleve_id = e.id AND i.annee_id = ?
        LEFT JOIN classes c ON c.id = i.classe_id
        WHERE e.organisation_id = ?
          AND (e.nom || ' ' || e.prenoms LIKE ? OR e.prenoms || ' ' || e.nom LIKE ? OR e.matricule LIKE ?)
        ORDER BY e.nom, e.prenoms LIMIT 8''', [_annee!['id'], widget.espace.orgId, motif, motif, motif]);
    if (!mounted || _recherche.text.trim() != q) return;
    setState(() => _trouves = r.map((e) => Map<String, Object?>.from(e)).toList());
  }

  void _ouvrirFiche(String id) => Navigator.of(context)
      .pushReplacement(MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: widget.espace, eleveId: id)));

  Widget _etapeRecherche(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    final schema = Theme.of(context).colorScheme;
    Widget choix(IconData icone, String titre, String detail, String type) => SizedBox(
          width: 280,
          child: Card(
            margin: EdgeInsets.zero,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() {
                _type = type;
                _choisi = true;
                final q = _recherche.text.trim();
                // Ce qu'on a cherché sert de point de départ au nom.
                if (_nom.text.isEmpty && q.isNotEmpty && !q.contains(RegExp(r'\d'))) {
                  final mots = q.split(RegExp(r'\s+'));
                  _nom.text = mots.first.toUpperCase();
                  _prenoms.text = mots.skip(1).join(' ');
                }
              }),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  CircleAvatar(backgroundColor: schema.primaryContainer, child: Icon(icone, color: schema.primary)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(titre, style: texte.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                      Text(detail, style: texte.bodySmall),
                    ]),
                  ),
                  const Icon(Icons.chevron_right),
                ]),
              ),
            ),
          ),
        );

    return ListView(padding: const EdgeInsets.all(20), children: [
      Text("L'élève est-il déjà connu ?", style: texte.headlineSmall),
      const SizedBox(height: 4),
      const Text('Cherchez-le par son nom ou son matricule avant de créer une fiche : on évite les doublons.'),
      const SizedBox(height: 16),
      TextField(
        controller: _recherche,
        autofocus: true,
        decoration: _champ('Nom, prénom ou matricule').copyWith(prefixIcon: const Icon(Icons.search)),
        onChanged: (_) => _chercher(),
      ),
      const SizedBox(height: 12),
      if (_trouves.isNotEmpty)
        Card(
          margin: EdgeInsets.zero,
          child: Column(children: [
            for (final e in _trouves)
              ListTile(
                leading: PhotoEleve(eleveId: e['id'] as String, nom: _nomEleve(e), version: e['photo_maj'] as String?),
                title: Text(_nomEleve(e)),
                subtitle: Text('${e['matricule']}'
                    '${e['date_naissance'] == null ? '' : ' · né(e) le ${_dateLisible(e['date_naissance'])}'}'
                    ' · ${e['classe'] ?? "pas inscrit cette année"}'),
                trailing: e['statut'] != null
                    ? etatInscription('${e['statut']}')
                    : FilledButton.tonal(
                        onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                            builder: (_) => InscrireScreen(espace: widget.espace, eleveId: e['id'] as String))),
                        child: const Text('Réinscrire'),
                      ),
                onTap: () => _ouvrirFiche(e['id'] as String),
              ),
          ]),
        )
      else if (_recherche.text.trim().length >= 2)
        const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Aucun élève trouvé à ce nom.')),
      const SizedBox(height: 28),
      Text('Sinon, nouvel élève', style: texte.titleMedium),
      const SizedBox(height: 10),
      Wrap(spacing: 12, runSpacing: 12, children: [
        choix(Icons.person_add_alt_1, 'Nouvelle inscription', "Première année dans l'école", 'nouvelle'),
        choix(Icons.swap_horiz, 'Transfert entrant', "Vient d'une autre école", 'transfert'),
        choix(Icons.history_edu, 'Déjà élève avant Scolagrid', 'Compté comme une réinscription', 'reinscription'),
      ]),
    ]);
  }

  // Contacts ----------------------------------------------------------------

  Future<void> _ajouterParent() async {
    final tel = TextEditingController();
    final nom = TextEditingController();
    final profession = TextEditingController();
    final adresse = TextEditingController(text: _quartier.text.trim());
    var lien = _parents.isEmpty ? 'pere' : 'mere';
    Map<String, Object?>? connu;
    final ok = await _formulaire(context, 'Ajouter un contact', (maj) => [
          TextField(
            controller: tel,
            keyboardType: TextInputType.phone,
            decoration: _champ('Téléphone', aide: connu == null ? 'Si ce parent a déjà un enfant ici, il sera retrouvé' : null),
            onChanged: (v) async {
              final n = numeroInternational(v);
              final c = n.length < 12
                  ? null
                  : await db.getOptional('SELECT * FROM contacts WHERE organisation_id = ? AND replace(telephone, \' \', \'\') = ?',
                      [widget.espace.orgId, n]);
              maj(() {
                connu = c;
                if (c != null) {
                  nom.text = '${c['nom_complet']}';
                  profession.text = '${c['profession'] ?? ''}';
                  adresse.text = '${c['adresse'] ?? ''}';
                }
              });
            },
          ),
          if (connu != null)
            Text('Parent déjà connu : ${connu!['nom_complet']}. Les enfants seront reliés (fratrie).',
                style: const TextStyle(color: Couleurs.regle)),
          TextField(
              controller: nom,
              enabled: connu == null,
              textCapitalization: TextCapitalization.words,
              decoration: _champ('Nom complet')),
          _liste('Type de contact', lien, liensFamille, (v) => maj(() => lien = v)),
          TextField(
              controller: profession,
              enabled: connu == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: _champ('Profession', aide: 'Facultatif')),
          TextField(
              controller: adresse,
              enabled: connu == null,
              decoration: _champ('Adresse', aide: 'Facultatif')),
        ]);
    if (!ok || nom.text.trim().length < 2) return;
    String? val(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    setState(() => _parents.add(_Parent(
          contactId: connu?['id'] as String?,
          nom: nom.text.trim(),
          telephone: tel.text.trim().isEmpty ? null : numeroInternational(tel.text),
          lien: lien,
          profession: val(profession),
          adresse: val(adresse),
          tuteur: _parents.every((p) => !p.tuteur),
          payeur: _parents.every((p) => !p.payeur),
        )));
    _majFratrie();
  }

  /// Frères et sœurs déjà inscrits cette année avec le même responsable financier.
  Future<void> _majFratrie() async {
    String? payeur;
    for (final p in _parents) {
      if (p.payeur && p.contactId != null) payeur = p.contactId;
    }
    if (payeur == null || _annee == null) {
      if (_freres.isNotEmpty && mounted) setState(() => _freres = []);
      return;
    }
    final f = await db.getAll('''
        SELECT DISTINCT e.id, e.nom, e.prenoms FROM eleves_contacts ec
        JOIN eleves e ON e.id = ec.eleve_id
        JOIN inscriptions i ON i.eleve_id = e.id AND i.annee_id = ?
          AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')
        WHERE ec.contact_id = ? AND ec.responsable_financier = 1 AND e.id <> ?''',
        [_annee!['id'], payeur, widget.eleveId ?? '']);
    if (mounted) setState(() => _freres = f.map((e) => Map<String, Object?>.from(e)).toList());
  }

  /// Élèves qui ressemblent à celui qu'on va créer (doublons).
  Future<List<(Map<String, Object?>, Alerte)>> _ressemblants() async {
    final tels = _parents.map((p) => p.telephone).whereType<String>().toSet();
    final tous = await db.getAll(
        '''SELECT e.*, (SELECT group_concat(replace(ct.telephone, ' ', ''), ',') FROM eleves_contacts ec
                        JOIN contacts ct ON ct.id = ec.contact_id WHERE ec.eleve_id = e.id) AS telephones
           FROM eleves e WHERE e.organisation_id = ?''',
        [widget.espace.orgId]);
    final r = <(Map<String, Object?>, Alerte)>[];
    for (final e in tous) {
      final memeTuteur = '${e['telephones'] ?? ''}'.split(',').any(tels.contains);
      final a = ressemblance(
        nom: _nom.text,
        prenoms: _prenoms.text,
        naissance: _naissance,
        autreNom: '${e['nom']}',
        autrePrenoms: '${e['prenoms']}',
        autreNaissance: DateTime.tryParse('${e['date_naissance']}'),
        memeTuteurEtQuartier: memeTuteur && _quartier.text.trim().isNotEmpty &&
            nomSimplifie(_quartier.text) == nomSimplifie('${e['quartier'] ?? ''}'),
      );
      if (a != Alerte.aucune) r.add((Map<String, Object?>.from(e), a));
    }
    r.sort((x, y) => y.$2.index.compareTo(x.$2.index));
    return r;
  }

  Future<void> _verifierDoublons() async {
    if (_reinscription || _nom.text.trim().length < 2) {
      if (_suspects.isNotEmpty && mounted) setState(() => _suspects = []);
      return;
    }
    final s = await _ressemblants();
    if (mounted) setState(() => _suspects = s);
  }

  // Classe et frais -----------------------------------------------------------

  Map<String, Object?>? get _classeChoisie {
    for (final c in _classes) {
      if (c['id'] == _classe) return c;
    }
    return null;
  }

  /// Niveaux où j'ai au moins une classe, dans l'ordre.
  Map<String, String> get _niveaux => {for (final c in _classes) c['niveau_id'] as String: '${c['niveau']}'};

  bool get _plusieursSites => _classes.map((c) => c['site_id']).toSet().length > 1;

  /// Frais de l'année pour la classe choisie : inscription (ou réinscription)
  /// et scolarité, avec les réductions prévues (même calcul qu'à la caisse).
  List<({String libelle, String type, int brut, int reduction})> get _lignesFrais {
    final c = _classeChoisie;
    if (c == null) return [];
    final entree = _type == 'reinscription' ? 'reinscription' : 'inscription';
    final applicables =
        reductionsApplicables(regles: _regles, attribuees: const {}, enfantsDuPayeur: _freres.length + 1, cumul: _cumul);
    final siens = fraisRetenus([
      for (final f in _frais)
        if ((f['site_id'] == null || f['site_id'] == c['site_id']) &&
            (f['niveau_id'] == null || f['niveau_id'] == c['niveau_id']) &&
            (f['type_frais'] == entree || f['type_frais'] == 'scolarite' || f['examen'] == 1))
          f,
    ]);
    return [
      for (final f in siens)
          (
            libelle: '${f['libelle']}',
            type: '${f['type_frais']}',
            brut: f['montant_gnf'] as int,
            reduction: reductionSurFrais(
                typeFrais: '${f['type_frais']}',
                total: f['montant_gnf'] as int,
                applicables: applicables,
                cumul: _cumul,
                plafond: _plafond),
          ),
    ];
  }

  int get _totalAnnee => _lignesFrais.fold(0, (s, l) => s + l.brut - l.reduction) - _retraitArrivee;

  DateTime get _rentree => DateTime.tryParse('${_annee?['debut']}') ?? _dateEffective;
  DateTime get _finAnnee => DateTime.tryParse('${_annee?['fin']}') ?? _dateEffective;

  /// L'élève arrive au moins un mois après la rentrée.
  bool get _arriveeTardive => moisEntre(_rentree, _dateEffective) >= 1 && !_dateEffective.isAfter(_finAnnee);

  /// Scolarité de l'année, réductions déduites.
  int get _scolariteNette => _lignesFrais.where((l) => l.type == 'scolarite').fold(0, (s, l) => s + l.brut - l.reduction);

  int get _retraitMois => retraitMoisArrivee(total: _scolariteNette, rentree: _rentree, fin: _finAnnee, arrivee: _dateEffective);

  int? get _scolariteSaisie => int.tryParse(_scolariteNegociee.text.replaceAll(RegExp(r'[^0-9]'), ''));

  /// Ce qu'on retire de la scolarité pour cette arrivée.
  int get _retraitArrivee {
    if (!_arriveeTardive || _scolariteNette == 0) return 0;
    return switch (_arrivee) {
      'mois' => _retraitMois,
      'negocie' => () {
          final saisie = _scolariteSaisie;
          if (saisie == null || saisie >= _scolariteNette) return 0;
          return _scolariteNette - (saisie < 0 ? 0 : saisie);
        }(),
      _ => 0,
    };
  }

  /// Le montant négocié : la direction du site de la classe.
  bool get _peutNegocier {
    final c = _classeChoisie;
    return c != null && widget.espace.gereSite(c['site_id'] as String);
  }

  // Avancement ----------------------------------------------------------------

  bool get _identiteOk =>
      _reinscription || (_nom.text.trim().isNotEmpty && _prenoms.text.trim().isNotEmpty && _sexe != null);
  bool get _contactsOk => _parents.isNotEmpty && _parents.any((p) => p.telephone != null);
  /// Les pièces qui concernent cet élève (admission, cycle de la classe choisie).
  List<PieceDossier> get _piecesConcernees =>
      _listePieces.where((p) => p.concerne(_type, _classeChoisie?['cycle'] as String?)).toList();

  bool get _piecesOk {
    final obligatoires = _piecesConcernees.where((p) => p.obligatoire);
    return obligatoires.isEmpty ? _pieces.isNotEmpty : obligatoires.every((p) => _pieces.contains(p.code));
  }
  bool get _classeOk => _classe != null;
  bool get _fraisOk => _classe != null;

  bool get _modifie => _nom.text.isNotEmpty || _parents.isNotEmpty || _classe != null || _photo != null;

  Future<void> _abandonner() async {
    if (!_reinscription && _modifie && !await _confirmer(context, 'Abandonner cette inscription ? Rien ne sera enregistré.')) {
      return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  // Enregistrement --------------------------------------------------------------

  Future<void> _enregistrer({required bool encaisser}) async {
    final messager = ScaffoldMessenger.of(context);
    void erreur(String m) => messager.showSnackBar(SnackBar(content: Text(m)));
    if (!_form.currentState!.validate()) return erreur('Complétez les champs signalés en rouge.');
    if (_classe == null) return erreur('Choisissez la classe.');
    final arriveeNegociee = _arriveeTardive && _scolariteNette > 0 && _arrivee == 'negocie';
    if (arriveeNegociee) {
      if (!_peutNegocier) return erreur('Seule la direction peut accorder un montant négocié.');
      final saisie = _scolariteSaisie;
      if (saisie == null || saisie > _scolariteNette) {
        return erreur('Indiquez la scolarité négociée (au plus ${gnf(_scolariteNette)}).');
      }
      if (_motifArrivee.text.trim().length < 3) return erreur('Indiquez le motif du montant négocié.');
    }
    if (!_reinscription && _parents.isEmpty) return erreur('Ajoutez au moins un parent ou tuteur.');
    if (!_reinscription && _parents.every((p) => p.telephone == null)) {
      return erreur('Il faut au moins un numéro de téléphone de parent.');
    }
    final classe = _classeChoisie!;
    final o = widget.espace.orgId;

    // Le matricule : sigle, code du site, année, lettre du poste.
    final org = await db.get('SELECT code FROM organisations WHERE id = ?', [o]);
    final poste = await cePoste();
    if (org['code'] == null || classe['code_site'] == null) {
      return erreur("Choisissez d'abord le sigle de l'école et le code du site (Paramètres).");
    }
    if (poste == null) return erreur("Activez d'abord ce poste (accueil) : sa lettre entre dans le matricule.");

    if (!_reinscription) {
      final semblables = await _ressemblants();
      if (!mounted) return;
      if (semblables.isNotEmpty) {
        final suite = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Cet élève existe peut-être déjà'),
            content: SizedBox(
              width: 420,
              child: ListView(shrinkWrap: true, children: [
                for (final (e, a) in semblables.take(6))
                  ListTile(
                    leading: Icon(Icons.warning_amber,
                        color: a == Alerte.forte ? Couleurs.retard : (a == Alerte.moyenne ? Couleurs.attente : Couleurs.attente)),
                    title: Text(_nomEleve(e)),
                    subtitle: Text('${e['matricule']} · né(e) le ${_dateLisible(e['date_naissance'])}'),
                    onTap: () => Navigator.pop(context, e['id'] as String),
                  ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Revoir la saisie')),
              FilledButton(onPressed: () => Navigator.pop(context, ''), child: const Text("C'est un autre élève")),
            ],
          ),
        );
        if (suite == null) return;
        if (suite.isNotEmpty) {
          // C'est le même : on ouvre sa fiche, d'où l'on peut le réinscrire.
          if (mounted) _ouvrirFiche(suite);
          return;
        }
      }
    }

    setState(() => _envoi = true);
    final maintenant = _maintenant();
    String? val(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    final pieces = piecesEnTexte(_pieces, _listePieces) ?? '';
    late String eleveId;
    try {
      await db.writeTransaction((tx) async {
        if (_reinscription) {
          eleveId = widget.eleveId!;
          if (pieces != '${_existant?['pieces_dossier'] ?? ''}') {
            await tx.execute('UPDATE eleves SET pieces_dossier = ?, updated_at = ? WHERE id = ?',
                [pieces.isEmpty ? null : pieces, maintenant, eleveId]);
          }
        } else {
          final prefixe = prefixeMatricule(
              sigle: org['code'] as String,
              codeSite: classe['code_site'] as String,
              annee: '${_annee!['libelle']}',
              lettre: poste['code'] as String);
          final existants = await tx.getAll('SELECT matricule FROM eleves WHERE matricule LIKE ?', ['$prefixe%']);
          final matricule = matriculeSuivant(prefixe, existants.map((m) => m['matricule'] as String));
          eleveId = (await tx.get('SELECT uuid() AS id'))['id'] as String;
          await tx.execute(
              '''INSERT INTO eleves (id, organisation_id, matricule, matricule_etat, site_origine_id, site_id, nom, prenoms,
                   sexe, date_naissance, lieu_naissance, nationalite, quartier, allergies, sante, ecole_precedente,
                   pieces_dossier, date_premiere_inscription, poste_id, cree_par, created_at, updated_at)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
              [
                eleveId, o, matricule, val(_matriculeEtat), classe['site_id'], classe['site_id'],
                _nom.text.trim().toUpperCase(), _prenoms.text.trim(), _sexe,
                _naissance == null ? null : _date(_naissance!), val(_lieu), val(_nationalite), val(_quartier),
                val(_allergies), val(_sante), val(_ecolePrecedente), pieces.isEmpty ? null : pieces,
                _date(_dateEffective), poste['poste_id'], monId, maintenant, maintenant,
              ]);
          for (final p in _parents) {
            var contactId = p.contactId;
            if (contactId == null) {
              contactId = (await tx.get('SELECT uuid() AS id'))['id'] as String;
              await tx.execute(
                  'INSERT INTO contacts (id, organisation_id, nom_complet, telephone, profession, adresse, created_at, updated_at) '
                  'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                  [contactId, o, p.nom, p.telephone, p.profession, p.adresse, maintenant, maintenant]);
            }
            await tx.execute(
                'INSERT INTO eleves_contacts (id, organisation_id, eleve_id, contact_id, lien, tuteur_principal, '
                'responsable_financier, created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?)',
                [o, eleveId, contactId, p.lien, p.tuteur ? 1 : 0, p.payeur ? 1 : 0, maintenant, maintenant]);
          }
        }
        await tx.execute(
            '''INSERT INTO inscriptions (id, organisation_id, eleve_id, annee_id, site_id, classe_id, type_admission,
                 statut, date_effective, arrivee_mode, arrivee_retrait_gnf, arrivee_motif, poste_id, cree_par, created_at, updated_at)
               VALUES (uuid(), ?, ?, ?, ?, ?, ?, 'en_attente', ?, ?, ?, ?, ?, ?, ?, ?)''',
            [
              o, eleveId, _annee!['id'], classe['site_id'], _classe, _type, _date(_dateEffective),
              _arriveeTardive && _scolariteNette > 0 ? _arrivee : null,
              arriveeNegociee ? _retraitArrivee : null,
              arriveeNegociee ? _motifArrivee.text.trim() : null,
              poste['poste_id'], monId, maintenant, maintenant,
            ]);
      });
    } finally {
      if (mounted) setState(() => _envoi = false);
    }
    if (_photo != null) {
      await enregistrerPhoto(orgId: o, eleveId: eleveId, photo: _photo!);
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => encaisser
            ? EncaisserScreen(espace: widget.espace, eleveId: eleveId)
            : FicheEleveScreen(espace: widget.espace, eleveId: eleveId)));
  }

  String? _requis(String? v) => (v == null || v.trim().isEmpty) ? 'Obligatoire' : null;

  // Affichage -----------------------------------------------------------------

  String get _libelleType => switch (_type) {
        'transfert' => 'Transfert entrant',
        'reinscription' => _reinscription ? 'Réinscription' : 'Réinscription (élève d\'avant Scolagrid)',
        _ => 'Nouvelle inscription',
      };

  String get _nomAffiche {
    if (_existant != null) return _nomEleve(_existant!);
    final n = '${_nom.text.trim().toUpperCase()} ${_prenoms.text.trim()}'.trim();
    return n.isEmpty ? 'Nouvel élève' : n;
  }

  Widget _vignette(double taille) {
    if (_photo != null) return CircleAvatar(radius: taille / 2, backgroundImage: MemoryImage(base64Decode(_photo!.base64)));
    if (_existant != null) {
      return PhotoEleve(eleveId: widget.eleveId!, nom: _nomEleve(_existant!), version: _photoExistante, taille: taille);
    }
    return _nom.text.trim().isEmpty
        ? CircleAvatar(
            radius: taille / 2,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Icon(Icons.person_outline, size: taille / 2, color: Theme.of(context).colorScheme.onSurfaceVariant))
        : Initiales('${_nom.text} ${_prenoms.text}', taille: taille);
  }

  /// Zone photo de la section Identité : la vignette et les boutons.
  Widget _zonePhoto() => SizedBox(
        width: 150,
        child: Column(children: [
          _vignette(96),
          const SizedBox(height: 8),
          if (cameraDisponible)
            TextButton.icon(
              onPressed: () async {
                final p = await choisirPhoto(context, camera: true);
                if (p != null) setState(() => _photo = p);
              },
              icon: const Icon(Icons.photo_camera_outlined, size: 18),
              label: const Text('Prendre'),
            ),
          TextButton.icon(
            onPressed: () async {
              final p = await choisirPhoto(context, camera: false);
              if (p != null) setState(() => _photo = p);
            },
            icon: const Icon(Icons.image_outlined, size: 18),
            label: Text(_photo == null ? (cameraDisponible ? 'Galerie' : 'Choisir une photo') : 'Changer'),
          ),
        ]),
      );

  Widget _champDate(String label, DateTime? valeur, Future<void> Function()? choisir, {bool requis = false}) =>
      TextFormField(
        key: ValueKey('$label ${valeur?.toIso8601String()}'),
        initialValue: valeur == null ? '' : _dateLisible(_date(valeur)),
        readOnly: true,
        enabled: choisir != null,
        onTap: choisir,
        validator: requis ? _requis : null,
        decoration: _champ(label).copyWith(
          hintText: 'jj/mm/aaaa',
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
        ),
      );

  Widget _sectionIdentite(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    if (_reinscription) {
      final e = _existant;
      return _Section(
        numero: 1,
        titre: 'Identité',
        complet: true,
        enfants: [
          if (e != null)
            Row(children: [
              _vignette(64),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_nomEleve(e), style: texte.titleMedium),
                  Text('${e['matricule']}', style: styleMono),
                  if (e['date_naissance'] != null) Text('Né(e) le ${_dateLisible(e['date_naissance'])}'),
                  const SizedBox(height: 4),
                  Text("Pour corriger l'identité, ouvrez la fiche de l'élève.", style: texte.bodySmall),
                ]),
              ),
            ]),
          const SizedBox(height: 16),
          _Grille(colonnes: 2, enfants: [
            _champDate("Date d'effet", _dateEffective, () async {
              final d = await _choisirDate(context, _dateEffective,
                  premier: DateTime.now().subtract(const Duration(days: 365)),
                  dernier: DateTime.now().add(const Duration(days: 180)));
              if (d != null) setState(() => _dateEffective = d);
            }),
            _champDate('Date de saisie', _dateSaisie, null),
          ]),
        ],
      );
    }
    final champsPrincipaux = _Grille(colonnes: 2, enfants: [
      TextFormField(
          controller: _nom,
          validator: _requis,
          textCapitalization: TextCapitalization.characters,
          decoration: _champ('Nom')),
      TextFormField(
          controller: _prenoms,
          validator: _requis,
          textCapitalization: TextCapitalization.words,
          decoration: _champ('Prénom(s)')),
      DropdownButtonFormField<String>(
        initialValue: _sexe,
        isExpanded: true,
        decoration: _champ('Sexe'),
        validator: (v) => v == null ? 'Obligatoire' : null,
        items: const [
          DropdownMenuItem(value: 'M', child: Text('Masculin')),
          DropdownMenuItem(value: 'F', child: Text('Féminin')),
        ],
        onChanged: (v) => setState(() => _sexe = v),
      ),
      _champDate('Date de naissance', _naissance, () async {
        final d = await _choisirDate(context, _naissance);
        if (d != null) {
          setState(() => _naissance = d);
          _verifierDoublons();
        }
      }),
    ]);
    return _Section(
      numero: 1,
      titre: 'Identité',
      complet: _identiteOk,
      enfants: [
        LayoutBuilder(
          builder: (context, c) => c.maxWidth < 520
              ? Column(children: [_zonePhoto(), const SizedBox(height: 12), champsPrincipaux])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _zonePhoto(),
                  const SizedBox(width: 16),
                  Expanded(child: champsPrincipaux),
                ]),
        ),
        const SizedBox(height: 12),
        _Grille(colonnes: 4, enfants: [
          TextFormField(controller: _lieu, decoration: _champ('Lieu de naissance')),
          TextFormField(controller: _nationalite, decoration: _champ('Nationalité')),
          TextFormField(controller: _quartier, decoration: _champ('Quartier')),
          TextFormField(controller: _matriculeEtat, decoration: _champ("Matricule d'État", aide: 'Facultatif')),
        ]),
        const SizedBox(height: 12),
        _Grille(colonnes: 2, enfants: [
          _champDate("Date d'effet", _dateEffective, () async {
            final d = await _choisirDate(context, _dateEffective,
                premier: DateTime.now().subtract(const Duration(days: 365)),
                dernier: DateTime.now().add(const Duration(days: 180)));
            if (d != null) setState(() => _dateEffective = d);
          }),
          _champDate('Date de saisie', _dateSaisie, null),
        ]),
        const SizedBox(height: 6),
        Text("L'échéancier des frais partira de la date d'effet.", style: texte.bodySmall),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Santé (facultatif)'),
            children: [
              _Grille(colonnes: 2, enfants: [
                TextFormField(controller: _allergies, decoration: _champ('Allergies', aide: 'Par exemple : arachide')),
                TextFormField(controller: _sante, decoration: _champ('Traitement ou condition', aide: 'Par exemple : asthme')),
              ]),
              const SizedBox(height: 8),
            ],
          ),
        ),
        if (_suspects.isNotEmpty)
          _Bandeau(
            ton: Ton.attente,
            icone: Icons.warning_amber,
            enfants: [
              Text(
                  _suspects.length == 1
                      ? '1 fiche ressemblante : vérifiez que ce n\'est pas le même élève.'
                      : '${_suspects.length} fiches ressemblantes : vérifiez que ce n\'est pas le même élève.',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              for (final (e, _) in _suspects.take(4))
                InkWell(
                  onTap: () => _ouvrirFiche(e['id'] as String),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${_nomEleve(e)} · ${e['matricule']}'
                        '${e['date_naissance'] == null ? '' : ' · né(e) le ${_dateLisible(e['date_naissance'])}'}',
                        style: const TextStyle(decoration: TextDecoration.underline)),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  /// Arrivée en cours d'année : l'école choisit avec la famille ce qu'elle paie.
  Widget _encadreArrivee(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    const mois = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
    Widget option(String cle, String titre, String detail, {Widget? enPlus, bool permis = true}) {
      final choisi = _arrivee == cle;
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: permis ? () => setState(() => _arrivee = cle) : null,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: choisi ? schema.onSurface : schema.outlineVariant, width: choisi ? 1.5 : 1),
          ),
          child: Opacity(
            opacity: permis ? 1 : .5,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(choisi ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18,
                    color: choisi ? schema.onSurface : gris),
                const SizedBox(width: 8),
                Expanded(child: Text(titre, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
                Text(detail, style: styleMono.copyWith(fontSize: 13)),
              ]),
              if (choisi && enPlus != null) ...[const SizedBox(height: 10), enPlus],
            ]),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Couleurs.infoFond, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text("Arrivée en cours d'année (${mois[_dateEffective.month - 1]})",
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text("Ce que la famille paie pour la scolarité, selon l'accord avec l'école.", style: TextStyle(fontSize: 12, color: gris)),
        const SizedBox(height: 10),
        option('complete', 'Année complète', gnf(_scolariteNette)),
        const SizedBox(height: 6),
        option('mois', "À partir du mois d'arrivée", gnf(_scolariteNette - _retraitMois)),
        const SizedBox(height: 6),
        option(
          'negocie',
          'Montant négocié',
          _scolariteSaisie == null ? '…' : gnf(_scolariteSaisie),
          permis: _peutNegocier,
          enPlus: Column(children: [
            TextField(
              controller: _scolariteNegociee,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: _champ('Scolarité à payer', suffixe: 'GNF', aide: 'Au plus ${gnf(_scolariteNette)}'),
            ),
            const SizedBox(height: 8),
            TextField(controller: _motifArrivee, decoration: _champ('Motif', aide: 'Par exemple : accord du directeur')),
          ]),
        ),
        if (!_peutNegocier)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Le montant négocié est réservé à la direction.', style: TextStyle(fontSize: 12, color: gris)),
          ),
      ]),
    );
  }

  Widget _choixRond(String libelle, bool actif, VoidCallback? choisir) => InkWell(
        onTap: choisir,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(actif ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 18, color: actif ? Theme.of(context).colorScheme.primary : null),
            const SizedBox(width: 6),
            Text(libelle),
          ]),
        ),
      );

  Widget _carteContact(_Parent p) {
    final schema = Theme.of(context).colorScheme;
    final texte = Theme.of(context).textTheme;
    final modifiable = !_reinscription;
    return Container(
      width: 250,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: p.tuteur ? schema.primary : schema.outlineVariant, width: p.tuteur ? 1.5 : 1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Initiales(p.nom, taille: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.nom, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
              Text(liensFamille[p.lien] ?? p.lien, style: texte.bodySmall),
            ]),
          ),
          if (modifiable)
            IconButton(
              tooltip: 'Retirer',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () {
                setState(() {
                  _parents.remove(p);
                  if (_parents.isNotEmpty && _parents.every((x) => !x.tuteur)) _parents.first.tuteur = true;
                  if (_parents.isNotEmpty && _parents.every((x) => !x.payeur)) _parents.first.payeur = true;
                });
                _majFratrie();
              },
            ),
        ]),
        const SizedBox(height: 6),
        Text(p.telephone ?? 'Sans téléphone', style: styleMono),
        if (p.profession != null) Text(p.profession!, style: texte.bodySmall),
        if (p.contactId != null && modifiable)
          const Padding(padding: EdgeInsets.only(top: 4), child: Etat('Déjà connu', ton: Ton.info)),
        const Divider(height: 16),
        _choixRond('Tuteur principal', p.tuteur, modifiable
            ? () => setState(() {
                  for (final x in _parents) {
                    x.tuteur = x == p;
                  }
                })
            : null),
        _choixRond('Resp. financier', p.payeur, modifiable
            ? () {
                setState(() {
                  for (final x in _parents) {
                    x.payeur = x == p;
                  }
                });
                _majFratrie();
              }
            : null),
      ]),
    );
  }

  Widget _sectionContacts(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return _Section(
      numero: 2,
      titre: 'Contacts',
      complet: _contactsOk,
      enfants: [
        if (_reinscription)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text('Les contacts se modifient depuis la fiche de l\'élève.', style: Theme.of(context).textTheme.bodySmall),
          ),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (final p in _parents) _carteContact(p),
          if (!_reinscription)
            InkWell(
              onTap: _ajouterParent,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 250,
                height: 150,
                decoration: BoxDecoration(
                  border: Border.all(color: schema.outline.withValues(alpha: .5)),
                  borderRadius: BorderRadius.circular(10),
                  color: schema.surfaceContainerLowest,
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.person_add_alt, color: schema.primary),
                  const SizedBox(height: 6),
                  Text('Ajouter un contact', style: TextStyle(color: schema.primary, fontWeight: FontWeight.w600)),
                  if (_parents.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('Au moins un parent, avec son téléphone', style: TextStyle(fontSize: 12)),
                    ),
                ]),
              ),
            ),
        ]),
        if (_freres.isNotEmpty)
          _Bandeau(
            ton: Ton.info,
            icone: Icons.family_restroom,
            enfants: [
              Text('Fratrie : ${_freres.map(_nomEleve).join(', ')} '
                  '${_freres.length == 1 ? 'est déjà inscrit(e)' : 'sont déjà inscrits'} cette année avec ce responsable financier.'),
              if (reductionsApplicables(regles: _regles, attribuees: const {}, enfantsDuPayeur: _freres.length + 1, cumul: _cumul)
                  .any((r) => r.type == 'fratrie'))
                const Text('La réduction fratrie est comptée dans les frais.')
              else if (_regles.any((r) => r.type == 'fratrie'))
                const Text("Pas encore assez d'enfants pour la réduction fratrie."),
            ],
          ),
      ],
    );
  }

  Widget _sectionPieces(BuildContext context) => _Section(
        numero: 3,
        titre: 'Pièces du dossier',
        complet: _piecesOk,
        sousTitre: '${_piecesConcernees.where((p) => _pieces.contains(p.code)).length}/${_piecesConcernees.length}'
            '${_piecesConcernees.any((p) => p.obligatoire) ? ' · * obligatoire' : ' · facultatives'}',
        enfants: [
          _Grille(colonnes: 3, largeurMin: 180, espacement: 0, enfants: [
            for (final p in _piecesConcernees)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _pieces.contains(p.code),
                title: Text(p.obligatoire ? '${p.libelle} *' : p.libelle),
                onChanged: (v) => setState(() => v == true ? _pieces.add(p.code) : _pieces.remove(p.code)),
              ),
          ]),
          if (_piecesConcernees.any((p) => p.obligatoire && !_pieces.contains(p.code)))
            Text("Une pièce obligatoire manquante n'empêche pas l'inscription : elle sera signalée sur la fiche.",
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      );

  Widget _carteClasse(Map<String, Object?> c) {
    final schema = Theme.of(context).colorScheme;
    final texte = Theme.of(context).textTheme;
    final effectif = (c['effectif'] as int?) ?? 0;
    final capacite = c['capacite'] as int?;
    final reste = capacite == null ? null : capacite - effectif;
    final choisie = c['id'] == _classe;
    final couleur = reste == null
        ? schema.primary
        : (reste <= 0 ? Couleurs.retard : (reste <= capacite! * .1 ? Couleurs.attente : schema.primary));
    return InkWell(
      onTap: () => setState(() => _classe = c['id'] as String),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 190,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: choisie ? schema.primary : schema.outlineVariant, width: choisie ? 2 : 1),
          borderRadius: BorderRadius.circular(10),
          color: choisie ? schema.primaryContainer.withValues(alpha: .35) : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${c['nom']}', style: const TextStyle(fontWeight: FontWeight.w600))),
            if (choisie) Icon(Icons.check_circle, size: 18, color: schema.primary),
          ]),
          if (_plusieursSites) Text('${c['site']}', style: texte.bodySmall),
          const SizedBox(height: 6),
          Text(
            reste == null ? '$effectif élèves' : (reste <= 0 ? 'Complète' : '$reste place${reste > 1 ? 's' : ''}'),
            style: TextStyle(color: couleur, fontSize: 13),
          ),
          if (capacite != null && capacite > 0) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (effectif / capacite).clamp(0, 1).toDouble(),
                minHeight: 6,
                color: couleur,
                backgroundColor: schema.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 4),
            Text('$effectif / $capacite', style: texte.bodySmall),
          ],
        ]),
      ),
    );
  }

  /// Ce que dit l'année précédente : diplômé, redoublement, niveau inférieur.
  List<Widget> _bandeauxParcours(String? niveau) {
    final p = _precedente;
    if (p == null) return const [];
    final ordre = _classes.where((c) => c['niveau_id'] == niveau).firstOrNull?['ordre_niveau'] as int?;
    final ordrePrecedent = p['ordre'] as int? ?? 0;
    return [
      _Bandeau(ton: Ton.info, icone: Icons.history_edu, enfants: [
        Text("L'an dernier (${p['annee']}) : ${p['niveau']}."),
      ]),
      if (p['niveau_final'] == 1 && p['statut'] != 'diplome')
        _Bandeau(ton: Ton.regle, icone: Icons.school_outlined, enfants: [
          Text("${p['niveau']} est le dernier niveau de l'école : si l'élève a terminé, il est diplômé, pas réinscrit."),
          const SizedBox(height: 6),
          OutlinedButton(onPressed: _marquerDiplome, child: const Text('Marquer « Diplômé »')),
        ]),
      if (niveau != null && niveau == p['niveau_id'])
        _Bandeau(
          ton: _redoublements + 1 > _redoublementsMax ? Ton.retard : Ton.attente,
          icone: Icons.replay,
          enfants: [
            Text('Redoublement${_redoublements > 0 ? ' (${_redoublements + 1}e)' : ''} : même niveau que l\'an dernier.'),
            if (_redoublements + 1 > _redoublementsMax)
              Text("Au-delà de la limite de l'école ($_redoublementsMax redoublement${_redoublementsMax > 1 ? 's' : ''}). "
                  "L'inscription reste possible, sur décision de la direction."),
          ],
        )
      else if (ordre != null && ordre < ordrePrecedent)
        const _Bandeau(ton: Ton.attente, icone: Icons.south, enfants: [Text("Niveau inférieur à celui de l'an dernier.")]),
    ];
  }

  Future<void> _marquerDiplome() async {
    final p = _precedente;
    if (p == null) return;
    if (!await _confirmer(context, "Marquer l'élève « Diplômé » pour ${p['annee']} ? Il ne sera pas réinscrit.")) return;
    await db.execute("UPDATE inscriptions SET statut = 'diplome', date_sortie = coalesce(date_sortie, ?), updated_at = ? WHERE id = ?",
        [_date(DateTime.now()), _maintenant(), p['id']]);
    if (mounted) Navigator.of(context).pop();
  }

  Widget _sectionClasse(BuildContext context) {
    final c = _classeChoisie;
    final pleine = c != null && c['capacite'] != null && ((c['effectif'] as int?) ?? 0) >= (c['capacite'] as int);
    final niveau = _niveau ?? c?['niveau_id'] as String?;
    return _Section(
      numero: 4,
      titre: 'Classe',
      complet: _classeOk,
      sousTitre: 'Année ${_annee!['libelle']}',
      enfants: [
        if (_classes.isEmpty)
          const Text("Aucune classe où vous pouvez inscrire. Créez les classes de l'année (Paramètres).")
        else ...[
          SizedBox(
            width: 320,
            child: _liste<String?>('Niveau', niveau, {null: 'Choisir le niveau', ..._niveaux}, (v) => setState(() {
                  _niveau = v;
                  if (_classeChoisie?['niveau_id'] != v) _classe = null;
                  // Une seule classe dans ce niveau : elle est choisie d'office.
                  final dansNiveau = _classes.where((x) => x['niveau_id'] == v).toList();
                  if (dansNiveau.length == 1) _classe = dansNiveau.first['id'] as String;
                })),
          ),
          if (niveau != null) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (final x in _classes)
                if (x['niveau_id'] == niveau) _carteClasse(x),
            ]),
          ],
          ..._bandeauxParcours(niveau),
          if (pleine)
            const _Bandeau(
              ton: Ton.attente,
              icone: Icons.info_outline,
              enfants: [Text("Classe complète — l'inscription reste possible.")],
            ),
          if (_type == 'transfert') ...[
            const SizedBox(height: 12),
            TextFormField(controller: _ecolePrecedente, decoration: _champ('École précédente')),
          ],
        ],
      ],
    );
  }

  Widget _sectionFrais(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    final lignes = _lignesFrais;
    final reduction = lignes.fold(0, (s, l) => s + l.reduction);
    Widget ligne(String libelle, String montant, {TextStyle? style, Color? couleur}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(libelle, style: style)),
            Text(montant, style: styleMono.merge(style).copyWith(color: couleur)),
          ]),
        );
    return _Section(
      numero: 5,
      titre: 'Frais',
      complet: _fraisOk,
      enfants: [
        if (_classe == null)
          const Text('Choisissez la classe pour voir les frais de l\'année.')
        else if (lignes.isEmpty)
          const Text('Aucun frais configuré pour cette classe (Paramètres › Frais).')
        else ...[
          for (final l in lignes) ligne(l.libelle, gnf(l.brut)),
          if (reduction > 0)
            ligne(
                'Réduction (${reductionsApplicables(regles: _regles, attribuees: const {}, enfantsDuPayeur: _freres.length + 1, cumul: _cumul).map((r) => r.libelle).join(', ')})',
                '− ${gnf(reduction)}',
                couleur: Couleurs.regle),
          if (_arriveeTardive && _scolariteNette > 0) ...[
            const SizedBox(height: 8),
            _encadreArrivee(context),
            if (_retraitArrivee > 0)
              ligne("Arrivée en cours d'année", '− ${gnf(_retraitArrivee)}', couleur: Couleurs.regle),
          ],
          const Divider(height: 20),
          ligne('Total année', gnf(_totalAnnee), style: texte.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text("L'élève reste « en attente » jusqu'au paiement des frais d'inscription.", style: texte.bodySmall),
        ],
      ],
    );
  }

  /// Colonne de droite : l'élève, l'avancement, le résumé et les boutons.
  Widget _recapitulatif(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    final c = _classeChoisie;
    String? tuteur, payeur;
    for (final p in _parents) {
      if (p.tuteur) tuteur = p.nom;
      if (p.payeur) payeur = p.nom;
    }
    Widget etape(int n, String titre, bool ok) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [_Pastille(numero: n, complet: ok), const SizedBox(width: 10), Text(titre)]),
        );
    Widget cle(String k, String? v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 110, child: Text(k, style: texte.bodySmall)),
            Expanded(child: Text(v ?? '—', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w500))),
          ]),
        );
    final naissance = _existant != null ? _existant!['date_naissance'] : (_naissance == null ? null : _date(_naissance!));
    final libelleCreer = _reinscription ? 'Réinscrire' : 'Créer';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: _vignette(80)),
          const SizedBox(height: 8),
          Text(_nomAffiche, textAlign: TextAlign.center, style: texte.titleMedium),
          const SizedBox(height: 4),
          Center(child: Etat(_libelleType, ton: Ton.info)),
          const Divider(height: 24),
          etape(1, 'Identité', _identiteOk),
          etape(2, 'Contacts', _contactsOk),
          etape(3, 'Pièces du dossier', _piecesOk),
          etape(4, 'Classe', _classeOk),
          etape(5, 'Frais', _fraisOk),
          const Divider(height: 24),
          cle('Naissance', naissance == null ? null : _dateLisible(naissance)),
          cle('Classe', c == null ? null : '${c['nom']}'),
          cle('Site', c == null ? null : '${c['site']}'),
          cle('Tuteur principal', tuteur),
          cle('Resp. financier', payeur),
          cle('Pièces', '${_piecesConcernees.where((p) => _pieces.contains(p.code)).length}/${_piecesConcernees.length}'),
          if (_freres.isNotEmpty) ...[
            const SizedBox(height: 6),
            Center(child: Etat('Fratrie : ${_freres.length + 1} enfants', ton: Ton.regle, icone: Icons.family_restroom)),
          ],
          const Divider(height: 24),
          Row(children: [
            Expanded(child: Text('Total année', style: texte.titleSmall)),
            Text(_classe == null ? '—' : gnf(_totalAnnee), style: styleMono.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 16),
          if (_peutEncaisser) ...[
            FilledButton.icon(
              onPressed: _envoi || _classes.isEmpty ? null : () => _enregistrer(encaisser: true),
              icon: const Icon(Icons.point_of_sale),
              label: Text(_envoi ? 'Enregistrement…' : '$libelleCreer et encaisser'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _envoi || _classes.isEmpty ? null : () => _enregistrer(encaisser: false),
              child: Text('$libelleCreer, payer plus tard'),
            ),
          ] else
            FilledButton.icon(
              onPressed: _envoi || _classes.isEmpty ? null : () => _enregistrer(encaisser: false),
              icon: const Icon(Icons.how_to_reg),
              label: Text(_envoi ? 'Enregistrement…' : (_reinscription ? 'Réinscrire' : "Créer l'inscription")),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_pret) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_annee == null) {
      return _Page(titre: 'Inscrire un élève', corps: _vide("Il faut d'abord une année scolaire en cours."));
    }
    if (!_choisi) return _Page(titre: 'Inscrire un élève', corps: _etapeRecherche(context));

    final texte = Theme.of(context).textTheme;
    final sections = [
      _sectionIdentite(context),
      _sectionContacts(context),
      _sectionPieces(context),
      _sectionClasse(context),
      _sectionFrais(context),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(_libelleType),
          Text('effet au ${_dateLisible(_date(_dateEffective))}', style: texte.bodySmall),
        ]),
        actions: [
          if (!_reinscription)
            TextButton.icon(
              onPressed: () => setState(() => _choisi = false),
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Recherche'),
            ),
          TextButton.icon(onPressed: _abandonner, icon: const Icon(Icons.close, size: 18), label: const Text('Abandonner')),
          const SizedBox(width: 8),
        ],
      ),
      body: Form(
        key: _form,
        child: LayoutBuilder(builder: (context, c) {
          if (c.maxWidth >= 1000) {
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1240),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 16, 12, 32),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: sections),
                    ),
                  ),
                  SizedBox(
                    width: 300,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 16, 24, 32),
                      child: _recapitulatif(context),
                    ),
                  ),
                ]),
              ),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...sections, _recapitulatif(context)]),
          );
        }),
      ),
    );
  }
}

/// Une section du formulaire : bandeau de titre numéroté, puis son contenu.
class _Section extends StatelessWidget {
  const _Section({required this.numero, required this.titre, required this.complet, required this.enfants, this.sousTitre});

  final int numero;
  final String titre;
  final bool complet;
  final String? sousTitre;
  final List<Widget> enfants;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final texte = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: schema.surfaceContainerHighest.withValues(alpha: .5),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            _Pastille(numero: numero, complet: complet),
            const SizedBox(width: 10),
            Expanded(child: Text(titre, style: texte.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
            if (sousTitre != null) Text(sousTitre!, style: texte.bodySmall),
          ]),
        ),
        Divider(height: 1, color: schema.outlineVariant),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: enfants),
        ),
      ]),
    );
  }
}

/// Rond numéroté ; coché en vert quand la section est complète.
class _Pastille extends StatelessWidget {
  const _Pastille({required this.numero, required this.complet});

  final int numero;
  final bool complet;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: complet ? Couleurs.regle : null,
        border: complet ? null : Border.all(color: schema.outline),
      ),
      child: complet
          ? const Icon(Icons.check, size: 14, color: Colors.white)
          : Text('$numero', style: TextStyle(fontSize: 12, color: schema.onSurfaceVariant)),
    );
  }
}

/// Champs alignés en colonnes, qui passent les uns sous les autres sur petit écran.
class _Grille extends StatelessWidget {
  const _Grille({required this.colonnes, required this.enfants, this.largeurMin = 200, this.espacement = 12});

  final int colonnes;
  final List<Widget> enfants;
  final double largeurMin;
  final double espacement;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        var n = (c.maxWidth / largeurMin).floor();
        if (n > colonnes) n = colonnes;
        if (n < 1) n = 1;
        final largeur = (c.maxWidth - 12 * (n - 1)) / n;
        return Wrap(spacing: 12, runSpacing: espacement, children: [
          for (final e in enfants) SizedBox(width: largeur, child: e),
        ]);
      });
}

/// Message coloré dans une section (fratrie, doublons, classe complète).
class _Bandeau extends StatelessWidget {
  const _Bandeau({required this.ton, required this.icone, required this.enfants});

  final Ton ton;
  final IconData icone;
  final List<Widget> enfants;

  @override
  Widget build(BuildContext context) {
    final (texte, fond) = Etat.couleurs(ton);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: fond, borderRadius: BorderRadius.circular(8)),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: texte),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icone, size: 18, color: texte),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: enfants)),
        ]),
      ),
    );
  }
}
