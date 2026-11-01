part of 'configuration.dart';

/// Frais scolaires : inscription, réinscription, scolarité (en mois ou en
/// tranches) et frais optionnels. Le montant d'un frais est le total de
/// l'année ; ses échéances disent quand le payer.


/// Frais scolaires, comme la maquette : le calendrier de paiement de
/// l'école, puis une grille (inscription, réinscription, scolarité) niveau par
/// niveau, les autres frais (cantine, transport…), un aperçu de ce que paie une
/// famille, et les corrections faites après paiement.
class FraisScreen extends StatefulWidget {
  const FraisScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<FraisScreen> createState() => _FraisScreenState();
}

/// Le calendrier d'une année, sous la forme qu'attendent les calculs.
Future<List<TrancheCalendrier>> _calendrierDe(String anneeId) async => [
      for (final t in await db.getAll('SELECT * FROM tranches_annee WHERE annee_id = ? ORDER BY ordre', [anneeId]))
        (libelle: t['libelle'] as String, dateLimite: DateTime.parse('${t['date_limite']}'), part: (t['part'] as num).toDouble()),
    ];

/// Refait les échéances d'un frais de scolarité d'après le calendrier de l'école.
/// Sans calendrier, on garde les échéances du frais.
Future<void> _refaireEcheances(dynamic tx,
    {required String orgId, required String fraisId, required int total, required List<TrancheCalendrier> cal, required String maintenant}) async {
  if (cal.isEmpty) return;
  await tx.execute('DELETE FROM echeances WHERE frais_id = ?', [fraisId]);
  for (final e in echeancesDuCalendrier(total: total, calendrier: cal)) {
    await tx.execute(
        'INSERT INTO echeances (id, organisation_id, frais_id, ordre, libelle, montant_gnf, date_limite, created_at, updated_at) '
        'VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?)',
        [orgId, fraisId, e.ordre, e.libelle, e.montant, _date(e.dateLimite), maintenant, maintenant]);
  }
}

class _FraisScreenState extends State<FraisScreen> {
  /// null : tarifs de toute l'école ; sinon tarifs propres à un site.
  String? _site;

  /// L'année affichée : celle en cours, ou la suivante en préparation.
  String? _anneeId;

  Espace get _e => widget.espace;

  bool get _modifiable => _site == null ? _e.fondateur : _e.gereSite(_site!);

  /// Fixe le montant d'une case de la grille (crée, corrige ou retire le frais).
  Future<void> _fixer(Map<String, Object?> annee, String type, String niveauId, int? montant) async {
    final messager = ScaffoldMessenger.of(context);
    final existant = await db.getOptional(
        'SELECT f.*, (SELECT count(*) FROM lignes_encaissement l WHERE l.frais_id = f.id) AS payes FROM frais f '
        'WHERE f.annee_id = ? AND f.type_frais = ? AND f.niveau_id = ? AND f.site_id IS ?',
        [annee['id'], type, niveauId, _site]);
    final maintenant = _maintenant();
    final cal = await _calendrierDe(annee['id'] as String);
    if (existant == null) {
      if (montant == null || montant <= 0) return;
      await db.writeTransaction((tx) async {
        final id = (await tx.get('SELECT uuid() AS id'))['id'] as String;
        await tx.execute(
            'INSERT INTO frais (id, organisation_id, annee_id, site_id, niveau_id, libelle, montant_gnf, periodicite, type_frais, '
            'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [
              id, _e.orgId, annee['id'], _site, niveauId, typesFrais[type]!.split(' (').first, montant,
              type == 'scolarite' ? (annee['periodicite'] ?? 'tranches') : 'unique', type, maintenant, maintenant,
            ]);
        if (type == 'scolarite') {
          await _refaireEcheances(tx, orgId: _e.orgId, fraisId: id, total: montant, cal: cal, maintenant: maintenant);
        }
      });
      return;
    }
    final payes = (existant['payes'] as int? ?? 0) > 0;
    if (montant == null || montant <= 0) {
      if (payes) {
        messager.showSnackBar(const SnackBar(content: Text('Ce frais a déjà été payé : il ne peut plus être retiré.')));
        return;
      }
      await db.writeTransaction((tx) async {
        await tx.execute('DELETE FROM echeances WHERE frais_id = ?', [existant['id']]);
        await tx.execute('DELETE FROM frais WHERE id = ?', [existant['id']]);
      });
      return;
    }
    if (montant == existant['montant_gnf']) return;
    String? motif;
    if (payes) {
      final m = TextEditingController();
      if (!mounted) return;
      final ok = await _formulaire(context, 'Corriger un frais déjà payé', (_) => [
            Text('${existant['libelle']} : ${gnf(existant['montant_gnf'])} → ${gnf(montant)}. '
                'Des familles ont déjà payé sur ce montant : la correction est gardée avec son motif.',
                style: const TextStyle(fontSize: 13)),
            TextField(controller: m, autofocus: true, decoration: _champ('Motif', aide: 'Par exemple : erreur de saisie')),
          ]);
      if (!ok || m.text.trim().length < 3) return;
      motif = m.text.trim();
    }
    await db.writeTransaction((tx) async {
      await tx.execute('UPDATE frais SET montant_gnf = ?, motif_correction = ?, updated_at = ? WHERE id = ?',
          [montant, motif ?? existant['motif_correction'], maintenant, existant['id']]);
      if (type == 'scolarite') {
        await _refaireEcheances(tx, orgId: _e.orgId, fraisId: existant['id'] as String, total: montant, cal: cal, maintenant: maintenant);
      }
    });
  }

  /// Autres frais : cantine, transport, tenue, examen…
  Future<void> _ajouterAutre(Map<String, Object?> annee) async {
    final niveaux = <String?, String>{
      null: 'Tous les niveaux',
      for (final n in await db.getAll('SELECT id, nom FROM niveaux WHERE organisation_id = ? ORDER BY ordre, nom', [_e.orgId]))
        n['id'] as String: n['nom'] as String,
    };
    final libelle = TextEditingController();
    final montant = TextEditingController();
    String? niveau;
    if (!mounted) return;
    final ok = await _formulaire(context, 'Autre frais', (maj) => [
          TextField(controller: libelle, autofocus: true, decoration: _champ('Libellé', aide: 'Cantine, Transport, Tenue, Examen…')),
          TextField(controller: montant, keyboardType: TextInputType.number, decoration: _champ("Montant pour l'année", suffixe: 'GNF')),
          _liste('Niveau', niveau, niveaux, (v) => maj(() => niveau = v)),
          const Text("La famille choisit de le prendre ou non (sur la fiche de l'élève).", style: TextStyle(fontSize: 13)),
        ]);
    final m = int.tryParse(montant.text.replaceAll(RegExp(r'[^0-9]'), ''));
    if (!ok || libelle.text.trim().length < 2 || m == null || m <= 0) return;
    await _inserer('frais', {
      'organisation_id': _e.orgId,
      'annee_id': annee['id'],
      'site_id': _site,
      'niveau_id': niveau,
      'libelle': libelle.text.trim(),
      'montant_gnf': m,
      'periodicite': 'unique',
      'type_frais': 'optionnel',
    });
  }

  @override
  Widget build(BuildContext context) => Requete(
        "SELECT * FROM annees_scolaires WHERE organisation_id = ? AND (en_cours = 1 OR etat IN ('preparation', 'inscriptions')) ORDER BY debut",
        parametres: [_e.orgId],
        builder: (context, annees) {
          if (annees.isEmpty) {
            return _Page(titre: 'Frais scolaires', corps: _vide("Il faut d'abord une année scolaire en cours."));
          }
          final annee = annees.where((a) => a['id'] == _anneeId).firstOrNull ??
              annees.where((a) => a['en_cours'] == 1).firstOrNull ??
              annees.first;
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          return _Page(
            titre: 'Frais scolaires ${annee['libelle']}',
            corps: Requete(
              'SELECT id, nom FROM sites WHERE organisation_id = ? ORDER BY created_at',
              parametres: [_e.orgId],
              builder: (context, sites) => ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
                if (annees.length > 1) ...[
                  Segments<String>(
                    valeur: annee['id'] as String,
                    choix: {
                      for (final a in annees) a['id'] as String: '${a['libelle']} · ${etatsAnnee[a['etat']] ?? ''}',
                    },
                    onChanged: (v) => setState(() => _anneeId = v),
                  ),
                  const SizedBox(height: 12),
                ],
                _ReglesPaiement(espace: _e),
                const SizedBox(height: 12),
                _Calendrier(espace: _e, annee: annee),
                const SizedBox(height: 20),
                Row(children: [
                  const Expanded(child: Text('Grille des tarifs', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                  if (sites.length > 1)
                    MenuCompact<String>(
                      largeur: 220,
                      valeur: _site,
                      tous: 'Toute l\'école',
                      choix: {for (final x in sites) x['id'] as String: '${x['nom']}'},
                      onChanged: (v) => setState(() => _site = v),
                    ),
                ]),
                const SizedBox(height: 4),
                Text(
                    _site == null
                        ? "Montants pour toute l'école. Saisissez un montant et quittez la case pour l'enregistrer."
                        : "Tarifs propres à ce site. Une case vide reprend le tarif de toute l'école (en gris).",
                    style: TextStyle(fontSize: 12, color: gris)),
                const SizedBox(height: 8),
                _GrilleTarifs(annee: annee, site: _site, modifiable: _modifiable, fixer: (t, n, m) => _fixer(annee, t, n, m)),
                const SizedBox(height: 20),
                _AutresFrais(annee: annee, site: _site, ajouter: _modifiable ? () => _ajouterAutre(annee) : null),
                const SizedBox(height: 20),
                _ApercuFamille(espace: _e, annee: annee),
                const SizedBox(height: 20),
                _Corrections(espace: _e),
              ]),
            ),
          );
        },
      );
}

/// Calendrier de paiement de l'école : périodicité, nombre de mois, tranches.
class _Calendrier extends StatelessWidget {
  const _Calendrier({required this.espace, required this.annee});

  final Espace espace;
  final Map<String, Object?> annee;

  static const _periodicites = {'tranches': 'Par tranches', 'mensuelle': 'Par mois', 'annuelle': 'En une fois'};

  static String _part(num p) => '${p.toStringAsFixed(1).replaceAll('.0', '').replaceAll('.', ',')} %';

  Future<void> _modifier(BuildContext context, List<Map<String, Object?>> actuelles) async {
    final rentree = DateTime.tryParse('${annee['debut']}') ?? DateTime.now();
    var periodicite = '${annee['periodicite'] ?? 'tranches'}';
    final nbMois = TextEditingController(text: '${annee['nb_mois'] ?? 9}');
    final nbTranches = TextEditingController(text: '${actuelles.isEmpty || periodicite != 'tranches' ? 3 : actuelles.length}');
    int lire(TextEditingController c, int defaut) {
      final n = int.tryParse(c.text.trim()) ?? defaut;
      return n < 1 ? 1 : (n > 12 ? 12 : n);
    }

    List<TrancheCalendrier> propose() => calendrierPropose(
          periodicite: periodicite,
          rentree: rentree,
          nbMois: lire(nbMois, 9),
          nbTranches: lire(nbTranches, 3),
        );
    var lignes = actuelles.isEmpty
        ? propose()
        : [
            for (final t in actuelles)
              (libelle: '${t['libelle']}', dateLimite: DateTime.parse('${t['date_limite']}'), part: (t['part'] as num).toDouble()),
          ];
    final ok = await _formulaire(context, 'Calendrier de paiement', (maj) => [
          _liste('Périodicité de la scolarité', periodicite, _periodicites, (v) => maj(() {
                periodicite = v;
                lignes = propose();
              })),
          TextField(
            controller: nbMois,
            keyboardType: TextInputType.number,
            onChanged: (_) => maj(() => lignes = propose()),
            decoration: _champ('Nombre de mois de scolarité', aide: 'À partir du mois de la rentrée (${_moisNom(rentree)})'),
          ),
          if (periodicite == 'tranches')
            TextField(
              controller: nbTranches,
              keyboardType: TextInputType.number,
              onChanged: (_) => maj(() => lignes = propose()),
              decoration: _champ('Nombre de tranches'),
            ),
          for (var k = 0; k < lignes.length; k++)
            Row(children: [
              Expanded(child: Text(lignes[k].libelle, style: const TextStyle(fontSize: 14))),
              Text(_part(lignes[k].part), style: styleMono.copyWith(fontSize: 13)),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  final d = await _choisirDate(context, lignes[k].dateLimite, premier: DateTime(2024), dernier: DateTime(2035));
                  if (d != null) maj(() => lignes[k] = (libelle: lignes[k].libelle, dateLimite: d, part: lignes[k].part));
                },
                child: Text('avant le ${_dateLisible(_date(lignes[k].dateLimite))}'),
              ),
            ]),
          const Text('Les parts suivent le nombre de mois de chaque tranche. Les échéances de tous les niveaux seront refaites.',
              style: TextStyle(fontSize: 12)),
        ]);
    if (!ok || lignes.isEmpty) return;
    final maintenant = _maintenant();
    await db.writeTransaction((tx) async {
      await tx.execute('UPDATE annees_scolaires SET periodicite = ?, nb_mois = ?, updated_at = ? WHERE id = ?',
          [periodicite, lire(nbMois, 9), maintenant, annee['id']]);
      await tx.execute('DELETE FROM tranches_annee WHERE annee_id = ?', [annee['id']]);
      for (var k = 0; k < lignes.length; k++) {
        await tx.execute(
            'INSERT INTO tranches_annee (id, organisation_id, annee_id, ordre, libelle, date_limite, part, created_at, updated_at) '
            'VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?)',
            [espace.orgId, annee['id'], k + 1, lignes[k].libelle, _date(lignes[k].dateLimite), lignes[k].part, maintenant, maintenant]);
      }
      // Les échéances de toutes les scolarités de l'année suivent le nouveau calendrier.
      for (final f in await tx.getAll("SELECT id, montant_gnf FROM frais WHERE annee_id = ? AND type_frais = 'scolarite'", [annee['id']])) {
        await _refaireEcheances(tx,
            orgId: espace.orgId, fraisId: f['id'] as String, total: f['montant_gnf'] as int, cal: lignes, maintenant: maintenant);
      }
    });
  }

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT * FROM tranches_annee WHERE annee_id = ? ORDER BY ordre',
        parametres: [annee['id']],
        builder: (context, tranches) {
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          return Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const Expanded(child: Text('Calendrier de paiement', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
                  if (espace.fondateur)
                    TextButton.icon(
                      onPressed: () => _modifier(context, tranches),
                      icon: const Icon(Icons.edit_calendar_outlined, size: 16),
                      label: Text(tranches.isEmpty ? 'Définir' : 'Modifier'),
                    ),
                ]),
                Text(
                    '${_periodicites[annee['periodicite']] ?? 'Par tranches'} · ${annee['nb_mois'] ?? 9} mois de scolarité · '
                    "le même calendrier pour toute l'école",
                    style: TextStyle(fontSize: 13, color: gris)),
                const SizedBox(height: 8),
                if (tranches.isEmpty)
                  Text('Pas encore de calendrier : chaque scolarité garde ses propres échéances.', style: TextStyle(fontSize: 13, color: gris)),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final t in tranches)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: Couleurs.doux(context), borderRadius: BorderRadius.circular(6)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${t['libelle']}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                        Text('${_part(t['part'] as num)} · avant le ${_dateLisible(t['date_limite'])}',
                            style: TextStyle(fontSize: 12, color: gris)),
                      ]),
                    ),
                ]),
              ]),
            ),
          );
        },
      );
}

/// La grille : une ligne par niveau (regroupés par cycle), trois montants.
class _GrilleTarifs extends StatelessWidget {
  const _GrilleTarifs({required this.annee, required this.site, required this.modifiable, required this.fixer});

  final Map<String, Object?> annee;
  final String? site;
  final bool modifiable;
  final Future<void> Function(String type, String niveauId, int? montant) fixer;

  static const _types = ['inscription', 'reinscription', 'scolarite'];

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT n.id, n.nom, n.cycle, n.ordre, '
        '(SELECT count(*) FROM classes c WHERE c.niveau_id = n.id AND c.annee_id = ?) AS classes '
        'FROM niveaux n WHERE n.organisation_id = ? ORDER BY n.ordre, n.nom',
        parametres: [annee['id'], annee['organisation_id']],
        builder: (context, niveaux) => Requete(
          'SELECT f.*, (SELECT count(*) FROM lignes_encaissement l WHERE l.frais_id = f.id) AS payes '
          "FROM frais f WHERE f.annee_id = ? AND f.type_frais IN ('inscription', 'reinscription', 'scolarite')",
          parametres: [annee['id']],
          builder: (context, frais) {
            final schema = Theme.of(context).colorScheme;
            final gris = schema.onSurfaceVariant;
            if (niveaux.isEmpty) {
              return Text("Créez d'abord les niveaux (Paramètres › Niveaux).", style: TextStyle(fontSize: 13, color: gris));
            }
            // Le frais propre à la case, et le montant dont elle hérite sinon.
            Map<String, Object?>? propre(String type, String niveau) {
              for (final f in frais) {
                if (f['type_frais'] == type && f['niveau_id'] == niveau && f['site_id'] == site) return f;
              }
              return null;
            }

            int? herite(String type, String niveau) {
              final r = fraisRetenus([
                for (final f in frais)
                  if (f['type_frais'] == type &&
                      (f['niveau_id'] == null || f['niveau_id'] == niveau) &&
                      (f['site_id'] == null || f['site_id'] == site) &&
                      !(f['niveau_id'] == niveau && f['site_id'] == site))
                    f,
              ]);
              return r.isEmpty ? null : r.first['montant_gnf'] as int?;
            }

            final parCycle = <String, List<Map<String, Object?>>>{};
            for (final n in niveaux) {
              parCycle.putIfAbsent('${n['cycle'] ?? ''}', () => []).add(n);
            }
            const entete = TextStyle(fontSize: 13, fontWeight: FontWeight.w500);
            return Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: schema.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: schema.outlineVariant),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: 650,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: schema.outlineVariant))),
                      child: const Row(children: [
                        SizedBox(width: 170, child: Text('Niveau', style: entete)),
                        SizedBox(width: 150, child: Text('Inscription', textAlign: TextAlign.right, style: entete)),
                        SizedBox(width: 150, child: Text('Réinscription', textAlign: TextAlign.right, style: entete)),
                        SizedBox(width: 156, child: Text('Scolarité (année)', textAlign: TextAlign.right, style: entete)),
                      ]),
                    ),
                    for (final c in parCycle.entries) ...[
                      Container(
                        color: Couleurs.doux(context).withValues(alpha: .6),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: Text((cycles[c.key] ?? c.key).toUpperCase(),
                            style: TextStyle(fontSize: 11, letterSpacing: .6, fontWeight: FontWeight.w500, color: gris)),
                      ),
                      for (final n in c.value)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: schema.outlineVariant))),
                          child: Row(children: [
                            SizedBox(
                              width: 170,
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('${n['nom']}', style: const TextStyle(fontSize: 14)),
                                if ((n['classes'] as int? ?? 0) > 0)
                                  Text('${n['classes']} classe(s)', style: TextStyle(fontSize: 11, color: gris)),
                              ]),
                            ),
                            for (final t in _types)
                              SizedBox(
                                width: t == 'scolarite' ? 156 : 150,
                                child: _Case(
                                  key: ValueKey('$site|${n['id']}|$t|${propre(t, n['id'] as String)?['montant_gnf']}'),
                                  valeur: propre(t, n['id'] as String)?['montant_gnf'] as int?,
                                  herite: herite(t, n['id'] as String),
                                  paye: ((propre(t, n['id'] as String)?['payes'] as int?) ?? 0) > 0,
                                  modifiable: modifiable,
                                  valider: (m) => fixer(t, n['id'] as String, m),
                                ),
                              ),
                          ]),
                        ),
                    ],
                  ]),
                ),
              ),
            );
          },
        ),
      );
}

/// Une case de la grille : saisie directe, enregistrée en quittant la case.
class _Case extends StatefulWidget {
  const _Case({super.key, required this.valeur, required this.herite, required this.paye, required this.modifiable, required this.valider});

  final int? valeur;
  final int? herite;
  final bool paye;
  final bool modifiable;
  final Future<void> Function(int? montant) valider;

  @override
  State<_Case> createState() => _CaseState();
}

class _CaseState extends State<_Case> {
  late final _c = TextEditingController(text: widget.valeur == null ? '' : _nombre(widget.valeur!));
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _envoyer();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _envoyer() {
    final brut = _c.text.replaceAll(RegExp(r'[^0-9]'), '');
    final m = brut.isEmpty ? null : int.tryParse(brut);
    if (m == widget.valeur) return;
    widget.valider(m);
  }

  @override
  Widget build(BuildContext context) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Row(children: [
        Expanded(
          child: SizedBox(
            height: 34,
            child: TextField(
              controller: _c,
              focusNode: _focus,
              enabled: widget.modifiable,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.right,
              onSubmitted: (_) => _envoyer(),
              style: styleMono.copyWith(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                hintText: widget.herite == null ? '—' : _nombre(widget.herite!),
                hintStyle: styleMono.copyWith(fontSize: 13, color: gris.withValues(alpha: .6)),
              ),
            ),
          ),
        ),
        SizedBox(
          width: 18,
          child: widget.paye
              ? Tooltip(
                  message: 'Déjà payé : une correction demandera un motif',
                  child: Icon(Icons.lock_outline, size: 13, color: gris),
                )
              : null,
        ),
      ]),
    );
  }
}

/// Les autres frais : cantine, transport, tenue, examen… (au choix des familles).
class _AutresFrais extends StatelessWidget {
  const _AutresFrais({required this.annee, required this.site, required this.ajouter});

  final Map<String, Object?> annee;
  final String? site;
  final VoidCallback? ajouter;

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT f.*, n.nom AS niveau, (SELECT count(*) FROM lignes_encaissement l WHERE l.frais_id = f.id) AS payes, '
        '(SELECT count(*) FROM souscriptions s WHERE s.frais_id = f.id AND s.actif = 1) AS pris '
        'FROM frais f LEFT JOIN niveaux n ON n.id = f.niveau_id '
        "WHERE f.annee_id = ? AND f.type_frais = 'optionnel' AND coalesce(f.examen, 0) = 0 AND f.site_id IS ? ORDER BY f.libelle",
        parametres: [annee['id'], site],
        builder: (context, frais) {
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(child: Text('Autres frais', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
              if (ajouter != null) TextButton.icon(onPressed: ajouter, icon: const Icon(Icons.add, size: 16), label: const Text('Ajouter')),
            ]),
            Text("Cantine, transport, tenue : la famille choisit de les prendre. Les frais d'examen se fixent dans Niveaux.", style: TextStyle(fontSize: 12, color: gris)),
            const SizedBox(height: 8),
            if (frais.isEmpty) Text('Aucun.', style: TextStyle(fontSize: 13, color: gris)),
            for (final f in frais)
              Card(
                child: ListTile(
                  title: Text('${f['libelle']}'),
                  subtitle: Text('${f['niveau'] ?? 'Tous les niveaux'} · pris par ${f['pris']} élève(s)'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(gnf(f['montant_gnf']), style: styleMono.copyWith(fontSize: 13)),
                    if (ajouter != null && (f['payes'] as int? ?? 0) == 0 && (f['pris'] as int? ?? 0) == 0)
                      IconButton(
                        tooltip: 'Retirer',
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () async {
                          if (await _confirmer(context, 'Retirer « ${f['libelle']} » ?')) {
                            await _supprimer('frais', f['id'] as String);
                          }
                        },
                      ),
                  ]),
                ),
              ),
          ]);
        },
      );
}

/// Ce que paie une famille : un niveau, nouvelle inscription ou réinscription,
/// le total de l'année et le calendrier (avant réduction).
class _ApercuFamille extends StatefulWidget {
  const _ApercuFamille({required this.espace, required this.annee});

  final Espace espace;
  final Map<String, Object?> annee;

  @override
  State<_ApercuFamille> createState() => _ApercuFamilleState();
}

class _ApercuFamilleState extends State<_ApercuFamille> {
  String? _niveau;
  bool _reinscription = false;

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT id, nom FROM niveaux WHERE organisation_id = ? ORDER BY ordre, nom',
        parametres: [widget.espace.orgId],
        builder: (context, niveaux) => Requete(
          "SELECT * FROM frais WHERE annee_id = ? AND type_frais IN ('inscription', 'reinscription', 'scolarite')",
          parametres: [widget.annee['id']],
          builder: (context, frais) => Requete(
            'SELECT * FROM tranches_annee WHERE annee_id = ? ORDER BY ordre',
            parametres: [widget.annee['id']],
            builder: (context, tranches) {
              final gris = Theme.of(context).colorScheme.onSurfaceVariant;
              if (niveaux.isEmpty) return const SizedBox.shrink();
              final niveau = _niveau ?? niveaux.first['id'] as String;
              final retenus = fraisRetenus([
                for (final f in frais)
                  if (f['site_id'] == null &&
                      (f['niveau_id'] == null || f['niveau_id'] == niveau) &&
                      (f['type_frais'] == 'scolarite' || f['type_frais'] == (_reinscription ? 'reinscription' : 'inscription')))
                    f,
              ]);
              final entree = retenus.where((f) => f['type_frais'] != 'scolarite').fold<int>(0, (s, f) => s + (f['montant_gnf'] as int));
              final scolarite = retenus.where((f) => f['type_frais'] == 'scolarite').fold<int>(0, (s, f) => s + (f['montant_gnf'] as int));
              final cal = [
                for (final t in tranches)
                  (libelle: '${t['libelle']}', dateLimite: DateTime.parse('${t['date_limite']}'), part: (t['part'] as num).toDouble()),
              ];
              final echeances = echeancesDuCalendrier(total: scolarite, calendrier: cal);
              return Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Text('Ce que paie une famille', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    Text("Avant réduction, tarifs de toute l'école.", style: TextStyle(fontSize: 12, color: gris)),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      MenuCompact<String>(
                        largeur: 200,
                        valeur: _niveau == niveaux.first['id'] ? null : _niveau,
                        tous: '${niveaux.first['nom']}',
                        choix: {for (final n in niveaux.skip(1)) n['id'] as String: '${n['nom']}'},
                        onChanged: (v) => setState(() => _niveau = v),
                      ),
                      Segments<bool>(
                        valeur: _reinscription,
                        choix: const {false: 'Nouvelle inscription', true: 'Réinscription'},
                        onChanged: (v) => setState(() => _reinscription = v),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: Text(_reinscription ? 'Réinscription' : 'Inscription', style: const TextStyle(fontSize: 14))),
                      Text(gnf(entree), style: styleMono.copyWith(fontSize: 13)),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      const Expanded(child: Text('Scolarité', style: TextStyle(fontSize: 14))),
                      Text(gnf(scolarite), style: styleMono.copyWith(fontSize: 13)),
                    ]),
                    for (final e in echeances)
                      Padding(
                        padding: const EdgeInsets.only(left: 12, top: 2),
                        child: Row(children: [
                          Expanded(
                              child: Text('${e.libelle} · avant le ${_dateLisible(_date(e.dateLimite))}',
                                  style: TextStyle(fontSize: 12, color: gris))),
                          Text(gnf(e.montant), style: styleMono.copyWith(fontSize: 12, color: gris)),
                        ]),
                      ),
                    const Divider(height: 20),
                    Row(children: [
                      const Expanded(child: Text("Total de l'année", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
                      Text(gnf(entree + scolarite), style: styleMono.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
                    ]),
                  ]),
                ),
              );
            },
          ),
        ),
      );
}

/// Les corrections de frais déjà payés : qui, quand, pourquoi.
class _Corrections extends StatelessWidget {
  const _Corrections({required this.espace});

  final Espace espace;

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT h.*, f.libelle, n.nom AS niveau, p.nom_complet AS auteur FROM historique_frais h '
        'JOIN frais f ON f.id = h.frais_id LEFT JOIN niveaux n ON n.id = f.niveau_id '
        'LEFT JOIN personnel p ON p.user_id = h.par AND p.organisation_id = h.organisation_id '
        'WHERE h.organisation_id = ? ORDER BY h.quand DESC LIMIT 20',
        parametres: [espace.orgId],
        builder: (context, l) {
          if (l.isEmpty) return const SizedBox.shrink();
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Corrections après paiement', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final h in l)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                    '${_dateLisible(h['quand'])} · ${h['libelle']}${h['niveau'] == null ? '' : ' (${h['niveau']})'} : '
                    '${gnf(h['ancien_gnf'])} → ${gnf(h['nouveau_gnf'])} · ${h['motif']}${h['auteur'] == null ? '' : ' · ${h['auteur']}'}',
                    style: TextStyle(fontSize: 13, color: gris)),
              ),
          ]);
        },
      );
}

String _moisNom(DateTime d) => const [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
    ][d.month - 1];



/// Règles de paiement de l'école : délai de grâce, et ce que paie par défaut
/// un élève qui arrive en cours d'année.
class _ReglesPaiement extends StatelessWidget {
  const _ReglesPaiement({required this.espace});

  final Espace espace;

  static const _arrivees = {
    'complete': 'Année complète',
    'mois': "À partir du mois d'arrivée",
    'negocie': 'Montant négocié (direction)',
  };

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT delai_grace_jours, arrivee_par_defaut, modes_sous_reserve FROM organisations WHERE id = ?',
        parametres: [espace.orgId],
        builder: (context, l) {
          if (l.isEmpty) return const SizedBox.shrink();
          final o = l.first;
          final grace = (o['delai_grace_jours'] as int?) ?? 7;
          final modifiable = espace.fondateur;
          return Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Règles de paiement', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Délai de grâce'),
                  subtitle: Text("Une échéance devient un arriéré $grace jour${grace > 1 ? 's' : ''} après sa date limite."),
                  trailing: modifiable ? const Icon(Icons.edit_outlined, size: 18) : null,
                  onTap: modifiable
                      ? () async {
                          final c = TextEditingController(text: '$grace');
                          final ok = await _formulaire(context, 'Délai de grâce', (_) => [
                                TextField(
                                  controller: c,
                                  autofocus: true,
                                  keyboardType: TextInputType.number,
                                  decoration: _champ('Jours après la date limite', aide: 'De 0 à 60'),
                                ),
                              ]);
                          final n = int.tryParse(c.text.trim());
                          if (ok && n != null && n >= 0 && n <= 60) {
                            await _modifier('organisations', espace.orgId, {'delai_grace_jours': n});
                          }
                        }
                      : null,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Arrivée en cours d'année, par défaut"),
                  subtitle: Text('${_arrivees[o['arrivee_par_defaut']] ?? _arrivees['mois']} · le guichet peut choisir autre chose'),
                  trailing: modifiable
                      ? PopupMenuButton<String>(
                          tooltip: 'Changer',
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onSelected: (v) => _modifier('organisations', espace.orgId, {'arrivee_par_defaut': v}),
                          itemBuilder: (_) => [
                            for (final a in _arrivees.entries) PopupMenuItem(value: a.key, child: Text(a.value)),
                          ],
                        )
                      : null,
                ),
                const SizedBox(height: 4),
                const Text('Encaissés « sous réserve »', style: TextStyle(fontSize: 14)),
                Text("L'argent n'est compté qu'une fois confirmé (chèque encaissé par la banque, virement reçu…).",
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final m in modesPaiement.entries)
                    if (m.key != 'especes')
                      FilterChip(
                        label: Text(m.value),
                        selected: '${o['modes_sous_reserve'] ?? 'cheque,virement'}'.split(',').contains(m.key),
                        onSelected: modifiable
                            ? (v) {
                                final actuels = '${o['modes_sous_reserve'] ?? 'cheque,virement'}'
                                    .split(',')
                                    .where((x) => x.isNotEmpty)
                                    .toSet();
                                v ? actuels.add(m.key) : actuels.remove(m.key);
                                _modifier('organisations', espace.orgId, {
                                  'modes_sous_reserve': modesPaiement.keys.where(actuels.contains).join(','),
                                });
                              }
                            : null,
                      ),
                ]),
              ]),
            ),
          );
        },
      );
}
