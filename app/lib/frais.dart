part of 'configuration.dart';

/// Frais scolaires : inscription, réinscription, scolarité (en mois ou en
/// tranches) et frais optionnels. Le montant d'un frais est le total de
/// l'année ; ses échéances disent quand le payer.

const _periodicites = {
  'unique': 'Une fois',
  'mensuel': 'Par mois',
  'tranches': 'Par tranches',
  'annuel': "En une fois pour l'année",
  'trimestriel': 'Par trimestre',
};

class FraisScreen extends StatelessWidget {
  const FraisScreen({super.key, required this.espace});

  final Espace espace;

  Future<void> _ajouter(BuildContext context) async {
    final annee = await db.getOptional(
        'SELECT id, debut FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1', [espace.orgId]);
    final sites = <String?, String>{
      if (espace.fondateur) null: 'Tous les sites',
      for (final s in await db.getAll('SELECT id, nom FROM sites WHERE organisation_id = ? ORDER BY created_at',
          [espace.orgId]))
        if (espace.gereSite(s['id'] as String)) s['id'] as String: s['nom'] as String,
    };
    final niveaux = <String?, String>{
      null: 'Tous les niveaux',
      for (final n in await db.getAll('SELECT id, nom FROM niveaux WHERE organisation_id = ? ORDER BY ordre, nom',
          [espace.orgId]))
        n['id'] as String: n['nom'] as String,
    };
    if (!context.mounted) return;
    if (annee == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Il faut d'abord une année scolaire en cours.")));
      return;
    }
    final rentree = DateTime.tryParse('${annee['debut']}') ?? DateTime.now();
    var type = 'scolarite';
    var decoupage = 'tranches';
    final libelle = TextEditingController(text: typesFrais[type]);
    final montant = TextEditingController();
    final nbMois = TextEditingController(text: '9');
    final nbTranches = TextEditingController(text: '3');
    String? site = sites.keys.first;
    String? niveau;
    int? lire(TextEditingController c) => int.tryParse(c.text.replaceAll(RegExp(r'[^0-9]'), ''));

    final ok = await _formulaire(context, 'Nouveaux frais', (maj) => [
          _liste('Type', type, typesFrais, (v) => maj(() {
                type = v;
                libelle.text = v == 'optionnel' ? '' : typesFrais[v]!;
              })),
          TextField(controller: libelle, decoration: _champ('Libellé', aide: type == 'optionnel' ? 'Cantine, Transport, Tenue…' : null)),
          if (type == 'scolarite')
            _liste('Paiement', decoupage, const {
              'tranches': 'Par tranches',
              'mensuel': 'Par mois',
              'annuel': "En une fois pour l'année",
            }, (v) => maj(() => decoupage = v)),
          TextField(
              controller: montant,
              keyboardType: TextInputType.number,
              decoration: _champ(type == 'scolarite' && decoupage == 'mensuel' ? 'Montant par mois' : "Montant pour l'année",
                  suffixe: 'GNF')),
          if (type == 'scolarite' && decoupage != 'annuel')
            TextField(
                controller: nbMois,
                keyboardType: TextInputType.number,
                decoration: _champ('Nombre de mois payés',
                    aide: 'À partir du mois de la rentrée (${_moisNom(rentree)})')),
          if (type == 'scolarite' && decoupage == 'tranches')
            TextField(
                controller: nbTranches,
                keyboardType: TextInputType.number,
                decoration: _champ('Nombre de tranches', aide: 'Les mois sont répartis entre les tranches')),
          _liste('Niveau', niveau, niveaux, (v) => maj(() => niveau = v)),
          if (sites.length > 1) _liste('Site', site, sites, (v) => maj(() => site = v)),
        ]);
    final m = lire(montant);
    final mois = (lire(nbMois) ?? 9).clamp(1, 12);
    final tranches = (lire(nbTranches) ?? 3).clamp(1, mois);
    if (!ok || libelle.text.trim().length < 2 || m == null) return;

    final premierMois = DateTime(rentree.year, rentree.month);
    final List<Echeance> echeances;
    final String periodicite;
    final int total;
    if (type != 'scolarite') {
      // Inscription, réinscription, optionnels : une seule fois, à l'inscription.
      echeances = const [];
      periodicite = 'unique';
      total = m;
    } else if (decoupage == 'mensuel') {
      echeances = echeancesMensuelles(parMois: m, premierMois: premierMois, nbMois: mois);
      periodicite = 'mensuel';
      total = m * mois;
    } else {
      echeances = echeancesEnTranches(
          total: m, premierMois: premierMois, mois: decoupage == 'annuel' ? [1] : moisParTranche(mois, tranches));
      periodicite = decoupage == 'annuel' ? 'annuel' : 'tranches';
      total = m;
    }

    final maintenant = _maintenant();
    await db.writeTransaction((tx) async {
      final id = (await tx.get('SELECT uuid() AS id'))['id'];
      await tx.execute(
          'INSERT INTO frais (id, organisation_id, annee_id, site_id, niveau_id, libelle, montant_gnf, periodicite, '
          'type_frais, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [id, espace.orgId, annee['id'], site, niveau, libelle.text.trim(), total, periodicite, type, maintenant, maintenant]);
      for (final e in echeances) {
        await tx.execute(
            'INSERT INTO echeances (id, organisation_id, frais_id, ordre, libelle, montant_gnf, date_limite, '
            'created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?)',
            [espace.orgId, id, e.ordre, e.libelle, e.montant, _date(e.dateLimite), maintenant, maintenant]);
      }
    });
  }

  Future<void> _supprimerFrais(String id) => db.writeTransaction((tx) async {
        await tx.execute('DELETE FROM echeances WHERE frais_id = ?', [id]);
        await tx.execute('DELETE FROM frais WHERE id = ?', [id]);
      });

  @override
  Widget build(BuildContext context) => _Page(
        titre: 'Frais scolaires',
        ajouter: espace.gestionnaire ? () => _ajouter(context) : null,
        libelleAjouter: 'Frais',
        corps: Requete(
            '''SELECT f.*, n.nom AS niveau, s.nom AS site,
                 (SELECT group_concat(e.libelle || ' : ' || e.montant_gnf || ' avant le ' || e.date_limite, '|')
                  FROM (SELECT * FROM echeances WHERE frais_id = f.id ORDER BY ordre) e) AS echeances
               FROM frais f
               JOIN annees_scolaires a ON a.id = f.annee_id AND a.en_cours = 1
               LEFT JOIN niveaux n ON n.id = f.niveau_id
               LEFT JOIN sites s ON s.id = f.site_id
               WHERE f.organisation_id = ?
               ORDER BY CASE f.type_frais WHEN 'inscription' THEN 0 WHEN 'reinscription' THEN 1
                        WHEN 'scolarite' THEN 2 ELSE 3 END, n.ordre, f.libelle''',
            parametres: [espace.orgId], builder: (context, frais) {
          if (frais.isEmpty) {
            return _vide("Aucun frais pour l'année en cours.\n\n"
                "Ajoutez au moins les frais d'inscription, de réinscription et la scolarité de chaque niveau.");
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
            for (final f in frais)
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.payments_outlined),
                  title: Text('${f['libelle']} · ${gnf(f['montant_gnf'])}'),
                  subtitle: Text([
                    typesFrais[f['type_frais']]?.split(' (').first ?? '',
                    _periodicites[f['periodicite']] ?? '',
                    f['niveau'] ?? 'Tous les niveaux',
                    f['site'] ?? 'Tous les sites',
                  ].where((t) => '$t'.isNotEmpty).join(' · ')),
                  children: [
                    for (final e in '${f['echeances'] ?? ''}'.split('|').where((e) => e.isNotEmpty))
                      ListTile(dense: true, title: Text(_ligneEcheance(e))),
                    if ((f['site_id'] == null ? espace.fondateur : espace.gereSite(f['site_id'] as String)))
                      TextButton.icon(
                        onPressed: () async {
                          if (await _confirmer(context, 'Supprimer ces frais et leurs échéances ?')) {
                            await _supprimerFrais(f['id'] as String);
                          }
                        },
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Supprimer'),
                      ),
                  ],
                ),
              ),
          ]);
        }),
      );
}

String _moisNom(DateTime d) => const [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
    ][d.month - 1];

/// « Tranche 1 : 250000 avant le 2026-12-31 » → « Tranche 1 : 250 000 GNF avant le 31/12/2026 ».
String _ligneEcheance(String brut) {
  final m = RegExp(r'^(.*) : (\d+) avant le (.*)$').firstMatch(brut);
  if (m == null) return brut;
  return '${m[1]} : ${gnf(int.parse(m[2]!))} avant le ${_dateLisible(m[3])}';
}
