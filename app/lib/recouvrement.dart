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
    const largeurCol = 124.0, largeurClasse = 110.0;

    // Une case : ce qui reste à payer ; « payé » si soldé ; en rouge si en retard.
    Widget casePour(_CaseRecouvrement? c) {
      if (c == null || c.du <= 0) return Text('—', style: TextStyle(color: gris));
      final reste = c.du - c.paye;
      if (reste <= 0) return const Text('payé', style: TextStyle(fontSize: 13, color: Couleurs.regle));
      return Tooltip(
        message: 'Dû ${gnf(c.du)} · payé ${gnf(c.paye)}',
        child: Text(_sansUnite(reste),
            style: _chiffresDep.copyWith(fontSize: 13, color: c.retard ? Couleurs.retard : null, fontWeight: c.retard ? FontWeight.w600 : null)),
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
      final largeurNom = (place.maxWidth - fixe).clamp(240.0, double.infinity);
      return Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: bordure)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ligneTableau([
              c(largeurNom, const Text('Élève', style: entete), droite: false),
              if (toutesClasses) c(largeurClasse, const Text('Classe', style: entete), droite: false),
              for (final k in colonnes) c(largeurCol, Text(k, style: entete, overflow: TextOverflow.ellipsis)),
              c(largeurCol, const Text('Dû', style: entete)),
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
                  for (final k in colonnes) c(largeurCol, casePour(l.cases[k])),
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
                for (final k in colonnes)
                  c(largeurCol,
                      Text(total[k] == null ? '—' : _sansUnite(total[k]!.du - total[k]!.paye),
                          style: _chiffresDep.copyWith(fontSize: 13, fontWeight: FontWeight.w600))),
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
                            casePour(l.cases[k]),
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
            _chiffre(context, 'Recouvrement', _taux(paye, du)),
            _chiffre(context, 'Dû', gnf(du)),
            _chiffre(context, 'Réglé', gnf(paye)),
            _chiffre(context, 'Reste', gnf(du - paye)),
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
          Text('Chaque case : ce qui reste à payer. En rouge : en retard (date limite et délai de grâce passés). '
              'Touchez un élève pour ouvrir sa fiche.',
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
            cases: [for (final k in colonnes) l.cases[k] == null ? null : l.cases[k]!.du - l.cases[k]!.paye],
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
      for (final k in colonnes) t('$k (reste)'),
      t('Dû (GNF)'), t('Réglé (GNF)'), t('Reste (GNF)'),
    ]);
    for (final l in lignes) {
      feuille.appendRow([
        t(l.nom), t(l.matricule), t(l.classe),
        for (final k in colonnes) l.cases[k] == null ? t('') : xl.IntCellValue(l.cases[k]!.du - l.cases[k]!.paye),
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
