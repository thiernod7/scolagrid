part of 'configuration.dart';

/// Module Inscriptions : élèves, parents et inscriptions.
/// Tout s'écrit dans la base locale (hors ligne) ; le matricule est fabriqué
/// par le poste avec sa lettre, donc unique sans réseau.

const statutsInscription = {
  'en_attente': 'En attente de paiement',
  'actif': 'Actif',
  'suspendu': 'Suspendu',
  'annule': 'Annulé',
  'exclu': 'Exclu',
  'transfert_sortant': 'Parti (transfert)',
  'diplome': 'Diplômé',
};

const typesAdmission = {
  'nouvelle': 'Nouvelle inscription',
  'reinscription': 'Réinscription',
  'transfert': "Transfert (vient d'une autre école)",
};

const liensFamille = {
  'pere': 'Père',
  'mere': 'Mère',
  'tuteur': 'Tuteur',
  'oncle': 'Oncle',
  'tante': 'Tante',
  'grand_parent': 'Grand-parent',
  'frere_soeur': 'Frère ou sœur',
  'autre': 'Autre',
};

/// Les droits de la personne connectée, d'après sa fiche synchronisée sur ce
/// poste. Le serveur vérifie de son côté ; ici on évite d'afficher l'impossible.
Future<bool> jAiLeDroit(String orgId, String? siteId, String droit) async {
  final fiche = await db.getOptional(
      "SELECT id FROM personnel WHERE organisation_id = ? AND user_id = ? AND statut = 'actif'", [orgId, monId]);
  if (fiche == null) return false;
  final aff = await db.getAll('SELECT fonction, site_id FROM affectations WHERE personnel_id = ? AND actif = 1', [fiche['id']]);
  if (aff.any((a) => a['fonction'] == 'fondateur')) return true;
  bool surCeSite(Map<String, Object?> l) => l['site_id'] == null || l['site_id'] == siteId;
  final exceptions = (await db.getAll('SELECT droit, accorde, site_id FROM droits_personnel WHERE personnel_id = ?',
          [fiche['id']]))
      .where(surCeSite)
      .where((d) => d['droit'] == droit);
  final parDefaut = droitsDesFonctions(aff.where(surCeSite).map((a) => a['fonction'] as String)).contains(droit);
  return (parDefaut || exceptions.any((d) => d['accorde'] == 1)) && !exceptions.any((d) => d['accorde'] == 0);
}

/// Sites où je peux inscrire.
Future<Map<String, String>> _sitesOuJInscris(String orgId) async => {
      for (final s in await db.getAll('SELECT id, nom FROM sites WHERE organisation_id = ? ORDER BY created_at', [orgId]))
        if (await jAiLeDroit(orgId, s['id'] as String, 'gerer_inscriptions')) s['id'] as String: s['nom'] as String,
    };

String _nomEleve(Map<String, Object?> e) => '${e['nom']} ${e['prenoms']}';

Future<DateTime?> _choisirDate(BuildContext context, DateTime? initiale, {DateTime? premier, DateTime? dernier}) =>
    showDatePicker(
      context: context,
      initialEntryMode: DatePickerEntryMode.input,
      initialDate: initiale ?? DateTime(DateTime.now().year - 10),
      firstDate: premier ?? DateTime(1990),
      lastDate: dernier ?? DateTime.now(),
      helpText: 'Date (jj/mm/aaaa)',
    );

// Liste des élèves -------------------------------------------------------------

class ElevesScreen extends StatefulWidget {
  const ElevesScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<ElevesScreen> createState() => _ElevesScreenState();
}

class _ElevesScreenState extends State<ElevesScreen> {
  final _recherche = TextEditingController();
  String? _classe;
  bool _peutInscrire = false;

  @override
  void initState() {
    super.initState();
    _sitesOuJInscris(widget.espace.orgId).then((s) {
      if (mounted) setState(() => _peutInscrire = s.isNotEmpty);
    });
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.espace.orgId;
    final texte = _recherche.text.trim();
    final motif = '%${texte.toUpperCase()}%';
    return _Page(
      titre: 'Élèves',
      ajouter: _peutInscrire
          ? () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => InscrireScreen(espace: widget.espace)))
          : null,
      libelleAjouter: 'Inscrire un élève',
      corps: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _recherche,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Nom, matricule, matricule d\'État, parent ou téléphone',
              border: const OutlineInputBorder(),
              suffixIcon: texte.isEmpty
                  ? null
                  : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(_recherche.clear)),
            ),
          ),
        ),
        // Classes de l'année en cours, avec effectif et capacité.
        SizedBox(
          height: 52,
          child: Requete(
            '''SELECT c.id, c.nom, c.capacite,
                 (SELECT count(*) FROM inscriptions i WHERE i.classe_id = c.id
                  AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')) AS effectif
               FROM classes c JOIN annees_scolaires a ON a.id = c.annee_id AND a.en_cours = 1
               JOIN niveaux n ON n.id = c.niveau_id
               WHERE c.organisation_id = ? ORDER BY n.ordre, c.nom''',
            parametres: [o],
            builder: (context, classes) => ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                      label: const Text('Toutes'),
                      selected: _classe == null,
                      onSelected: (_) => setState(() => _classe = null)),
                ),
                for (final c in classes)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('${c['nom']} · ${c['effectif']}${c['capacite'] == null ? '' : '/${c['capacite']}'}'),
                      selected: _classe == c['id'],
                      onSelected: (_) => setState(() => _classe = c['id'] as String),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Requete(
            '''SELECT e.*, i.statut, c.nom AS classe
               FROM eleves e
               LEFT JOIN inscriptions i ON i.eleve_id = e.id
                 AND i.annee_id = (SELECT id FROM annees_scolaires WHERE organisation_id = e.organisation_id AND en_cours = 1)
               LEFT JOIN classes c ON c.id = i.classe_id
               WHERE e.organisation_id = ?
                 AND (? IS NULL OR i.classe_id = ?)
                 AND (? = '' OR upper(e.nom || ' ' || e.prenoms) LIKE ? OR upper(e.prenoms || ' ' || e.nom) LIKE ?
                      OR e.matricule LIKE ? OR upper(coalesce(e.matricule_etat, '')) LIKE ?
                      OR EXISTS (SELECT 1 FROM eleves_contacts ec JOIN contacts ct ON ct.id = ec.contact_id
                                 WHERE ec.eleve_id = e.id AND (upper(ct.nom_complet) LIKE ?
                                   OR replace(coalesce(ct.telephone, ''), ' ', '') LIKE ?)))
               ORDER BY e.nom, e.prenoms
               LIMIT 300''',
            parametres: [o, _classe, _classe, texte, motif, motif, motif, motif, motif, '%${texte.replaceAll(' ', '')}%'],
            builder: (context, eleves) {
              if (eleves.isEmpty) {
                return _vide(texte.isEmpty && _classe == null
                    ? 'Aucun élève pour le moment.'
                    : 'Aucun élève trouvé. Vérifiez l\'orthographe, ou cherchez par matricule ou téléphone du parent.');
              }
              return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 88), children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('${eleves.length}${eleves.length == 300 ? '+' : ''} élève(s)'),
                ),
                for (final e in eleves)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Text('${e['nom']}'.isEmpty ? '?' : '${e['nom']}'[0])),
                      title: Text(_nomEleve(e)),
                      subtitle: Text([
                        e['matricule'],
                        e['classe'] ?? 'Pas inscrit cette année',
                        if (e['statut'] != null) statutsInscription[e['statut']],
                      ].join(' · ')),
                      trailing: (e['allergies'] != null || e['sante'] != null)
                          ? const Tooltip(message: 'Information de santé', child: Icon(Icons.medical_information, color: Colors.red))
                          : null,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => FicheEleveScreen(espace: widget.espace, eleveId: e['id'] as String))),
                    ),
                  ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

// Inscription -----------------------------------------------------------------

/// Un parent saisi dans le formulaire : nouveau, ou déjà connu (frère ou sœur inscrit).
class _Parent {
  _Parent({this.contactId, required this.nom, this.telephone, required this.lien, this.tuteur = false, this.payeur = false});

  final String? contactId;
  final String nom;
  final String? telephone;
  final String lien;
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
  String _type = 'nouvelle';
  String? _classe;
  final _parents = <_Parent>[];
  bool _envoi = false;

  Map<String, Object?>? _annee;
  Lignes _classes = [];
  Map<String, Object?>? _existant;

  bool get _reinscription => widget.eleveId != null;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    final o = widget.espace.orgId;
    final annee = await db.getOptional('SELECT * FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1', [o]);
    final sites = await _sitesOuJInscris(o);
    final classes = annee == null
        ? <Map<String, Object?>>[]
        : (await db.getAll('''SELECT c.*, s.code AS code_site, s.nom AS site,
                 (SELECT count(*) FROM inscriptions i WHERE i.classe_id = c.id
                  AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')) AS effectif
               FROM classes c JOIN niveaux n ON n.id = c.niveau_id JOIN sites s ON s.id = c.site_id
               WHERE c.annee_id = ? ORDER BY s.created_at, n.ordre, c.nom''', [annee['id']]))
            .where((c) => sites.containsKey(c['site_id']))
            .map((c) => Map<String, Object?>.from(c))
            .toList();
    final existant =
        widget.eleveId == null ? null : await db.getOptional('SELECT * FROM eleves WHERE id = ?', [widget.eleveId]);
    if (!mounted) return;
    setState(() {
      _annee = annee;
      _classes = classes;
      _existant = existant;
      if (_reinscription) _type = 'reinscription';
    });
  }

  Future<void> _ajouterParent() async {
    final tel = TextEditingController();
    final nom = TextEditingController();
    var lien = _parents.isEmpty ? 'pere' : 'mere';
    Map<String, Object?>? connu;
    final ok = await _formulaire(context, 'Parent ou tuteur', (maj) => [
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
                if (c != null) nom.text = '${c['nom_complet']}';
              });
            },
          ),
          if (connu != null)
            Text('Parent déjà connu : ${connu!['nom_complet']}. Les enfants seront reliés (fratrie).',
                style: const TextStyle(color: Colors.teal)),
          TextField(
              controller: nom,
              enabled: connu == null,
              textCapitalization: TextCapitalization.words,
              decoration: _champ('Nom complet')),
          _liste('Lien avec l\'élève', lien, liensFamille, (v) => maj(() => lien = v)),
        ]);
    if (!ok || nom.text.trim().length < 2) return;
    setState(() => _parents.add(_Parent(
          contactId: connu?['id'] as String?,
          nom: nom.text.trim(),
          telephone: tel.text.trim().isEmpty ? null : numeroInternational(tel.text),
          lien: lien,
          tuteur: _parents.every((p) => !p.tuteur),
          payeur: _parents.every((p) => !p.payeur),
        )));
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

  Future<void> _enregistrer() async {
    final messager = ScaffoldMessenger.of(context);
    void erreur(String m) => messager.showSnackBar(SnackBar(content: Text(m)));
    if (!_reinscription && !_form.currentState!.validate()) return;
    if (_classe == null) return erreur('Choisissez la classe.');
    if (!_reinscription && _parents.isEmpty) return erreur('Ajoutez au moins un parent ou tuteur.');
    if (!_reinscription && _parents.every((p) => p.telephone == null)) {
      return erreur('Il faut au moins un numéro de téléphone de parent.');
    }
    final classe = _classes.firstWhere((c) => c['id'] == _classe);
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
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: widget.espace, eleveId: suite)));
          return;
        }
      }
    }

    setState(() => _envoi = true);
    final maintenant = _maintenant();
    String? val(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    late String eleveId;
    try {
      await db.writeTransaction((tx) async {
        if (_reinscription) {
          eleveId = widget.eleveId!;
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
                   date_premiere_inscription, poste_id, cree_par, created_at, updated_at)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
              [
                eleveId, o, matricule, val(_matriculeEtat), classe['site_id'], classe['site_id'],
                _nom.text.trim().toUpperCase(), _prenoms.text.trim(), _sexe,
                _naissance == null ? null : _date(_naissance!), val(_lieu), val(_nationalite), val(_quartier),
                val(_allergies), val(_sante), val(_ecolePrecedente), _date(_dateEffective), poste['poste_id'], monId,
                maintenant, maintenant,
              ]);
          for (final p in _parents) {
            var contactId = p.contactId;
            if (contactId == null) {
              contactId = (await tx.get('SELECT uuid() AS id'))['id'] as String;
              await tx.execute(
                  'INSERT INTO contacts (id, organisation_id, nom_complet, telephone, created_at, updated_at) '
                  'VALUES (?, ?, ?, ?, ?, ?)',
                  [contactId, o, p.nom, p.telephone, maintenant, maintenant]);
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
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: widget.espace, eleveId: eleveId)));
  }

  String? _requis(String? v) => (v == null || v.trim().isEmpty) ? 'Obligatoire' : null;

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    if (_annee == null) {
      return _Page(titre: 'Inscrire un élève', corps: _vide("Il faut d'abord une année scolaire en cours."));
    }
    final titre = _reinscription ? 'Réinscrire ${_existant == null ? '' : _nomEleve(_existant!)}' : 'Inscrire un élève';
    return _Page(
      titre: titre,
      corps: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (!_reinscription) ...[
            Text('Identité', style: texte.titleMedium),
            const SizedBox(height: 8),
            TextFormField(
                controller: _nom,
                validator: _requis,
                textCapitalization: TextCapitalization.characters,
                decoration: _champ('Nom')),
            const SizedBox(height: 10),
            TextFormField(
                controller: _prenoms,
                validator: _requis,
                textCapitalization: TextCapitalization.words,
                decoration: _champ('Prénoms')),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'M', label: Text('Garçon')),
                ButtonSegment(value: 'F', label: Text('Fille')),
              ],
              selected: {if (_sexe != null) _sexe!},
              emptySelectionAllowed: true,
              onSelectionChanged: (s) => setState(() => _sexe = s.isEmpty ? null : s.first),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                final d = await _choisirDate(context, _naissance);
                if (d != null) setState(() => _naissance = d);
              },
              icon: const Icon(Icons.cake_outlined),
              label: Text(_naissance == null ? 'Date de naissance' : 'Né(e) le ${_dateLisible(_date(_naissance!))}'),
            ),
            const SizedBox(height: 10),
            TextField(controller: _lieu, decoration: _champ('Lieu de naissance')),
            const SizedBox(height: 10),
            TextField(controller: _nationalite, decoration: _champ('Nationalité')),
            const SizedBox(height: 10),
            TextField(controller: _quartier, decoration: _champ('Quartier de résidence')),
            const SizedBox(height: 10),
            TextField(controller: _matriculeEtat, decoration: _champ("Matricule d'État (si connu)")),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Santé (facultatif)'),
              children: [
                TextField(controller: _allergies, decoration: _champ('Allergies', aide: 'Par exemple : arachide')),
                const SizedBox(height: 10),
                TextField(controller: _sante, decoration: _champ('Traitement ou condition', aide: 'Par exemple : asthme')),
              ],
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: Text('Parents et tuteurs', style: texte.titleMedium)),
              TextButton.icon(onPressed: _ajouterParent, icon: const Icon(Icons.person_add_alt), label: const Text('Ajouter')),
            ]),
            if (_parents.isEmpty) const Text('Ajoutez au moins un parent, avec son téléphone.'),
            for (final p in _parents)
              Card(
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.family_restroom),
                    title: Text(p.nom),
                    subtitle: Text('${liensFamille[p.lien]} · ${p.telephone ?? 'sans téléphone'}'
                        '${p.contactId != null ? ' · déjà connu' : ''}'),
                    trailing: IconButton(
                        icon: const Icon(Icons.close), onPressed: () => setState(() => _parents.remove(p))),
                  ),
                  Wrap(spacing: 8, children: [
                    FilterChip(
                      label: const Text('Tuteur principal'),
                      tooltip: 'Contact pour les convocations et les communications',
                      selected: p.tuteur,
                      onSelected: (_) => setState(() {
                        for (final x in _parents) {
                          x.tuteur = x == p;
                        }
                      }),
                    ),
                    FilterChip(
                      label: const Text('Paie les frais'),
                      tooltip: 'Responsable financier (sert à la réduction fratrie)',
                      selected: p.payeur,
                      onSelected: (_) => setState(() {
                        for (final x in _parents) {
                          x.payeur = x == p;
                        }
                      }),
                    ),
                  ]),
                  const SizedBox(height: 8),
                ]),
              ),
            const SizedBox(height: 16),
          ],
          Text('Scolarité ${_annee!['libelle']}', style: texte.titleMedium),
          const SizedBox(height: 8),
          if (_classes.isEmpty)
            const Text("Aucune classe où vous pouvez inscrire. Créez les classes de l'année (Configurer l'établissement).")
          else
            _liste<String?>('Classe', _classe, {
              for (final c in _classes)
                c['id'] as String: '${c['nom']} · ${c['effectif']}${c['capacite'] == null ? '' : '/${c['capacite']}'} élèves'
                    '${_classes.map((x) => x['site_id']).toSet().length > 1 ? ' · ${c['site']}' : ''}',
            }, (v) => setState(() => _classe = v)),
          const SizedBox(height: 10),
          _liste('Type', _type, {
            for (final t in typesAdmission.entries)
              if (!_reinscription || t.key != 'nouvelle') t.key: t.value,
          }, (v) => setState(() => _type = v)),
          if (_type == 'reinscription' && !_reinscription)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text("Élève déjà scolarisé ici avant Scolagrid : il est compté comme réinscrit.",
                  style: TextStyle(fontStyle: FontStyle.italic)),
            ),
          if (_type == 'transfert') ...[
            const SizedBox(height: 10),
            TextField(controller: _ecolePrecedente, decoration: _champ('École précédente')),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () async {
              final d = await _choisirDate(context, _dateEffective, premier: DateTime.now().subtract(const Duration(days: 365)));
              if (d != null) setState(() => _dateEffective = d);
            },
            icon: const Icon(Icons.event),
            label: Text("Date d'arrivée : ${_dateLisible(_date(_dateEffective))}"),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _envoi || _classes.isEmpty ? null : _enregistrer,
            icon: const Icon(Icons.how_to_reg),
            label: Text(_envoi ? 'Enregistrement…' : (_reinscription ? 'Réinscrire' : "Inscrire l'élève")),
          ),
          const SizedBox(height: 8),
          const Text("L'élève reste « en attente » jusqu'au paiement des frais d'inscription."),
        ]),
      ),
    );
  }
}

// Fiche élève -----------------------------------------------------------------

class FicheEleveScreen extends StatefulWidget {
  const FicheEleveScreen({super.key, required this.espace, required this.eleveId});

  final Espace espace;
  final String eleveId;

  @override
  State<FicheEleveScreen> createState() => _FicheEleveScreenState();
}

class _FicheEleveScreenState extends State<FicheEleveScreen> {
  bool _peutModifier = false;

  @override
  void initState() {
    super.initState();
    db.getOptional('SELECT organisation_id, site_id FROM eleves WHERE id = ?', [widget.eleveId]).then((e) async {
      if (e == null) return;
      final ok = await jAiLeDroit(e['organisation_id'] as String, e['site_id'] as String?, 'gerer_inscriptions');
      if (mounted) setState(() => _peutModifier = ok);
    });
  }

  Future<void> _changerClasse(Map<String, Object?> ins) async {
    final classes = {
      for (final c in await db.getAll(
          '''SELECT c.id, c.nom, c.capacite, (SELECT count(*) FROM inscriptions i WHERE i.classe_id = c.id
               AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')) AS effectif
             FROM classes c JOIN niveaux n ON n.id = c.niveau_id
             WHERE c.annee_id = ? AND c.site_id = ? AND c.id <> ? ORDER BY n.ordre, c.nom''',
          [ins['annee_id'], ins['site_id'], ins['classe_id']]))
        c['id'] as String: '${c['nom']} · ${c['effectif']}${c['capacite'] == null ? '' : '/${c['capacite']}'}',
    };
    if (!mounted) return;
    if (classes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Aucune autre classe sur ce site.')));
      return;
    }
    var choix = classes.keys.first;
    final ok = await _formulaire(context, 'Changer de classe', (maj) => [
          const Text('Le matricule, les paiements et les notes suivent l\'élève. Le changement est historisé.'),
          _liste('Nouvelle classe', choix, classes, (v) => maj(() => choix = v)),
        ]);
    if (ok) await _modifier('inscriptions', ins['id'] as String, {'classe_id': choix});
  }

  Future<void> _sortie(Map<String, Object?> ins) async {
    var statut = 'annule';
    final motif = TextEditingController();
    final ok = await _formulaire(context, "Fin de l'inscription", (maj) => [
          _liste('Motif', statut, const {
            'annule': 'Annulation (place libérée)',
            'transfert_sortant': 'Départ vers une autre école',
            'exclu': 'Exclusion',
            'suspendu': 'Suspension temporaire',
          }, (v) => maj(() => statut = v)),
          TextField(controller: motif, decoration: _champ('Explication', aide: 'Obligatoire')),
          const Text('Rien n\'est effacé : la fiche, les paiements et l\'historique restent.'),
        ]);
    if (!ok || motif.text.trim().length < 3) return;
    await _modifier('inscriptions', ins['id'] as String, {'statut': statut, 'motif': motif.text.trim()});
  }

  Future<void> _reprendre(Map<String, Object?> ins) async {
    if (await _confirmer(context, 'Reprendre cet élève (suspension levée) ?')) {
      await _modifier('inscriptions', ins['id'] as String, {'statut': ins['date_actif'] == null ? 'en_attente' : 'actif'});
    }
  }

  Future<void> _modifierIdentite(Map<String, Object?> e) async {
    TextEditingController c(String col) => TextEditingController(text: e[col] as String? ?? '');
    final champs = {
      'nom': c('nom'),
      'prenoms': c('prenoms'),
      'lieu_naissance': c('lieu_naissance'),
      'nationalite': c('nationalite'),
      'quartier': c('quartier'),
      'matricule_etat': c('matricule_etat'),
      'allergies': c('allergies'),
      'sante': c('sante'),
    };
    const libelles = {
      'nom': 'Nom',
      'prenoms': 'Prénoms',
      'lieu_naissance': 'Lieu de naissance',
      'nationalite': 'Nationalité',
      'quartier': 'Quartier',
      'matricule_etat': "Matricule d'État",
      'allergies': 'Allergies',
      'sante': 'Traitement ou condition',
    };
    var naissance = DateTime.tryParse('${e['date_naissance']}');
    var sexe = e['sexe'] as String?;
    final ok = await _formulaire(context, "Modifier l'identité", (maj) => [
          Text('Matricule ${e['matricule']} : il ne change jamais.'),
          for (final k in champs.keys) TextField(controller: champs[k], decoration: _champ(libelles[k]!)),
          _liste<String?>('Sexe', sexe, const {null: 'Non renseigné', 'M': 'Garçon', 'F': 'Fille'}, (v) => maj(() => sexe = v)),
          OutlinedButton.icon(
            onPressed: () async {
              final d = await _choisirDate(context, naissance);
              if (d != null) maj(() => naissance = d);
            },
            icon: const Icon(Icons.cake_outlined),
            label: Text(naissance == null ? 'Date de naissance' : 'Né(e) le ${_dateLisible(_date(naissance!))}'),
          ),
        ]);
    if (!ok || champs['nom']!.text.trim().isEmpty || champs['prenoms']!.text.trim().isEmpty) return;
    await _modifier('eleves', widget.eleveId, {
      for (final k in champs.keys)
        k: champs[k]!.text.trim().isEmpty ? null : (k == 'nom' ? champs[k]!.text.trim().toUpperCase() : champs[k]!.text.trim()),
      'sexe': sexe,
      'date_naissance': naissance == null ? null : _date(naissance!),
    });
  }

  Future<void> _ajouterParent(Map<String, Object?> e) async {
    final tel = TextEditingController();
    final nom = TextEditingController();
    var lien = 'mere';
    Map<String, Object?>? connu;
    final ok = await _formulaire(context, 'Ajouter un parent', (maj) => [
          TextField(
            controller: tel,
            keyboardType: TextInputType.phone,
            decoration: _champ('Téléphone'),
            onChanged: (v) async {
              final n = numeroInternational(v);
              final c = n.length < 12
                  ? null
                  : await db.getOptional("SELECT * FROM contacts WHERE organisation_id = ? AND replace(telephone, ' ', '') = ?",
                      [e['organisation_id'], n]);
              maj(() {
                connu = c;
                if (c != null) nom.text = '${c['nom_complet']}';
              });
            },
          ),
          TextField(controller: nom, enabled: connu == null, decoration: _champ('Nom complet')),
          _liste("Lien avec l'élève", lien, liensFamille, (v) => maj(() => lien = v)),
        ]);
    if (!ok || nom.text.trim().length < 2) return;
    final maintenant = _maintenant();
    await db.writeTransaction((tx) async {
      var contactId = connu?['id'] as String?;
      if (contactId == null) {
        contactId = (await tx.get('SELECT uuid() AS id'))['id'] as String;
        await tx.execute(
            'INSERT INTO contacts (id, organisation_id, nom_complet, telephone, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
            [contactId, e['organisation_id'], nom.text.trim(),
              tel.text.trim().isEmpty ? null : numeroInternational(tel.text), maintenant, maintenant]);
      }
      final deja = await tx.getOptional('SELECT 1 FROM eleves_contacts WHERE eleve_id = ? AND contact_id = ?', [widget.eleveId, contactId]);
      if (deja != null) return;
      final sansTuteur = await tx.getOptional('SELECT 1 FROM eleves_contacts WHERE eleve_id = ? AND tuteur_principal = 1', [widget.eleveId]) == null;
      final sansPayeur = await tx.getOptional('SELECT 1 FROM eleves_contacts WHERE eleve_id = ? AND responsable_financier = 1', [widget.eleveId]) == null;
      await tx.execute(
          'INSERT INTO eleves_contacts (id, organisation_id, eleve_id, contact_id, lien, tuteur_principal, responsable_financier, '
          'created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?)',
          [e['organisation_id'], widget.eleveId, contactId, lien, sansTuteur ? 1 : 0, sansPayeur ? 1 : 0, maintenant, maintenant]);
    });
  }

  /// Un seul tuteur principal et un seul payeur : on retire d'abord l'ancien.
  Future<void> _designer(String lienId, String colonne) => db.writeTransaction((tx) async {
        final m = _maintenant();
        await tx.execute('UPDATE eleves_contacts SET $colonne = 0, updated_at = ? WHERE eleve_id = ? AND $colonne = 1',
            [m, widget.eleveId]);
        await tx.execute('UPDATE eleves_contacts SET $colonne = 1, updated_at = ? WHERE id = ?', [m, lienId]);
      });

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    return Requete('SELECT e.*, s.nom AS site FROM eleves e LEFT JOIN sites s ON s.id = e.site_id WHERE e.id = ?',
        parametres: [widget.eleveId], builder: (context, l) {
      if (l.isEmpty) return const Scaffold(body: Center(child: Text('Élève introuvable sur ce poste.')));
      final e = l.first;
      return _Page(
        titre: _nomEleve(e),
        corps: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: Text('${e['matricule']}', style: texte.titleMedium),
              subtitle: Text([
                if (e['matricule_etat'] != null) "Matricule d'État : ${e['matricule_etat']}",
                [
                  e['sexe'] == 'M' ? 'Garçon' : (e['sexe'] == 'F' ? 'Fille' : null),
                  if (e['date_naissance'] != null) 'né(e) le ${_dateLisible(e['date_naissance'])}',
                  if (e['lieu_naissance'] != null) 'à ${e['lieu_naissance']}',
                ].whereType<String>().join(' '),
                [e['nationalite'], e['quartier'], e['site']].whereType<String>().join(' · '),
                'Première inscription le ${_dateLisible(e['date_premiere_inscription'])}',
              ].where((t) => t.isNotEmpty).join('\n')),
              isThreeLine: true,
              trailing: _peutModifier
                  ? IconButton(tooltip: "Modifier l'identité", icon: const Icon(Icons.edit_outlined), onPressed: () => _modifierIdentite(e))
                  : null,
            ),
          ),
          if (e['allergies'] != null || e['sante'] != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.medical_information),
                title: const Text('Santé'),
                subtitle: Text([
                  if (e['allergies'] != null) 'Allergies : ${e['allergies']}',
                  if (e['sante'] != null) '${e['sante']}',
                ].join('\n')),
              ),
            ),
          const SizedBox(height: 8),
          // Inscription de l'année en cours.
          Requete(
            '''SELECT i.*, c.nom AS classe, a.libelle AS annee FROM annees_scolaires a
               LEFT JOIN inscriptions i ON i.annee_id = a.id AND i.eleve_id = ?
               LEFT JOIN classes c ON c.id = i.classe_id
               WHERE a.organisation_id = ? AND a.en_cours = 1''',
            parametres: [widget.eleveId, e['organisation_id']],
            builder: (context, r) {
              if (r.isEmpty) return const SizedBox.shrink();
              final ins = r.first;
              if (ins['id'] == null) {
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.school_outlined),
                    title: Text('Pas inscrit en ${ins['annee']}'),
                    trailing: _peutModifier
                        ? FilledButton(
                            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => InscrireScreen(espace: widget.espace, eleveId: widget.eleveId))),
                            child: const Text('Réinscrire'))
                        : null,
                  ),
                );
              }
              final sorti = const {'annule', 'exclu', 'transfert_sortant', 'diplome'}.contains(ins['statut']);
              return Card(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ListTile(
                    leading: Icon(Icons.school_outlined,
                        color: ins['statut'] == 'actif' ? Colors.teal : (sorti ? Colors.grey : Colors.orange)),
                    title: Text('${ins['classe']} · ${ins['annee']}'),
                    subtitle: Text([
                      statutsInscription[ins['statut']],
                      typesAdmission[ins['type_admission']],
                      'arrivé le ${_dateLisible(ins['date_effective'])}',
                      if (ins['motif'] != null) 'Motif : ${ins['motif']}',
                    ].join('\n')),
                    isThreeLine: true,
                  ),
                  if (_peutModifier)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: Wrap(spacing: 8, children: [
                        if (!sorti && ins['statut'] != 'suspendu')
                          OutlinedButton.icon(
                              onPressed: () => _changerClasse(ins),
                              icon: const Icon(Icons.swap_horiz),
                              label: const Text('Changer de classe')),
                        if (!sorti && ins['statut'] != 'suspendu')
                          OutlinedButton.icon(
                              onPressed: () => _sortie(ins),
                              icon: const Icon(Icons.logout),
                              label: const Text("Fin d'inscription")),
                        if (ins['statut'] == 'suspendu')
                          OutlinedButton.icon(
                              onPressed: () => _reprendre(ins), icon: const Icon(Icons.undo), label: const Text('Reprendre')),
                      ]),
                    ),
                ]),
              );
            },
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text('Parents et tuteurs', style: texte.titleMedium)),
            if (_peutModifier)
              TextButton.icon(
                  onPressed: () => _ajouterParent(e), icon: const Icon(Icons.person_add_alt), label: const Text('Ajouter')),
          ]),
          Requete(
            '''SELECT ec.*, ct.nom_complet, ct.telephone,
                 (SELECT count(*) FROM eleves_contacts x WHERE x.contact_id = ct.id AND x.responsable_financier = 1) AS a_charge
               FROM eleves_contacts ec JOIN contacts ct ON ct.id = ec.contact_id
               WHERE ec.eleve_id = ? ORDER BY ec.tuteur_principal DESC, ec.responsable_financier DESC''',
            parametres: [widget.eleveId],
            builder: (context, parents) => Column(children: [
              if (parents.isEmpty) const Text('Contacts non visibles sur ce poste, ou aucun parent enregistré.'),
              for (final p in parents)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.family_restroom),
                    title: Text('${p['nom_complet']} · ${liensFamille[p['lien']] ?? ''}'),
                    subtitle: Text([
                      p['telephone'] ?? 'sans téléphone',
                      if (p['tuteur_principal'] == 1) 'Tuteur principal',
                      if (p['responsable_financier'] == 1)
                        'Paie les frais${(p['a_charge'] as int? ?? 0) > 1 ? ' de ${p['a_charge']} enfants' : ''}',
                    ].join(' · ')),
                    trailing: _peutModifier
                        ? PopupMenuButton<String>(
                            onSelected: (v) => v == 'retirer'
                                ? _supprimer('eleves_contacts', p['id'] as String)
                                : _designer(p['id'] as String, v),
                            itemBuilder: (_) => [
                              if (p['tuteur_principal'] != 1)
                                const PopupMenuItem(value: 'tuteur_principal', child: Text('Faire tuteur principal')),
                              if (p['responsable_financier'] != 1)
                                const PopupMenuItem(value: 'responsable_financier', child: Text('Désigner comme payeur')),
                              if (p['tuteur_principal'] != 1 && p['responsable_financier'] != 1)
                                const PopupMenuItem(value: 'retirer', child: Text('Retirer de la fiche')),
                            ],
                          )
                        : null,
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          Text('Historique', style: texte.titleMedium),
          Requete(
            '''SELECT h.*, cd.nom AS de_classe, cv.nom AS vers_classe, p.nom_complet AS auteur
               FROM historique_eleves h
               LEFT JOIN classes cd ON cd.id = h.de_classe_id
               LEFT JOIN classes cv ON cv.id = h.vers_classe_id
               LEFT JOIN personnel p ON p.user_id = h.par AND p.organisation_id = h.organisation_id
               WHERE h.eleve_id = ? ORDER BY h.quand DESC''',
            parametres: [widget.eleveId],
            builder: (context, h) => Column(children: [
              if (h.isEmpty) const Text("L'historique apparaît après la synchronisation."),
              for (final x in h)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history),
                  title: Text(switch (x['evenement']) {
                    'inscription' => 'Inscription en ${x['vers_classe'] ?? ''}',
                    'mutation' => 'Changement de classe : ${x['de_classe'] ?? '?'} → ${x['vers_classe'] ?? '?'}',
                    _ => '${statutsInscription[x['ancien_statut']] ?? x['ancien_statut']} → '
                        '${statutsInscription[x['nouveau_statut']] ?? x['nouveau_statut']}',
                  }),
                  subtitle: Text('${_dateLisible(x['quand'])}${x['auteur'] != null ? ' · ${x['auteur']}' : ''}'
                      '${x['motif'] != null ? ' · ${x['motif']}' : ''}'),
                ),
            ]),
          ),
        ]),
      );
    });
  }
}
