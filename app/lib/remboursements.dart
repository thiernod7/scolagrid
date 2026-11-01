part of 'configuration.dart';

/// Remboursements : la caisse enregistre la demande, le titulaire du droit
/// « valider un remboursement » autorise ou refuse, la caisse verse l'argent
/// contre une décharge signée. Le paiement d'origine n'est jamais modifié.

const statutsRemboursement = {
  'demande': 'À autoriser',
  'autorise': 'Autorisé, à verser',
  'refuse': 'Refusé',
  'verse': 'Versé',
};

Ton _tonRemboursement(String statut) => switch (statut) {
      'demande' => Ton.attente,
      'autorise' => Ton.info,
      'verse' => Ton.regle,
      _ => Ton.neutre,
    };

/// Depuis un reçu : choisir la ligne (élève et frais), le montant et le motif.
Future<void> demanderRemboursement(BuildContext context, Map<String, Object?> recu) async {
  final messager = ScaffoldMessenger.of(context);
  final org = await db.get('SELECT * FROM organisations WHERE id = ?', [recu['organisation_id']]);
  if (org['remboursement_aucun'] == 1) {
    messager.showSnackBar(const SnackBar(content: Text("L'école ne rembourse pas (politique de remboursement).")));
    return;
  }
  bool remboursable(String type) => switch (type) {
        'inscription' => org['remboursable_inscription'] == 1,
        'reinscription' => org['remboursable_reinscription'] == 1,
        'scolarite' => org['remboursable_scolarite'] == 1,
        _ => org['remboursable_optionnel'] == 1,
      };
  final lignes = [
    for (final l in await db.getAll(
        '''SELECT l.*, f.libelle AS frais, f.type_frais, e.nom, e.prenoms,
             l.montant_gnf - (SELECT coalesce(sum(r.montant_gnf), 0) FROM remboursements r
                              WHERE r.ligne_id = l.id AND r.statut <> 'refuse') AS disponible
           FROM lignes_encaissement l JOIN frais f ON f.id = l.frais_id JOIN eleves e ON e.id = l.eleve_id
           WHERE l.encaissement_id = ? ORDER BY e.nom''',
        [recu['id']]))
      if (remboursable(l['type_frais'] as String? ?? 'optionnel') && (l['disponible'] as int? ?? 0) > 0) Map.of(l),
  ];
  if (!context.mounted) return;
  if (lignes.isEmpty) {
    messager.showSnackBar(const SnackBar(
        content: Text("Rien à rembourser sur ce reçu : frais non remboursables selon la politique de l'école, ou déjà remboursés.")));
    return;
  }
  var ligne = lignes.first['id'] as String;
  final montant = TextEditingController(text: '${lignes.first['disponible']}');
  final beneficiaire = TextEditingController(text: '${recu['payeur_nom']}');
  final motif = TextEditingController();
  var mode = 'especes';
  final ok = await _formulaire(context, 'Demande de remboursement', (maj) => [
        _liste('Ligne du reçu', ligne, {
          for (final l in lignes)
            l['id'] as String: '${l['nom']} ${l['prenoms']} · ${l['frais']} · jusqu\'à ${gnf(l['disponible'])}',
        }, (v) => maj(() {
              ligne = v;
              montant.text = '${lignes.firstWhere((l) => l['id'] == v)['disponible']}';
            })),
        TextField(controller: montant, keyboardType: TextInputType.number, decoration: _champ('Montant à rembourser', suffixe: 'GNF')),
        TextField(controller: beneficiaire, decoration: _champ('Remis à', aide: 'La personne qui signera la décharge')),
        _liste('Rendu en', mode, modesPaiement, (v) => maj(() => mode = v)),
        TextField(controller: motif, decoration: _champ('Motif', aide: 'Obligatoire : annulation, départ, erreur…')),
        const Text("La demande devra être autorisée par une personne habilitée avant que l'argent sorte de la caisse."),
      ]);
  final m = int.tryParse(montant.text.replaceAll(RegExp(r'[^0-9]'), ''));
  final choisie = lignes.firstWhere((l) => l['id'] == ligne);
  if (!ok || !context.mounted) return;
  if (m == null || m <= 0 || m > (choisie['disponible'] as int)) {
    messager.showSnackBar(SnackBar(content: Text('Montant invalide : au plus ${gnf(choisie['disponible'])}.')));
    return;
  }
  if (motif.text.trim().length < 3 || beneficiaire.text.trim().length < 2) {
    messager.showSnackBar(const SnackBar(content: Text('Le motif et le nom de la personne sont obligatoires.')));
    return;
  }
  final poste = await cePoste();
  await _inserer('remboursements', {
    'organisation_id': recu['organisation_id'],
    'site_id': recu['site_id'],
    'ligne_id': ligne,
    'encaissement_id': recu['id'],
    'inscription_id': choisie['inscription_id'],
    'eleve_id': choisie['eleve_id'],
    'frais_id': choisie['frais_id'],
    'montant_gnf': m,
    'beneficiaire': beneficiaire.text.trim(),
    'motif': motif.text.trim(),
    'mode': mode,
    'statut': 'demande',
    'demande_par': monId,
    'poste_id': poste?['poste_id'],
  });
  messager.showSnackBar(const SnackBar(content: Text('Demande enregistrée : en attente d\'autorisation.')));
}

class RemboursementsScreen extends StatefulWidget {
  const RemboursementsScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<RemboursementsScreen> createState() => _RemboursementsScreenState();
}

class _RemboursementsScreenState extends State<RemboursementsScreen> {
  bool _valideur = false;
  bool _caisse = false;

  @override
  void initState() {
    super.initState();
    Future.wait([
      jAiLeDroitQuelquePart(widget.espace.orgId, 'valider_remboursement'),
      jAiLeDroitQuelquePart(widget.espace.orgId, 'encaisser'),
    ]).then((r) {
      if (mounted) {
        setState(() {
          _valideur = r[0];
          _caisse = r[1];
        });
      }
    });
  }

  Future<void> _decider(Map<String, Object?> r, bool autoriser) async {
    String? refus;
    if (autoriser) {
      if (!await _confirmer(context, 'Autoriser le remboursement de ${gnf(r['montant_gnf'])} à ${r['beneficiaire']} ?')) return;
    } else {
      final c = TextEditingController();
      if (!mounted) return;
      final ok = await _formulaire(context, 'Refuser le remboursement', (_) => [
            TextField(controller: c, autofocus: true, decoration: _champ('Motif du refus', aide: 'Obligatoire')),
          ]);
      if (!ok || c.text.trim().length < 3) return;
      refus = c.text.trim();
    }
    await _modifier('remboursements', r['id'] as String, {
      'statut': autoriser ? 'autorise' : 'refuse',
      'autorise_par': monId,
      'autorise_le': _maintenant(),
      'motif_refus': refus,
    });
  }

  Future<void> _verser(Map<String, Object?> r) async {
    final decharge = TextEditingController();
    final ok = await _formulaire(context, 'Verser ${gnf(r['montant_gnf'])}', (_) => [
          Text('Remettez l\'argent à ${r['beneficiaire']} et faites-lui signer la décharge.'),
          TextField(
              controller: decharge,
              decoration: _champ('Décharge papier (facultatif)', aide: 'Carnet et n°, si vous utilisez un carnet de décharges')),
          const Text('La décharge PDF sera imprimée juste après.'),
        ]);
    if (!ok) return;
    final aujourdhui = _date(DateTime.now());
    await _modifier('remboursements', r['id'] as String, {
      'statut': 'verse',
      'verse_par': monId,
      'verse_le': aujourdhui,
      'decharge': decharge.text.trim().isEmpty ? null : decharge.text.trim(),
    });
    await _imprimerDecharge(r['id'] as String);
  }

  Future<void> _imprimerDecharge(String id) async {
    final r = await db.get(
        '''SELECT r.*, e.nom, e.prenoms, e.matricule, f.libelle AS frais, x.numero, x.feuille
           FROM remboursements r JOIN eleves e ON e.id = r.eleve_id JOIN frais f ON f.id = r.frais_id
           JOIN encaissements x ON x.id = r.encaissement_id WHERE r.id = ?''',
        [id]);
    final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [r['organisation_id']]);
    final deja = (await db.get(
        "SELECT count(*) AS n FROM impressions_documents WHERE eleve_id = ? AND type_document = 'decharge_remboursement' AND motif LIKE ?",
        [r['eleve_id'], '%$id%']))['n'] as int;
    final poste = await cePoste();
    await _inserer('impressions_documents', {
      'organisation_id': r['organisation_id'],
      'eleve_id': r['eleve_id'],
      'inscription_id': r['inscription_id'],
      'type_document': 'decharge_remboursement',
      'rang': deja + 1,
      // Le motif garde la référence du remboursement (et dit si c'est une réimpression).
      'motif': deja == 0 ? 'Remboursement $id' : 'Réimpression · remboursement $id',
      'par': monId,
      'poste_id': poste?['poste_id'],
    });
    final pdf = await dechargePdf(ecole: Map.of(ecole), remboursement: Map.of(r), rang: deja + 1, images: await _imagesEcole(ecole['id']));
    await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Décharge ${r['matricule']}');
  }

  @override
  Widget build(BuildContext context) => _Page(
        titre: 'Remboursements',
        corps: Requete(
          '''SELECT r.*, e.nom, e.prenoms, f.libelle AS frais, x.numero,
               pd.nom_complet AS demandeur, pa.nom_complet AS autorisateur
             FROM remboursements r JOIN eleves e ON e.id = r.eleve_id JOIN frais f ON f.id = r.frais_id
             JOIN encaissements x ON x.id = r.encaissement_id
             LEFT JOIN personnel pd ON pd.user_id = r.demande_par AND pd.organisation_id = r.organisation_id
             LEFT JOIN personnel pa ON pa.user_id = r.autorise_par AND pa.organisation_id = r.organisation_id
             WHERE r.organisation_id = ?
             ORDER BY CASE r.statut WHEN 'demande' THEN 0 WHEN 'autorise' THEN 1 ELSE 2 END, r.created_at DESC
             LIMIT 200''',
          parametres: [widget.espace.orgId],
          builder: (context, liste) {
            if (liste.isEmpty) {
              return _vide('Aucun remboursement.\n\nPour en demander un, ouvrez le reçu concerné (Caisse) : « Demander un remboursement ».');
            }
            return ListView(padding: const EdgeInsets.all(16), children: [
              for (final r in liste)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Text('${gnf(r['montant_gnf'])} · ${r['nom']} ${r['prenoms']}',
                              style: Theme.of(context).textTheme.titleSmall),
                        ),
                        Etat(statutsRemboursement[r['statut']] ?? '${r['statut']}', ton: _tonRemboursement(r['statut'] as String)),
                      ]),
                      const SizedBox(height: 4),
                      Text([
                        '${r['frais']} · reçu ${r['numero']} · ${modesPaiement[r['mode']]}',
                        'Remis à ${r['beneficiaire']} · motif : ${r['motif']}',
                        'Demandé le ${_dateLisible(r['created_at'])}${r['demandeur'] != null ? ' par ${r['demandeur']}' : ''}',
                        if (r['autorisateur'] != null)
                          '${r['statut'] == 'refuse' ? 'Refusé' : 'Autorisé'} par ${r['autorisateur']}'
                              '${r['motif_refus'] != null ? ' : ${r['motif_refus']}' : ''}',
                        if (r['statut'] == 'verse') 'Versé le ${_dateLisible(r['verse_le'])}${r['decharge'] != null ? ' · décharge ${r['decharge']}' : ''}',
                      ].join('\n')),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        if (r['statut'] == 'demande' && _valideur) ...[
                          FilledButton(onPressed: () => _decider(r, true), child: const Text('Autoriser')),
                          OutlinedButton(onPressed: () => _decider(r, false), child: const Text('Refuser')),
                        ],
                        if (r['statut'] == 'autorise' && _caisse)
                          FilledButton.icon(
                              onPressed: () => _verser(r), icon: const Icon(Icons.payments_outlined), label: const Text('Verser')),
                        if (r['statut'] == 'verse')
                          OutlinedButton.icon(
                              onPressed: () => _imprimerDecharge(r['id'] as String),
                              icon: const Icon(Icons.print),
                              label: const Text('Réimprimer la décharge')),
                      ]),
                    ]),
                  ),
                ),
            ]);
          },
        ),
      );
}

// Politique de remboursement (paramètres) ----------------------------------------------

class PolitiqueRemboursementScreen extends StatelessWidget {
  const PolitiqueRemboursementScreen({super.key, required this.espace});

  final Espace espace;

  @override
  Widget build(BuildContext context) => _Page(
        titre: 'Politique de remboursement',
        corps: Requete('SELECT * FROM organisations WHERE id = ?', parametres: [espace.orgId], builder: (context, l) {
          if (l.isEmpty) return const SizedBox.shrink();
          final o = l.first;
          final aucun = o['remboursement_aucun'] == 1;
          Widget choix(String colonne, String titre) => SwitchListTile(
                value: o[colonne] == 1,
                title: Text(titre),
                onChanged: espace.fondateur && !aucun ? (v) => _modifier('organisations', espace.orgId, {colonne: v ? 1 : 0}) : null,
              );
          return ListView(padding: const EdgeInsets.all(16), children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text("Ce que l'école accepte de rembourser, frais par frais. Chaque remboursement doit ensuite être "
                  "autorisé par une personne qui a le droit « valider un remboursement » (directeur par défaut)."),
            ),
            Card(
              child: SwitchListTile(
                value: aucun,
                title: const Text('Aucun remboursement'),
                subtitle: const Text("L'école ne rembourse jamais : prime sur les choix ci-dessous."),
                onChanged: espace.fondateur ? (v) => _modifier('organisations', espace.orgId, {'remboursement_aucun': v ? 1 : 0}) : null,
              ),
            ),
            Card(
              child: Column(children: [
                choix('remboursable_inscription', "Frais d'inscription"),
                choix('remboursable_reinscription', 'Frais de réinscription'),
                choix('remboursable_scolarite', 'Scolarité'),
                choix('remboursable_optionnel', 'Frais optionnels (cantine, transport…)'),
              ]),
            ),
          ]);
        }),
      );
}
