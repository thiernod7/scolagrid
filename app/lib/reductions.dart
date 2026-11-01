part of 'configuration.dart';

/// Réductions de l'école : fratrie (barème par nombre d'enfants du même payeur),
/// paiement de l'année en une fois, et réductions personnalisées (bourse,
/// orphelin, mérite…) accordées élève par élève.

class ReductionsScreen extends StatelessWidget {
  const ReductionsScreen({super.key, required this.espace});

  final Espace espace;

  Future<void> _ajouter(BuildContext context) async {
    var type = 'fratrie';
    var pourcentage = true;
    var portee = 'scolarite';
    final libelle = TextEditingController(text: '2 enfants');
    final valeur = TextEditingController();
    final enfants = TextEditingController(text: '2');
    final ok = await _formulaire(context, 'Nouvelle réduction', (maj) => [
          _liste('Type', type, typesReduction, (v) => maj(() {
                type = v;
                if (v != 'personnalisee' && v != 'personnel') portee = 'scolarite';
                libelle.text = switch (v) {
                  'fratrie' => '${enfants.text} enfants',
                  'paiement_annuel' => "Année payée d'un coup",
                  'personnel' => 'Enfant du personnel',
                  _ => '',
                };
              })),
          TextField(controller: libelle, decoration: _champ('Nom', aide: type == 'personnalisee' ? 'Bourse, Orphelin, Mérite…' : null)),
          if (type == 'fratrie')
            TextField(
              controller: enfants,
              keyboardType: TextInputType.number,
              decoration: _champ("À partir de combien d'enfants", aide: 'Payés par la même personne. Ex. 2, puis une autre règle pour 3…'),
              onChanged: (v) => libelle.text = '$v enfants',
            ),
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: true, label: Text('Pourcentage')), ButtonSegment(value: false, label: Text('Montant'))],
            selected: {pourcentage},
            onSelectionChanged: (s) => maj(() => pourcentage = s.first),
          ),
          TextField(
            controller: valeur,
            keyboardType: TextInputType.number,
            decoration: _champ(pourcentage ? 'Réduction' : 'Réduction par frais', suffixe: pourcentage ? '%' : 'GNF'),
          ),
          if (type == 'personnalisee' || type == 'personnel') _liste('Sur', portee, porteesReduction, (v) => maj(() => portee = v)),
        ]);
    final v = num.tryParse(valeur.text.replaceAll(',', '.').replaceAll(' ', ''));
    final n = int.tryParse(enfants.text);
    if (!context.mounted || !ok) return;
    String? probleme;
    if (libelle.text.trim().length < 2) probleme = 'Donnez un nom à la réduction.';
    if (v == null || v <= 0 || (pourcentage && v > 100)) probleme = 'Montant ou pourcentage invalide.';
    if (type == 'fratrie' && (n == null || n < 2 || n > 20)) probleme = "Le nombre d'enfants va de 2 à 20.";
    if (probleme != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(probleme)));
      return;
    }
    await _inserer('regles_reduction', {
      'organisation_id': espace.orgId,
      'type': type,
      'libelle': libelle.text.trim(),
      'pourcentage': pourcentage ? 1 : 0,
      'valeur': v,
      'portee': portee,
      'nb_enfants': type == 'fratrie' ? n : null,
      'actif': 1,
    });
  }

  Future<void> _plafond(BuildContext context, int actuel) async {
    final c = TextEditingController(text: '$actuel');
    final ok = await _formulaire(context, 'Plafond des réductions cumulées', (_) => [
          TextField(controller: c, keyboardType: TextInputType.number, decoration: _champ('Plafond', suffixe: '%')),
        ]);
    final v = int.tryParse(c.text);
    if (ok && v != null && v >= 0 && v <= 100) await _modifier('organisations', espace.orgId, {'reductions_plafond': v});
  }

  @override
  Widget build(BuildContext context) => _Page(
        titre: 'Réductions',
        ajouter: espace.fondateur ? () => _ajouter(context) : null,
        libelleAjouter: 'Réduction',
        corps: Requete('SELECT reductions_cumul, reductions_plafond FROM organisations WHERE id = ?', parametres: [espace.orgId],
            builder: (context, o) {
          final cumul = o.isNotEmpty && o.first['reductions_cumul'] == 1;
          final plafond = o.isEmpty ? 100 : (o.first['reductions_plafond'] as int? ?? 100);
          return Requete('SELECT * FROM regles_reduction WHERE organisation_id = ? ORDER BY type, nb_enfants, created_at',
              parametres: [espace.orgId], builder: (context, regles) {
            return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
              Card(
                child: Column(children: [
                  SwitchListTile(
                    value: cumul,
                    title: const Text('Les réductions se cumulent'),
                    subtitle: Text(cumul
                        ? 'Un élève peut avoir plusieurs réductions, jusqu\'à $plafond % au total.'
                        : 'Une seule réduction par élève : fratrie, sinon enfant du personnel, sinon paiement annuel, sinon personnalisée.'),
                    onChanged: espace.fondateur ? (v) => _modifier('organisations', espace.orgId, {'reductions_cumul': v ? 1 : 0}) : null,
                  ),
                  if (cumul)
                    ListTile(
                      title: Text('Plafond : $plafond %'),
                      trailing: espace.fondateur ? const Icon(Icons.edit_outlined) : null,
                      onTap: espace.fondateur ? () => _plafond(context, plafond) : null,
                    ),
                ]),
              ),
              if (regles.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Aucune réduction. Exemple : fratrie « 2 enfants » -10 %, « 3 enfants » -15 % ; '
                      '« Orphelin » -100 % sur l\'inscription ; « Enfant du personnel » -50 % sur tous les frais.'),
                ),
              for (final r in regles)
                Card(
                  child: SwitchListTile(
                    value: r['actif'] == 1,
                    title: Text('${r['libelle']} : -${r['pourcentage'] == 1 ? '${'${r['valeur']}'.replaceAll('.0', '')} %' : gnf((r['valeur'] as num).toInt())}'),
                    subtitle: Text('${typesReduction[r['type']]?.split(' (').first} · ${porteesReduction[r['portee']]}'
                        '${r['type'] == 'fratrie' ? ' · dès ${r['nb_enfants']} enfants' : ''}'
                        '${r['type'] == 'personnalisee' || r['type'] == 'personnel' ? ' · accordée élève par élève, avec un motif' : ''}'),
                    onChanged: espace.fondateur ? (v) => _modifier('regles_reduction', r['id'] as String, {'actif': v ? 1 : 0}) : null,
                  ),
                ),
            ]);
          });
        }),
      );
}
