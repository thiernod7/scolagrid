part of 'configuration.dart';

/// Formulaire d'inscription. D'abord : « l'élève est-il déjà connu ? » (pour
/// éviter les doublons). Ensuite, une colonne de sections numérotées
/// (identité, contacts, pièces, classe, frais) et, à droite, le récapitulatif
/// avec les boutons. Sur téléphone, le récapitulatif passe en bas.

/// Pièces que la famille peut remettre. Toutes facultatives.
const piecesDossier = {
  'acte_naissance': 'Extrait de naissance',
  'photo': "Photo d'identité",
  'vaccination': 'Carnet de vaccination',
  'bulletin': 'Bulletin précédent',
  'certificat_scolarite': 'Certificat de scolarité',
  'residence': 'Certificat de résidence',
};

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
  String _type = 'nouvelle';
  String? _niveau;
  String? _classe;
  final _parents = <_Parent>[];
  final _pieces = <String>{};
  PhotoPrete? _photo;
  bool _envoi = false;
  bool _pret = false;
  bool _choisi = false;
  bool _peutEncaisser = false;

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
        : (await db.getAll('''SELECT c.*, s.code AS code_site, s.nom AS site, n.nom AS niveau, n.ordre AS ordre_niveau,
                 (SELECT count(*) FROM inscriptions i WHERE i.classe_id = c.id
                  AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')) AS effectif
               FROM classes c JOIN niveaux n ON n.id = c.niveau_id JOIN sites s ON s.id = c.site_id
               WHERE c.annee_id = ? ORDER BY n.ordre, c.nom, s.created_at''', [annee['id']]))
            .where((c) => sites.containsKey(c['site_id']))
            .map((c) => Map<String, Object?>.from(c))
            .toList();
    final frais = annee == null
        ? <Map<String, Object?>>[]
        : (await db.getAll('SELECT * FROM frais WHERE annee_id = ? ORDER BY created_at', [annee['id']]))
            .map((f) => Map<String, Object?>.from(f))
            .toList();
    final org = await db.get('SELECT reductions_cumul, reductions_plafond FROM organisations WHERE id = ?', [o]);
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

    Map<String, Object?>? existant;
    String? photo;
    final parents = <_Parent>[];
    if (widget.eleveId != null) {
      existant = await db.getOptional('SELECT * FROM eleves WHERE id = ?', [widget.eleveId]);
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
      _peutEncaisser = peutEncaisser;
      _existant = existant;
      _photoExistante = photo;
      _parents.addAll(parents);
      if (existant != null) {
        _type = 'reinscription';
        _choisi = true;
        _pieces.addAll('${existant['pieces_dossier'] ?? ''}'.split(',').where(piecesDossier.containsKey));
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
  List<({String libelle, int brut, int reduction})> get _lignesFrais {
    final c = _classeChoisie;
    if (c == null) return [];
    final entree = _type == 'reinscription' ? 'reinscription' : 'inscription';
    final applicables =
        reductionsApplicables(regles: _regles, attribuees: const {}, enfantsDuPayeur: _freres.length + 1, cumul: _cumul);
    return [
      for (final f in _frais)
        if ((f['site_id'] == null || f['site_id'] == c['site_id']) &&
            (f['niveau_id'] == null || f['niveau_id'] == c['niveau_id']) &&
            (f['type_frais'] == entree || f['type_frais'] == 'scolarite'))
          (
            libelle: '${f['libelle']}',
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

  int get _totalAnnee => _lignesFrais.fold(0, (s, l) => s + l.brut - l.reduction);

  // Avancement ----------------------------------------------------------------

  bool get _identiteOk =>
      _reinscription || (_nom.text.trim().isNotEmpty && _prenoms.text.trim().isNotEmpty && _sexe != null);
  bool get _contactsOk => _parents.isNotEmpty && _parents.any((p) => p.telephone != null);
  bool get _piecesOk => _pieces.isNotEmpty;
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
      return erreur("Choisissez d'abord le sigle de l'école et le code du site (Configurer l'établissement).");
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
                        color: a == Alerte.forte ? Colors.red : (a == Alerte.moyenne ? Colors.orange : Colors.amber)),
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
    final pieces = piecesDossier.keys.where(_pieces.contains).join(',');
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
                 statut, date_effective, poste_id, cree_par, created_at, updated_at)
               VALUES (uuid(), ?, ?, ?, ?, ?, ?, 'en_attente', ?, ?, ?, ?, ?)''',
            [o, eleveId, _annee!['id'], classe['site_id'], _classe, _type, _date(_dateEffective), poste['poste_id'], monId,
              maintenant, maintenant]);
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
        sousTitre: '${_pieces.length}/${piecesDossier.length} · facultatives',
        enfants: [
          _Grille(colonnes: 3, largeurMin: 180, espacement: 0, enfants: [
            for (final p in piecesDossier.entries)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _pieces.contains(p.key),
                title: Text(p.value),
                onChanged: (v) => setState(() => v == true ? _pieces.add(p.key) : _pieces.remove(p.key)),
              ),
          ]),
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
          const Text("Aucune classe où vous pouvez inscrire. Créez les classes de l'année (Configurer l'établissement).")
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
          const Text('Aucun frais configuré pour cette classe (Configurer l\'établissement › Frais).')
        else ...[
          for (final l in lignes) ligne(l.libelle, gnf(l.brut)),
          if (reduction > 0)
            ligne(
                'Réduction (${reductionsApplicables(regles: _regles, attribuees: const {}, enfantsDuPayeur: _freres.length + 1, cumul: _cumul).map((r) => r.libelle).join(', ')})',
                '− ${gnf(reduction)}',
                couleur: Couleurs.regle),
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
          cle('Pièces', '${_pieces.length}/${piecesDossier.length}'),
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

/// Pièces du dossier sur la fiche de l'élève : celles remises, celles qui
/// manquent, et (avec le droit d'inscrire) la case à cocher quand la famille
/// apporte une pièce plus tard.
class _PiecesDossier extends StatelessWidget {
  const _PiecesDossier({required this.eleve, required this.modifiable});

  final Map<String, Object?> eleve;
  final bool modifiable;

  Set<String> get _fournies =>
      '${eleve['pieces_dossier'] ?? ''}'.split(',').where(piecesDossier.containsKey).toSet();

  Future<void> _basculer(String piece, bool fournie) {
    final p = {..._fournies};
    fournie ? p.add(piece) : p.remove(piece);
    final liste = piecesDossier.keys.where(p.contains).join(',');
    return _modifier('eleves', eleve['id'] as String, {'pieces_dossier': liste.isEmpty ? null : liste});
  }

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    final fournies = _fournies;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Pièces du dossier', style: texte.titleMedium)),
            Etat('${fournies.length}/${piecesDossier.length} remises',
                ton: fournies.length == piecesDossier.length ? Ton.regle : Ton.neutre),
          ]),
          const SizedBox(height: 4),
          _Grille(colonnes: 3, largeurMin: 200, espacement: 0, enfants: [
            for (final p in piecesDossier.entries)
              modifiable
                  ? CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: fournies.contains(p.key),
                      title: Text(p.value),
                      onChanged: (v) => _basculer(p.key, v == true),
                    )
                  : ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(fournies.contains(p.key) ? Icons.check_circle : Icons.radio_button_unchecked,
                          color: fournies.contains(p.key) ? Couleurs.regle : null, size: 20),
                      title: Text(p.value),
                    ),
          ]),
        ]),
      ),
    );
  }
}
