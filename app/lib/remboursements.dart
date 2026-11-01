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
  // Qui peut dire oui : direction, ou droit « valider un remboursement ».
  final direction = {
    for (final p in await db.getAll('''
        SELECT p.id, p.nom_complet FROM personnel p
        WHERE p.organisation_id = ? AND p.statut = 'actif' AND (
          EXISTS (SELECT 1 FROM affectations a WHERE a.personnel_id = p.id AND a.actif = 1 AND a.fonction IN ('fondateur', 'directeur'))
          OR EXISTS (SELECT 1 FROM droits_personnel d WHERE d.personnel_id = p.id AND d.droit = 'valider_remboursement' AND d.accorde = 1))
        ORDER BY p.nom_complet''', [recu['organisation_id']]))
      p['id'] as String: p['nom_complet'] as String,
  };
  final delai = (org['delai_confirmation_heures'] as int?) ?? 48;
  var orale = false;
  String? parQui;
  if (!context.mounted) return;
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
        if (direction.isNotEmpty)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: orale,
            onChanged: (v) => maj(() => orale = v),
            title: const Text('Déjà autorisé de vive voix'),
            subtitle: Text("L'argent peut sortir tout de suite ; la personne devra confirmer dans l'application sous $delai h."),
          ),
        if (orale) _liste<String?>('Autorisé par', parQui, {null: 'Choisir', ...direction}, (v) => maj(() => parQui = v)),
        if (!orale) const Text("La demande devra être autorisée par une personne habilitée avant que l'argent sorte de la caisse."),
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
  if (orale && parQui == null) {
    messager.showSnackBar(const SnackBar(content: Text('Indiquez qui a autorisé le remboursement.')));
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
    'statut': orale ? 'autorise' : 'demande',
    'demande_par': monId,
    'poste_id': poste?['poste_id'],
    'autorisation_orale': orale ? 1 : 0,
    'autorise_oralement_par': orale ? parQui : null,
    'autorise_le': orale ? _maintenant() : null,
    'confirmation': orale ? 'attendue' : null,
  });
  messager.showSnackBar(SnackBar(
      content: Text(orale
          ? 'Autorisé de vive voix : vous pouvez verser. ${direction[parQui]} devra confirmer sous $delai h.'
          : 'Demande enregistrée : en attente d\'autorisation.')));
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

  /// Autorisation orale : la direction confirme, ou conteste avec un motif.
  Future<void> _confirmerOral(Map<String, Object?> r, bool confirme) async {
    String? motif;
    if (confirme) {
      if (!await _confirmer(context, 'Confirmer avoir autorisé le remboursement de ${gnf(r['montant_gnf'])} à ${r['beneficiaire']} ?')) return;
    } else {
      final c = TextEditingController();
      final ok = await _formulaire(context, 'Contester le remboursement', (_) => [
            const Text("Le remboursement reste enregistré ; la contestation est gardée pour le suivi."),
            TextField(controller: c, autofocus: true, decoration: _champ('Motif', aide: 'Obligatoire')),
          ]);
      if (!ok || c.text.trim().length < 3) return;
      motif = c.text.trim();
    }
    await _modifier('remboursements', r['id'] as String, {
      'confirmation': confirme ? 'confirmee' : 'contestee',
      'confirme_par': monId,
      'confirme_le': _maintenant(),
      'motif_contestation': motif,
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
               pd.nom_complet AS demandeur, pa.nom_complet AS autorisateur, po.nom_complet AS autorisateur_oral,
               pc.nom_complet AS confirmateur, o.delai_confirmation_heures AS delai
             FROM remboursements r JOIN organisations o ON o.id = r.organisation_id JOIN eleves e ON e.id = r.eleve_id JOIN frais f ON f.id = r.frais_id
             JOIN encaissements x ON x.id = r.encaissement_id
             LEFT JOIN personnel pd ON pd.user_id = r.demande_par AND pd.organisation_id = r.organisation_id
             LEFT JOIN personnel pa ON pa.user_id = r.autorise_par AND pa.organisation_id = r.organisation_id
             LEFT JOIN personnel po ON po.id = r.autorise_oralement_par
             LEFT JOIN personnel pc ON pc.user_id = r.confirme_par AND pc.organisation_id = r.organisation_id
             WHERE r.organisation_id = ?
             ORDER BY CASE WHEN r.confirmation = 'attendue' THEN 0 WHEN r.statut = 'demande' THEN 1 WHEN r.statut = 'autorise' THEN 2 ELSE 3 END,
               r.created_at DESC
             LIMIT 200''',
          parametres: [widget.espace.orgId],
          builder: (context, liste) {
            if (liste.isEmpty) {
              return _vide('Aucun remboursement.\n\nPour en demander un, ouvrez le reçu concerné (Caisse) : « Demander un remboursement ».');
            }
            bool horsDelai(Map<String, Object?> r) {
              final le = DateTime.tryParse('${r['autorise_le']}');
              return r['confirmation'] == 'attendue' &&
                  le != null &&
                  DateTime.now().toUtc().difference(le.toUtc()).inHours >= ((r['delai'] as int?) ?? 48);
            }

            return ListView(padding: const EdgeInsets.all(16), children: [
              for (final r in liste)
                Card(
                  shape: horsDelai(r)
                      ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Couleurs.retard))
                      : null,
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
                        if (r['autorisation_orale'] == 1)
                          'Autorisé de vive voix par ${r['autorisateur_oral'] ?? '?'} le ${_dateLisible(r['autorise_le'])}'
                              '${switch (r['confirmation']) {
                            'confirmee' => ' · confirmé${r['confirmateur'] != null ? ' par ${r['confirmateur']}' : ''}',
                            'contestee' => ' · CONTESTÉ${r['confirmateur'] != null ? ' par ${r['confirmateur']}' : ''} : ${r['motif_contestation']}',
                            _ => ' · à confirmer sous ${r['delai'] ?? 48} h',
                          }}',
                        if (r['statut'] == 'verse') 'Versé le ${_dateLisible(r['verse_le'])}${r['decharge'] != null ? ' · décharge ${r['decharge']}' : ''}',
                      ].join('\n')),
                      const SizedBox(height: 8),
                      if (horsDelai(r))
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Etat('Confirmation en retard', ton: Ton.retard, icone: Icons.schedule),
                        ),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        if (r['confirmation'] == 'attendue' && _valideur) ...[
                          FilledButton(onPressed: () => _confirmerOral(r, true), child: const Text("Confirmer l'autorisation")),
                          OutlinedButton(onPressed: () => _confirmerOral(r, false), child: const Text('Contester')),
                        ],
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
            Card(
              child: ListTile(
                title: const Text('Autorisation de vive voix : délai pour confirmer'),
                subtitle: Text("Quand la direction dit oui oralement, la caisse verse tout de suite ; la direction confirme dans "
                    "l'application sous ${o['delai_confirmation_heures'] ?? 48} h, sinon c'est signalé en rouge."),
                trailing: espace.fondateur
                    ? DropdownButton<int>(
                        value: const [24, 48, 72, 168].contains(o['delai_confirmation_heures']) ? o['delai_confirmation_heures'] as int : 48,
                        underline: const SizedBox(),
                        items: const [
                          DropdownMenuItem(value: 24, child: Text('24 h')),
                          DropdownMenuItem(value: 48, child: Text('48 h')),
                          DropdownMenuItem(value: 72, child: Text('72 h')),
                          DropdownMenuItem(value: 168, child: Text('7 jours')),
                        ],
                        onChanged: (v) => v == null ? null : _modifier('organisations', espace.orgId, {'delai_confirmation_heures': v}),
                      )
                    : null,
              ),
            ),
          ]);
        }),
      );
}
