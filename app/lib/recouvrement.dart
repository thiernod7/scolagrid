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

class RecouvrementScreen extends StatelessWidget {
  const RecouvrementScreen({super.key, required this.espace});

  final Espace espace;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: _AvecRecouvrement(orgId: espace.orgId, builder: (context, m) => _classes(context, m)),
      );

  Widget _classes(BuildContext context, _Mesures m) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    final largeur = MediaQuery.sizeOf(context).width;
    final telephone = largeur < 640;
    // Une ligne par classe, dans l'ordre des niveaux.
    final parClasse = <String, List<_LigneRecouvrement>>{};
    for (final l in m.recouvrement) {
      parClasse.putIfAbsent(l.classeId, () => []).add(l);
    }
    final classes = parClasse.values.toList()
      ..sort((a, b) {
        final v = a.first.ordre.compareTo(b.first.ordre);
        return v != 0 ? v : a.first.classe.compareTo(b.first.classe);
      });
    int somme(Iterable<_LigneRecouvrement> l, int Function(_LigneRecouvrement) f) => l.fold(0, (s, x) => s + f(x));
    final du = somme(m.recouvrement, (x) => x.du);
    final paye = somme(m.recouvrement, (x) => x.paye);
    const entete = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);

    Widget cellule(double? l, Widget w, {int flex = 1, bool droite = false}) {
      final c = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(alignment: droite ? Alignment.centerRight : Alignment.centerLeft, child: w),
      );
      return l == null ? Expanded(flex: flex, child: c) : SizedBox(width: l, child: c);
    }

    Widget barre(int p, int d) => ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: d <= 0 ? 0 : (p / d).clamp(0, 1).toDouble(),
            minHeight: 4,
            backgroundColor: Couleurs.doux(context),
            color: d > 0 && p * 100 / d < 70 ? Couleurs.attente : Couleurs.regle,
          ),
        );

    void ouvrir(List<_LigneRecouvrement> l) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _RecouvrementClasseScreen(espace: espace, classeId: l.first.classeId, classe: l.first.classe)));

    final tableau = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: bordure)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!telephone)
          Container(
            height: 36,
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bordure))),
            child: Row(children: [
              cellule(null, const Text('Classe', style: entete), flex: 2),
              cellule(80, const Text('Élèves', style: entete), droite: true),
              cellule(150, const Text('Dû', style: entete), droite: true),
              cellule(150, const Text('Réglé', style: entete), droite: true),
              cellule(150, const Text('Reste', style: entete), droite: true),
              cellule(140, const Text('Recouvrement', style: entete)),
              cellule(110, const Text('En retard', style: entete), droite: true),
              const SizedBox(width: 32),
            ]),
          ),
        if (classes.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text('Aucun élève inscrit cette année.', textAlign: TextAlign.center, style: TextStyle(color: gris)),
          ),
        for (final l in classes)
          Builder(builder: (context) {
            final d = somme(l, (x) => x.du), p = somme(l, (x) => x.paye);
            final retard = l.where((x) => x.retard > 0).length;
            return InkWell(
              onTap: () => ouvrir(l),
              hoverColor: Couleurs.doux(context).withValues(alpha: .5),
              child: Container(
                padding: EdgeInsets.symmetric(vertical: 10, horizontal: telephone ? 12 : 0),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bordure))),
                child: telephone
                    ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Expanded(child: Text(l.first.classe, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                          Text(_taux(p, d), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                          Icon(Icons.chevron_right, size: 18, color: gris),
                        ]),
                        const SizedBox(height: 6),
                        barre(p, d),
                        const SizedBox(height: 6),
                        Text('${l.length} élève(s) · reste ${gnf(d - p)}${retard > 0 ? ' · $retard en retard' : ''}',
                            style: TextStyle(fontSize: 12, color: retard > 0 ? Couleurs.retard : gris)),
                      ])
                    : Row(children: [
                        cellule(null, Text(l.first.classe, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)), flex: 2),
                        cellule(80, Text('${l.length}', style: const TextStyle(fontSize: 14)), droite: true),
                        cellule(150, Text(gnf(d), style: _chiffresDep.copyWith(fontSize: 14)), droite: true),
                        cellule(150, Text(gnf(p), style: _chiffresDep.copyWith(fontSize: 14)), droite: true),
                        cellule(150, Text(gnf(d - p), style: _chiffresDep.copyWith(fontSize: 14, fontWeight: FontWeight.w500)), droite: true),
                        cellule(
                          140,
                          Row(children: [
                            SizedBox(width: 44, child: Text(_taux(p, d), style: const TextStyle(fontSize: 14))),
                            Expanded(child: barre(p, d)),
                          ]),
                        ),
                        cellule(
                            110,
                            Text(retard == 0 ? '—' : '$retard élève(s)',
                                style: TextStyle(fontSize: 14, color: retard > 0 ? Couleurs.retard : gris)),
                            droite: true),
                        SizedBox(width: 32, child: Icon(Icons.chevron_right, size: 18, color: gris)),
                      ]),
              ),
            );
          }),
      ]),
    );

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 12, children: [
                  const Text('Recouvrement', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -.2)),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text('${m.annee ?? ''} · ${_taux(paye, du)} recouvré', style: TextStyle(fontSize: 14, color: gris)),
                  ),
                ]),
                const SizedBox(height: 2),
                Text('${gnf(paye)} réglés sur ${gnf(du)} · reste ${gnf(du - paye)}', style: TextStyle(fontSize: 13, color: gris)),
              ]),
            ),
            if (!telephone)
              PopupMenuButton<String>(
                tooltip: 'Exporter',
                icon: const Icon(Icons.more_horiz),
                onSelected: (_) => _exporterClasses(context, classes),
                itemBuilder: (_) => const [PopupMenuItem(value: 'x', child: _ItemMenu(Icons.download_outlined, 'Exporter en Excel'))],
              ),
          ]),
          const SizedBox(height: 4),
          Text('Choisissez une classe pour voir chaque élève, tranche par tranche.', style: TextStyle(fontSize: 12, color: gris)),
          const SizedBox(height: 12),
          tableau,
        ]),
      ),
    );
  }

  Future<void> _exporterClasses(BuildContext context, List<List<_LigneRecouvrement>> classes) async {
    final messager = ScaffoldMessenger.of(context);
    final classeur = xl.Excel.createExcel();
    final feuille = classeur['Recouvrement'];
    classeur.setDefaultSheet('Recouvrement');
    xl.TextCellValue t(Object? v) => xl.TextCellValue(v == null ? '' : '$v');
    feuille.appendRow([for (final c in const ['Classe', 'Élèves', 'Dû (GNF)', 'Réglé (GNF)', 'Reste (GNF)', 'Recouvrement', 'En retard']) t(c)]);
    for (final l in classes) {
      final d = l.fold(0, (s, x) => s + x.du), p = l.fold(0, (s, x) => s + x.paye);
      feuille.appendRow([
        t(l.first.classe), xl.IntCellValue(l.length), xl.IntCellValue(d), xl.IntCellValue(p), xl.IntCellValue(d - p),
        t(_taux(p, d)), xl.IntCellValue(l.where((x) => x.retard > 0).length),
      ]);
    }
    await _enregistrerClasseur(messager, classeur, 'Recouvrement', 'recouvrement.xlsx');
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

/// Une classe : chaque élève, colonne par colonne. On imprime ou on exporte l'état.
class _RecouvrementClasseScreen extends StatefulWidget {
  const _RecouvrementClasseScreen({required this.espace, required this.classeId, required this.classe});

  final Espace espace;
  final String classeId;
  final String classe;

  @override
  State<_RecouvrementClasseScreen> createState() => _RecouvrementClasseScreenState();
}

class _RecouvrementClasseScreenState extends State<_RecouvrementClasseScreen> {
  String _filtre = 'tous'; // tous, retard, soldes

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Recouvrement · ${widget.classe}'), titleSpacing: 0),
        body: _AvecRecouvrement(orgId: widget.espace.orgId, builder: _contenu),
      );

  Widget _contenu(BuildContext context, _Mesures m) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    final telephone = MediaQuery.sizeOf(context).width < 640;
    final toutes = m.recouvrement.where((l) => l.classeId == widget.classeId).toList()
      ..sort((a, b) => nomSimplifie(a.nom).compareTo(nomSimplifie(b.nom)));
    final lignes = toutes.where((l) => switch (_filtre) {
          'retard' => l.retard > 0,
          'soldes' => l.du > 0 && l.reste <= 0,
          _ => true,
        }).toList();
    final colonnes = _colonnes(m, toutes);
    int somme(int Function(_LigneRecouvrement) f) => lignes.fold(0, (s, x) => s + f(x));
    final du = somme((x) => x.du), paye = somme((x) => x.paye);
    const entete = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    const largeurNom = 220.0, largeurCol = 118.0;

    // Une case : ce qui reste à payer ; « payé » si soldé ; en rouge si en retard.
    Widget casePour(_Case? c) {
      if (c == null || c.du <= 0) return Text('—', style: TextStyle(color: gris));
      final reste = c.du - c.paye;
      if (reste <= 0) return const Text('payé', style: TextStyle(fontSize: 13, color: Couleurs.regle));
      return Tooltip(
        message: 'Dû ${gnf(c.du)} · payé ${gnf(c.paye)}',
        child: Text(_sansUnite(reste),
            style: _chiffresDep.copyWith(fontSize: 13, color: c.retard ? Couleurs.retard : null, fontWeight: c.retard ? FontWeight.w600 : null)),
      );
    }

    Widget ligneTableau(List<Widget> cases, {Color? fond, VoidCallback? auClic, bool gras = false}) => InkWell(
          onTap: auClic,
          child: Container(
            color: fond,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: fond == null ? BoxDecoration(border: Border(bottom: BorderSide(color: bordure))) : null,
            child: Row(children: cases),
          ),
        );
    Widget c(double l, Widget w, {bool droite = true}) => SizedBox(
        width: l,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
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

    final tableau = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: bordure)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ligneTableau([
            c(largeurNom, const Text('Élève', style: entete), droite: false),
            for (final k in colonnes) c(largeurCol, Text(k, style: entete, overflow: TextOverflow.ellipsis)),
            c(largeurCol, const Text('Dû', style: entete)),
            c(largeurCol, const Text('Réglé', style: entete)),
            c(largeurCol, const Text('Reste', style: entete)),
          ]),
          if (lignes.isEmpty)
            SizedBox(
              width: largeurNom + largeurCol * (colonnes.length + 3),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Aucun élève.', textAlign: TextAlign.center, style: TextStyle(color: gris)),
              ),
            ),
          for (final l in lignes)
            ligneTableau(
              [
                c(
                    largeurNom,
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l.nom, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                      Text(l.matricule, style: styleMono.copyWith(fontSize: 11, color: gris)),
                    ]),
                    droite: false),
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
              auClic: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: widget.espace, eleveId: l.eleveId))),
            ),
          if (lignes.isNotEmpty)
            ligneTableau([
              c(largeurNom, const Text('Total', style: entete), droite: false),
              for (final k in colonnes)
                c(largeurCol, Text(total[k] == null ? '—' : _sansUnite(total[k]!.du - total[k]!.paye), style: _chiffresDep.copyWith(fontSize: 13, fontWeight: FontWeight.w600))),
              c(largeurCol, Text(_sansUnite(du), style: _chiffresDep.copyWith(fontSize: 13, fontWeight: FontWeight.w600))),
              c(largeurCol, Text(_sansUnite(paye), style: _chiffresDep.copyWith(fontSize: 13, fontWeight: FontWeight.w600))),
              c(largeurCol, Text(_sansUnite(du - paye), style: _chiffresDep.copyWith(fontSize: 13, fontWeight: FontWeight.w700))),
            ], fond: Couleurs.doux(context)),
        ]),
      ),
    );

    return ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
      Wrap(spacing: 24, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _chiffre(context, 'Recouvrement', _taux(paye, du)),
        _chiffre(context, 'Dû', gnf(du)),
        _chiffre(context, 'Réglé', gnf(paye)),
        _chiffre(context, 'Reste', gnf(du - paye)),
        _chiffre(context, 'En retard', '${toutes.where((l) => l.retard > 0).length} élève(s)'),
      ]),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Segments<String>(
          valeur: _filtre,
          choix: {
            'tous': 'Tous (${toutes.length})',
            'retard': 'En retard (${toutes.where((l) => l.retard > 0).length})',
            'soldes': 'Soldés (${toutes.where((l) => l.du > 0 && l.reste <= 0).length})',
          },
          onChanged: (v) => setState(() => _filtre = v),
        ),
        OutlinedButton.icon(
          onPressed: lignes.isEmpty ? null : () => _imprimer(m, colonnes, lignes),
          icon: const Icon(Icons.print_outlined, size: 16),
          label: const Text('Imprimer'),
        ),
        if (!telephone)
          OutlinedButton.icon(
            onPressed: lignes.isEmpty ? null : () => _exporter(colonnes, lignes),
            icon: const Icon(Icons.download_outlined, size: 16),
            label: const Text('Excel'),
          ),
      ]),
      const SizedBox(height: 6),
      Text('Chaque case : ce qui reste à payer. En rouge : en retard (date limite et délai de grâce passés).',
          style: TextStyle(fontSize: 12, color: gris)),
      const SizedBox(height: 10),
      tableau,
    ]);
  }

  Widget _chiffre(BuildContext context, String libelle, String valeur) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(libelle, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        Text(valeur, style: _chiffresDep.copyWith(fontSize: 16, fontWeight: FontWeight.w600)),
      ]);

  Future<void> _imprimer(_Mesures m, List<String> colonnes, List<_LigneRecouvrement> lignes) async {
    final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [widget.espace.orgId]);
    final pdf = await etatRecouvrementPdf(
      ecole: Map.of(ecole),
      classe: widget.classe,
      annee: m.annee ?? '',
      colonnes: colonnes,
      lignes: [
        for (final l in lignes)
          (
            nom: l.nom,
            matricule: l.matricule,
            cases: [for (final k in colonnes) l.cases[k] == null ? null : l.cases[k]!.du - l.cases[k]!.paye],
            du: l.du,
            paye: l.paye,
          ),
      ],
      images: await _imagesEcole(widget.espace.orgId),
    );
    await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Recouvrement ${widget.classe}');
  }

  Future<void> _exporter(List<String> colonnes, List<_LigneRecouvrement> lignes) async {
    final messager = ScaffoldMessenger.of(context);
    final classeur = xl.Excel.createExcel();
    final feuille = classeur['Recouvrement'];
    classeur.setDefaultSheet('Recouvrement');
    xl.TextCellValue t(Object? v) => xl.TextCellValue(v == null ? '' : '$v');
    feuille.appendRow([
      t('Élève'), t('Matricule'),
      for (final k in colonnes) t('$k (reste)'),
      t('Dû (GNF)'), t('Réglé (GNF)'), t('Reste (GNF)'),
    ]);
    for (final l in lignes) {
      feuille.appendRow([
        t(l.nom), t(l.matricule),
        for (final k in colonnes) l.cases[k] == null ? t('') : xl.IntCellValue(l.cases[k]!.du - l.cases[k]!.paye),
        xl.IntCellValue(l.du), xl.IntCellValue(l.paye), xl.IntCellValue(l.reste),
      ]);
    }
    await _enregistrerClasseur(messager, classeur, 'Recouvrement', 'recouvrement-${widget.classe.replaceAll(' ', '-')}.xlsx');
  }
}
