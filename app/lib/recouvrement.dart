part of 'configuration.dart';

/// Recouvrement : ce qui est dû, réglé et en retard, classe par classe, puis
/// élève par élève et tranche par tranche. Mêmes calculs que la caisse et le
/// tableau de bord (réductions, arrivées en cours d'année, délai de grâce).

/// Mémoire du calcul, refait quand la caisse ou les inscriptions changent.
String? _versionRecouvrement;
Future<_Mesures>? _recouvrementEnCours;
Future<_Mesures> _recouvrement(String org, String version) {
  if (_versionRecouvrement != '$org|$version' || _recouvrementEnCours == null) {
    _versionRecouvrement = '$org|$version';
    _recouvrementEnCours = _mesurer(org, Periode.annee);
  }
  return _recouvrementEnCours!;
}

/// Les colonnes de l'état, dans l'ordre : inscription, tranches par date, autres frais.
List<String> _colonnes(_Mesures m, Iterable<_LigneRecouvrement> lignes) {
  final presentes = {for (final l in lignes) ...l.cases.keys};
  final c = m.colonnesRecouvrement.entries.where((e) => presentes.contains(e.key)).toList()
    ..sort((a, b) {
      final v = a.value.$1.compareTo(b.value.$1);
      if (v != 0) return v;
      final da = a.value.$2, db = b.value.$2;
      if (da == null || db == null) return a.key.compareTo(b.key);
      return da.compareTo(db);
    });
  return [for (final e in c) e.key];
}

String _taux(int paye, int du) => du <= 0 ? '—' : '${(paye * 100 / du).round()} %';

/// Calcule l'état (une seule fois par changement des données) et l'affiche.
class _AvecRecouvrement extends StatelessWidget {
  const _AvecRecouvrement({required this.orgId, required this.builder});

  final String orgId;
  final Widget Function(BuildContext context, _Mesures m) builder;

  @override
  Widget build(BuildContext context) => Requete(
        _sqlVersionSoldes,
        builder: (context, v) => FutureBuilder<_Mesures>(
          future: _recouvrement(orgId, '${v.first}'),
          builder: (context, s) {
            if (s.hasError) return Center(child: Text('Calcul impossible : ${s.error}'));
            if (!s.hasData) return const Center(child: CircularProgressIndicator());
            return builder(context, s.data!);
          },
        ),
      );
}

/// Recouvrement : une seule page. Les élèves directement, avec chaque tranche ;
/// un filtre de classe (toutes par défaut), En retard / Soldés, une recherche.
/// Les grands chiffres en haut suivent le filtre.
class RecouvrementScreen extends StatefulWidget {
  const RecouvrementScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<RecouvrementScreen> createState() => _RecouvrementScreenState();
}

class _RecouvrementScreenState extends State<RecouvrementScreen> {
  String? _classeId; // null : toutes les classes
  String _filtre = 'tous'; // tous, retard, soldes
  String _recherche = '';
  int _affiches = 100; // lignes affichées (les grandes écoles : « Afficher plus »)

  @override
  Widget build(BuildContext context) => Scaffold(
        body: _AvecRecouvrement(orgId: widget.espace.orgId, builder: _contenu),
      );

  Widget _contenu(BuildContext context, _Mesures m) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    final telephone = MediaQuery.sizeOf(context).width < 640;

    // Les classes, dans l'ordre des niveaux, avec leur effectif.
    final classes = <String, ({String nom, int ordre, int n})>{};
    for (final l in m.recouvrement) {
      final c = classes[l.classeId];
      classes[l.classeId] = (nom: l.classe, ordre: l.ordre, n: (c?.n ?? 0) + 1);
    }
    final ordreClasses = classes.entries.toList()
      ..sort((a, b) {
        final v = a.value.ordre.compareTo(b.value.ordre);
        return v != 0 ? v : a.value.nom.compareTo(b.value.nom);
      });
    if (_classeId != null && !classes.containsKey(_classeId)) _classeId = null;
    final toutesClasses = _classeId == null;

    final q = nomSimplifie(_recherche.trim());
    final toutes = m.recouvrement
        .where((l) => (_classeId == null || l.classeId == _classeId) &&
            (q.isEmpty || nomSimplifie(l.nom).contains(q) || l.matricule.toLowerCase().contains(q.toLowerCase())))
        .toList()
      ..sort((a, b) {
        final v = a.ordre.compareTo(b.ordre);
        if (v != 0) return v;
        final c = a.classe.compareTo(b.classe);
        return c != 0 ? c : nomSimplifie(a.nom).compareTo(nomSimplifie(b.nom));
      });
    final lignes = toutes.where((l) => switch (_filtre) {
          'retard' => l.retard > 0,
          'soldes' => l.du > 0 && l.reste <= 0,
          _ => true,
        }).toList();
    final visibles = lignes.take(_affiches).toList();
    final colonnes = _colonnes(m, toutes);
    int somme(Iterable<_LigneRecouvrement> l, int Function(_LigneRecouvrement) f) => l.fold(0, (s, x) => s + f(x));
    final du = somme(toutes, (x) => x.du), paye = somme(toutes, (x) => x.paye);
    final enRetard = toutes.where((l) => l.retard > 0).length;
    final soldes = toutes.where((l) => l.du > 0 && l.reste <= 0).length;
    final nomClasse = _classeId == null ? 'Toutes les classes' : classes[_classeId]!.nom;
    const entete = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    // Avec la colonne Classe en plus, des colonnes un peu plus étroites : tout tient à l'écran.
    final largeurCol = toutesClasses ? 108.0 : 124.0;
    const largeurClasse = 96.0;

    // L'échéance sous le nom de la colonne (« 15/10 »), quand c'est une tranche datée.
    String? echeance(String k) {
      final d = m.colonnesRecouvrement[k]?.$2;
      return d == null ? null : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
    }

    // Une case : ce que l'élève a VERSÉ sur cette tranche (comme l'état papier).
    // Soldée : écrit normalement ; échéance passée et pas soldée : en rouge ;
    // pas encore due : en gris. Le détail (attendu, reste) au survol.
    Widget casePour(_CaseRecouvrement? c, {_LigneRecouvrement? ligne, String? colonne}) {
      if (c == null || c.du <= 0) return Text('—', style: TextStyle(color: gris));
      final reste = c.du - c.paye;
      // Un montant versé s'ouvre : les reçus qui le composent (souligné en pointillé).
      if (c.paye > 0 && ligne != null && colonne != null) {
        return InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => _recusDeLaCase(context, m, ligne, colonne, colonnes, echeance(colonne)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(_sansUnite(c.paye),
                style: _chiffresDep.copyWith(
                    fontSize: 13,
                    color: reste <= 0 ? schema.onSurface : (c.retard ? Couleurs.retard : gris),
                    fontWeight: reste > 0 && c.retard ? FontWeight.w600 : null,
                    decoration: TextDecoration.underline,
                    decorationStyle: TextDecorationStyle.dotted,
                    decorationColor: gris)),
          ),
        );
      }
      return Tooltip(
        message: reste <= 0
            ? 'Soldé : ${gnf(c.paye)} versés'
            : '${c.paye == 0 ? 'Aucun versement' : 'Versé ${gnf(c.paye)}'} sur ${gnf(c.du)} attendus · reste ${gnf(reste)}',
        child: Text(_sansUnite(c.paye),
            style: _chiffresDep.copyWith(
                fontSize: 13,
                color: reste <= 0 ? schema.onSurface : (c.retard ? Couleurs.retard : gris),
                fontWeight: reste > 0 && c.retard ? FontWeight.w600 : null)),
      );
    }


    void ouvrirEleve(_LigneRecouvrement l) =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: widget.espace, eleveId: l.eleveId)));

    Widget ligneTableau(List<Widget> cases, {Color? fond, VoidCallback? auClic, bool entetes = false}) => InkWell(
          onTap: auClic,
          hoverColor: Couleurs.doux(context).withValues(alpha: .5),
          child: Container(
            color: fond,
            padding: EdgeInsets.fromLTRB(8, entetes ? 12 : 16, 8, entetes ? 12 : 16),
            decoration: fond == null ? BoxDecoration(border: Border(bottom: BorderSide(color: bordure))) : null,
            child: Row(children: cases),
          ),
        );
    Widget c(double l, Widget w, {bool droite = true}) => SizedBox(
        width: l,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(alignment: droite ? Alignment.centerRight : Alignment.centerLeft, child: w),
        ));

    final total = <String, ({int du, int paye})>{};
    for (final l in lignes) {
      for (final k in colonnes) {
        final x = l.cases[k];
        if (x == null) continue;
        final t = total[k];
        total[k] = (du: (t?.du ?? 0) + x.du, paye: (t?.paye ?? 0) + x.paye);
      }
    }
    final duF = somme(lignes, (x) => x.du), payeF = somme(lignes, (x) => x.paye);

    // La colonne des noms prend la place libre : le tableau remplit son cadre.
    final tableau = LayoutBuilder(builder: (context, place) {
      final fixe = largeurCol * (colonnes.length + 3) + (toutesClasses ? largeurClasse : 0) + 16 + 2;
      final largeurNom = (place.maxWidth - fixe).clamp(200.0, double.infinity);
      return Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: bordure)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ligneTableau([
              c(largeurNom, const Text('Élève', style: entete), droite: false),
              if (toutesClasses) c(largeurClasse, const Text('Classe', style: entete), droite: false),
              for (final k in colonnes)
                c(
                    largeurCol,
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(k, style: entete, overflow: TextOverflow.ellipsis),
                      if (echeance(k) != null) Text(echeance(k)!, style: TextStyle(fontSize: 11, color: gris)),
                    ])),
              c(largeurCol, const Text('Total dû', style: entete)),
              c(largeurCol, const Text('Réglé', style: entete)),
              c(largeurCol, const Text('Reste', style: entete)),
            ], entetes: true),
            if (lignes.isEmpty)
              SizedBox(
                width: largeurNom + fixe - 18,
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text('Aucun élève.', textAlign: TextAlign.center, style: TextStyle(color: gris)),
                ),
              ),
            for (final l in visibles)
              ligneTableau(
                [
                  c(
                      largeurNom,
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l.nom, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        Text(l.matricule, style: styleMono.copyWith(fontSize: 11, color: gris)),
                      ]),
                      droite: false),
                  if (toutesClasses) c(largeurClasse, Text(l.classe, style: const TextStyle(fontSize: 13)), droite: false),
                  for (final k in colonnes) c(largeurCol, casePour(l.cases[k], ligne: l, colonne: k)),
                  c(largeurCol, Text(_sansUnite(l.du), style: _chiffresDep.copyWith(fontSize: 13))),
                  c(largeurCol, Text(_sansUnite(l.paye), style: _chiffresDep.copyWith(fontSize: 13))),
                  c(
                      largeurCol,
                      Text(l.reste <= 0 ? 'soldé' : _sansUnite(l.reste),
                          style: _chiffresDep.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: l.reste <= 0 ? Couleurs.regle : (l.retard > 0 ? Couleurs.retard : null)))),
                ],
                auClic: () => ouvrirEleve(l),
              ),
            if (lignes.isNotEmpty)
              ligneTableau([
                c(largeurNom, Text(lignes.length > visibles.length ? 'Total (${lignes.length} élèves)' : 'Total', style: entete), droite: false),
                if (toutesClasses) c(largeurClasse, const SizedBox()),
                // Par tranche : l'encaissé, et sa part de l'attendu.
                for (final k in colonnes)
                  c(
                      largeurCol,
                      total[k] == null
                          ? Text('—', style: TextStyle(color: gris))
                          : Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              Text(_sansUnite(total[k]!.paye), style: _chiffresDep.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
                              Text(_taux(total[k]!.paye, total[k]!.du), style: TextStyle(fontSize: 11, color: gris)),
                            ])),
                c(largeurCol, Text(_sansUnite(duF), style: _chiffresDep.copyWith(fontSize: 13, fontWeight: FontWeight.w600))),
                c(largeurCol, Text(_sansUnite(payeF), style: _chiffresDep.copyWith(fontSize: 13, fontWeight: FontWeight.w600))),
                c(largeurCol, Text(_sansUnite(duF - payeF), style: _chiffresDep.copyWith(fontSize: 13, fontWeight: FontWeight.w700))),
              ], fond: Couleurs.doux(context)),
          ]),
        ),
      );
    });

    // Téléphone : une carte par élève, ses tranches en dessous (pas de tableau à faire glisser).
    Widget cartes() => Column(children: [
          for (final l in visibles)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                onTap: () => ouvrirEleve(l),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l.nom, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                          Text(toutesClasses ? '${l.classe} · ${l.matricule}' : l.matricule,
                              style: styleMono.copyWith(fontSize: 11, color: gris)),
                        ]),
                      ),
                      Text(l.reste <= 0 ? 'soldé' : gnf(l.reste),
                          style: _chiffresDep.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: l.reste <= 0 ? Couleurs.regle : (l.retard > 0 ? Couleurs.retard : null))),
                    ]),
                    const SizedBox(height: 8),
                    Wrap(spacing: 14, runSpacing: 6, children: [
                      for (final k in colonnes)
                        if (l.cases[k] != null && l.cases[k]!.du > 0)
                          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text(k, style: TextStyle(fontSize: 11, color: gris)),
                            casePour(l.cases[k], ligne: l, colonne: k),
                          ]),
                    ]),
                  ]),
                ),
              ),
            ),
          if (lignes.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text('Aucun élève.', style: TextStyle(color: gris))),
        ]);

    // Filtre de classe, à la façon de la page Élèves.
    final menuClasse = SizedBox(
      width: telephone ? double.infinity : 220,
      height: 36,
      child: DropdownButtonHideUnderline(
        child: Container(
          padding: const EdgeInsets.only(left: 12, right: 8),
          decoration: BoxDecoration(border: Border.all(color: bordure), borderRadius: BorderRadius.circular(6), color: schema.surface),
          child: DropdownButton<String?>(
            value: _classeId,
            isExpanded: true,
            isDense: true,
            icon: Icon(Icons.keyboard_arrow_down, size: 18, color: gris),
            style: TextStyle(fontFamily: policeTexte, fontSize: 14, color: schema.onSurface),
            items: [
              DropdownMenuItem<String?>(value: null, child: Text('Toutes les classes  ${m.recouvrement.length}')),
              for (final e in ordreClasses)
                DropdownMenuItem<String?>(value: e.key, child: Text('${e.value.nom}  ${e.value.n}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() {
              _classeId = v;
              _affiches = 100;
            }),
          ),
        ),
      ),
    );
    final champRecherche = SizedBox(
      width: telephone ? double.infinity : 260,
      height: 36,
      child: TextField(
        onChanged: (v) => setState(() {
          _recherche = v;
          _affiches = 100;
        }),
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          prefixIcon: Icon(Icons.search, size: 18, color: gris),
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          hintText: 'Nom ou matricule',
          hintStyle: TextStyle(fontSize: 14, color: gris),
        ),
      ),
    );

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 12, children: [
                const Text('Recouvrement', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -.2)),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('${m.annee ?? ''} · $nomClasse', style: TextStyle(fontSize: 14, color: gris)),
                ),
              ]),
            ),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                onPressed: lignes.isEmpty ? null : () => _imprimer(m, colonnes, lignes, nomClasse, toutesClasses),
                icon: const Icon(Icons.print_outlined, size: 16),
                label: const Text('Imprimer'),
              ),
              if (!telephone)
                OutlinedButton.icon(
                  onPressed: lignes.isEmpty ? null : () => _exporter(colonnes, lignes, nomClasse),
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: const Text('Excel'),
                ),
            ]),
          ]),
          const SizedBox(height: 16),
          // Les grands chiffres, pour la classe choisie (ou toute l'école).
          Wrap(spacing: 32, runSpacing: 12, children: [
            _chiffre(context, 'Attendu', gnf(du)),
            _chiffre(context, 'Encaissé', gnf(paye)),
            _chiffre(context, 'Reste à percevoir', gnf(du - paye)),
            _chiffre(context, 'Recouvrement', _taux(paye, du)),
            _chiffre(context, 'Soldés', '$soldes / ${toutes.length}'),
            _chiffre(context, 'En retard', '$enRetard élève(s)', alerte: enRetard > 0),
          ]),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            menuClasse,
            Segments<String>(
              valeur: _filtre,
              choix: {
                'tous': 'Tous (${toutes.length})',
                'retard': 'En retard ($enRetard)',
                'soldes': 'Soldés ($soldes)',
              },
              onChanged: (v) => setState(() {
                _filtre = v;
                _affiches = 100;
              }),
            ),
            champRecherche,
          ]),
          const SizedBox(height: 12),
          Text('Chaque case : ce que l\'élève a versé sur la tranche. En rouge : échéance passée, tranche pas soldée. '
              'Montant souligné : touchez-le pour voir les reçus. Touchez un élève pour ouvrir sa fiche.',
              style: TextStyle(fontSize: 13, color: gris)),
          const SizedBox(height: 12),
          if (telephone) cartes() else tableau,
          if (lignes.length > visibles.length) ...[
            const SizedBox(height: 12),
            Center(
              child: OutlinedButton(
                onPressed: () => setState(() => _affiches += 200),
                child: Text('Afficher plus (${lignes.length - visibles.length} autres)'),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  /// Les reçus qui composent une case : l'imputation suit l'ordre des tranches
  /// (les versements de scolarité remplissent la 1re tranche, puis la suivante).
  Future<void> _recusDeLaCase(BuildContext context, _Mesures m, _LigneRecouvrement l, String colonne, List<String> colonnes,
      String? echeance) async {
    final c = l.cases[colonne]!;
    final tranche = m.colonnesRecouvrement[colonne]?.$1 == 1;
    final type = tranche ? "f.type_frais = 'scolarite'" : (colonne == 'Autres frais' ? "f.type_frais = 'optionnel'" : "f.type_frais NOT IN ('scolarite', 'optionnel')");
    final versements = await db.getAll('''
        SELECT e.id, e.numero, e.date_effective, e.mode, e.reference, e.payeur_nom, e.total_gnf, l.montant_gnf, l.imputation
        FROM lignes_encaissement l
        JOIN encaissements e ON e.id = l.encaissement_id AND e.statut = 'valide' AND e.confirmation <> 'rejete'
        JOIN frais f ON f.id = l.frais_id
        JOIN annees_scolaires a ON a.id = e.annee_id AND a.en_cours = 1
        WHERE l.eleve_id = ? AND $type
        ORDER BY e.date_effective, e.created_at''', [l.eleveId]);
    // La part de chaque reçu dans cette case.
    final parts = <(Map<String, Object?>, int)>[];
    if (tranche) {
      var avant = 0;
      for (final k in colonnes) {
        if (k == colonne) break;
        if (m.colonnesRecouvrement[k]?.$1 == 1) avant += l.cases[k]?.du ?? 0;
      }
      final fin = avant + c.du;
      var cumul = 0;
      for (final v in versements) {
        final montant = v['montant_gnf'] as int? ?? 0;
        final debut = cumul;
        cumul += montant;
        // La répartition enregistrée avec le reçu fait foi ; sinon, le calcul dans l'ordre.
        final enregistree = _partEnregistree(v['imputation'], colonne);
        final part = enregistree ?? (cumul < fin ? cumul : fin) - (debut > avant ? debut : avant);
        if (part > 0) parts.add((v, part));
      }
    } else {
      for (final v in versements) {
        parts.add((v, v['montant_gnf'] as int? ?? 0));
      }
    }
    if (!context.mounted) return;
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    await showDialog<void>(
      context: context,
      builder: (dialogue) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$colonne · ${l.nom}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('${echeance == null ? '' : 'Échéance $echeance · '}attendu ${gnf(c.du)}', style: TextStyle(fontSize: 13, color: gris)),
        ]),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Divider(height: 1),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                if (parts.isEmpty)
                  Padding(padding: const EdgeInsets.all(20), child: Text('Aucun reçu trouvé.', style: TextStyle(color: gris))),
                for (final (v, part) in parts)
                  InkWell(
                    onTap: () {
                      Navigator.pop(dialogue);
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => RecuScreen(espace: widget.espace, encaissementId: v['id'] as String)));
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Expanded(child: Text('${v['numero']}', style: styleMono.copyWith(fontSize: 12))),
                          Text(gnf(part), style: _chiffresDep.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
                        ]),
                        const SizedBox(height: 2),
                        Text(
                            [
                              _dateLisible(v['date_effective']),
                              modesPaiement[v['mode']] ?? '${v['mode']}',
                              if (v['reference'] != null) '${v['reference']}',
                              if ((v['total_gnf'] as int? ?? 0) != part) 'versement de ${gnf(v['total_gnf'])}',
                            ].join(' · '),
                            style: TextStyle(fontSize: 12, color: gris)),
                        Text('Payé par ${v['payeur_nom']}', style: TextStyle(fontSize: 12, color: gris)),
                      ]),
                    ),
                  ),
              ]),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
              child: Row(children: [
                Expanded(
                    child: Text(c.du - c.paye > 0 ? 'Reste ${gnf(c.du - c.paye)}' : 'Tranche soldée',
                        style: TextStyle(fontSize: 13, color: gris))),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(dialogue);
                    Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: widget.espace, eleveId: l.eleveId)));
                  },
                  icon: const Icon(Icons.receipt_long_outlined, size: 16),
                  label: const Text('Tous les reçus'),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  /// La part d'une tranche dans la répartition enregistrée (null : pas de répartition).
  static int? _partEnregistree(Object? imputation, String tranche) {
    if (imputation == null || '$imputation'.isEmpty) return null;
    try {
      final l = (jsonDecode('$imputation') as List).cast<Map<String, dynamic>>();
      return l.where((x) => x['tranche'] == tranche).fold<int>(0, (s, x) => s + ((x['montant'] as num?)?.toInt() ?? 0));
    } catch (_) {
      return null;
    }
  }

  Widget _chiffre(BuildContext context, String libelle, String valeur, {bool alerte = false}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(libelle, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(valeur, style: _chiffresDep.copyWith(fontSize: 18, fontWeight: FontWeight.w600, color: alerte ? Couleurs.retard : null)),
      ]);

  Future<void> _imprimer(_Mesures m, List<String> colonnes, List<_LigneRecouvrement> lignes, String classe, bool toutes) async {
    final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [widget.espace.orgId]);
    final pdf = await etatRecouvrementPdf(
      ecole: Map.of(ecole),
      classe: classe,
      annee: m.annee ?? '',
      colonnes: colonnes,
      lignes: [
        for (final l in lignes)
          (
            nom: toutes ? '${l.nom} (${l.classe})' : l.nom,
            matricule: l.matricule,
            cases: [for (final k in colonnes) l.cases[k] == null || l.cases[k]!.du <= 0 ? null : l.cases[k]!.paye],
            du: l.du,
            paye: l.paye,
          ),
      ],
      images: await _imagesEcole(widget.espace.orgId),
    );
    await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Recouvrement $classe');
  }

  Future<void> _exporter(List<String> colonnes, List<_LigneRecouvrement> lignes, String classe) async {
    final messager = ScaffoldMessenger.of(context);
    final classeur = xl.Excel.createExcel();
    final feuille = classeur['Recouvrement'];
    classeur.setDefaultSheet('Recouvrement');
    xl.TextCellValue t(Object? v) => xl.TextCellValue(v == null ? '' : '$v');
    feuille.appendRow([
      t('Élève'), t('Matricule'), t('Classe'),
      for (final k in colonnes) t('$k (versé)'),
      t('Dû (GNF)'), t('Réglé (GNF)'), t('Reste (GNF)'),
    ]);
    for (final l in lignes) {
      feuille.appendRow([
        t(l.nom), t(l.matricule), t(l.classe),
        for (final k in colonnes) l.cases[k] == null ? t('') : xl.IntCellValue(l.cases[k]!.paye),
        xl.IntCellValue(l.du), xl.IntCellValue(l.paye), xl.IntCellValue(l.reste),
      ]);
    }
    await _enregistrerClasseur(messager, classeur, 'Recouvrement', 'recouvrement-${classe.replaceAll(' ', '-')}.xlsx');
  }
}

Future<void> _enregistrerClasseur(ScaffoldMessengerState messager, xl.Excel classeur, String feuille, String nom) async {
  for (final f in classeur.tables.keys.toList()) {
    if (f != feuille) classeur.delete(f);
  }
  final octets = classeur.encode();
  if (octets == null) return;
  try {
    await FilePicker.saveFile(dialogTitle: 'Exporter', fileName: nom, bytes: Uint8List.fromList(octets));
    messager.showSnackBar(const SnackBar(content: Text('Fichier exporté.')));
  } catch (_) {
    messager.showSnackBar(const SnackBar(content: Text("Impossible d'enregistrer le fichier sur cet appareil.")));
  }
}
