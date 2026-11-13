part of 'configuration.dart';

/// Notes et bulletins (lot 5) : la fin d'année d'une classe. La moyenne annuelle
/// (simple, ou la dernière période pesant plus) propose Admis ou Redouble selon le
/// seuil du barème ; le conseil décide, et la décision alimente la réinscription.
/// Spécification §6.7, §9 : « le calcul propose, le conseil dispose ».

const decisionsAnnee = {
  'admis': 'Admis',
  'redouble': 'Redouble',
  'admis_conseil': 'Admis par décision du conseil',
  'exclu': 'Exclu',
  'oriente': 'Orienté',
};

class _FinAnnee extends StatelessWidget {
  const _FinAnnee({
    required this.espace,
    required this.annee,
    required this.classe,
    required this.periodes,
    required this.peutDecider,
  });

  final Espace espace;
  final Map<String, Object?> annee;
  final Map<String, Object?> classe;
  /// Les périodes du cycle de la classe, dans l'ordre.
  final List<Map<String, Object?>> periodes;
  final bool peutDecider;

  @override
  Widget build(BuildContext context) => Requete(
        '''SELECT i.id AS ins, e.id, e.nom, e.prenoms, e.matricule,
             (SELECT count(*) FROM inscriptions r WHERE r.eleve_id = e.id AND r.redoublant = 1) AS redoublements,
             d.id AS decision_id, d.decision, d.motif
           FROM inscriptions i JOIN eleves e ON e.id = i.eleve_id
           LEFT JOIN decisions_annee d ON d.inscription_id = i.id
           WHERE i.classe_id = ? AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')
           ORDER BY e.nom, e.prenoms''',
        parametres: [classe['id']],
        builder: (context, eleves) => Requete(
          'SELECT id, nom, coefficient FROM matieres WHERE niveau_id = ? ORDER BY nom',
          parametres: [classe['niveau_id']],
          builder: (context, matieres) => Requete(
            '''SELECT n.eleve_id, n.valeur, n.etat, ev.matiere_id, ev.periode_id, t.poids, t.compte
               FROM notes n JOIN evaluations ev ON ev.id = n.evaluation_id JOIN types_evaluation t ON t.id = ev.type_id
               WHERE ev.classe_id = ?''',
            parametres: [classe['id']],
            builder: (context, notes) => Requete(
              '''SELECT r.*, o.redoublements_max FROM organisations o LEFT JOIN regles_notes r ON r.organisation_id = o.id
                 WHERE o.id = ?''',
              parametres: [espace.orgId],
              builder: (context, regles) => _SelonSynchro(
                builder: (context, synchronise) =>
                    _contenu(context, eleves, matieres, notes, regles.isEmpty ? const {} : regles.first, synchronise),
              ),
            ),
          ),
        ),
      );

  Widget _contenu(BuildContext context, Lignes eleves, Lignes matieres, Lignes notes, Map<String, Object?> regles, bool synchronise) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    final parAcquis = periodes.isNotEmpty && periodes.every((p) => p['nature'] == 'appreciations');
    final bareme = periodes.isEmpty ? 20 : periodes.first['bareme'] as int? ?? 20;
    final absences = '${regles['absences'] ?? 'justifie_exclu'}';
    final seuil = ((bareme == 10 ? regles['seuil_passage_10'] : regles['seuil_passage_20']) as num?)?.toDouble() ?? bareme / 2;
    final ponderee = regles['moyenne_annuelle'] == 'ponderee';
    final poidsDerniere = (regles['poids_derniere'] as num?)?.toDouble() ?? 2;
    final maxRedoublements = regles['redoublements_max'] as int? ?? 1;

    // Moyenne générale de chaque période (repartie des notes), puis la moyenne annuelle.
    final parPeriode = <String, Map<String, double?>>{}; // période → élève → moyenne
    for (final p in periodes) {
      final parEleveMatiere = <String, List<NoteCalcul>>{};
      for (final n in notes.where((n) => n['periode_id'] == p['id'])) {
        parEleveMatiere.putIfAbsent('${n['eleve_id']}|${n['matiere_id']}', () => []).add(NoteCalcul(
              valeur: (n['valeur'] as num?)?.toDouble(),
              etat: '${n['etat']}',
              poids: (n['poids'] as num? ?? 1).toDouble(),
              compte: n['compte'] == 1,
            ));
      }
      parPeriode[p['id'] as String] = {
        for (final e in eleves)
          e['id'] as String: moyenneGenerale([
            for (final m in matieres)
              (
                moyenneMatiere(parEleveMatiere['${e['id']}|${m['id']}'] ?? const [], absences: absences),
                (m['coefficient'] as num? ?? 1).toDouble(),
              ),
          ]),
      };
    }
    final annuelle = <String, double?>{};
    for (final e in eleves) {
      var somme = 0.0, poids = 0.0;
      for (var i = 0; i < periodes.length; i++) {
        final v = parPeriode[periodes[i]['id']]![e['id']];
        if (v == null) continue;
        final w = ponderee && i == periodes.length - 1 ? poidsDerniere : 1.0;
        somme += v * w;
        poids += w;
      }
      annuelle[e['id'] as String] = poids == 0 ? null : somme / poids;
    }
    final rang = synchronise ? rangs(annuelle) : <String, int>{};
    String? proposition(String eleve) {
      final m = annuelle[eleve];
      if (parAcquis || m == null) return null;
      return m >= seuil - 1e-9 ? 'admis' : 'redouble';
    }

    Future<void> decider(Map<String, Object?> e, String decision) async {
      final messager = ScaffoldMessenger.of(context);
      String? motif;
      // « Admis par décision du conseil » s'écarte du calcul : motif obligatoire.
      if (decision == 'admis_conseil' || decision == 'exclu' || decision == 'oriente') {
        final c = TextEditingController(text: '${e['motif'] ?? ''}');
        final ok = await _formulaire(context, '${decisionsAnnee[decision]} · ${e['nom']} ${e['prenoms']}', (_) => [
              TextField(
                controller: c,
                autofocus: true,
                maxLength: 300,
                maxLines: 2,
                decoration: _champ(decision == 'admis_conseil' ? 'Motif (obligatoire)' : 'Motif',
                    aide: 'Par exemple : progression constante au 2e semestre'),
              ),
            ]);
        if (!ok) return;
        motif = c.text.trim().isEmpty ? null : c.text.trim();
        if (decision == 'admis_conseil' && (motif == null || motif.length < 3)) {
          messager.showSnackBar(const SnackBar(content: Text('Un motif est obligatoire quand le conseil s\'écarte du calcul.')));
          return;
        }
      }
      final valeurs = {
        'decision': decision,
        'motif': motif,
        'moyenne_annuelle': annuelle[e['id']],
        'proposition': proposition(e['id'] as String),
      };
      if (e['decision_id'] != null) {
        await _modifier('decisions_annee', e['decision_id'] as String, {...valeurs, 'par': monId});
      } else {
        await _inserer('decisions_annee', {
          ...valeurs,
          'organisation_id': espace.orgId,
          'annee_id': annee['id'],
          'inscription_id': e['ins'],
          'eleve_id': e['id'],
          'par': monId,
        });
      }
    }

    Future<void> suivreLesPropositions() async {
      for (final e in eleves) {
        final p = proposition(e['id'] as String);
        if (e['decision'] == null && p != null) await decider(e, p);
      }
    }

    Future<void> imprimer(List<Map<String, Object?>> qui) async {
      final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [espace.orgId]);
      final pdf = await bulletinsAnnuelsPdf(
        ecole: Map.of(ecole),
        annee: '${annee['libelle']}',
        classe: '${classe['nom']}',
        bareme: bareme,
        effectif: eleves.length,
        bulletins: [
          for (final e in qui)
            (
              nom: '${e['nom']} ${e['prenoms']}',
              matricule: '${e['matricule']}',
              periodes: [for (final p in periodes) (libelle: '${p['libelle']}', moyenne: parPeriode[p['id']]![e['id']])],
              moyenne: annuelle[e['id']],
              rang: rang[e['id']],
              decision: e['decision'] == null ? null : decisionsAnnee[e['decision']],
            ),
        ],
        images: await _imagesEcole(espace.orgId),
      );
      await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Bulletins de fin d\'année ${classe['nom']}');
    }

    final ordre = [...eleves]..sort((a, b) {
        final ra = rang[a['id']], rb = rang[b['id']];
        if (ra == null && rb == null) return nomSimplifie('${a['nom']}').compareTo(nomSimplifie('${b['nom']}'));
        if (ra == null) return 1;
        if (rb == null) return -1;
        return ra.compareTo(rb);
      });
    final sansDecision = eleves.where((e) => e['decision'] == null).length;

    Widget cellule(double l, Widget w, {bool droite = true}) => SizedBox(
        width: l,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Align(alignment: droite ? Alignment.centerRight : Alignment.centerLeft, child: w),
        ));
    const entete = TextStyle(fontSize: 12, fontWeight: FontWeight.w600);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!synchronise)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Couleurs.attenteFond, borderRadius: BorderRadius.circular(8)),
          child: const Text('Poste pas à jour : le rang annuel et les bulletins attendent la synchronisation.'),
        ),
      Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(
            parAcquis
                ? 'Maternelle : pas de moyenne ; le conseil décide pour chaque enfant.'
                : 'Moyenne annuelle ${ponderee ? 'pondérée (dernière période ×${noteLisible(poidsDerniere).replaceAll(',00', '')})' : 'simple'} '
                    'sur $bareme · passage à partir de ${noteLisible(seuil).replaceAll(',00', '')} · '
                    '$sansDecision décision(s) à prendre',
            style: TextStyle(fontSize: 13, color: gris)),
        if (peutDecider && sansDecision > 0 && !parAcquis)
          OutlinedButton.icon(
            onPressed: suivreLesPropositions,
            icon: const Icon(Icons.done_all, size: 16),
            label: const Text('Suivre les propositions'),
          ),
        FilledButton.icon(
          onPressed: eleves.isEmpty || !synchronise || parAcquis ? null : () => imprimer(ordre),
          icon: const Icon(Icons.print_outlined, size: 16),
          label: const Text('Bulletins de fin d\'année'),
        ),
      ]),
      const SizedBox(height: 12),
      Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: bordure)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bordure))),
              child: Row(children: [
                cellule(48, const Text('Rang', style: entete)),
                cellule(230, const Text('Élève', style: entete), droite: false),
                if (!parAcquis) ...[
                  for (final p in periodes) cellule(104, Text('${p['libelle']}', style: entete, overflow: TextOverflow.ellipsis)),
                  cellule(104, const Text('Annuelle', style: entete)),
                  cellule(110, const Text('Proposition', style: entete), droite: false),
                ],
                cellule(260, const Text('Décision du conseil', style: entete), droite: false),
              ]),
            ),
            for (final e in ordre)
              Container(
                padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bordure))),
                child: Row(children: [
                  cellule(48, Text(rangLisible(rang[e['id']]), style: const TextStyle(fontSize: 13))),
                  cellule(
                      230,
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${e['nom']} ${e['prenoms']}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        Text('${e['matricule']}', style: styleMono.copyWith(fontSize: 11, color: gris)),
                      ]),
                      droite: false),
                  if (!parAcquis) ...[
                    for (final p in periodes)
                      cellule(104, Text(noteLisible(parPeriode[p['id']]![e['id']]), style: _chiffresDep.copyWith(fontSize: 13))),
                    cellule(
                        104,
                        Text(noteLisible(annuelle[e['id']]),
                            style: _chiffresDep.copyWith(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: annuelle[e['id']] != null && annuelle[e['id']]! < seuil ? Couleurs.retard : null))),
                    cellule(
                        110,
                        proposition(e['id'] as String) == null
                            ? Text('—', style: TextStyle(color: gris))
                            : Etat(decisionsAnnee[proposition(e['id'] as String)]!,
                                ton: proposition(e['id'] as String) == 'admis' ? Ton.regle : Ton.attente),
                        droite: false),
                  ],
                  cellule(
                    260,
                    Row(children: [
                      Expanded(
                        child: peutDecider
                            ? DropdownButton<String?>(
                                value: e['decision'] as String?,
                                isExpanded: true,
                                isDense: true,
                                underline: const SizedBox.shrink(),
                                hint: const Text('À décider', style: TextStyle(fontSize: 13)),
                                style: TextStyle(fontFamily: policeTexte, fontSize: 13, color: schema.onSurface),
                                items: [for (final d in decisionsAnnee.entries) DropdownMenuItem(value: d.key, child: Text(d.value))],
                                onChanged: (v) => v == null ? null : decider(e, v),
                              )
                            : Text(e['decision'] == null ? 'À décider' : decisionsAnnee[e['decision']]!, style: const TextStyle(fontSize: 13)),
                      ),
                      // La limite de redoublement de l'école : le système alerte, le conseil tranche.
                      if ((e['decision'] == 'redouble' || (e['decision'] == null && proposition(e['id'] as String) == 'redouble')) &&
                          (e['redoublements'] as int? ?? 0) + 1 > maxRedoublements)
                        Tooltip(
                          message: 'Limite de redoublement de l\'école atteinte ($maxRedoublements) : orientation ou autre décision ?',
                          child: const Icon(Icons.warning_amber, size: 18, color: Couleurs.retard),
                        ),
                      if (e['motif'] != null)
                        Tooltip(message: '${e['motif']}', child: Icon(Icons.notes, size: 18, color: gris)),
                      if (synchronise && !parAcquis)
                        IconButton(
                          tooltip: 'Imprimer son bulletin de fin d\'année',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.print_outlined, size: 18),
                          onPressed: () => imprimer([e]),
                        ),
                    ]),
                    droite: false,
                  ),
                ]),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      Text('La décision est reprise à la réinscription : admis, niveau suivant ; redouble, même niveau.',
          style: TextStyle(fontSize: 12, color: gris)),
    ]);
  }
}
