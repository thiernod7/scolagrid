part of 'configuration.dart';

/// Caisse : encaisser (un reçu, un ou plusieurs élèves), imprimer le reçu,
/// journal du jour. Tout fonctionne hors ligne ; le numéro de reçu porte la
/// lettre du poste.

Future<bool> jAiLeDroitQuelquePart(String orgId, String droit) async {
  if (await jAiLeDroit(orgId, null, droit)) return true;
  for (final s in await db.getAll('SELECT id FROM sites WHERE organisation_id = ?', [orgId])) {
    if (await jAiLeDroit(orgId, s['id'] as String, droit)) return true;
  }
  return false;
}

/// Ce que doit un élève pour son inscription : frais applicables, échéances,
/// déjà payé. Calculé sur le poste, d'après les données synchronisées.
Future<List<FraisDu>> situationInscription(String inscriptionId) async {
  final ins = await db.getOptional(
      'SELECT i.*, c.niveau_id FROM inscriptions i JOIN classes c ON c.id = i.classe_id WHERE i.id = ?', [inscriptionId]);
  if (ins == null) return [];
  final typeEntree = ins['type_admission'] == 'reinscription' ? 'reinscription' : 'inscription';
  final frais = await db.getAll('''
      SELECT f.*,
        (SELECT coalesce(sum(l.montant_gnf), 0) FROM lignes_encaissement l
         JOIN encaissements e ON e.id = l.encaissement_id AND e.statut = 'valide' AND e.confirmation <> 'rejete'
         WHERE l.inscription_id = ? AND l.frais_id = f.id) AS paye
      FROM frais f
      WHERE f.annee_id = ? AND (f.site_id IS NULL OR f.site_id = ?) AND (f.niveau_id IS NULL OR f.niveau_id = ?)
        AND (f.type_frais IN (?, 'scolarite')
             OR (f.type_frais = 'optionnel' AND EXISTS (SELECT 1 FROM souscriptions s
                 WHERE s.inscription_id = ? AND s.frais_id = f.id AND s.actif = 1)))
      ORDER BY f.created_at''',
      [inscriptionId, ins['annee_id'], ins['site_id'], ins['niveau_id'], typeEntree, inscriptionId]);
  final arrivee = DateTime.tryParse('${ins['date_effective']}') ?? DateTime.now();
  return [
    for (final f in frais)
      situationFrais(
        id: f['id'] as String,
        libelle: f['libelle'] as String,
        type: f['type_frais'] as String? ?? 'optionnel',
        total: f['montant_gnf'] as int,
        echeances: [
          for (final e in await db.getAll('SELECT * FROM echeances WHERE frais_id = ? ORDER BY ordre', [f['id']]))
            (libelle: e['libelle'] as String, montant: e['montant_gnf'] as int, dateLimite: DateTime.parse('${e['date_limite']}')),
        ],
        arrivee: arrivee,
        dejaPaye: f['paye'] as int? ?? 0,
      ),
  ];
}

/// Résumé financier sur la fiche de l'élève.
class SituationFinanciere extends StatelessWidget {
  const SituationFinanciere({super.key, required this.espace, required this.inscriptionId, required this.eleveId});

  final Espace espace;
  final String inscriptionId;
  final String eleveId;

  @override
  Widget build(BuildContext context) => Requete(
        // Se recalcule à chaque paiement, souscription ou frais modifié.
        '''SELECT (SELECT count(*) FROM lignes_encaissement WHERE inscription_id = ?) AS n,
                  (SELECT count(*) FROM encaissements WHERE statut = 'annule') AS a,
                  (SELECT count(*) FROM souscriptions WHERE inscription_id = ?) AS s,
                  (SELECT max(updated_at) FROM frais) AS f''',
        parametres: [inscriptionId, inscriptionId],
        builder: (context, _) => FutureBuilder(
          future: situationInscription(inscriptionId),
          builder: (context, s) {
            if (!s.hasData) return const SizedBox(height: 40);
            final frais = s.data!;
            final total = frais.fold(0, (x, f) => x + f.total);
            final paye = frais.fold(0, (x, f) => x + f.paye);
            final aujourdhui = DateTime.now();
            final retards = [for (final f in frais) ...f.echeances.where((e) => e.enRetard(aujourdhui))];
            return Card(
              child: ExpansionTile(
                leading: Icon(Icons.account_balance_wallet_outlined, color: retards.isNotEmpty ? Colors.orange : null),
                title: Text(total == 0 ? 'Aucun frais configuré pour cette classe' : 'Reste à payer : ${gnf(total - paye)}'),
                subtitle: Text('Payé ${gnf(paye)} sur ${gnf(total)}'
                    '${retards.isNotEmpty ? ' · ${retards.length} échéance(s) en retard' : ''}'),
                children: [
                  for (final f in frais) ...[
                    ListTile(
                      dense: true,
                      title: Text('${f.libelle} : ${gnf(f.total)}'),
                      trailing: Text(f.reste <= 0 ? 'Payé' : 'Reste ${gnf(f.reste)}'),
                    ),
                    if (f.echeances.length > 1)
                      for (final e in f.echeances)
                        Padding(
                          padding: const EdgeInsets.only(left: 32, right: 16, bottom: 2),
                          child: Row(children: [
                            Expanded(child: Text('${e.libelle} · avant le ${_dateLisible(_date(e.dateLimite))}')),
                            Text(e.soldee ? 'Payée' : (e.enRetard(aujourdhui) ? 'En retard : ${gnf(e.reste)}' : gnf(e.reste)),
                                style: TextStyle(color: e.enRetard(aujourdhui) ? Colors.orange.shade800 : null)),
                          ]),
                        ),
                  ],
                  _Souscrire(espace: espace, inscriptionId: inscriptionId),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => EncaisserScreen(espace: espace, eleveId: eleveId))),
                      icon: const Icon(Icons.point_of_sale),
                      label: const Text('Encaisser'),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
}

/// Frais optionnels (cantine, transport…) que l'élève peut prendre.
class _Souscrire extends StatelessWidget {
  const _Souscrire({required this.espace, required this.inscriptionId});

  final Espace espace;
  final String inscriptionId;

  @override
  Widget build(BuildContext context) => Requete(
        '''SELECT f.id, f.libelle, f.montant_gnf,
             (SELECT s.id FROM souscriptions s WHERE s.inscription_id = i.id AND s.frais_id = f.id) AS souscription,
             (SELECT s.actif FROM souscriptions s WHERE s.inscription_id = i.id AND s.frais_id = f.id) AS actif
           FROM inscriptions i JOIN classes c ON c.id = i.classe_id
           JOIN frais f ON f.annee_id = i.annee_id AND f.type_frais = 'optionnel'
             AND (f.site_id IS NULL OR f.site_id = i.site_id) AND (f.niveau_id IS NULL OR f.niveau_id = c.niveau_id)
           WHERE i.id = ?''',
        parametres: [inscriptionId],
        builder: (context, options) => options.isEmpty
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(spacing: 8, children: [
                  for (final o in options)
                    FilterChip(
                      label: Text('${o['libelle']} (${gnf(o['montant_gnf'])})'),
                      selected: o['actif'] == 1,
                      onSelected: (v) async {
                        if (o['souscription'] != null) {
                          await _modifier('souscriptions', o['souscription'] as String, {'actif': v ? 1 : 0});
                        } else {
                          await _inserer('souscriptions', {
                            'organisation_id': espace.orgId,
                            'inscription_id': inscriptionId,
                            'frais_id': o['id'],
                            'actif': 1,
                          });
                        }
                      },
                    ),
                ]),
              ),
      );
}

// Encaisser ---------------------------------------------------------------------

class _LigneEleve {
  _LigneEleve(this.eleve, this.inscription, this.frais)
      : montants = {for (final f in frais) f.id: TextEditingController()},
        global = TextEditingController();

  final Map<String, Object?> eleve;
  final Map<String, Object?> inscription;
  final List<FraisDu> frais;
  final Map<String, TextEditingController> montants;
  final TextEditingController global;

  int montant(String fraisId) => int.tryParse(montants[fraisId]!.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  int get total => frais.fold(0, (s, f) => s + montant(f.id));
}

class EncaisserScreen extends StatefulWidget {
  const EncaisserScreen({super.key, required this.espace, this.eleveId});

  final Espace espace;
  final String? eleveId;

  @override
  State<EncaisserScreen> createState() => _EncaisserScreenState();
}

class _EncaisserScreenState extends State<EncaisserScreen> {
  final _payeur = TextEditingController();
  final _reference = TextEditingController();
  final _carnet = TextEditingController();
  final _feuille = TextEditingController();
  String _mode = 'especes';
  DateTime _jourPaiement = DateTime.now();
  final _lignes = <_LigneEleve>[];
  List<Map<String, Object?>> _freres = [];
  bool _envoi = false;

  @override
  void initState() {
    super.initState();
    _preparer();
  }

  Future<void> _preparer() async {
    // Le carnet en cours et la feuille suivante, d'après le dernier reçu de ce poste.
    final poste = await cePoste();
    final dernier = poste == null
        ? null
        : await db.getOptional(
            "SELECT carnet, feuille FROM encaissements WHERE poste_id = ? AND feuille IS NOT NULL ORDER BY created_at DESC LIMIT 1",
            [poste['poste_id']]);
    if (dernier != null) {
      _carnet.text = dernier['carnet'] as String? ?? '';
      _feuille.text = feuilleSuivante(dernier['feuille'] as String?) ?? '';
    }
    if (widget.eleveId != null) await _ajouterEleve(widget.eleveId!);
    if (mounted) setState(() {});
  }

  Future<void> _ajouterEleve(String eleveId) async {
    if (_lignes.any((l) => l.eleve['id'] == eleveId)) return;
    final eleve = await db.getOptional('SELECT * FROM eleves WHERE id = ?', [eleveId]);
    final ins = await db.getOptional(
        '''SELECT i.*, c.nom AS classe FROM inscriptions i JOIN classes c ON c.id = i.classe_id
           JOIN annees_scolaires a ON a.id = i.annee_id AND a.en_cours = 1
           WHERE i.eleve_id = ? AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')''',
        [eleveId]);
    if (!mounted) return;
    if (eleve == null || ins == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Cet élève n'est pas inscrit cette année.")));
      return;
    }
    final frais = await situationInscription(ins['id'] as String);
    // Le payeur habituel : le responsable financier de l'élève.
    final rf = await db.getOptional(
        '''SELECT ct.id, ct.nom_complet FROM eleves_contacts ec JOIN contacts ct ON ct.id = ec.contact_id
           WHERE ec.eleve_id = ? AND ec.responsable_financier = 1''',
        [eleveId]);
    if (_payeur.text.isEmpty && rf != null) _payeur.text = '${rf['nom_complet']}';
    // Frères et sœurs payés par la même personne : proposés en un clic.
    final freres = rf == null
        ? <Map<String, Object?>>[]
        : (await db.getAll(
                '''SELECT e.id, e.nom, e.prenoms FROM eleves_contacts ec JOIN eleves e ON e.id = ec.eleve_id
                   WHERE ec.contact_id = ? AND ec.responsable_financier = 1 AND e.id <> ?''',
                [rf['id'], eleveId]))
            .map((x) => Map<String, Object?>.from(x))
            .toList();
    setState(() {
      _lignes.add(_LigneEleve(Map.of(eleve), Map.of(ins), frais));
      _freres = [
        ..._freres,
        ...freres.where((f) => !_freres.any((x) => x['id'] == f['id'])),
      ].where((f) => !_lignes.any((l) => l.eleve['id'] == f['id'])).toList();
    });
  }

  Future<void> _chercherEleve() async {
    final choix = await showDialog<String>(context: context, builder: (_) => _ChoisirEleve(orgId: widget.espace.orgId));
    if (choix != null) await _ajouterEleve(choix);
  }

  int get _total => _lignes.fold(0, (s, l) => s + l.total);

  Future<void> _valider() async {
    final messager = ScaffoldMessenger.of(context);
    void erreur(String m) => messager.showSnackBar(SnackBar(content: Text(m)));
    if (_lignes.isEmpty) return erreur('Ajoutez au moins un élève.');
    if (_payeur.text.trim().length < 2) return erreur('Indiquez le nom de la personne qui paie.');
    if (_mode != 'especes' && _reference.text.trim().isEmpty) {
      return erreur('Saisissez la référence (n° de transaction, de chèque ou de virement).');
    }
    for (final l in _lignes) {
      for (final f in l.frais) {
        if (l.montant(f.id) > f.reste) {
          return erreur('${_nomEleve(l.eleve)} : ${f.libelle} dépasse le reste dû (${gnf(f.reste)}).');
        }
      }
    }
    if (_total <= 0) return erreur('Aucun montant saisi.');
    final o = widget.espace.orgId;
    final poste = await cePoste();
    if (poste == null) return erreur("Activez d'abord ce poste (accueil) : sa lettre entre dans le numéro du reçu.");
    final site = _lignes.first.inscription['site_id'] as String;
    final infos = await db.get(
        '''SELECT o.code AS sigle, s.code AS code_site, a.libelle AS annee, a.id AS annee_id
           FROM organisations o, sites s, annees_scolaires a
           WHERE o.id = ? AND s.id = ? AND a.organisation_id = o.id AND a.en_cours = 1''',
        [o, site]);
    if (infos['sigle'] == null || infos['code_site'] == null) {
      return erreur("Choisissez d'abord le sigle de l'école et le code du site (Configurer l'établissement).");
    }
    final carnet = _carnet.text.trim().isEmpty ? null : _carnet.text.trim();
    final feuille = _feuille.text.trim().isEmpty ? null : _feuille.text.trim();
    if (feuille != null &&
        await db.getOptional('SELECT 1 FROM encaissements WHERE carnet IS ? AND feuille = ?', [carnet, feuille]) != null) {
      return erreur('La feuille $feuille de ce carnet a déjà été saisie.');
    }
    if (!mounted) return;
    if (!await _confirmer(context, 'Encaisser ${gnf(_total)} (${modesPaiement[_mode]}) de ${_payeur.text.trim()} ?')) return;

    setState(() => _envoi = true);
    late String id;
    try {
      final maintenant = _maintenant();
      await db.writeTransaction((tx) async {
        final numero = numeroRecuSuivant(
          sigle: infos['sigle'] as String,
          codeSite: infos['code_site'] as String,
          annee: infos['annee'] as String,
          lettre: poste['code'] as String,
          existants: (await tx.getAll('SELECT numero FROM encaissements WHERE poste_id = ?', [poste['poste_id']]))
              .map((r) => r['numero'] as String),
        );
        id = (await tx.get('SELECT uuid() AS id'))['id'] as String;
        await tx.execute(
            '''INSERT INTO encaissements (id, organisation_id, site_id, annee_id, numero, carnet, feuille, payeur_nom, mode,
                 reference, date_effective, total_gnf, confirmation, statut, impressions, poste_id, encaisse_par, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'valide', 0, ?, ?, ?, ?)''',
            [
              id, o, site, infos['annee_id'], numero, carnet, feuille, _payeur.text.trim(), _mode,
              _reference.text.trim().isEmpty ? null : _reference.text.trim(), _date(_jourPaiement), _total,
              _mode == 'cheque' || _mode == 'virement' ? 'en_attente' : 'confirme', poste['poste_id'], monId,
              maintenant, maintenant,
            ]);
        for (final l in _lignes) {
          for (final f in l.frais) {
            final m = l.montant(f.id);
            if (m <= 0) continue;
            await tx.execute(
                '''INSERT INTO lignes_encaissement (id, organisation_id, encaissement_id, inscription_id, eleve_id, frais_id,
                     montant_gnf, created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?)''',
                [o, id, l.inscription['id'], l.eleve['id'], f.id, m, maintenant, maintenant]);
          }
        }
      });
    } finally {
      if (mounted) setState(() => _envoi = false);
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => RecuScreen(espace: widget.espace, encaissementId: id)));
  }

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    return _Page(
      titre: 'Encaisser',
      corps: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _payeur, textCapitalization: TextCapitalization.words, decoration: _champ('Reçu de (qui paie)')),
        const SizedBox(height: 10),
        _liste('Mode de paiement', _mode, modesPaiement, (v) => setState(() => _mode = v)),
        if (_mode != 'especes') ...[
          const SizedBox(height: 10),
          TextField(controller: _reference, decoration: _champ('Référence', aide: 'N° de transaction (SMS), de chèque ou de virement')),
        ],
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _carnet, decoration: _champ('Carnet', aide: 'Ex. Vert n° 3'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _feuille, decoration: _champ('N° du reçu papier'))),
        ]),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () async {
            final d = await _choisirDate(context, _jourPaiement, premier: DateTime.now().subtract(const Duration(days: 60)));
            if (d != null) setState(() => _jourPaiement = d);
          },
          icon: const Icon(Icons.event),
          label: Text('Date du paiement : ${_dateLisible(_date(_jourPaiement))}'),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Text('Élèves', style: texte.titleMedium)),
          TextButton.icon(onPressed: _chercherEleve, icon: const Icon(Icons.person_search), label: const Text('Ajouter un élève')),
        ]),
        if (_freres.isNotEmpty)
          Wrap(spacing: 8, children: [
            const Text('Même payeur : '),
            for (final f in _freres)
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: Text('${f['prenoms']} ${f['nom']}'),
                onPressed: () => _ajouterEleve(f['id'] as String),
              ),
          ]),
        for (final l in _lignes)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text('${_nomEleve(l.eleve)} · ${l.inscription['classe']}', style: texte.titleSmall),
                  ),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _lignes.remove(l))),
                ]),
                if (l.frais.isEmpty) const Text('Aucun frais configuré pour sa classe.'),
                if (l.frais.isNotEmpty)
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: l.global,
                        keyboardType: TextInputType.number,
                        decoration: _champ('Montant versé pour cet élève', suffixe: 'GNF',
                            aide: 'Réparti : inscription, puis scolarité tranche par tranche'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () => setState(() {
                        final m = int.tryParse(l.global.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
                        final r = repartir(m, l.frais);
                        for (final f in l.frais) {
                          l.montants[f.id]!.text = r[f.id] == null ? '' : '${r[f.id]}';
                        }
                      }),
                      child: const Text('Répartir'),
                    ),
                  ]),
                for (final f in l.frais)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(children: [
                      Expanded(
                        child: Text('${f.libelle}\nreste ${gnf(f.reste)}',
                            style: TextStyle(color: f.reste <= 0 ? Colors.grey : null)),
                      ),
                      SizedBox(
                        width: 150,
                        child: TextField(
                          controller: l.montants[f.id],
                          enabled: f.reste > 0,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => setState(() {}),
                          decoration: _champ(f.reste <= 0 ? 'Payé' : 'Montant', suffixe: 'GNF'),
                        ),
                      ),
                    ]),
                  ),
              ]),
            ),
          ),
        const SizedBox(height: 16),
        Text('Total : ${gnf(_total)}', style: texte.titleLarge),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _envoi ? null : _valider,
          icon: const Icon(Icons.receipt_long),
          label: Text(_envoi ? 'Enregistrement…' : 'Valider et voir le reçu'),
        ),
      ]),
    );
  }
}

/// Recherche rapide d'un élève inscrit cette année.
class _ChoisirEleve extends StatefulWidget {
  const _ChoisirEleve({required this.orgId});

  final String orgId;

  @override
  State<_ChoisirEleve> createState() => _ChoisirEleveState();
}

class _ChoisirEleveState extends State<_ChoisirEleve> {
  final _q = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final m = '%${_q.text.trim().toUpperCase()}%';
    return AlertDialog(
      title: const Text('Choisir un élève'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(children: [
          TextField(
            controller: _q,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Nom ou matricule'),
          ),
          Expanded(
            child: Requete(
              '''SELECT e.id, e.nom, e.prenoms, e.matricule, c.nom AS classe FROM eleves e
                 JOIN inscriptions i ON i.eleve_id = e.id AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')
                 JOIN annees_scolaires a ON a.id = i.annee_id AND a.en_cours = 1
                 JOIN classes c ON c.id = i.classe_id
                 WHERE e.organisation_id = ? AND (upper(e.nom || ' ' || e.prenoms) LIKE ? OR upper(e.prenoms || ' ' || e.nom) LIKE ?
                   OR e.matricule LIKE ?)
                 ORDER BY e.nom, e.prenoms LIMIT 50''',
              parametres: [widget.orgId, m, m, m],
              builder: (context, eleves) => ListView(children: [
                for (final e in eleves)
                  ListTile(
                    title: Text(_nomEleve(e)),
                    subtitle: Text('${e['matricule']} · ${e['classe']}'),
                    onTap: () => Navigator.pop(context, e['id'] as String),
                  ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

// Reçu --------------------------------------------------------------------------

class RecuScreen extends StatelessWidget {
  const RecuScreen({super.key, required this.espace, required this.encaissementId});

  final Espace espace;
  final String encaissementId;

  Future<List<LigneRecu>> _lignes() async => [
        for (final l in await db.getAll(
            '''SELECT l.montant_gnf, f.libelle AS frais, e.nom, e.prenoms, e.matricule, c.nom AS classe
               FROM lignes_encaissement l JOIN eleves e ON e.id = l.eleve_id JOIN frais f ON f.id = l.frais_id
               JOIN inscriptions i ON i.id = l.inscription_id JOIN classes c ON c.id = i.classe_id
               WHERE l.encaissement_id = ? ORDER BY e.nom, e.prenoms''',
            [encaissementId]))
          LigneRecu(
            eleve: '${l['nom']} ${l['prenoms']}',
            matricule: '${l['matricule']}',
            classe: '${l['classe']}',
            frais: '${l['frais']}',
            montant: l['montant_gnf'] as int,
          ),
      ];

  Future<void> _imprimer(BuildContext context, Map<String, Object?> r) async {
    final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [r['organisation_id']]);
    final par = await db.getOptional(
        'SELECT nom_complet FROM personnel WHERE user_id = ? AND organisation_id = ?', [r['encaisse_par'], r['organisation_id']]);
    final duplicata = (r['impressions'] as int? ?? 0) > 0;
    final pdf = await recuPdf(
      ecole: Map.of(ecole),
      recu: r,
      lignes: await _lignes(),
      encaissePar: '${par?['nom_complet'] ?? ''}',
      duplicata: duplicata,
    );
    // Chaque impression est comptée : la deuxième porte « DUPLICATA ».
    await _modifier('encaissements', encaissementId, {'impressions': (r['impressions'] as int? ?? 0) + 1});
    await Printing.layoutPdf(onLayout: (_) async => pdf, name: '${r['numero']}${duplicata ? '-duplicata' : ''}');
  }

  Future<void> _annuler(BuildContext context, Map<String, Object?> r) async {
    final motif = TextEditingController();
    final ok = await _formulaire(context, 'Annuler le reçu ${r['numero']}', (_) => [
          const Text("L'argent ne bouge pas : on corrige une erreur de saisie. Le reçu reste dans la suite des numéros, "
              'marqué ANNULÉ, et les tranches redeviennent dues. Barrez aussi la feuille papier.'),
          TextField(controller: motif, decoration: _champ('Motif', aide: 'Obligatoire')),
        ]);
    if (!ok || motif.text.trim().length < 3) return;
    await _modifier('encaissements', encaissementId, {
      'statut': 'annule',
      'motif_annulation': motif.text.trim(),
      'annule_par': monId,
      'annule_le': _maintenant(),
    });
  }

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT * FROM encaissements WHERE id = ?',
        parametres: [encaissementId],
        builder: (context, l) {
          if (l.isEmpty) return const Scaffold(body: Center(child: Text('Reçu introuvable.')));
          final r = l.first;
          final annule = r['statut'] == 'annule';
          final recent = DateTime.now().difference(DateTime.tryParse('${r['created_at']}') ?? DateTime(2000)).inHours < 24;
          return _Page(
            titre: 'Reçu ${r['numero']}',
            corps: FutureBuilder(
              future: Future.wait([
                _lignes(),
                jAiLeDroit(espace.orgId, r['site_id'] as String?, 'annuler_recu'),
              ]),
              builder: (context, s) {
                if (!s.hasData) return const Center(child: CircularProgressIndicator());
                final lignes = s.data![0] as List<LigneRecu>;
                final peutAnnuler = !annule && ((r['encaisse_par'] == monId && recent) || s.data![1] as bool);
                return ListView(padding: const EdgeInsets.all(16), children: [
                  if (annule)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: ListTile(
                          leading: const Icon(Icons.block), title: const Text('Reçu annulé'), subtitle: Text('${r['motif_annulation']}')),
                    ),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.receipt_long),
                      title: Text('${gnf(r['total_gnf'])} · ${modesPaiement[r['mode']]}'),
                      subtitle: Text([
                        'Reçu de ${r['payeur_nom']}, le ${_dateLisible(r['date_effective'])}',
                        if (r['feuille'] != null) 'Reçu papier : ${r['carnet'] ?? ''} n° ${r['feuille']}',
                        if (r['reference'] != null) 'Réf. ${r['reference']}',
                        if (r['confirmation'] == 'en_attente') "Sous réserve d'encaissement",
                        'Imprimé ${r['impressions']} fois',
                      ].join('\n')),
                      isThreeLine: true,
                    ),
                  ),
                  for (final x in lignes)
                    ListTile(
                      dense: true,
                      title: Text('${x.eleve} · ${x.classe}'),
                      subtitle: Text(x.frais),
                      trailing: Text(gnf(x.montant)),
                    ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => _imprimer(context, r),
                    icon: const Icon(Icons.print),
                    label: Text((r['impressions'] as int? ?? 0) == 0 ? 'Imprimer le reçu' : 'Réimprimer (duplicata)'),
                  ),
                  if (peutAnnuler) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                        onPressed: () => _annuler(context, r), icon: const Icon(Icons.block), label: const Text('Annuler ce reçu')),
                  ],
                ]);
              },
            ),
          );
        },
      );
}

// Journal de caisse -----------------------------------------------------------------

class CaisseScreen extends StatefulWidget {
  const CaisseScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<CaisseScreen> createState() => _CaisseScreenState();
}

class _CaisseScreenState extends State<CaisseScreen> {
  DateTime _jour = DateTime.now();
  bool _mesRecus = false;

  /// Feuilles manquantes dans la suite d'un carnet (reçu perdu ou non saisi).
  static List<String> _trous(List<String> feuilles) {
    final n = feuilles.map((f) => int.tryParse(f)).whereType<int>().toList()..sort();
    final trous = <String>[];
    for (var i = 1; i < n.length; i++) {
      for (var x = n[i - 1] + 1; x < n[i] && trous.length < 20; x++) {
        trous.add(x.toString().padLeft(feuilles.first.length, '0'));
      }
    }
    return trous;
  }

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    return _Page(
      titre: 'Caisse du ${_dateLisible(_date(_jour))}',
      ajouter: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => EncaisserScreen(espace: widget.espace))),
      libelleAjouter: 'Encaisser',
      corps: Requete(
        '''SELECT e.*, p.nom_complet AS encaisseur FROM encaissements e
           LEFT JOIN personnel p ON p.user_id = e.encaisse_par AND p.organisation_id = e.organisation_id
           WHERE e.organisation_id = ? AND e.date_effective = ? AND (? = 0 OR e.encaisse_par = ?)
           ORDER BY e.carnet, e.feuille, e.created_at''',
        parametres: [widget.espace.orgId, _date(_jour), _mesRecus ? 1 : 0, monId],
        builder: (context, recus) {
          final valides = recus.where((r) => r['statut'] == 'valide');
          final parMode = <String, int>{};
          for (final r in valides) {
            parMode[r['mode'] as String] = (parMode[r['mode']] ?? 0) + (r['total_gnf'] as int);
          }
          final total = parMode.values.fold(0, (s, v) => s + v);
          final carnets = <String, List<String>>{};
          for (final r in recus.where((r) => r['feuille'] != null)) {
            carnets.putIfAbsent('${r['carnet'] ?? ''}', () => []).add(r['feuille'] as String);
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 88), children: [
            Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await _choisirDate(context, _jour, premier: DateTime(2024));
                  if (d != null) setState(() => _jour = d);
                },
                icon: const Icon(Icons.event),
                label: const Text('Changer de jour'),
              ),
              FilterChip(label: const Text('Mes reçus seulement'), selected: _mesRecus, onSelected: (v) => setState(() => _mesRecus = v)),
            ]),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Total encaissé : ${gnf(total)}', style: texte.titleLarge),
                  for (final m in parMode.entries) Text('${modesPaiement[m.key]} : ${gnf(m.value)}'),
                  Text('${valides.length} reçu(s) valide(s), ${recus.length - valides.length} annulé(s)'),
                  for (final c in carnets.entries)
                    if (_trous(c.value).isNotEmpty)
                      Text('Carnet ${c.key} : feuille(s) manquante(s) ${_trous(c.value).join(', ')}',
                          style: TextStyle(color: Colors.orange.shade800)),
                ]),
              ),
            ),
            for (final r in recus)
              Card(
                child: ListTile(
                  leading: Icon(r['statut'] == 'annule' ? Icons.block : Icons.receipt_long,
                      color: r['statut'] == 'annule' ? Colors.red : null),
                  title: Text('${gnf(r['total_gnf'])} · ${r['payeur_nom']}'),
                  subtitle: Text([
                    r['numero'],
                    if (r['feuille'] != null) 'papier ${r['feuille']}',
                    modesPaiement[r['mode']],
                    if (r['encaisseur'] != null) r['encaisseur'],
                    if (r['statut'] == 'annule') 'ANNULÉ',
                  ].join(' · ')),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => RecuScreen(espace: widget.espace, encaissementId: r['id'] as String))),
                ),
              ),
          ]);
        },
      ),
    );
  }
}
