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

/// Réductions dont bénéficie une inscription (même calcul que le serveur).
/// [paiementAnnuel] : compter la remise « année payée d'un coup » même si elle
/// n'est pas encore attribuée (au moment où la famille paie).
Future<({List<Regle> applicables, bool cumul, int plafond})> reductionsInscription(String inscriptionId,
    {bool paiementAnnuel = false}) async {
  final ins = await db.getOptional('SELECT * FROM inscriptions WHERE id = ?', [inscriptionId]);
  if (ins == null) return (applicables: <Regle>[], cumul: false, plafond: 100);
  final org = await db.get('SELECT reductions_cumul, reductions_plafond FROM organisations WHERE id = ?', [ins['organisation_id']]);
  final regles = [
    for (final r in await db.getAll(
        'SELECT * FROM regles_reduction WHERE organisation_id = ? AND actif = 1 ORDER BY created_at', [ins['organisation_id']]))
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
  final attribuees = {
    for (final r in await db.getAll('SELECT regle_id FROM reductions_eleves WHERE inscription_id = ? AND actif = 1', [inscriptionId]))
      r['regle_id'] as String,
    if (paiementAnnuel) ...regles.where((r) => r.type == 'paiement_annuel').map((r) => r.id),
  };
  final enfants = await db.get('''
      SELECT count(DISTINCT i2.id) AS n FROM eleves_contacts ec
      JOIN eleves_contacts ec2 ON ec2.contact_id = ec.contact_id AND ec2.responsable_financier = 1
      JOIN inscriptions i2 ON i2.eleve_id = ec2.eleve_id AND i2.annee_id = ?
        AND i2.statut NOT IN ('annule', 'exclu', 'transfert_sortant')
      WHERE ec.eleve_id = ? AND ec.responsable_financier = 1''', [ins['annee_id'], ins['eleve_id']]);
  final cumul = org['reductions_cumul'] == 1;
  return (
    applicables: reductionsApplicables(
        regles: regles, attribuees: attribuees, enfantsDuPayeur: (enfants['n'] as int?) ?? 1, cumul: cumul),
    cumul: cumul,
    plafond: (org['reductions_plafond'] as int?) ?? 100,
  );
}

/// Ce que doit un élève pour son inscription : frais applicables, réductions,
/// échéances, déjà payé. Calculé sur le poste, d'après les données synchronisées.
Future<List<FraisDu>> situationInscription(String inscriptionId, {bool paiementAnnuel = false}) async {
  final ins = await db.getOptional(
      '''SELECT i.*, c.niveau_id, a.debut AS annee_debut, a.fin AS annee_fin, o.delai_grace_jours
         FROM inscriptions i JOIN classes c ON c.id = i.classe_id
         JOIN annees_scolaires a ON a.id = i.annee_id JOIN organisations o ON o.id = i.organisation_id
         WHERE i.id = ?''', [inscriptionId]);
  if (ins == null) return [];
  final red = await reductionsInscription(inscriptionId, paiementAnnuel: paiementAnnuel);
  final typeEntree = ins['type_admission'] == 'reinscription' ? 'reinscription' : 'inscription';
  final frais = fraisRetenus((await db.getAll('''
      SELECT f.*,
        (SELECT coalesce(sum(l.montant_gnf), 0) FROM lignes_encaissement l
         JOIN encaissements e ON e.id = l.encaissement_id AND e.statut = 'valide' AND e.confirmation <> 'rejete'
         WHERE l.inscription_id = ? AND l.frais_id = f.id)
        - (SELECT coalesce(sum(r.montant_gnf), 0) FROM remboursements r
           WHERE r.inscription_id = ? AND r.frais_id = f.id AND r.statut = 'verse') AS paye
      FROM frais f
      WHERE f.annee_id = ? AND (f.site_id IS NULL OR f.site_id = ?) AND (f.niveau_id IS NULL OR f.niveau_id = ?)
        AND (f.type_frais IN (?, 'scolarite')
             OR (f.type_frais = 'optionnel'
                 AND (f.classes IS NULL OR f.classes = '' OR instr(',' || f.classes || ',', ',' || ? || ',') > 0)
                 AND (f.examen = 1 OR f.obligatoire = 1 OR EXISTS (SELECT 1 FROM souscriptions s
                      WHERE s.inscription_id = ? AND s.frais_id = f.id AND s.actif = 1))))
      ORDER BY f.created_at''',
      [inscriptionId, inscriptionId, ins['annee_id'], ins['site_id'], ins['niveau_id'], typeEntree, ins['classe_id'], inscriptionId]))
      .map((f) => Map<String, Object?>.from(f)));
  final amenagees = <String, List<({String libelle, int montant, DateTime dateLimite})>>{};
  for (final e in await db.getAll(
      'SELECT * FROM echeances_eleves WHERE inscription_id = ? ORDER BY frais_id, ordre', [inscriptionId])) {
    amenagees.putIfAbsent(e['frais_id'] as String, () => []).add(
        (libelle: e['libelle'] as String, montant: e['montant_gnf'] as int, dateLimite: DateTime.parse('${e['date_limite']}')));
  }
  final arrivee = DateTime.tryParse('${ins['date_effective']}') ?? DateTime.now();
  final grace = (ins['delai_grace_jours'] as int?) ?? 7;
  final resultats = <FraisDu>[];
  // Arrivée en cours d'année : ce qu'on retire de la scolarité (mois passés ou montant négocié).
  var retraitNegocie = ins['arrivee_mode'] == 'negocie' ? (ins['arrivee_retrait_gnf'] as int? ?? 0) : 0;
  for (final f in frais) {
    final type = f['type_frais'] as String? ?? 'optionnel';
    final total = f['montant_gnf'] as int;
    final reduction = reductionSurFrais(typeFrais: type, total: total, applicables: red.applicables, cumul: red.cumul, plafond: red.plafond);
    var retrait = 0;
    if (type == 'scolarite') {
      if (ins['arrivee_mode'] == 'mois') {
        retrait = retraitMoisArrivee(
          total: total - reduction,
          rentree: DateTime.tryParse('${ins['annee_debut']}') ?? arrivee,
          fin: DateTime.tryParse('${ins['annee_fin']}') ?? arrivee,
          arrivee: arrivee,
        );
      } else if (retraitNegocie > 0) {
        retrait = retraitNegocie < total - reduction ? retraitNegocie : total - reduction;
        retraitNegocie -= retrait;
      }
    }
    resultats.add(situationFrais(
      id: f['id'] as String,
      libelle: f['libelle'] as String,
      type: type,
      total: total,
      echeances: amenagees[f['id']] ??
          [
            for (final e in await db.getAll('SELECT * FROM echeances WHERE frais_id = ? ORDER BY ordre', [f['id']]))
              (libelle: e['libelle'] as String, montant: e['montant_gnf'] as int, dateLimite: DateTime.parse('${e['date_limite']}')),
          ],
      arrivee: arrivee,
      dejaPaye: f['paye'] as int? ?? 0,
      reduction: reduction,
      retrait: retrait,
      grace: grace,
    ));
  }
  return resultats;
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
                  (SELECT max(updated_at) FROM frais) AS f,
                  (SELECT max(updated_at) FROM reductions_eleves) AS r,
                  (SELECT max(updated_at) FROM regles_reduction) AS g,
                  (SELECT max(updated_at) FROM organisations) AS o,
                  (SELECT max(updated_at) FROM eleves_contacts) AS c''',
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
                leading: Icon(Icons.account_balance_wallet_outlined, color: retards.isNotEmpty ? Couleurs.attente : null),
                title: Text(total == 0 ? 'Aucun frais configuré pour cette classe' : 'Reste à payer : ${gnf(total - paye)}'),
                subtitle: Text('Payé ${gnf(paye)} sur ${gnf(total)}'
                    '${retards.isNotEmpty ? ' · ${retards.length} échéance(s) en retard' : ''}'),
                children: [
                  for (final f in frais) ...[
                    ListTile(
                      dense: true,
                      title: Text('${f.libelle} : ${gnf(f.total)}'),
                      subtitle: f.reduction > 0 ? Text('au lieu de ${gnf(f.brut)}, réduction ${gnf(f.reduction)}') : null,
                      trailing: Text(f.reste <= 0 ? 'Payé' : 'Reste ${gnf(f.reste)}'),
                    ),
                    if (f.echeances.length > 1)
                      for (final e in f.echeances)
                        Padding(
                          padding: const EdgeInsets.only(left: 32, right: 16, bottom: 2),
                          child: Row(children: [
                            Expanded(child: Text('${e.libelle} · avant le ${_dateLisible(_date(e.dateLimite))}')),
                            Text(e.soldee ? 'Payée' : (e.enRetard(aujourdhui) ? 'En retard : ${gnf(e.reste)}' : gnf(e.reste)),
                                style: TextStyle(color: e.enRetard(aujourdhui) ? Couleurs.attente : null)),
                          ]),
                        ),
                  ],
                  _Souscrire(espace: espace, inscriptionId: inscriptionId),
                  _Reductions(espace: espace, inscriptionId: inscriptionId),
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

/// Réductions de l'élève : celles qui s'appliquent, l'attribution des
/// réductions accordées élève par élève (bourse, orphelin, enfant du personnel)
/// avec motif et durée, et la reconduction — jamais automatique — de celles de
/// l'an dernier qui courent encore.
class _Reductions extends StatelessWidget {
  const _Reductions({required this.espace, required this.inscriptionId});

  final Espace espace;
  final String inscriptionId;

  Future<void> _attribuer(BuildContext context) async {
    final ins = await db.get('SELECT organisation_id, site_id FROM inscriptions WHERE id = ?', [inscriptionId]);
    final regles = await db.getAll(
        '''SELECT g.*, r.id AS attribution, r.actif AS attribuee, r.motif, r.duree_annees, r.annee_rang FROM regles_reduction g
           LEFT JOIN reductions_eleves r ON r.regle_id = g.id AND r.inscription_id = ?
           WHERE g.organisation_id = ? AND g.actif = 1 AND g.type IN ('personnalisee', 'personnel') ORDER BY g.type, g.created_at''',
        [inscriptionId, ins['organisation_id']]);
    final personnel = {
      for (final p in await db.getAll(
          "SELECT id, nom_complet FROM personnel WHERE organisation_id = ? AND statut = 'actif' ORDER BY nom_complet",
          [ins['organisation_id']]))
        p['id'] as String: p['nom_complet'] as String,
    };
    if (!context.mounted) return;
    if (regles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Aucune réduction à accorder. Le fondateur les crée dans Paramètres → Réductions.")));
      return;
    }
    final choix = {for (final r in regles) r['id'] as String: r['attribuee'] == 1};
    bool nouvelle(Map<String, Object?> r) => r['attribution'] == null && choix[r['id']] == true;
    final motif = TextEditingController();
    var duree = 1;
    String? parent;
    final ok = await _formulaire(context, 'Réductions accordées', (maj) {
      final nouvelles = regles.where(nouvelle).toList();
      return [
        for (final r in regles)
          CheckboxListTile(
            value: choix[r['id']],
            title: Text('${r['libelle']}'),
            subtitle: Text([
              r['pourcentage'] == 1 ? '${'${r['valeur']}'.replaceAll('.0', '')} %' : gnf((r['valeur'] as num).toInt()),
              porteesReduction[r['portee']],
              if (r['motif'] != null) '${r['motif']}',
              if (r['attribution'] != null && (r['duree_annees'] as int? ?? 1) > 1) 'année ${r['annee_rang']} sur ${r['duree_annees']}',
            ].join(' · ')),
            onChanged: (v) => maj(() => choix[r['id'] as String] = v ?? false),
          ),
        if (nouvelles.isNotEmpty) ...[
          TextField(controller: motif, decoration: _champ('Motif', aide: 'Obligatoire : père décédé, bourse du mérite, fille du surveillant…')),
          _liste('Durée', duree, {for (var n = 1; n <= 6; n++) n: n == 1 ? 'Cette année seulement' : '$n ans'}, (v) => maj(() => duree = v)),
          if (duree > 1)
            const Text("Elle ne se reconduit pas seule : à la réinscription, la direction choisit de la reconduire.",
                style: TextStyle(fontSize: 12)),
          if (nouvelles.any((r) => r['type'] == 'personnel'))
            _liste<String?>('Parent membre du personnel', parent, {null: 'Choisir', ...personnel}, (v) => maj(() => parent = v)),
        ],
      ];
    });
    if (!ok || !context.mounted) return;
    final nouvelles = regles.where(nouvelle).toList();
    String? probleme;
    if (nouvelles.isNotEmpty && motif.text.trim().length < 3) probleme = 'Le motif est obligatoire.';
    if (nouvelles.any((r) => r['type'] == 'personnel') && parent == null) probleme = 'Choisissez le parent membre du personnel.';
    if (probleme != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(probleme)));
      return;
    }
    final m = _maintenant();
    await db.writeTransaction((tx) async {
      for (final r in regles) {
        final voulu = choix[r['id']]!;
        if (r['attribution'] == null) {
          if (voulu) {
            await tx.execute(
                'INSERT INTO reductions_eleves (id, organisation_id, inscription_id, regle_id, actif, motif, accorde_par, '
                'personnel_id, duree_annees, annee_rang, created_at, updated_at) VALUES (uuid(), ?, ?, ?, 1, ?, ?, ?, ?, 1, ?, ?)',
                [ins['organisation_id'], inscriptionId, r['id'], motif.text.trim(), monId,
                  r['type'] == 'personnel' ? parent : null, duree, m, m]);
          }
        } else if (voulu != (r['attribuee'] == 1)) {
          await tx.execute('UPDATE reductions_eleves SET actif = ?, updated_at = ? WHERE id = ?', [voulu ? 1 : 0, m, r['attribution']]);
        }
      }
    });
  }

  /// Réductions de l'an dernier qui courent encore (année 1 sur 3…) et ne sont
  /// pas déjà sur cette inscription.
  static Future<List<Map<String, Object?>>> _aReconduire(String inscriptionId) async => [
        for (final r in await db.getAll('''
            SELECT re.*, g.libelle FROM inscriptions i
            JOIN inscriptions p ON p.eleve_id = i.eleve_id AND p.id <> i.id
            JOIN annees_scolaires ap ON ap.id = p.annee_id
            JOIN annees_scolaires ai ON ai.id = i.annee_id AND ap.debut < ai.debut
            JOIN reductions_eleves re ON re.inscription_id = p.id AND re.actif = 1 AND re.annee_rang < re.duree_annees
            JOIN regles_reduction g ON g.id = re.regle_id AND g.actif = 1
            WHERE i.id = ?
              AND p.annee_id = (SELECT a2.id FROM inscriptions p2 JOIN annees_scolaires a2 ON a2.id = p2.annee_id
                                WHERE p2.eleve_id = i.eleve_id AND a2.debut < ai.debut ORDER BY a2.debut DESC LIMIT 1)
              AND NOT EXISTS (SELECT 1 FROM reductions_eleves x WHERE x.inscription_id = i.id AND x.regle_id = re.regle_id)''',
            [inscriptionId]))
          Map<String, Object?>.from(r),
      ];

  Future<void> _reconduire(BuildContext context, Map<String, Object?> r) async {
    if (!await _confirmer(context,
        'Reconduire « ${r['libelle']} » (${r['motif']}) : année ${(r['annee_rang'] as int) + 1} sur ${r['duree_annees']} ?')) {
      return;
    }
    await _inserer('reductions_eleves', {
      'organisation_id': r['organisation_id'],
      'inscription_id': inscriptionId,
      'regle_id': r['regle_id'],
      'actif': 1,
      'motif': r['motif'],
      'accorde_par': monId,
      'personnel_id': r['personnel_id'],
      'duree_annees': r['duree_annees'],
      'annee_rang': (r['annee_rang'] as int) + 1,
      'reconduite_de': r['id'],
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: Future.wait([
          reductionsInscription(inscriptionId),
          db.get('SELECT site_id FROM inscriptions WHERE id = ?', [inscriptionId]),
          _aReconduire(inscriptionId),
        ]),
        builder: (context, s) {
          if (!s.hasData) return const SizedBox.shrink();
          final red = s.data![0] as ({List<Regle> applicables, bool cumul, int plafond});
          final site = (s.data![1] as Map<String, Object?>)['site_id'] as String;
          final reconduire = s.data![2] as List<Map<String, Object?>>;
          final gere = espace.gereSite(site);
          return Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.discount_outlined),
              title: Text(red.applicables.isEmpty
                  ? 'Aucune réduction'
                  : 'Réductions : ${red.applicables.map((r) => r.libelle).join(', ')}'),
              trailing: gere ? TextButton(onPressed: () => _attribuer(context), child: const Text('Accorder')) : null,
            ),
            for (final r in reconduire)
              ListTile(
                dense: true,
                leading: const Icon(Icons.update, color: Couleurs.attente),
                title: Text('À reconduire ? ${r['libelle']} · année ${(r['annee_rang'] as int) + 1} sur ${r['duree_annees']}'),
                subtitle: Text("${r['motif'] ?? ''} · accordée l'an dernier, pas reconduite d'office"),
                trailing: gere ? TextButton(onPressed: () => _reconduire(context, r), child: const Text('Reconduire')) : null,
              ),
          ]);
        },
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
           JOIN frais f ON f.annee_id = i.annee_id AND f.type_frais = 'optionnel' AND coalesce(f.examen, 0) = 0
             AND coalesce(f.obligatoire, 0) = 0
             AND (f.classes IS NULL OR f.classes = '' OR instr(',' || f.classes || ',', ',' || i.classe_id || ',') > 0)
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

/// Un reçu en préparation : un mode de paiement, sa référence, sa feuille et ses élèves.
class _Brouillon {
  _Brouillon(this.mode);

  String mode;
  final reference = TextEditingController();
  final feuille = TextEditingController();
  final lignes = <_LigneEleve>[];
}

class _LigneEleve {
  _LigneEleve(this.eleve, this.inscription, this.frais, {this.regleAnnuelle})
      : montants = {for (final f in frais) f.id: TextEditingController()},
        global = TextEditingController();

  final Map<String, Object?> eleve;
  final Map<String, Object?> inscription;
  List<FraisDu> frais;

  /// Remise « année payée d'un coup », proposée tant que rien de la scolarité
  /// n'est payé ; [annuel] : la famille paie toute l'année maintenant.
  final Map<String, Object?>? regleAnnuelle;
  bool annuel = false;
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
  final _carnet = TextEditingController();
  // Un reçu = un mode de paiement. « Second mode de paiement » ouvre un
  // deuxième reçu pour la même famille (ex. une partie en espèces, le reste
  // par Orange Money) : chacun a sa feuille, sa référence et ses montants.
  final _recus = <_Brouillon>[_Brouillon('especes')];
  int _actif = 0;
  _Brouillon get _b => _recus[_actif];
  String get _mode => _b.mode;
  set _mode(String v) => _b.mode = v;
  TextEditingController get _reference => _b.reference;
  TextEditingController get _feuille => _b.feuille;
  List<_LigneEleve> get _lignes => _b.lignes;
  DateTime _jourPaiement = DateTime.now();
  List<Map<String, Object?>> _freres = [];
  bool _envoi = false;
  final _cherche = TextEditingController();
  String? _ecole;
  String? _site;
  String? _ville;
  String? _annee;
  String? _moi;

  /// Modes encaissés « sous réserve » (réglés par l'école).
  Set<String> _sousReserve = const {'cheque', 'virement'};

  @override
  void initState() {
    super.initState();
    _preparer();
  }

  /// Jours passés encaissés mais pas clôturés : il faut les clôturer d'abord.
  List<Map<String, Object?>> _nonClos = [];

  Future<void> _verifierClotures() async {
    final j = await joursNonClotures(widget.espace.orgId);
    if (mounted) setState(() => _nonClos = j);
  }

  Future<void> _preparer() async {
    await _verifierClotures();
    final o = widget.espace.orgId;
    final ecole = await db.getOptional('SELECT coalesce(nom_officiel, nom) AS nom, ville FROM organisations WHERE id = ?', [o]);
    final sites = await db.getAll('SELECT id, nom, ville FROM sites WHERE organisation_id = ? ORDER BY created_at', [o]);
    Map<String, Object?>? site = sites.length == 1 ? sites.first : null;
    for (final x in sites) {
      if (x['id'] == widget.espace.siteId) site = x;
    }
    final annee = await db.getOptional('SELECT libelle FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1', [o]);
    final moi = await db.getOptional('SELECT nom_complet FROM personnel WHERE organisation_id = ? AND user_id = ?', [o, monId]);
    _ecole = ecole?['nom'] as String?;
    _site = site?['nom'] as String?;
    _ville = (site?['ville'] ?? ecole?['ville']) as String?;
    _annee = annee?['libelle'] as String?;
    _moi = moi?['nom_complet'] as String?;
    final reserve = await db.getOptional('SELECT modes_sous_reserve FROM organisations WHERE id = ?', [o]);
    _sousReserve = '${reserve?['modes_sous_reserve'] ?? 'cheque,virement'}'.split(',').toSet();
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
    // L'année en cours, la suivante si ses inscriptions sont ouvertes, et les
    // années clôturées tant qu'il reste des arriérés.
    final candidates = await db.getAll(
        '''SELECT i.*, c.nom AS classe, a.libelle AS annee_libelle, a.en_cours AS annee_en_cours, a.etat AS annee_etat
           FROM inscriptions i JOIN classes c ON c.id = i.classe_id
           JOIN annees_scolaires a ON a.id = i.annee_id AND (a.en_cours = 1 OR a.etat IN ('inscriptions', 'cloturee'))
           WHERE i.eleve_id = ? AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')
           ORDER BY a.debut''',
        [eleveId]);
    final retenues = <(Map<String, Object?>, List<FraisDu>)>[];
    for (final c in candidates) {
      final situation = await situationInscription(c['id'] as String);
      final reste = situation.fold<int>(0, (t, f) => t + f.reste);
      if (c['annee_etat'] == 'cloturee' && reste <= 0) continue;
      retenues.add((Map<String, Object?>.from(c), situation));
    }
    if (!mounted) return;
    if (eleve == null || retenues.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Cet élève n'est pas inscrit cette année et ne doit rien.")));
      return;
    }
    // La ligne principale (paiement annuel, frères et sœurs) : l'année en cours s'il y en a une.
    final principale = retenues.firstWhere((r) => r.$1['annee_en_cours'] == 1, orElse: () => retenues.first);
    final (ins, frais) = principale;
    final scolarite = frais.where((f) => f.type == 'scolarite');
    final annuelle = scolarite.isEmpty || scolarite.any((f) => f.paye > 0)
        ? null
        : await db.getOptional(
            '''SELECT g.* FROM regles_reduction g WHERE g.organisation_id = ? AND g.actif = 1 AND g.type = 'paiement_annuel'
               AND NOT EXISTS (SELECT 1 FROM reductions_eleves r WHERE r.regle_id = g.id AND r.inscription_id = ? AND r.actif = 1)
               ORDER BY g.created_at LIMIT 1''',
            [ins['organisation_id'], ins['id']]);
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
            .map((x) => <String, Object?>{...x, 'payeur': rf['id']})
            .toList();
    final photo = await db.getOptional('SELECT updated_at FROM photos_eleves WHERE eleve_id = ?', [eleveId]);
    if (!mounted) return;
    setState(() {
      final e = {...eleve, 'payeur_id': rf?['id'], 'photo_maj': photo?['updated_at']};
      // Une ligne par année : arriéré de l'an dernier, année en cours, rentrée prochaine.
      for (final (autre, autresFrais) in retenues.where((r) => r.$1['id'] != ins['id'])) {
        _lignes.add(_LigneEleve(e, autre, autresFrais));
      }
      _lignes.add(_LigneEleve(e, Map.of(ins), frais, regleAnnuelle: annuelle == null ? null : Map.of(annuelle)));
      _freres = [
        ..._freres,
        ...freres.where((f) => !_freres.any((x) => x['id'] == f['id'])),
      ].where((f) => !_lignes.any((l) => l.eleve['id'] == f['id'])).toList();
    });
  }

  int get _total => _lignes.fold<int>(0, (s, l) => s + l.total);
  int get _totalTous => _recus.fold(0, (s, b) => s + b.lignes.fold<int>(0, (x, l) => x + l.total));

  void _secondMode() {
    final pris = _recus.map((b) => b.mode).toSet();
    final mode = modesPaiement.keys.firstWhere((m) => !pris.contains(m), orElse: () => 'orange_money');
    final nouveau = _Brouillon(mode);
    // Feuille suivante du carnet, et les mêmes élèves (montants à saisir).
    String? derniere;
    for (final b in _recus) {
      if (b.feuille.text.trim().isNotEmpty) derniere = b.feuille.text.trim();
    }
    nouveau.feuille.text = derniere == null ? '' : (feuilleSuivante(derniere) ?? '');
    for (final l in _b.lignes) {
      nouveau.lignes.add(_LigneEleve(l.eleve, l.inscription, l.frais));
    }
    setState(() {
      _recus.add(nouveau);
      _actif = _recus.length - 1;
    });
  }

  /// Ce que les autres reçus en préparation versent déjà sur ce frais.
  int _prevuAilleurs(_LigneEleve l, String fraisId) {
    var t = 0;
    for (final b in _recus) {
      if (identical(b, _b)) continue;
      for (final x in b.lignes) {
        if (x.inscription['id'] == l.inscription['id']) t += x.montant(fraisId);
      }
    }
    return t;
  }

  /// Ce qui reste dû sur un frais, une fois déduit ce que prévoient les autres reçus.
  int _dispo(_LigneEleve l, FraisDu f) {
    final d = f.reste - _prevuAilleurs(l, f.id);
    return d < 0 ? 0 : (d > f.reste ? f.reste : d);
  }

  Future<void> _valider() async {
    final messager = ScaffoldMessenger.of(context);
    void erreur(String m) => messager.showSnackBar(SnackBar(content: Text(m)));
    if (await posteEnAttente()) return erreur(messagePosteEnAttente);
    if (await horlogeBloque(context)) return;
    if (_nonClos.isNotEmpty) return erreur("Clôturez d'abord votre caisse du ${_dateLisible(_nonClos.first['jour'])}.");
    final recus = _recus.where((b) => b.lignes.any((l) => l.total > 0)).toList();
    if (_recus.every((b) => b.lignes.isEmpty)) return erreur('Ajoutez au moins un élève.');
    if (recus.isEmpty) return erreur('Aucun montant saisi.');
    if (_payeur.text.trim().length < 2) return erreur('Indiquez le nom de la personne qui paie.');
    final numeroRecu = {for (var i = 0; i < _recus.length; i++) _recus[i]: i + 1};
    String nom(_Brouillon b) => _recus.length > 1 ? 'Reçu ${numeroRecu[b]} (${modesPaiement[b.mode]}) : ' : '';
    for (final b in recus) {
      if (b.mode != 'especes' && b.reference.text.trim().isEmpty) {
        return erreur('${nom(b)}saisissez la référence (n° de transaction, de chèque ou de virement).');
      }
    }
    // Pour chaque élève et chaque frais : la somme des reçus ne dépasse pas le reste dû.
    final prevu = <String, int>{};
    final frais = <String, (FraisDu, _LigneEleve)>{};
    for (final b in recus) {
      for (final l in b.lignes) {
        for (final f in l.frais) {
          final k = '${l.inscription['id']}|${f.id}';
          prevu[k] = (prevu[k] ?? 0) + l.montant(f.id);
          frais[k] = (f, l);
        }
      }
    }
    for (final e in prevu.entries) {
      final (f, l) = frais[e.key]!;
      if (e.value > f.reste) {
        return erreur('${_nomEleve(l.eleve)} : ${f.libelle} dépasse le reste dû (${gnf(f.reste)}).');
      }
    }
    for (final b in recus) {
      for (final l in b.lignes.where((l) => l.annuel)) {
        for (final f in l.frais.where((f) => f.type == 'scolarite')) {
          if (prevu['${l.inscription['id']}|${f.id}'] != f.reste) {
            return erreur("${_nomEleve(l.eleve)} : la remise « année payée d'un coup » demande de payer toute la scolarité "
                '(${gnf(f.reste)}).');
          }
        }
      }
    }
    final o = widget.espace.orgId;
    final poste = await cePoste();
    if (poste == null) return erreur("Activez d'abord ce poste (accueil) : sa lettre entre dans le numéro du reçu.");
    final carnet = _carnet.text.trim().isEmpty ? null : _carnet.text.trim();
    final feuilles = <String>{};
    for (final b in recus) {
      final feuille = b.feuille.text.trim();
      if (feuille.isEmpty) continue;
      if (!feuilles.add(feuille)) return erreur('Deux reçus portent la même feuille $feuille.');
      if (await db.getOptional('SELECT 1 FROM encaissements WHERE carnet IS ? AND feuille = ?', [carnet, feuille]) != null) {
        return erreur('La feuille $feuille de ce carnet a déjà été saisie.');
      }
    }
    final infos = <String, Map<String, Object?>>{};
    for (final b in recus) {
      final site = b.lignes.firstWhere((l) => l.total > 0).inscription['site_id'] as String;
      final x = await db.get(
          '''SELECT o.code AS sigle, s.code AS code_site, a.libelle AS annee, a.id AS annee_id
             FROM organisations o, sites s, annees_scolaires a
             WHERE o.id = ? AND s.id = ? AND a.organisation_id = o.id AND a.en_cours = 1''',
          [o, site]);
      if (x['sigle'] == null || x['code_site'] == null) {
        return erreur("Choisissez d'abord le sigle de l'école et le code du site (Paramètres).");
      }
      infos[site] = Map.of(x);
    }
    if (!mounted) return;
    final resume = recus.map((b) => '${gnf(b.lignes.fold<int>(0, (s, l) => s + l.total))} (${modesPaiement[b.mode]})').join(' + ');
    if (!await _confirmer(context, 'Encaisser $resume de ${_payeur.text.trim()} ?')) return;

    setState(() => _envoi = true);
    final ids = <String>[];
    try {
      final maintenant = _maintenant();
      await db.writeTransaction((tx) async {
        for (final b in recus) {
          final total = b.lignes.fold<int>(0, (s, l) => s + l.total);
          final site = b.lignes.firstWhere((l) => l.total > 0).inscription['site_id'] as String;
          final x = infos[site]!;
          final numero = numeroRecuSuivant(
            sigle: x['sigle'] as String,
            codeSite: x['code_site'] as String,
            annee: x['annee'] as String,
            lettre: poste['code'] as String,
            existants: [
              ...(await tx.getAll('SELECT numero FROM encaissements WHERE poste_id = ?', [poste['poste_id']])).map((r) => r['numero'] as String),
              ...await derniersNumeros(tx, 'recu:${x['code_site']}:${x['annee']}'),
            ],
          );
          await noterNumero(tx, 'recu:${x['code_site']}:${x['annee']}', numero);
          final id = (await tx.get('SELECT uuid() AS id'))['id'] as String;
          ids.add(id);
          await tx.execute(
              '''INSERT INTO encaissements (id, organisation_id, site_id, annee_id, numero, carnet, feuille, payeur_nom, mode,
                   reference, date_effective, jour_caisse, total_gnf, confirmation, statut, impressions, poste_id, encaisse_par,
                   created_at, updated_at)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'valide', 0, ?, ?, ?, ?)''',
              [
                id, o, site, x['annee_id'], numero, carnet, b.feuille.text.trim().isEmpty ? null : b.feuille.text.trim(),
                _payeur.text.trim(), b.mode, b.reference.text.trim().isEmpty ? null : b.reference.text.trim(),
                // Payé le jour choisi ; entré dans la caisse aujourd'hui.
                _date(_jourPaiement), _date(DateTime.now()), total, _sousReserve.contains(b.mode) ? 'en_attente' : 'confirme',
                poste['poste_id'], monId, maintenant, maintenant,
              ]);
          for (final l in b.lignes) {
            if (l.annuel && l.regleAnnuelle != null) {
              // La remise est attribuée avec le paiement, dans la même opération.
              await tx.execute(
                  'INSERT INTO reductions_eleves (id, organisation_id, inscription_id, regle_id, actif, motif, accorde_par, created_at, updated_at) '
                  "VALUES (uuid(), ?, ?, ?, 1, 'Année payée en une fois', ?, ?, ?)",
                  [o, l.inscription['id'], l.regleAnnuelle!['id'], monId, maintenant, maintenant]);
            }
            for (final f in l.frais) {
              final m = l.montant(f.id);
              if (m <= 0) continue;
              await tx.execute(
                  '''INSERT INTO lignes_encaissement (id, organisation_id, encaissement_id, inscription_id, eleve_id, frais_id,
                       montant_gnf, created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?)''',
                  [o, id, l.inscription['id'], l.eleve['id'], f.id, m, maintenant, maintenant]);
            }
          }
        }
      });
    } finally {
      if (mounted) setState(() => _envoi = false);
    }
    if (!mounted) return;
    final navigation = Navigator.of(context);
    // Les reçus s'impriment tout de suite, l'un après l'autre ; l'écran du premier reste ouvert.
    unawaited(() async {
      for (final id in ids) {
        await _imprimerRecu(id);
      }
    }());
    navigation.pushReplacement(MaterialPageRoute(builder: (_) => RecuScreen(espace: widget.espace, encaissementId: ids.first)));
  }

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final largeur = MediaQuery.sizeOf(context).width;
    final telephone = largeur < 640;
    final maintenant = DateTime.now();
    final technique = '${_dateLisible(_date(maintenant))} à ${maintenant.hour.toString().padLeft(2, '0')}:'
        '${maintenant.minute.toString().padLeft(2, '0')}';
    final bouton = SizedBox(
      height: 40,
      child: FilledButton.icon(
        onPressed: _envoi ? null : _valider,
        icon: const Icon(Icons.print_outlined, size: 16),
        label: Text(_envoi ? 'Enregistrement…' : (_recus.length > 1 ? 'Enregistrer et imprimer les ${_recus.length} reçus' : 'Enregistrer et imprimer')),
      ),
    );
    BoxDecoration carte() => BoxDecoration(
          color: schema.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: schema.outlineVariant),
        );
    Widget champ(String libelle, Widget enfant) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(libelle, style: TextStyle(fontSize: 14, color: gris)),
          const SizedBox(height: 6),
          SizedBox(height: 36, child: enfant),
        ]);
    InputDecoration fin({String? indice, bool actif = true}) => InputDecoration(
          isDense: true,
          hintText: indice,
          hintStyle: TextStyle(fontSize: 14, color: gris),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          fillColor: actif ? schema.surface : Couleurs.doux(context),
        );
    const styleChamp = TextStyle(fontSize: 14);

    final enTete = Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 12, children: [
      const Text('Encaisser', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -.2)),
      Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text([_site, _annee].whereType<String>().join(' · '), style: TextStyle(fontSize: 14, color: gris)),
      ),
    ]);

    final alerte = _nonClos.isEmpty
        ? null
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Couleurs.attenteFond,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Couleurs.attente.withValues(alpha: .35)),
            ),
            child: Row(children: [
              const Icon(Icons.warning_amber, size: 16, color: Couleurs.attente),
              const SizedBox(width: 8),
              Expanded(
                child: Text("La caisse du ${_dateLisible(_nonClos.first['jour'])} n'a pas été clôturée. "
                    "Comptez les espèces de ce jour-là avant d'encaisser aujourd'hui.",
                    style: const TextStyle(fontSize: 14)),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () async {
                  await cloturerCaisse(context,
                      orgId: widget.espace.orgId, siteId: _nonClos.first['site_id'] as String, jour: '${_nonClos.first['jour']}');
                  await _verifierClotures();
                },
                child: const Text('Clôturer'),
              ),
            ]),
          );

    // Carte 1 : qui paie, quand, qui encaisse.
    final carteQui = Container(
      padding: const EdgeInsets.all(16),
      decoration: carte(),
      child: LayoutBuilder(builder: (context, c) {
        final n = c.maxWidth >= 640 ? 4 : (c.maxWidth >= 320 ? 2 : 1);
        final l = (c.maxWidth - 12 * (n - 1)) / n;
        return Wrap(spacing: 12, runSpacing: 12, children: [
          SizedBox(
            width: l,
            child: champ(
                'Payeur',
                TextField(
                  controller: _payeur,
                  onChanged: (_) => setState(() {}),
                  textCapitalization: TextCapitalization.words,
                  style: styleChamp,
                  decoration: fin(indice: 'Nom du payeur'),
                )),
          ),
          SizedBox(
            width: l,
            child: champ(
                'Date effective',
                TextField(
                  key: ValueKey(_jourPaiement),
                  readOnly: true,
                  controller: TextEditingController(text: _dateLisible(_date(_jourPaiement))),
                  style: styleChamp,
                  decoration: fin().copyWith(suffixIcon: Icon(Icons.calendar_today_outlined, size: 16, color: gris)),
                  onTap: () async {
                    final d = await _choisirDate(context, _jourPaiement, premier: DateTime.now().subtract(const Duration(days: 60)));
                    if (d != null) setState(() => _jourPaiement = d);
                  },
                )),
          ),
          // Sur téléphone : date technique et encaisseur en une ligne, sans champs grisés.
          if (n < 4)
            SizedBox(
              width: c.maxWidth,
              child: Text('Saisi le $technique · par ${_moi ?? ''}', style: TextStyle(fontSize: 12, color: gris)),
            ),
          if (n >= 4) SizedBox(
            width: l,
            child: champ(
                'Date technique',
                TextField(
                    enabled: false,
                    controller: TextEditingController(text: technique),
                    style: styleChamp.copyWith(color: gris),
                    decoration: fin(actif: false))),
          ),
          if (n >= 4) SizedBox(
            width: l,
            child: champ(
                'Encaissé par',
                TextField(
                    enabled: false,
                    controller: TextEditingController(text: _moi ?? ''),
                    style: styleChamp.copyWith(color: gris),
                    decoration: fin(actif: false))),
          ),
        ]);
      }),
    );

    // Carte 2 : mode de paiement et carnet papier.
    final carteMode = Container(
      padding: const EdgeInsets.all(16),
      decoration: carte(),
      child: LayoutBuilder(builder: (context, c) {
        final n = c.maxWidth >= 640 ? 3 : (c.maxWidth >= 320 ? 2 : 1);
        final l = (c.maxWidth - 12 * (n - 1)) / n;
        return Wrap(spacing: 12, runSpacing: 12, children: [
          SizedBox(
            width: l,
            child: champ(
              'Mode de paiement',
              MenuCompact<String>(
                largeur: l,
                valeur: _mode == 'especes' ? null : _mode,
                tous: 'Espèces',
                choix: {for (final m in modesPaiement.entries) if (m.key != 'especes') m.key: m.value},
                onChanged: (v) => setState(() => _mode = v ?? 'especes'),
              ),
            ),
          ),
          if (_mode != 'especes')
            SizedBox(
              width: l,
              child: champ(
                  _mode == 'cheque' ? 'N° du chèque' : 'Référence de la transaction',
                  TextField(
                    controller: _reference,
                    onChanged: (_) => setState(() {}),
                    style: styleMono.copyWith(fontSize: 14),
                    decoration: fin(indice: 'Obligatoire'),
                  )),
            ),
          SizedBox(
            width: l,
            child: champ(
                'Carnet',
                TextField(
                    controller: _carnet,
                    onChanged: (_) => setState(() {}),
                    style: styleChamp,
                    decoration: fin(indice: 'Ex. Vert n° 3'))),
          ),
          SizedBox(
            width: l,
            child: champ(
                'Feuille du carnet papier',
                TextField(
                    controller: _feuille,
                    onChanged: (_) => setState(() {}),
                    style: styleMono.copyWith(fontSize: 14),
                    decoration: fin(indice: '001452'))),
          ),
        ]);
      }),
    );

    // Carte 3 : les lignes du reçu.
    final recherche = SizedBox(
      width: telephone ? double.infinity : 320,
      height: 36,
      child: TextField(
        controller: _cherche,
        onChanged: (_) => setState(() {}),
        style: styleChamp,
        decoration: fin(indice: 'Ajouter un élève — nom, matricule, classe').copyWith(
          prefixIcon: Icon(Icons.search, size: 16, color: gris),
          prefixIconConstraints: const BoxConstraints(minWidth: 34),
          suffixIcon: _cherche.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(_cherche.clear),
                ),
        ),
      ),
    );
    final q = '%${_cherche.text.trim().toUpperCase()}%';
    final resultats = _cherche.text.trim().length < 2
        ? null
        : Requete(
            '''SELECT e.id, e.nom, e.prenoms, e.matricule,
                 coalesce(max(CASE WHEN a.en_cours = 1 THEN c.nom END), max(c.nom)) AS classe,
                 (SELECT p.updated_at FROM photos_eleves p WHERE p.eleve_id = e.id) AS photo_maj
               FROM eleves e
               JOIN inscriptions i ON i.eleve_id = e.id AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')
               JOIN annees_scolaires a ON a.id = i.annee_id AND (a.en_cours = 1 OR a.etat IN ('inscriptions', 'cloturee'))
               JOIN classes c ON c.id = i.classe_id
               WHERE e.organisation_id = ? AND (upper(e.nom || ' ' || e.prenoms) LIKE ? OR upper(e.prenoms || ' ' || e.nom) LIKE ?
                 OR e.matricule LIKE ? OR upper(c.nom) LIKE ?)
               GROUP BY e.id
               ORDER BY e.nom, e.prenoms LIMIT 8''',
            parametres: [widget.espace.orgId, q, q, q, q],
            builder: (context, eleves) => Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              decoration: BoxDecoration(
                color: schema.surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: schema.outlineVariant),
                boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4))],
              ),
              child: Column(children: [
                if (eleves.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Aucun élève inscrit cette année ne correspond.', style: TextStyle(fontSize: 14, color: gris)),
                  ),
                for (final e in eleves)
                  InkWell(
                    onTap: () async {
                      setState(_cherche.clear);
                      await _ajouterEleve(e['id'] as String);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(children: [
                        PhotoEleve(eleveId: e['id'] as String, nom: _nomEleve(e), version: e['photo_maj'] as String?, taille: 36),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(_nomEleve(e), style: const TextStyle(fontSize: 14)),
                            Text('${e['classe']} · ${e['matricule']}',
                                overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
                          ]),
                        ),
                        if (_lignes.any((l) => l.eleve['id'] == e['id'])) const Etat('déjà sur le reçu'),
                      ]),
                    ),
                  ),
              ]),
            ),
          );

    final aujourdhui = DateTime.now();
    Widget ligneEleve(_LigneEleve l) {
      final reste = l.frais.fold(0, (s, f) => s + _dispo(l, f));
      final freres = _freres.where((f) => f['payeur'] == l.eleve['payeur_id']).toList();
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: schema.outlineVariant))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            PhotoEleve(eleveId: l.eleve['id'] as String, nom: _nomEleve(l.eleve), version: l.eleve['photo_maj'] as String?, taille: 56),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_nomEleve(l.eleve), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Wrap(spacing: 10, children: [
                    Text('${l.inscription['classe']}', style: TextStyle(fontSize: 12, color: gris)),
                    if (l.inscription['annee_en_cours'] != 1 && l.inscription['annee_libelle'] != null)
                      Etat(l.inscription['annee_etat'] == 'cloturee' ? 'Arriéré ${l.inscription['annee_libelle']}' : 'Année ${l.inscription['annee_libelle']}',
                          ton: l.inscription['annee_etat'] == 'cloturee' ? Ton.retard : Ton.info),
                    Text('${l.eleve['matricule']}', style: styleMono.copyWith(fontSize: 12, color: gris)),
                    Text('solde ${gnf(reste)}', style: TextStyle(fontSize: 12, color: gris)),
                  ]),
                ]),
              ),
            ),
            if (!telephone) ...[
              SizedBox(
                width: 140,
                height: 36,
                child: TextField(
                  controller: l.global,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.right,
                  style: styleChamp,
                  onChanged: (_) => setState(() => _repartir(l)),
                  decoration: fin(indice: '0'),
                ),
              ),
              TextButton(onPressed: reste <= 0 ? null : () => setState(() => _solder(l)), child: const Text('Solde')),
            ],
            IconButton(
              tooltip: 'Retirer du reçu',
              icon: Icon(Icons.delete_outline, size: 18, color: gris),
              onPressed: () => setState(() => _lignes.remove(l)),
            ),
          ]),
          if (telephone)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: TextField(
                      controller: l.global,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.right,
                      onChanged: (_) => setState(() => _repartir(l)),
                      decoration: fin(indice: 'Montant versé').copyWith(suffixText: 'GNF'),
                    ),
                  ),
                ),
                TextButton(onPressed: reste <= 0 ? null : () => setState(() => _solder(l)), child: const Text('Solde')),
              ]),
            ),
          const SizedBox(height: 8),
          if (l.frais.isEmpty)
            Padding(
              padding: EdgeInsets.only(left: telephone ? 0 : 68),
              child: Text('Aucun frais configuré pour sa classe.', style: TextStyle(fontSize: 13, color: gris)),
            ),
          for (final f in l.frais)
            Padding(
              padding: EdgeInsets.only(left: telephone ? 0 : 52, top: 3, bottom: 3),
              child: Row(children: [
                SizedBox(
                  width: telephone ? 120 : 180,
                  child: Text(f.libelle, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: f.total == 0 ? 1 : ((f.paye + l.montant(f.id)) / f.total).clamp(0, 1).toDouble(),
                        minHeight: 4,
                        backgroundColor: Couleurs.doux(context),
                        color: f.reste <= 0 ? Couleurs.regle : schema.primary,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 130,
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    Text(f.reste <= 0 ? 'payé' : gnf(f.reste),
                        style: TextStyle(
                          fontSize: 13,
                          color: f.reste <= 0
                              ? Couleurs.regle
                              : (f.echeances.any((e) => e.enRetard(aujourdhui)) ? Couleurs.retard : gris),
                        )),
                    if (f.echeances.any((e) => e.enRetard(aujourdhui))) ...[
                      const SizedBox(width: 4),
                      const Tooltip(message: 'Échéance dépassée', child: Icon(Icons.warning_amber, size: 14, color: Couleurs.retard)),
                    ],
                  ]),
                ),
              ]),
            ),
          if (l.regleAnnuelle != null)
            Padding(
              padding: EdgeInsets.only(left: telephone ? 0 : 52, top: 6),
              child: Row(children: [
                Switch(
                  value: l.annuel,
                  onChanged: (v) async {
                    final frais = await situationInscription(l.inscription['id'] as String, paiementAnnuel: v);
                    setState(() {
                      l.annuel = v;
                      l.frais = frais;
                      if (v) {
                        _solder(l, sansOptions: true);
                      } else {
                        _repartir(l);
                      }
                    });
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text("Toute l'année d'un coup : ${l.regleAnnuelle!['libelle']}",
                      style: const TextStyle(fontSize: 13)),
                ),
              ]),
            ),
          if (freres.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(left: telephone ? 0 : 52, top: 6),
              child: InkWell(
                onTap: () async {
                  for (final f in freres) {
                    await _ajouterEleve(f['id'] as String);
                  }
                },
                child: Row(children: [
                  Icon(Icons.group_outlined, size: 14, color: gris),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                        freres.length == 1
                            ? 'Ajouter ${freres.first['prenoms']} ${freres.first['nom']}, même payeur'
                            : 'Ajouter les ${freres.length} autres enfants de ${_payeur.text.trim().isEmpty ? 'ce payeur' : _payeur.text.trim()}',
                        style: TextStyle(fontSize: 13, color: gris, decoration: TextDecoration.underline)),
                  ),
                ]),
              ),
            ),
        ]),
      );
    }

    final carteLignes = Container(
      decoration: carte(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Lignes du reçu', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(width: 12),
                Text('${_lignes.length} élève${_lignes.length > 1 ? 's' : ''}', style: TextStyle(fontSize: 14, color: gris)),
              ]),
              recherche,
            ],
          ),
        ),
        ?resultats,
        Divider(height: 1, color: schema.outlineVariant),
        if (_lignes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Text('Ajouter un élève pour commencer.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: gris)),
          ),
        for (final l in _lignes) ligneEleve(l),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _recus.length >= modesPaiement.length ? null : _secondMode,
                icon: const Icon(Icons.add, size: 16),
                label: Text(_recus.length < 2 ? 'Second mode de paiement' : 'Autre mode de paiement'),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                  Text('Total du reçu', style: TextStyle(fontSize: 14, color: gris)),
                  const SizedBox(width: 10),
                  Text(gnf(_total), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ]),
                if (_recus.length > 1)
                  Text('Total versé (${_recus.length} reçus) : ${gnf(_totalTous)}', style: TextStyle(fontSize: 12, color: gris)),
              ]),
            ],
          ),
        ),
      ]),
    );

    final apercu = _ApercuRecu(
      ecole: _ecole,
      lieu: [_site, _ville].whereType<String>().join(' · '),
      carnet: _carnet.text.trim(),
      feuille: _feuille.text.trim(),
      payeur: _payeur.text.trim(),
      dateEffective: _dateLisible(_date(_jourPaiement)),
      dateTechnique: technique.replaceFirst(' à ', ' '),
      mode: modesPaiement[_mode] ?? _mode,
      reference: _mode == 'especes' ? '' : _reference.text.trim(),
      lignes: [
        for (final l in _lignes)
          if (l.total > 0) ('${l.eleve['nom']} ${l.eleve['prenoms']}', '${l.inscription['classe']}', l.total),
      ],
      total: _total,
      encaissePar: _moi ?? '',
    );

    final onglets = _recus.length < 2
        ? null
        : Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < _recus.length; i++)
              Material(
                color: i == _actif ? schema.surface : Couleurs.doux(context),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                  side: BorderSide(color: i == _actif ? schema.onSurface : schema.outlineVariant),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => setState(() => _actif = i),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(12, 6, i == 0 ? 12 : 4, 6),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('Reçu ${i + 1} · ${modesPaiement[_recus[i].mode]}',
                          style: TextStyle(fontSize: 14, fontWeight: i == _actif ? FontWeight.w500 : FontWeight.w400)),
                      const SizedBox(width: 8),
                      Text(gnf(_recus[i].lignes.fold<int>(0, (s, l) => s + l.total)), style: TextStyle(fontSize: 12, color: gris)),
                      if (i > 0)
                        InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => setState(() {
                            _recus.removeAt(i);
                            _actif = 0;
                          }),
                          child: Padding(padding: const EdgeInsets.all(4), child: Icon(Icons.close, size: 14, color: gris)),
                        ),
                    ]),
                  ),
                ),
              ),
          ]);

    final gauche = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (alerte != null) ...[alerte, const SizedBox(height: 12)],
      carteQui,
      const SizedBox(height: 12),
      if (onglets != null) ...[onglets, const SizedBox(height: 12)],
      carteMode,
      const SizedBox(height: 12),
      carteLignes,
    ]);

    // Téléphone : total et bouton toujours visibles en bas de l'écran.
    final barreTelephone = Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(color: schema.surface, border: Border(top: BorderSide(color: schema.outlineVariant))),
      child: SafeArea(
        top: false,
        child: Row(children: [
          Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_recus.length > 1 ? 'Total versé (${_recus.length} reçus)' : 'Total du reçu', style: TextStyle(fontSize: 11, color: gris)),
            Text(gnf(_recus.length > 1 ? _totalTous : _total), style: styleMono.copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 44,
              child: FilledButton.icon(
                onPressed: _envoi ? null : _valider,
                icon: const Icon(Icons.print_outlined, size: 16),
                label: Text(_envoi ? 'Enregistrement…' : 'Encaisser et imprimer'),
              ),
            ),
          ),
        ]),
      ),
    );

    return Scaffold(
      appBar: Navigator.of(context).canPop() ? AppBar(toolbarHeight: 44) : null,
      bottomNavigationBar: telephone ? barreTelephone : null,
      body: LayoutBuilder(builder: (context, c) {
        final large = c.maxWidth >= 1000;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1600),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(telephone ? 12 : 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                enTete,
                const SizedBox(height: 16),
                if (large)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: gauche),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 336,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        apercu,
                        const SizedBox(height: 12),
                        bouton,
                        const SizedBox(height: 8),
                        Text('Fonctionne sans internet : le reçu part au serveur dès que possible.',
                            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: gris)),
                      ]),
                    ),
                  ])
                else ...[
                  gauche,
                  if (!telephone) ...[
                    const SizedBox(height: 12),
                    bouton,
                  ],
                ],
              ]),
            ),
          ),
        );
      }),
    );
  }

  /// Répartit le montant saisi : inscription, puis scolarité tranche par tranche.
  void _repartir(_LigneEleve l) {
    var m = int.tryParse(l.global.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    final tries = [...l.frais]..sort((a, b) => ordreTypes.indexOf(a.type).compareTo(ordreTypes.indexOf(b.type)));
    for (final f in tries) {
      final d = _dispo(l, f);
      final part = m <= 0 ? 0 : (m < d ? m : d);
      l.montants[f.id]!.text = part == 0 ? '' : '$part';
      m -= part;
    }
  }

  /// Tout ce qui reste dû (sans les options, pour la remise annuelle).
  void _solder(_LigneEleve l, {bool sansOptions = false}) {
    final reste = l.frais.where((f) => !sansOptions || f.type != 'optionnel').fold(0, (s, f) => s + _dispo(l, f));
    l.global.text = '$reste';
    _repartir(l);
  }
}

/// Le reçu tel qu'il sera imprimé, rempli pendant la saisie.
class _ApercuRecu extends StatelessWidget {
  const _ApercuRecu({
    required this.ecole,
    required this.lieu,
    required this.carnet,
    required this.feuille,
    required this.payeur,
    required this.dateEffective,
    required this.dateTechnique,
    required this.mode,
    required this.reference,
    required this.lignes,
    required this.total,
    required this.encaissePar,
  });

  final String? ecole;
  final String lieu;
  final String carnet;
  final String feuille;
  final String payeur;
  final String dateEffective;
  final String dateTechnique;
  final String mode;
  final String reference;
  final List<(String, String, int)> lignes;
  final int total;
  final String encaissePar;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final petit = TextStyle(fontSize: 12, color: gris);
    Widget kv(String a, String b) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(children: [
            Expanded(child: Text(a, style: petit)),
            Text(b, style: const TextStyle(fontSize: 12)),
          ]),
        );
    Widget trait() => Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1, color: schema.outlineVariant));
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: schema.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: schema.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text((ecole ?? 'École').toUpperCase(),
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: .3)),
        if (lieu.isNotEmpty) Text(lieu, textAlign: TextAlign.center, style: petit),
        const SizedBox(height: 6),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            decoration: BoxDecoration(border: Border.all(color: schema.outline), borderRadius: BorderRadius.circular(3)),
            child: const Text('ORIGINAL', style: TextStyle(fontSize: 12, letterSpacing: .6)),
          ),
        ),
        trait(),
        Text("Numéro attribué à l'enregistrement", style: petit),
        const SizedBox(height: 2),
        Text('Carnet ${carnet.isEmpty ? '–' : carnet} — feuille ${feuille.isEmpty ? '…' : feuille}',
            style: styleMono.copyWith(fontSize: 12, color: gris)),
        trait(),
        kv('Payeur', payeur.isEmpty ? '—' : payeur),
        kv('Date effective', dateEffective),
        kv('Date technique', dateTechnique),
        kv('Mode', mode),
        if (reference.isNotEmpty) kv('Référence', reference),
        trait(),
        if (lignes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('Aucune ligne', textAlign: TextAlign.center, style: petit.copyWith(fontSize: 13)),
          ),
        for (final (eleve, classe, montant) in lignes)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: eleve, style: const TextStyle(fontSize: 12)),
                  TextSpan(text: ' ($classe)', style: petit),
                ])),
              ),
              Text(_nombre(montant), style: const TextStyle(fontSize: 12)),
            ]),
          ),
        trait(),
        Row(children: [
          const Expanded(child: Text('TOTAL', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
          Text(gnf(total), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 10),
        Text('Encaissé par ${encaissePar.isEmpty ? '…' : encaissePar}', style: petit),
        const SizedBox(height: 12),
        Container(height: 1, color: schema.outlineVariant.withValues(alpha: .6)),
        const SizedBox(height: 6),
        Text('Signature', style: petit),
      ]),
    );
  }
}

// Reçu --------------------------------------------------------------------------

Future<List<LigneRecu>> _lignesRecu(String encaissementId) async => [
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

/// Imprime un reçu. Chaque impression est comptée : la deuxième porte « DUPLICATA ».
/// Le PDF d'un reçu. Chaque exemplaire (imprimé ou partagé) est compté :
/// à partir du deuxième, il porte « DUPLICATA ».
Future<(Uint8List, String)> _pdfRecu(String encaissementId) async {
  final r = await db.get('SELECT * FROM encaissements WHERE id = ?', [encaissementId]);
  final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [r['organisation_id']]);
  final par = await db.getOptional(
      'SELECT nom_complet FROM personnel WHERE user_id = ? AND organisation_id = ?', [r['encaisse_par'], r['organisation_id']]);
  final duplicata = (r['impressions'] as int? ?? 0) > 0;
  final pdf = await recuPdf(
    ecole: Map.of(ecole),
    recu: Map.of(r),
    lignes: await _lignesRecu(encaissementId),
    encaissePar: '${par?['nom_complet'] ?? ''}',
    duplicata: duplicata,
    images: await _imagesEcole(r['organisation_id']),
  );
  await _modifier('encaissements', encaissementId, {'impressions': (r['impressions'] as int? ?? 0) + 1});
  return (pdf, '${r['numero']}${duplicata ? '-duplicata' : ''}');
}

Future<void> _imprimerRecu(String encaissementId) async {
  final (pdf, nom) = await _pdfRecu(encaissementId);
  await Printing.layoutPdf(onLayout: (_) async => pdf, name: nom);
}

/// Partage le PDF du reçu (WhatsApp, e-mail…) : sur téléphone, la feuille de partage.
Future<void> _partagerRecu(String encaissementId) async {
  final (pdf, nom) = await _pdfRecu(encaissementId);
  await Printing.sharePdf(bytes: pdf, filename: '$nom.pdf');
}

/// Le numéro à qui envoyer le reçu : le payeur, sinon le responsable financier
/// puis le tuteur principal d'un élève du reçu.
Future<String?> _telephonePayeur(Map<String, Object?> r) async {
  if (r['payeur_contact_id'] != null) {
    final c = await db.getOptional('SELECT telephone FROM contacts WHERE id = ?', [r['payeur_contact_id']]);
    if (c?['telephone'] != null) return '${c!['telephone']}';
  }
  final c = await db.getOptional(
      '''SELECT ct.telephone FROM lignes_encaissement l
         JOIN eleves_contacts ec ON ec.eleve_id = l.eleve_id JOIN contacts ct ON ct.id = ec.contact_id
         WHERE l.encaissement_id = ? AND ct.telephone IS NOT NULL
         ORDER BY ec.responsable_financier DESC, ec.tuteur_principal DESC LIMIT 1''',
      [r['id']]);
  return c?['telephone'] as String?;
}

/// Le message WhatsApp d'un reçu : l'école, le reçu, ce qui a été payé, ce qu'il reste.
Future<String> _messageRecu(Map<String, Object?> r) async {
  final ecole = await db.get('SELECT nom, nom_officiel FROM organisations WHERE id = ?', [r['organisation_id']]);
  final lignes = await db.getAll(
      '''SELECT l.eleve_id, l.montant_gnf, f.libelle AS frais, e.nom, e.prenoms, c.nom AS classe
         FROM lignes_encaissement l JOIN eleves e ON e.id = l.eleve_id JOIN frais f ON f.id = l.frais_id
         JOIN inscriptions i ON i.id = l.inscription_id JOIN classes c ON c.id = i.classe_id
         WHERE l.encaissement_id = ? ORDER BY e.nom, e.prenoms''',
      [r['id']]);
  final parEleve = <String, List<Map<String, Object?>>>{};
  for (final l in lignes) {
    parEleve.putIfAbsent(l['eleve_id'] as String, () => []).add(l);
  }
  Map<String, ({int du, int paye, int retard})> soldes = const {};
  try {
    soldes = await soldesDesEleves(r['organisation_id'] as String);
  } catch (_) {}
  final b = StringBuffer()
    ..writeln('${ecole['nom_officiel'] ?? ecole['nom']}')
    ..writeln('Reçu n° ${r['numero']} du ${_dateLisible(r['date_effective'])}')
    ..writeln('Montant reçu : ${gnf(r['total_gnf'])} (${modesPaiement[r['mode']] ?? r['mode']})')
    ..writeln('Payé par : ${r['payeur_nom']}');
  for (final e in parEleve.entries) {
    final l = e.value.first;
    b.writeln('');
    b.writeln('${l['prenoms']} ${l['nom']} (${l['classe']})');
    for (final x in e.value) {
      b.writeln('- ${x['frais']} : ${gnf(x['montant_gnf'])}');
    }
    final s = soldes[e.key];
    if (s != null) b.writeln(s.du - s.paye > 0 ? 'Reste à payer pour l\'année : ${gnf(s.du - s.paye)}' : 'Année soldée. Merci !');
  }
  if (r['statut'] == 'annule') b.writeln('\nATTENTION : ce reçu a été annulé.');
  return b.toString().trim();
}

/// Ouvre WhatsApp vers le payeur avec le message du reçu : il ne reste qu'à appuyer sur « Envoyer ».
Future<void> _envoyerRecuWhatsApp(BuildContext context, Map<String, Object?> r) async {
  final messager = ScaffoldMessenger.of(context);
  final tel = await _telephonePayeur(r);
  if (!context.mounted) return;
  final champ = TextEditingController(text: tel ?? '');
  final ok = await _formulaire(context, 'Envoyer le reçu par WhatsApp', (_) => [
        TextField(
          controller: champ,
          keyboardType: TextInputType.phone,
          decoration: _champ('Numéro WhatsApp', aide: tel == null ? 'Aucun numéro trouvé pour ce payeur' : 'Numéro du payeur, modifiable'),
        ),
        const Text("WhatsApp s'ouvre avec le message prêt ; appuyez sur « Envoyer ». Sur téléphone, « Partager le PDF » "
            'envoie aussi le reçu lui-même.', style: TextStyle(fontSize: 12)),
      ], valider: () => 'Ouvrir WhatsApp');
  if (!ok) return;
  final n = champ.text.replaceAll(RegExp(r'[^0-9+]'), '');
  if (n.length < 8) {
    messager.showSnackBar(const SnackBar(content: Text('Numéro incomplet.')));
    return;
  }
  final international = n.startsWith('+') ? n.substring(1) : (n.length == 9 ? '224$n' : n);
  final texte = await _messageRecu(r);
  final ouvert = await launchUrl(Uri.parse('https://wa.me/$international?text=${Uri.encodeComponent(texte)}'),
      mode: LaunchMode.externalApplication);
  if (!ouvert) messager.showSnackBar(const SnackBar(content: Text("Impossible d'ouvrir WhatsApp sur cet appareil.")));
}

class RecuScreen extends StatelessWidget {
  const RecuScreen({super.key, required this.espace, required this.encaissementId});

  final Espace espace;
  final String encaissementId;

  Future<List<LigneRecu>> _lignes() => _lignesRecu(encaissementId);

  Future<void> _imprimer(BuildContext context, Map<String, Object?> r) => _imprimerRecu(encaissementId);

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

  /// Corriger la date d'un reçu mal daté (horloge de l'ordinateur fausse, erreur de saisie) :
  /// réservé au droit « annuler un reçu », motivé, tracé ; impossible sur une journée clôturée.
  Future<void> _corrigerDate(BuildContext context, Map<String, Object?> r) async {
    final messager = ScaffoldMessenger.of(context);
    var paye = DateTime.tryParse('${r['date_effective']}') ?? DateTime.now();
    var caisse = DateTime.tryParse('${r['jour_caisse'] ?? r['date_effective']}') ?? DateTime.now();
    final motif = TextEditingController();
    Widget choix(String libelle, DateTime valeur, ValueChanged<DateTime> change) => InkWell(
          onTap: () async {
            final d = await _choisirDate(context, valeur,
                premier: DateTime.now().subtract(const Duration(days: 365)), dernier: DateTime.now());
            if (d != null) change(d);
          },
          child: InputDecorator(
            decoration: _champ(libelle).copyWith(suffixIcon: const Icon(Icons.event_outlined, size: 18)),
            child: Text(_dateLisible(_date(valeur))),
          ),
        );
    final ok = await _formulaire(context, 'Corriger la date du reçu ${r['numero']}', (maj) => [
          const Text("Pour un reçu mal daté (ordinateur qui n'était pas à la bonne date, erreur de saisie). "
              "La date d'origine reste dans l'historique du reçu."),
          Row(children: [
            Expanded(child: choix('Payé le', paye, (d) => maj(() => paye = d))),
            const SizedBox(width: 12),
            Expanded(child: choix('Entré en caisse le', caisse, (d) => maj(() => caisse = d))),
          ]),
          TextField(
              controller: motif,
              decoration: _champ('Motif', aide: "Obligatoire. Par exemple : l'ordinateur indiquait le 20/10")),
        ]);
    if (!ok) return;
    if (motif.text.trim().length < 3) {
      messager.showSnackBar(const SnackBar(content: Text('Le motif est obligatoire.')));
      return;
    }
    if (paye.isAfter(caisse)) {
      messager.showSnackBar(const SnackBar(content: Text("Le paiement ne peut pas être après son entrée en caisse.")));
      return;
    }
    final close = await db.getOptional(
        '''SELECT 1 FROM clotures_caisse WHERE organisation_id = ? AND site_id = ? AND encaisse_par = ? AND jour IN (?, ?)''',
        [r['organisation_id'], r['site_id'], r['encaisse_par'], r['jour_caisse'] ?? r['date_effective'], _date(caisse)]);
    if (close != null) {
      messager.showSnackBar(const SnackBar(content: Text('Cette journée de caisse est clôturée : la date ne peut plus être corrigée.')));
      return;
    }
    await _modifier('encaissements', encaissementId,
        {'date_effective': _date(paye), 'jour_caisse': _date(caisse), 'motif_correction_date': motif.text.trim()});
    messager.showSnackBar(const SnackBar(content: Text('Date du reçu corrigée.')));
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
                return ListView(padding: EdgeInsets.symmetric(horizontal: ((MediaQuery.sizeOf(context).width - 680) / 2).clamp(16.0, double.infinity), vertical: 16), children: [
                  if (annule)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: ListTile(
                          leading: const Icon(Icons.block), title: const Text('Reçu annulé'), subtitle: Text('${r['motif_annulation']}')),
                    ),
                  _FicheRecu(r: r, lignes: lignes),
                  const SizedBox(height: 16),
                  // Une seule action en vue : imprimer. Le reste attend derrière « Plus ».
                  Row(children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _imprimer(context, r),
                        icon: const Icon(Icons.print),
                        label: Text((r['impressions'] as int? ?? 0) == 0 ? 'Imprimer le reçu' : 'Réimprimer (duplicata)'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    MenuAnchor(
                      alignmentOffset: const Offset(0, 4),
                      builder: (context, menu, _) => OutlinedButton.icon(
                        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                        icon: const Icon(Icons.more_horiz),
                        label: const Text('Plus'),
                      ),
                      menuChildren: [
                        // Envoyer le reçu au parent : gratuit, depuis le WhatsApp de ce poste.
                        MenuItemButton(
                            leadingIcon: const Icon(Icons.chat_outlined),
                            onPressed: () => _envoyerRecuWhatsApp(context, r),
                            child: const Text('Envoyer par WhatsApp')),
                        MenuItemButton(
                            leadingIcon: const Icon(Icons.share_outlined),
                            onPressed: () => _partagerRecu(encaissementId),
                            child: const Text('Partager le PDF')),
                        if (!annule) ...[
                          const Divider(height: 1),
                          MenuItemButton(
                              leadingIcon: const Icon(Icons.currency_exchange),
                              onPressed: () => demanderRemboursement(context, r),
                              child: const Text('Demander un remboursement')),
                        ],
                        if (!annule && s.data![1] as bool)
                          MenuItemButton(
                              leadingIcon: const Icon(Icons.edit_calendar_outlined),
                              onPressed: () => _corrigerDate(context, r),
                              child: const Text('Corriger la date')),
                        if (peutAnnuler)
                          MenuItemButton(
                              leadingIcon: Icon(Icons.block, color: Theme.of(context).colorScheme.error),
                              onPressed: () => _annuler(context, r),
                              child: Text('Annuler ce reçu', style: TextStyle(color: Theme.of(context).colorScheme.error))),
                      ],
                    ),
                  ]),
                ]);
              },
            ),
          );
        },
      );
}

/// Le reçu présenté comme sur papier : le montant en grand, les informations
/// sur des lignes « libellé — valeur », puis ce qui a été payé et le total.
class _FicheRecu extends StatelessWidget {
  const _FicheRecu({required this.r, required this.lignes});

  final Map<String, Object?> r;
  final List<LigneRecu> lignes;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = schema.outlineVariant;
    Widget info(String libelle, String valeur, {Color? couleur}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 140, child: Text(libelle, style: TextStyle(fontSize: 13, color: gris))),
            Expanded(child: Text(valeur, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: couleur))),
          ]),
        );
    final avertissements = [
      if (r['date_douteuse'] == 1) "Date à vérifier : l'ordinateur n'était pas à la bonne date",
      if (r['confirmation'] == 'en_attente') "Sous réserve d'encaissement",
    ];
    return Container(
      decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: bordure)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Montant reçu', style: TextStyle(fontSize: 12, color: gris)),
            const SizedBox(height: 2),
            Text(gnf(r['total_gnf']), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.payments_outlined, size: 16),
                  label: Text('${modesPaiement[r['mode']] ?? r['mode']}')),
              Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.print_outlined, size: 16),
                  label: Text((r['impressions'] as int? ?? 0) == 0 ? 'Pas encore imprimé' : 'Imprimé ${r['impressions']} fois')),
            ]),
          ]),
        ),
        for (final a in avertissements)
          Container(
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: schema.errorContainer, borderRadius: BorderRadius.circular(8)),
            child: Text(a, style: TextStyle(fontSize: 13, color: schema.onErrorContainer)),
          ),
        Divider(height: 1, color: bordure),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Column(children: [
            info('Payé par', '${r['payeur_nom']}'),
            info('Date du paiement', _dateLisible(r['date_effective'])),
            if (r['jour_caisse'] != null && r['jour_caisse'] != r['date_effective']) info('Entré en caisse le', _dateLisible(r['jour_caisse'])),
            if (r['date_initiale'] != null)
              info('Date corrigée', 'au départ ${_dateLisible(r['date_initiale'])} · ${r['motif_correction_date'] ?? ''}'),
            if (r['reference'] != null) info('Référence', '${r['reference']}'),
            if (r['feuille'] != null) info('Reçu papier', '${r['carnet'] ?? ''} n° ${r['feuille']}'),
          ]),
        ),
        Divider(height: 1, color: bordure),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Text('DÉTAIL', style: TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w600, color: gris)),
        ),
        for (final x in lignes)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(x.frais, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  Text('${x.eleve} · ${x.classe}', style: TextStyle(fontSize: 12, color: gris)),
                ]),
              ),
              Text(gnf(x.montant), style: const TextStyle(fontSize: 14)),
            ]),
          ),
        Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
              color: schema.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12))),
          child: Row(children: [
            const Expanded(child: Text('Total', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
            Text(gnf(r['total_gnf']), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
    );
  }
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

  String? _encaisseur;
  String? _modeFiltre;

  @override
  Widget build(BuildContext context) {
    final jour = _date(_jour);
    return Scaffold(
      body: Requete(
        '''SELECT e.*, p.nom_complet AS encaisseur,
             (SELECT count(DISTINCT l.eleve_id) FROM lignes_encaissement l WHERE l.encaissement_id = e.id) AS nb_eleves,
             (SELECT el.nom || ' ' || el.prenoms FROM lignes_encaissement l JOIN eleves el ON el.id = l.eleve_id
              WHERE l.encaissement_id = e.id LIMIT 1) AS eleve
           FROM encaissements e
           LEFT JOIN personnel p ON p.user_id = e.encaisse_par AND p.organisation_id = e.organisation_id
           WHERE e.organisation_id = ? AND e.jour_caisse = ?
           ORDER BY e.created_at''',
        parametres: [widget.espace.orgId, jour],
        builder: (context, recus) => Requete(
          // Sorties du jour : remboursements versés et dépenses sorties de la caisse.
          // Le tri porte sur l'ensemble (SQLite refuse un ORDER BY directement après UNION sur ces vues).
          '''SELECT * FROM (
             SELECT 'remboursement' AS genre, r.id AS id, r.montant_gnf AS montant_gnf, r.mode AS mode,
                    r.beneficiaire AS beneficiaire, r.motif AS motif, NULL AS categorie,
                    r.updated_at AS updated_at, r.updated_at AS created_at, p.nom_complet AS par
             FROM remboursements r
             LEFT JOIN personnel p ON p.user_id = r.verse_par AND p.organisation_id = r.organisation_id
             WHERE r.organisation_id = ? AND r.statut = 'verse' AND r.verse_le = ?
             UNION ALL
             SELECT 'depense' AS genre, d.id AS id, d.montant_gnf AS montant_gnf, 'especes' AS mode,
                    d.beneficiaire AS beneficiaire, d.motif AS motif, d.categorie AS categorie,
                    d.updated_at AS updated_at, d.updated_at AS created_at, p.nom_complet AS par
             FROM depenses d
             LEFT JOIN personnel p ON p.user_id = d.sortie_par AND p.organisation_id = d.organisation_id
             WHERE d.organisation_id = ? AND d.statut = 'sortie' AND d.sortie_le = ?
             ) ORDER BY updated_at''',
          parametres: [widget.espace.orgId, jour, widget.espace.orgId, jour],
          builder: (context, sorties) => _contenu(context, recus, sorties),
        ),
      ),
    );
  }

  Widget _contenu(BuildContext context, Lignes tousRecus, Lignes toutesSorties) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final largeur = MediaQuery.sizeOf(context).width;
    final telephone = largeur < 640;
    final aujourdhui = _date(DateTime.now()) == _date(_jour);

    final encaisseurs = <String>{
      for (final r in tousRecus)
        if (r['encaisseur'] != null) r['encaisseur'] as String,
    }.toList()
      ..sort();
    final recus = tousRecus
        .where((r) => (_encaisseur == null || r['encaisseur'] == _encaisseur) && (_modeFiltre == null || r['mode'] == _modeFiltre))
        .toList();
    final sorties = toutesSorties
        .where((r) => (_encaisseur == null || r['par'] == _encaisseur) && (_modeFiltre == null || r['mode'] == _modeFiltre))
        .toList();
    final valides = recus.where((r) => r['statut'] == 'valide').toList();
    final parMode = <String, int>{};
    for (final r in valides) {
      parMode[r['mode'] as String] = (parMode[r['mode']] ?? 0) + (r['total_gnf'] as int? ?? 0);
    }
    final entrees = parMode.values.fold(0, (s, v) => s + v);
    final totalSorties = sorties.fold(0, (s, r) => s + (r['montant_gnf'] as int? ?? 0));
    final carnets = <String, List<String>>{};
    for (final r in recus.where((r) => r['feuille'] != null)) {
      carnets.putIfAbsent('${r['carnet'] ?? ''}', () => []).add(r['feuille'] as String);
    }

    // Le livre de caisse : reçus, remboursements et dépenses, dans l'ordre de la journée.
    final mouvements = <(String, Map<String, Object?>)>[
      for (final r in recus) ('recu', r),
      for (final r in sorties) ('sortie', r),
    ]..sort((a, b) => '${a.$2['created_at'] ?? a.$2['updated_at']}'.compareTo('${b.$2['created_at'] ?? b.$2['updated_at']}'));
    String heure(Object? iso) {
      final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
      return d == null ? '—' : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }

    final enTete = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 10,
      children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 4, children: [
          const Text('Journal de caisse', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -.2)),
          Text('${aujourdhui ? "aujourd'hui" : 'journée du ${_dateLisible(_date(_jour))}'} · ${valides.length} reçu${valides.length > 1 ? 's' : ''}',
              style: TextStyle(fontSize: 14, color: gris)),
        ]),
        Wrap(spacing: 8, runSpacing: 8, children: [
          Requete(
            "SELECT count(*) AS n FROM remboursements WHERE organisation_id = ? AND statut IN ('demande', 'autorise')",
            parametres: [widget.espace.orgId],
            builder: (context, x) => OutlinedButton.icon(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => RemboursementsScreen(espace: widget.espace))),
              icon: const Icon(Icons.currency_exchange, size: 16),
              label: Text((x.first['n'] as int? ?? 0) > 0 ? 'Remboursements · ${x.first['n']}' : 'Remboursements'),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DepensesScreen(espace: widget.espace))),
            icon: const Icon(Icons.outbox_outlined, size: 16),
            label: const Text('Dépenses'),
          ),
          // Un lecteur consulte le journal sans encaisser.
          if (widget.espace.fondateur || widget.espace.droits.contains('encaisser'))
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => EncaisserScreen(espace: widget.espace))),
              icon: const Icon(Icons.point_of_sale_outlined, size: 16),
              label: const Text('Encaisser'),
            ),
        ]),
      ],
    );

    // Encaisseur et mode : côte à côte sur grand écran, dans « Filtres » sur téléphone.
    List<Widget> menusJournal(double largeur, VoidCallback rafraichir) => [
          MenuCompact<String>(
            largeur: largeur > 0 ? largeur : 200,
            valeur: _encaisseur,
            tous: 'Tous les encaisseurs',
            choix: {for (final e in encaisseurs) e: e},
            onChanged: (v) {
              setState(() => _encaisseur = v);
              rafraichir();
            },
          ),
          MenuCompact<String>(
            largeur: largeur > 0 ? largeur : 180,
            valeur: _modeFiltre,
            tous: 'Tous les modes',
            choix: modesPaiement,
            onChanged: (v) {
              setState(() => _modeFiltre = v);
              rafraichir();
            },
          ),
        ];
    final filtres = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Container(
        height: 36,
        decoration: BoxDecoration(
          color: schema.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: schema.outlineVariant),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: 'Jour précédent',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_left, size: 18),
            onPressed: () => setState(() => _jour = _jour.subtract(const Duration(days: 1))),
          ),
          InkWell(
            onTap: () async {
              final d = await _choisirDate(context, _jour, premier: DateTime(2024));
              if (d != null) setState(() => _jour = d);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('${_dateLisible(_date(_jour))}${aujourdhui ? " — aujourd'hui" : ''}', style: const TextStyle(fontSize: 14)),
            ),
          ),
          IconButton(
            tooltip: 'Jour suivant',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_right, size: 18),
            onPressed: aujourdhui ? null : () => setState(() => _jour = _jour.add(const Duration(days: 1))),
          ),
        ]),
      ),
      if (telephone)
        BoutonFiltres(
          actifs: [_encaisseur, _modeFiltre].where((x) => x != null).length,
          menus: menusJournal,
          reinitialiser: () => setState(() {
            _encaisseur = null;
            _modeFiltre = null;
          }),
        )
      else
        ...menusJournal(0, () {}),
      if (!telephone && (_encaisseur != null || _modeFiltre != null))
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: gris),
          onPressed: () => setState(() {
            _encaisseur = null;
            _modeFiltre = null;
          }),
          icon: const Icon(Icons.close, size: 14),
          label: const Text('Réinitialiser'),
        ),
    ]);

    const entete = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);
    final colonnesLarges = largeur >= 1024;
    Widget cellule(double? l, Widget e, {TextAlign? a}) {
      final c = Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: e);
      return l == null ? Expanded(child: c) : SizedBox(width: l, child: c);
    }

    var solde = 0;
    final lignes = <Widget>[];
    for (final (sens, m) in mouvements) {
      final annule = m['statut'] == 'annule';
      final montant = (sens == 'recu' ? m['total_gnf'] : m['montant_gnf']) as int? ?? 0;
      if (!annule) solde += sens == 'recu' ? montant : -montant;
      lignes.add(InkWell(
        onTap: sens == 'recu'
            ? () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => RecuScreen(espace: widget.espace, encaissementId: m['id'] as String)))
            : null,
        child: Opacity(
          opacity: annule ? .55 : 1,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: schema.outlineVariant))),
            child: Row(children: [
              if (!telephone) cellule(64, Text(heure(m['created_at'] ?? m['updated_at']), style: const TextStyle(fontSize: 14))),
              cellule(
                110,
                sens == 'recu'
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${m['feuille'] ?? m['numero'].toString().split('-').last}',
                            overflow: TextOverflow.ellipsis, style: styleMono.copyWith(fontSize: 14)),
                        if (m['carnet'] != null) Text('${m['carnet']}', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
                      ])
                    : Text('Sortie', style: styleMono.copyWith(fontSize: 12, color: gris)),
              ),
              cellule(
                null,
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                      sens == 'recu'
                          ? '${m['payeur_nom']}'
                          : m['genre'] == 'depense'
                              ? 'Dépense · ${m['categorie']}${m['beneficiaire'] != null ? ' · ${m['beneficiaire']}' : ''}'
                              : 'Remboursement · ${m['beneficiaire'] ?? ''}',
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                  if (sens == 'recu' && m['jour_caisse'] != null && m['date_effective'] != m['jour_caisse'])
                    Text('payé le ${_dateLisible(m['date_effective'])}', style: const TextStyle(fontSize: 12, color: Couleurs.attente)),
                  if (m['date_douteuse'] == 1)
                    const Text("date à vérifier : horloge de l'ordinateur", style: TextStyle(fontSize: 12, color: Couleurs.retard)),
                  if (m['apres_cloture'] == 1)
                    const Text('saisi après la clôture', style: TextStyle(fontSize: 12, color: Couleurs.attente)),
                  if (m['confirmation'] == 'en_attente')
                    const Text("sous réserve d'encaissement", style: TextStyle(fontSize: 12, color: Couleurs.attente)),
                  if (sens == 'recu' && (m['nb_eleves'] as int? ?? 0) == 0)
                    const Text('sans détail : lignes non enregistrées', style: TextStyle(fontSize: 12, color: Couleurs.retard)),
                ]),
              ),
              if (colonnesLarges)
                cellule(
                  null,
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                        sens == 'recu'
                            ? ((m['nb_eleves'] as int? ?? 0) > 1 ? '${m['nb_eleves']} élèves' : '${m['eleve'] ?? ''}')
                            : '${m['motif'] ?? ''}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: gris)),
                    Text('${modesPaiement[m['mode']] ?? m['mode']}${m['reference'] != null ? ' · ${m['reference']}' : ''}',
                        overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
                  ]),
                ),
              if (!telephone)
                cellule(130, Text('${(sens == 'recu' ? m['encaisseur'] : m['par']) ?? ''}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
              cellule(
                telephone ? 110 : 128,
                Text(sens == 'recu' ? gnf(montant) : '',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500, decoration: annule ? TextDecoration.lineThrough : null)),
              ),
              if (!telephone)
                cellule(
                  128,
                  Text(sens == 'sortie' ? '− ${_nombre(montant)}' : '', textAlign: TextAlign.right, style: const TextStyle(fontSize: 14)),
                ),
              if (!telephone)
                cellule(
                  128,
                  Text(_nombre(solde),
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 14, color: solde < 0 ? Couleurs.retard : gris)),
                ),
              SizedBox(width: 32, child: annule ? const Icon(Icons.block, size: 16, color: Couleurs.retard) : null),
            ]),
          ),
        ),
      ));
    }

    final tableau = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: schema.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: schema.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 36,
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: schema.outlineVariant))),
          child: Row(children: [
            if (!telephone) cellule(64, const Text('Heure', style: entete)),
            cellule(110, const Text('Pièce', style: entete)),
            cellule(null, const Text('Tiers', style: entete)),
            if (colonnesLarges) cellule(null, const Text('Détail', style: entete)),
            if (!telephone) cellule(130, const Text('Par', style: entete)),
            cellule(telephone ? 110 : 128, const Text('Entrée', textAlign: TextAlign.right, style: entete)),
            if (!telephone) cellule(128, const Text('Sortie', textAlign: TextAlign.right, style: entete)),
            if (!telephone) cellule(128, const Text('Solde', textAlign: TextAlign.right, style: entete)),
            const SizedBox(width: 32),
          ]),
        ),
        if (mouvements.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Text('Aucun mouvement ce jour-là.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: gris)),
          ),
        ...lignes,
        if (mouvements.isNotEmpty)
          Container(
            color: Couleurs.doux(context).withValues(alpha: .5),
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(children: [
              if (!telephone) cellule(64, const SizedBox()),
              cellule(null, Text('Arrêté au ${_dateLisible(_date(_jour))}', style: entete)),
              if (colonnesLarges) cellule(null, const SizedBox()),
              if (!telephone) cellule(110 + 130, const SizedBox()),
              cellule(telephone ? 110 : 128, Text(gnf(entrees), textAlign: TextAlign.right, style: entete)),
              if (!telephone) cellule(128, Text(totalSorties == 0 ? '' : '− ${_nombre(totalSorties)}', textAlign: TextAlign.right, style: entete)),
              if (!telephone) cellule(128, Text(_nombre(entrees - totalSorties), textAlign: TextAlign.right, style: entete)),
              const SizedBox(width: 32),
            ]),
          ),
      ]),
    );

    final resume = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: schema.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: schema.outlineVariant),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Total encaissé', style: TextStyle(fontSize: 14, color: gris)),
          Text(gnf(entrees), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          for (final m in modesPaiement.entries)
            if (parMode[m.key] != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(child: Text(m.value, style: TextStyle(fontSize: 14, color: gris))),
                  Text(gnf(parMode[m.key]), style: const TextStyle(fontSize: 14)),
                ]),
              ),
          if (totalSorties > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                Expanded(child: Text('Remboursements versés', style: TextStyle(fontSize: 14, color: gris))),
                Text('− ${gnf(totalSorties)}', style: const TextStyle(fontSize: 14)),
              ]),
            ),
          const SizedBox(height: 8),
          Text('${valides.length} reçu(s) valide(s) · ${recus.length - valides.length} annulé(s)',
              style: TextStyle(fontSize: 12, color: gris)),
          for (final c in carnets.entries)
            if (_trous(c.value).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Carnet ${c.key} : feuille(s) manquante(s) ${_trous(c.value).join(', ')}',
                    style: const TextStyle(fontSize: 12, color: Couleurs.attente)),
              ),
        ]),
      ),
      const SizedBox(height: 12),
      _ClotureDuJour(espace: widget.espace, jour: _date(_jour)),
    ]);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
          enTete,
          const SizedBox(height: 12),
          if (widget.espace.fondateur || widget.espace.droits.contains('encaisser')) _JoursNonClos(espace: widget.espace),
          filtres,
          const SizedBox(height: 12),
          if (largeur >= 1100)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: tableau),
              const SizedBox(width: 12),
              SizedBox(width: 320, child: resume),
            ])
          else ...[
            resume,
            const SizedBox(height: 12),
            tableau,
          ],
        ]),
      ),
    );
  }
}

// Clôture de caisse -----------------------------------------------------------------

/// Clôture la caisse de la personne connectée pour un jour et un site :
/// espèces attendues (calculées), espèces comptées (saisies), écart justifié.
const _joursSemaine = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

/// « jeudi 05/11/2026 » : le jour de la semaine évite de se tromper de journée.
String _jourLong(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? _dateLisible(iso) : '${_joursSemaine[d.weekday - 1]} ${_dateLisible(iso)}';
}

/// Mes journées non clôturées avant [jour] (la plus ancienne d'abord).
const _sqlJoursNonClos = """SELECT e.jour_caisse AS jour, e.site_id FROM encaissements e
     WHERE e.organisation_id = ? AND e.encaisse_par = ? AND e.statut = 'valide' AND e.jour_caisse < ?
     GROUP BY e.jour_caisse, e.site_id
     HAVING count(*) > (SELECT coalesce(sum(c.nb_recus), 0) FROM clotures_caisse c WHERE c.organisation_id = e.organisation_id
         AND c.site_id = e.site_id AND c.encaisse_par = e.encaisse_par AND c.jour = e.jour_caisse)
     ORDER BY e.jour_caisse""";

Future<void> cloturerCaisse(BuildContext context, {required String orgId, required String siteId, required String jour}) async {
  // Dans l'ordre : une journée plus ancienne non clôturée passe d'abord.
  final avantLui = await db.getAll(_sqlJoursNonClos, [orgId, monId, jour]);
  if (avantLui.isNotEmpty && context.mounted) {
    final ancien = '${avantLui.first['jour']}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Une journée plus ancienne reste à clôturer'),
        content: Text('Votre caisse du ${_jourLong(ancien)} n\'est pas clôturée. On clôture les journées dans l\'ordre : '
            'comptez d\'abord les espèces de ce jour-là.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Clôturer le ${_dateLisible(ancien)}')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await cloturerCaisse(context, orgId: orgId, siteId: avantLui.first['site_id'] as String, jour: ancien);
    }
    return;
  }
  final recus = await db.get(
      """SELECT coalesce(sum(total_gnf) FILTER (WHERE mode = 'especes'), 0) AS especes,
                coalesce(sum(total_gnf) FILTER (WHERE mode <> 'especes'), 0) AS autres,
                count(*) AS n
         FROM encaissements WHERE organisation_id = ? AND site_id = ? AND encaisse_par = ? AND jour_caisse = ? AND statut = 'valide'""",
      [orgId, siteId, monId, jour]);
  final rembourse = (await db.get(
      """SELECT coalesce(sum(montant_gnf), 0) AS s FROM remboursements WHERE organisation_id = ? AND site_id = ?
         AND verse_par = ? AND verse_le = ? AND statut = 'verse' AND mode = 'especes'""",
      [orgId, siteId, monId, jour]))['s'] as int? ?? 0;
  // Les dépenses que j'ai sorties de ma caisse ce jour-là (même calcul que le serveur).
  final depense = (await db.get(
      """SELECT coalesce(sum(montant_gnf), 0) AS s FROM depenses WHERE organisation_id = ? AND site_id = ?
         AND sortie_par = ? AND sortie_le = ? AND statut = 'sortie'""",
      [orgId, siteId, monId, jour]))['s'] as int? ?? 0;
  final sorties = rembourse + depense;
  // Déjà clôturé ce jour-là : on clôture le complément (les reçus venus après).
  final avant = await db.get(
      '''SELECT count(*) AS n, coalesce(sum(attendu_especes), 0) AS attendu, coalesce(sum(nb_recus), 0) AS recus,
                coalesce(sum(total_autres_modes), 0) AS autres
         FROM clotures_caisse WHERE organisation_id = ? AND site_id = ? AND encaisse_par = ? AND jour = ?''',
      [orgId, siteId, monId, jour]);
  final rang = (avant['n'] as int? ?? 0) + 1;
  final attendu = (recus['especes'] as int? ?? 0) - sorties - (avant['attendu'] as int? ?? 0);
  final nbRecus = (recus['n'] as int? ?? 0) - (avant['recus'] as int? ?? 0);
  final autres = (recus['autres'] as int? ?? 0) - (avant['autres'] as int? ?? 0);
  if (rang > 1 && nbRecus <= 0 && attendu == 0) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rien de nouveau à clôturer pour ce jour.')));
    }
    return;
  }
  final compte = TextEditingController();
  final justification = TextEditingController();
  if (!context.mounted) return;
  final ok = await _formulaire(context, rang == 1 ? 'Clôturer ma caisse du ${_jourLong(jour)}' : 'Clôturer le complément du ${_jourLong(jour)}', (maj) {
    final c = int.tryParse(compte.text.replaceAll(RegExp(r'[^0-9]'), ''));
    final ecart = c == null ? null : c - attendu;
    return [
      if (rang > 1)
        Text('La caisse de ce jour est déjà clôturée (clôture n° $rang). Ce complément couvre les '
            '$nbRecus reçu(s) encaissé(s) depuis : comptez seulement les espèces reçues depuis la dernière clôture.'),
      Text('Espèces attendues : ${gnf(attendu)}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
      if (rembourse > 0) Text('Remboursements versés en espèces déduits : ${gnf(rembourse)}'),
      if (depense > 0) Text('Dépenses sorties de la caisse déduites : ${gnf(depense)}'),
      Text('$nbRecus reçu(s) ; autres modes (Orange Money, MTN, chèques, virements) : ${gnf(autres)}, '
          'non comptés dans le tiroir.'),
      TextField(
        controller: compte,
        autofocus: true,
        keyboardType: TextInputType.number,
        onChanged: (_) => maj(() {}),
        decoration: _champ('Espèces comptées dans la caisse', suffixe: 'GNF'),
      ),
      if (ecart != null)
        Etat(ecart == 0 ? 'Aucun écart' : 'Écart : ${ecart > 0 ? '+' : '-'}${gnf(ecart.abs())}',
            ton: ecart == 0 ? Ton.regle : Ton.retard),
      if (ecart != null && ecart != 0)
        TextField(
          controller: justification,
          decoration: _champ('Justification obligatoire', aide: 'Monnaie rendue en trop, reçu oublié, erreur de comptage…'),
        ),
      const Text('Après la clôture, la journée est verrouillée : annuler un de ses reçus demandera la direction.'),
    ];
  });
  final c = int.tryParse(compte.text.replaceAll(RegExp(r'[^0-9]'), ''));
  if (!ok || c == null || !context.mounted) return;
  final ecart = c - attendu;
  if (ecart != 0 && justification.text.trim().length < 3) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Un écart doit être justifié.')));
    return;
  }
  final poste = await cePoste();
  await _inserer('clotures_caisse', {
    'organisation_id': orgId,
    'site_id': siteId,
    'encaisse_par': monId,
    'jour': jour,
    'attendu_especes': attendu,
    'compte_especes': c,
    'ecart': ecart,
    'justification': ecart == 0 ? null : justification.text.trim(),
    'nb_recus': nbRecus,
    'total_autres_modes': autres,
    'rang': rang,
    'poste_id': poste?['poste_id'],
  });
}

/// Jours passés où la personne connectée a encaissé sans clôturer (le plus ancien d'abord).
Future<List<Map<String, Object?>>> joursNonClotures(String orgId) async => [
      for (final r in await db.getAll(_sqlJoursNonClos, [orgId, monId, _date(DateTime.now())])) Map.of(r),
    ];

/// Bandeau du journal : mes journées passées pas encore clôturées, chacune avec son bouton.
class _JoursNonClos extends StatelessWidget {
  const _JoursNonClos({required this.espace});

  final Espace espace;

  @override
  Widget build(BuildContext context) => Requete(
        _sqlJoursNonClos,
        parametres: [espace.orgId, monId, _date(DateTime.now())],
        builder: (context, jours) {
          if (jours.isEmpty) return const SizedBox.shrink();
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: BoxDecoration(
              color: Couleurs.attenteFond,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Couleurs.attente.withValues(alpha: .4)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(Icons.warning_amber, size: 16, color: Couleurs.attente),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      jours.length == 1
                          ? 'Votre caisse du ${_jourLong('${jours.first['jour']}')} n\'est pas clôturée.'
                          : '${jours.length} journées de votre caisse ne sont pas clôturées : dans l\'ordre, la plus ancienne d\'abord.',
                      style: const TextStyle(fontSize: 14)),
                ),
                FilledButton.tonal(
                  onPressed: () => cloturerCaisse(context,
                      orgId: espace.orgId, siteId: jours.first['site_id'] as String, jour: '${jours.first['jour']}'),
                  child: Text('Clôturer le ${_dateLisible(jours.first['jour'])}'),
                ),
              ]),
            ]),
          );
        },
      );
}

class _ClotureDuJour extends StatelessWidget {
  const _ClotureDuJour({required this.espace, required this.jour});

  final Espace espace;
  final String jour;

  @override
  Widget build(BuildContext context) => Requete(
        """SELECT c.*, p.nom_complet AS encaisseur, s.nom AS site FROM clotures_caisse c
           LEFT JOIN personnel p ON p.user_id = c.encaisse_par AND p.organisation_id = c.organisation_id
           LEFT JOIN sites s ON s.id = c.site_id
           WHERE c.organisation_id = ? AND c.jour = ? ORDER BY c.created_at""",
        parametres: [espace.orgId, jour],
        builder: (context, clotures) => Requete(
          // Mes sites de la journée qui restent à clôturer.
          """SELECT e.site_id,
                 (SELECT count(*) FROM clotures_caisse c WHERE c.organisation_id = e.organisation_id AND c.site_id = e.site_id
                   AND c.encaisse_par = e.encaisse_par AND c.jour = e.jour_caisse) AS deja
               FROM encaissements e WHERE e.organisation_id = ? AND e.encaisse_par = ?
               AND e.jour_caisse = ? AND e.statut = 'valide'
               GROUP BY e.site_id
               HAVING count(*) > (SELECT coalesce(sum(c.nb_recus), 0) FROM clotures_caisse c WHERE c.organisation_id = e.organisation_id
                 AND c.site_id = e.site_id AND c.encaisse_par = e.encaisse_par AND c.jour = e.jour_caisse)""",
          parametres: [espace.orgId, monId, jour],
          builder: (context, aClore) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final s in aClore)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: FilledButton.icon(
                  onPressed: () => cloturerCaisse(context, orgId: espace.orgId, siteId: s['site_id'] as String, jour: jour),
                  icon: const Icon(Icons.lock_outline),
                  label: Text((s['deja'] as int? ?? 0) > 0 ? 'Clôturer le complément (reçus après la clôture)' : 'Clôturer ma caisse de ce jour'),
                ),
              ),
            for (final c in clotures)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.lock),
                  title: Text('${(c['rang'] as int? ?? 1) > 1 ? 'Complément n° ${(c['rang'] as int) - 1}' : 'Caisse clôturée'} · ${c['encaisseur'] ?? ''}'),
                  subtitle: Text([
                    'Attendu ${gnf(c['attendu_especes'])} · compté ${gnf(c['compte_especes'])}',
                    if ((c['ecart'] as int? ?? 0) != 0) 'Écart ${gnf(c['ecart'])} : ${c['justification'] ?? ''}',
                    '${c['nb_recus']} reçu(s) · autres modes ${gnf(c['total_autres_modes'])}',
                  ].join('\n')),
                  isThreeLine: true,
                  trailing: c['a_verifier'] == 1
                      ? const Etat('À vérifier', ton: Ton.attente)
                      : Etat((c['ecart'] as int? ?? 0) == 0 ? 'Sans écart' : 'Écart', ton: (c['ecart'] as int? ?? 0) == 0 ? Ton.regle : Ton.retard),
                ),
              ),
          ]),
        ),
      );
}
