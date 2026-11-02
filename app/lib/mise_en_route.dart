part of 'configuration.dart';

/// Mise en route d'une école : les réglages dans l'ordre, puis l'import des
/// élèves. Chaque étape dit où elle en est et ouvre la rubrique concernée.

class MiseEnRouteScreen extends StatelessWidget {
  const MiseEnRouteScreen({super.key, required this.espace});

  final Espace espace;

  void _ouvrir(BuildContext context, Widget ecran) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ecran));

  Widget? _rubrique(String cle) {
    for (final r in _reglages) {
      if (r.cle == cle) return r.ecran(espace);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final o = espace.orgId;
    return Requete(
      '''SELECT
           (SELECT code FROM organisations WHERE id = ?) AS sigle,
           (SELECT count(*) FROM sites WHERE organisation_id = ? AND code IS NULL) AS sites_sans_code,
           (SELECT libelle FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1) AS annee,
           (SELECT count(*) FROM niveaux WHERE organisation_id = ?) AS niveaux,
           (SELECT count(*) FROM classes c JOIN annees_scolaires a ON a.id = c.annee_id AND a.en_cours = 1
            WHERE c.organisation_id = ? AND c.fermee = 0) AS classes,
           (SELECT count(*) FROM frais f JOIN annees_scolaires a ON a.id = f.annee_id AND a.en_cours = 1
            WHERE f.organisation_id = ?) AS frais,
           (SELECT count(*) FROM pieces_dossier WHERE organisation_id = ? AND actif = 1) AS pieces,
           (SELECT count(*) FROM eleves WHERE organisation_id = ?) AS eleves,
           (SELECT count(*) FROM ce_poste) AS poste''',
      parametres: [o, o, o, o, o, o, o, o],
      builder: (context, l) {
        final r = l.first;
        int n(String c) => r[c] as int? ?? 0;
        final gris = Theme.of(context).colorScheme.onSurfaceVariant;
        final etapes = <({String titre, String detail, bool fait, bool facultatif, String? cle})>[
          (
            titre: "L'école",
            detail: r['sigle'] == null ? 'Sigle et code du site : ils entrent dans les matricules et les reçus.' : 'Sigle ${r['sigle']}',
            fait: r['sigle'] != null && n('sites_sans_code') == 0,
            facultatif: false,
            cle: 'ecole'
          ),
          (titre: 'Année scolaire', detail: r['annee'] == null ? "Créez l'année de cette rentrée." : '${r['annee']} en cours',
            fait: r['annee'] != null, facultatif: false, cle: 'annee'),
          (titre: 'Niveaux', detail: n('niveaux') == 0 ? 'Partez du modèle guinéen.' : '${n('niveaux')} niveaux',
            fait: n('niveaux') > 0, facultatif: false, cle: 'niveaux'),
          (titre: 'Classes', detail: n('classes') == 0 ? "Créez les classes de l'année (plusieurs groupes d'un coup)." : '${n('classes')} classes',
            fait: n('classes') > 0, facultatif: false, cle: 'classes'),
          (titre: 'Frais scolaires', detail: n('frais') == 0 ? 'Inscription, réinscription, scolarité, calendrier.' : '${n('frais')} frais',
            fait: n('frais') > 0, facultatif: false, cle: 'frais'),
          (titre: 'Pièces du dossier', detail: n('pieces') == 0 ? 'Facultatif : la liste proposée convient au départ.' : '${n('pieces')} pièces',
            fait: n('pieces') > 0, facultatif: true, cle: 'pieces'),
        ];
        final pret = etapes.where((e) => !e.facultatif).every((e) => e.fait);
        Widget pastille(int i, bool fait) => CircleAvatar(
              radius: 14,
              backgroundColor: fait ? Couleurs.regle : Couleurs.doux(context),
              child: fait
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : Text('$i', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: gris)),
            );
        return _Page(
          titre: 'Mise en route',
          corps: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
            Text("Les étapes pour démarrer l'école dans ScolaGrid, dans l'ordre. Ensuite, importez vos élèves en une fois "
                'depuis Excel ou CSV.', style: TextStyle(fontSize: 13, color: gris)),
            const SizedBox(height: 12),
            for (var i = 0; i < etapes.length; i++)
              Card(
                child: ListTile(
                  leading: pastille(i + 1, etapes[i].fait),
                  title: Text(etapes[i].titre + (etapes[i].facultatif ? ' (facultatif)' : '')),
                  subtitle: Text(etapes[i].detail),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    final ecran = _rubrique(etapes[i].cle!);
                    if (ecran != null) _ouvrir(context, ecran);
                  },
                ),
              ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    pastille(etapes.length + 1, n('eleves') > 0),
                    const SizedBox(width: 16),
                    const Expanded(child: Text('Importer les élèves', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                      n('eleves') > 0
                          ? '${n('eleves')} élève(s) dans ScolaGrid. Vous pouvez importer une autre liste si besoin.'
                          : !pret
                              ? "Terminez d'abord les étapes ci-dessus : chaque élève est rangé dans une classe."
                              : n('poste') == 0
                                  ? "Activez d'abord ce poste (accueil, « À faire ») : sa lettre entre dans les matricules."
                                  : 'Un fichier Excel ou CSV, une ligne par élève. Rien n\'est créé avant votre confirmation.',
                      style: TextStyle(fontSize: 13, color: gris)),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: pret && n('poste') > 0 ? () => _ouvrir(context, ImportElevesScreen(espace: espace)) : null,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Importer les élèves'),
                  ),
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }
}
