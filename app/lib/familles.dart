part of 'configuration.dart';

/// Parents & tuteurs : on part de la personne. Ses enfants et ses deux rôles
/// (tuteur principal, responsable financier), ce qu'elle doit pour les enfants à
/// sa charge, encaisser, l'appeler, corriger ses coordonnées une seule fois pour
/// tous ses enfants, et fusionner une personne créée deux fois.

typedef _SoldeEleve = ({int du, int paye, int retard});

/// Mémoire des soldes, recalculés quand la caisse ou les inscriptions changent.
String? _versionSoldes;
Future<Map<String, _SoldeEleve>>? _soldesEnCours;
Future<Map<String, _SoldeEleve>> _soldes(String org, String version) {
  if (version != _versionSoldes || _soldesEnCours == null) {
    _versionSoldes = version;
    _soldesEnCours = soldesDesEleves(org);
  }
  return _soldesEnCours!;
}

/// Ce qui change les soldes : reçus, remboursements, inscriptions, frais, réductions.
const _sqlVersionSoldes = '''SELECT
    (SELECT count(*) || max(updated_at) FROM lignes_encaissement) AS a,
    (SELECT count(*) || max(updated_at) FROM encaissements) AS b,
    (SELECT count(*) || max(updated_at) FROM inscriptions) AS c,
    (SELECT count(*) || max(updated_at) FROM frais) AS d,
    (SELECT count(*) || max(updated_at) FROM remboursements) AS e,
    (SELECT count(*) || max(updated_at) FROM souscriptions) AS f,
    (SELECT count(*) || max(updated_at) FROM reductions_eleves) AS g''';

/// Les familles et ce qu'elles doivent : la liste, puis les soldes une fois calculés.
class _AvecSoldes extends StatelessWidget {
  const _AvecSoldes({required this.orgId, required this.builder});

  final String orgId;
  final Widget Function(BuildContext context, Map<String, _SoldeEleve>? soldes) builder;

  @override
  Widget build(BuildContext context) => Requete(
        _sqlVersionSoldes,
        builder: (context, v) => FutureBuilder<Map<String, _SoldeEleve>>(
          future: _soldes(orgId, '${v.first}'),
          builder: (context, s) => builder(context, s.data),
        ),
      );
}

/// « 620 00 00 00 » → appel ou WhatsApp.
Future<void> _appeler(String telephone, {bool whatsapp = false}) async {
  final n = telephone.replaceAll(RegExp(r'[^0-9+]'), '');
  final international = n.startsWith('+') ? n.substring(1) : (n.length == 9 ? '224$n' : n);
  await launchUrl(whatsapp ? Uri.parse('https://wa.me/$international') : Uri.parse('tel:+$international'));
}

/// Une personne et ses liens : tuteur principal de combien d'enfants, responsable
/// financier (payeur) de combien. Le reste dû ne porte que sur les enfants À SA
/// CHARGE : l'oncle qui paie et le père tuteur ne comptent pas deux fois la même dette.
const _sqlFamilles = '''SELECT c.id, c.organisation_id, c.nom_complet, c.telephone, c.telephone2, c.profession, c.adresse,
    count(DISTINCT ec.eleve_id) AS nb,
    sum(CASE WHEN ec.tuteur_principal = 1 THEN 1 ELSE 0 END) AS tutelle,
    sum(CASE WHEN ec.responsable_financier = 1 THEN 1 ELSE 0 END) AS charge,
    group_concat(DISTINCT ec.lien) AS liens,
    group_concat(DISTINCT CASE WHEN ec.responsable_financier = 1 THEN e.id END) AS a_charge,
    group_concat(e.prenoms || CASE WHEN cl.nom IS NULL THEN '' ELSE ' (' || cl.nom || ')' END, '|') AS enfants
  FROM contacts c
  JOIN eleves_contacts ec ON ec.contact_id = c.id
  JOIN eleves e ON e.id = ec.eleve_id
  LEFT JOIN annees_scolaires a ON a.organisation_id = e.organisation_id AND a.en_cours = 1
  LEFT JOIN inscriptions i ON i.eleve_id = e.id AND i.annee_id = a.id
  LEFT JOIN classes cl ON cl.id = i.classe_id
  WHERE c.organisation_id = ?
  GROUP BY c.id''';

/// Total des enfants à la charge d'une personne.
_SoldeEleve _soldeACharge(Map<String, Object?> f, Map<String, _SoldeEleve>? soldes) {
  var du = 0, paye = 0, retard = 0;
  for (final id in '${f['a_charge'] ?? ''}'.split(',').where((x) => x.isNotEmpty)) {
    final s = soldes?[id];
    if (s == null) continue;
    du += s.du;
    paye += s.paye;
    retard += s.retard;
  }
  return (du: du, paye: paye, retard: retard);
}

String _liensLisibles(Object? liens, {String sep = ', '}) =>
    '${liens ?? ''}'.split(',').where((x) => x.isNotEmpty).map((l) => liensFamille[l] ?? l).toSet().join(sep);

List<String> _enfantsDe(Map<String, Object?> f) => '${f['enfants'] ?? ''}'.split('|').where((x) => x.isNotEmpty).toList();

/// « 620 00 13 07 » : le numéro tel qu'on le dit, sans l'indicatif guinéen.
String _telLisible(Object? tel) {
  var t = '${tel ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '');
  if (t.isEmpty) return '';
  if (t.startsWith('224') && t.length == 12) t = t.substring(3);
  if (t.length != 9) return '${tel ?? ''}';
  return '${t.substring(0, 3)} ${t.substring(3, 5)} ${t.substring(5, 7)} ${t.substring(7)}';
}

String _sansUnite(int v) => gnf(v).replaceAll(' GNF', '');

const _chiffres = TextStyle(fontFeatures: [ui.FontFeature.tabularFigures()]);

class FamillesScreen extends StatefulWidget {
  const FamillesScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<FamillesScreen> createState() => _FamillesScreenState();
}

class _FamillesScreenState extends State<FamillesScreen> {
  final _recherche = TextEditingController();
  String? _filtre; // retard, fratrie, doublons, tuteurs, payeurs, reste
  String _tri = 'nom';
  int _ordre = 1;
  int _page = 0;
  int _parPage = 50;
  String? _ouvert;

  static const _plus = {
    'tuteurs': 'Tuteurs principaux',
    'payeurs': 'Responsables financiers',
    'reste': 'Avec un reste à payer',
  };

  @override
  void dispose() {
    _recherche.dispose();
    super.dispose();
  }

  void _trier(String t) => setState(() {
        if (_tri == t) {
          _ordre = -_ordre;
        } else {
          _tri = t;
          _ordre = t == 'nom' ? 1 : -1;
        }
      });

  void _ouvrir(String id) {
    if (MediaQuery.sizeOf(context).width >= 1280) {
      setState(() => _ouvert = id);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => FicheFamilleScreen(espace: widget.espace, contactId: id)));
    }
  }

  /// La liste affichée (filtres compris), en fichier Excel.
  Future<void> _exporter(List<Map<String, Object?>> familles, Map<String, _SoldeEleve>? soldes) async {
    final messager = ScaffoldMessenger.of(context);
    final classeur = xl.Excel.createExcel();
    final feuille = classeur['Familles'];
    classeur.setDefaultSheet('Familles');
    xl.TextCellValue t(Object? v) => xl.TextCellValue(v == null ? '' : '$v');
    feuille.appendRow([
      for (final c in const [
        'Parent', 'Lien', 'Téléphone', 'Deuxième téléphone', 'Profession', 'Adresse', 'Enfants', 'Tuteur principal de',
        'Responsable financier de', 'Reste dû (GNF)', 'En retard (GNF)',
      ])
        t(c),
    ]);
    for (final f in familles) {
      final s = _soldeACharge(f, soldes);
      feuille.appendRow([
        t(f['nom_complet']), t(_liensLisibles(f['liens'])), t(f['telephone']), t(f['telephone2']), t(f['profession']),
        t(f['adresse']), t(_enfantsDe(f).join(', ')), xl.IntCellValue(f['tutelle'] as int? ?? 0),
        xl.IntCellValue(f['charge'] as int? ?? 0), xl.IntCellValue(s.du - s.paye), xl.IntCellValue(s.retard),
      ]);
    }
    for (final f in classeur.tables.keys.toList()) {
      if (f != 'Familles') classeur.delete(f);
    }
    final octets = classeur.encode();
    if (octets == null) return;
    try {
      await FilePicker.saveFile(dialogTitle: 'Exporter les familles', fileName: 'familles.xlsx', bytes: Uint8List.fromList(octets));
      messager.showSnackBar(SnackBar(content: Text('${familles.length} famille(s) exportée(s).')));
    } catch (_) {
      messager.showSnackBar(const SnackBar(content: Text("Impossible d'enregistrer le fichier sur cet appareil.")));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Requete(
          _sqlFamilles,
          parametres: [widget.espace.orgId],
          builder: (context, familles) => _AvecSoldes(
            orgId: widget.espace.orgId,
            builder: (context, soldes) {
              final liste = _liste(context, familles, soldes);
              final ouvert = _ouvert;
              if (ouvert == null || MediaQuery.sizeOf(context).width < 1280) return liste;
              return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: liste),
                Container(
                  width: 480,
                  decoration: BoxDecoration(border: Border(left: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
                  child: FicheFamille(
                    key: ValueKey(ouvert),
                    espace: widget.espace,
                    contactId: ouvert,
                    fermer: () => setState(() => _ouvert = null),
                  ),
                ),
              ]);
            },
          ),
        ),
      );

  Widget _liste(BuildContext context, Lignes familles, Map<String, _SoldeEleve>? soldes) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final telephone = MediaQuery.sizeOf(context).width < 640;
    final doublons = famillesEnDouble(familles);
    final q = nomSimplifie(_recherche.text);
    final chiffres = _recherche.text.replaceAll(RegExp(r'[^0-9]'), '');
    bool garde(Map<String, Object?> f, String? filtre) {
      final s = _soldeACharge(f, soldes);
      return switch (filtre) {
        'tuteurs' => (f['tutelle'] as int? ?? 0) > 0,
        'payeurs' => (f['charge'] as int? ?? 0) > 0,
        'fratrie' => (f['charge'] as int? ?? 0) >= 2,
        'retard' => s.retard > 0,
        'reste' => s.du - s.paye > 0,
        'doublons' => doublons.contains(f['id']),
        _ => true,
      };
    }

    final cherches = familles.where((f) =>
        q.isEmpty ||
        nomSimplifie('${f['nom_complet']} ${f['enfants'] ?? ''}').contains(q) ||
        (chiffres.length >= 3 && '${f['telephone'] ?? ''}${f['telephone2'] ?? ''}'.replaceAll(' ', '').contains(chiffres)));
    int reste(Map<String, Object?> f) {
      final s = _soldeACharge(f, soldes);
      return (f['charge'] as int? ?? 0) == 0 ? -1 : s.du - s.paye;
    }

    final liste = cherches.where((f) => garde(f, _filtre)).map((f) => Map<String, Object?>.from(f)).toList()
      ..sort((a, b) {
        final v = _tri == 'reste'
            ? reste(a).compareTo(reste(b))
            : nomSimplifie('${a['nom_complet']}').compareTo(nomSimplifie('${b['nom_complet']}'));
        return v * _ordre;
      });
    int compte(String filtre) => familles.where((f) => garde(f, filtre)).length;
    final pages = liste.isEmpty ? 1 : (liste.length / _parPage).ceil();
    final page = _page.clamp(0, pages - 1);
    final affiches = liste.skip(page * _parPage).take(_parPage).toList();
    void filtrer(VoidCallback f) => setState(() {
          f();
          _page = 0;
        });

    Widget puce(String? cle, String libelle) {
      final choisi = _filtre == cle;
      return ChoiceChip(
        label: Text(libelle),
        selected: choisi,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        labelStyle: TextStyle(fontSize: 13, color: choisi ? schema.onSecondaryContainer : gris),
        side: BorderSide(color: choisi ? Colors.transparent : schema.outlineVariant),
        onSelected: (_) => filtrer(() => _filtre = cle),
      );
    }

    Widget enTete(String libelle, String cle) => InkWell(
          onTap: () => _trier(cle),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(libelle, style: TextStyle(fontSize: 12, color: gris, letterSpacing: .3)),
            if (_tri == cle) Icon(_ordre > 0 ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: gris),
          ]),
        );

    final nbRetard = soldes == null ? 0 : compte('retard');
    final nbFratrie = compte('fratrie');
    return ListView(padding: EdgeInsets.fromLTRB(telephone ? 12 : 24, 16, telephone ? 12 : 24, 24), children: [
      Row(children: [
        Text('Parents & tuteurs', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        Text('${familles.length}', style: TextStyle(fontSize: 16, color: gris)),
        const Spacer(),
        IconButton(
          tooltip: 'Exporter la liste (Excel)',
          onPressed: liste.isEmpty ? null : () => _exporter(liste, soldes),
          icon: Icon(Icons.download_outlined, size: 20, color: gris),
        ),
      ]),
      const SizedBox(height: 12),
      SizedBox(
        height: 40,
        child: TextField(
          controller: _recherche,
          onChanged: (_) => filtrer(() {}),
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            prefixIcon: Icon(Icons.search, size: 18, color: gris),
            prefixIconConstraints: const BoxConstraints(minWidth: 36),
            suffixIcon: _recherche.text.isEmpty
                ? null
                : IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () => filtrer(_recherche.clear)),
            hintText: "Nom, téléphone ou prénom d'un enfant",
            hintStyle: TextStyle(fontSize: 14, color: gris),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        puce(null, 'Tous'),
        if (nbRetard > 0) puce('retard', 'En retard · $nbRetard'),
        if (nbFratrie > 0) puce('fratrie', 'Fratries · $nbFratrie'),
        if (doublons.isNotEmpty) puce('doublons', 'Doublons · ${doublons.length}'),
        PopupMenuButton<String>(
          tooltip: "Plus de filtres",
          onSelected: (v) => filtrer(() => _filtre = v),
          itemBuilder: (_) => [for (final e in _plus.entries) CheckedPopupMenuItem(value: e.key, checked: _filtre == e.key, child: Text(e.value))],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_plus[_filtre] ?? 'Plus', style: TextStyle(fontSize: 13, color: _plus.containsKey(_filtre) ? schema.primary : gris)),
              Icon(Icons.expand_more, size: 16, color: gris),
            ]),
          ),
        ),
      ]),
      if (_filtre == 'doublons')
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text("Même téléphone, ou même nom quand l'un n'a pas de numéro : sans doute la même personne créée deux fois. "
              'Ouvrez celle à garder, puis ⋯ › Fusionner.', style: TextStyle(fontSize: 12, color: gris)),
        ),
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(children: [
          enTete('NOM', 'nom'),
          const Spacer(),
          Tooltip(
            message: 'Ne compte que les enfants à sa charge (dont elle est responsable financier). « — » : ne paie pour aucun enfant.',
            child: Icon(Icons.info_outline, size: 14, color: gris),
          ),
          const SizedBox(width: 6),
          enTete('RESTE DÛ (GNF)', 'reste'),
        ]),
      ),
      Divider(height: 1, color: schema.outlineVariant),
      if (affiches.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text('Personne.', style: TextStyle(color: gris))),
      for (final f in affiches) ...[
        _ligne(context, f, soldes, doublons.contains(f['id'])),
        Divider(height: 1, color: schema.outlineVariant.withValues(alpha: .6)),
      ],
      if (liste.length > 25)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            Text('${page * _parPage + 1}–${page * _parPage + affiches.length} sur ${liste.length}', style: TextStyle(fontSize: 13, color: gris)),
            const Spacer(),
            PopupMenuButton<int>(
              tooltip: 'Lignes par page',
              onSelected: (v) => filtrer(() => _parPage = v),
              itemBuilder: (_) => [for (final n in const [25, 50, 100]) CheckedPopupMenuItem(value: n, checked: n == _parPage, child: Text('$n par page'))],
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Text('$_parPage par page', style: TextStyle(fontSize: 13, color: gris)),
              ),
            ),
            IconButton(
                tooltip: 'Page précédente',
                onPressed: page > 0 ? () => setState(() => _page = page - 1) : null,
                icon: const Icon(Icons.chevron_left, size: 20)),
            IconButton(
                tooltip: 'Page suivante',
                onPressed: page < pages - 1 ? () => setState(() => _page = page + 1) : null,
                icon: const Icon(Icons.chevron_right, size: 20)),
          ]),
        ),
    ]);
  }

  Widget _ligne(BuildContext context, Map<String, Object?> f, Map<String, _SoldeEleve>? soldes, bool doublon) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final s = _soldeACharge(f, soldes);
    final reste = s.du - s.paye;
    final charge = f['charge'] as int? ?? 0;
    final tutelle = f['tutelle'] as int? ?? 0;
    final enfants = _enfantsDe(f);
    final liens = _liensLisibles(f['liens'], sep: ' / ');
    final qui = '${liens.isEmpty ? 'Parent' : liens} de ${enfants.take(2).join(', ')}${enfants.length > 2 ? ' +${enfants.length - 2}' : ''}';
    final tel = _telLisible(f['telephone']);
    final marques = [
      if (charge >= 2) 'Fratrie de $charge',
      if (charge == 0) 'ne paie pas',
      if (charge > 0 && tutelle == 0) 'payeur, pas tuteur',
      if (doublon) 'Doublon ?',
    ];
    final Widget montant;
    if (soldes == null) {
      montant = const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (charge == 0) {
      montant = Text('—', style: TextStyle(color: gris));
    } else if (reste <= 0) {
      montant = const Text('À jour', style: TextStyle(fontSize: 13, color: Couleurs.regle));
    } else {
      montant = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        Text(_sansUnite(reste),
            style: _chiffres.copyWith(fontSize: 14, fontWeight: FontWeight.w500, color: s.retard > 0 ? Couleurs.retard : null)),
        if (s.retard > 0)
          Text('${_sansUnite(s.retard)} en retard', style: _chiffres.copyWith(fontSize: 11, color: Couleurs.retard)),
      ]);
    }
    return Material(
      color: _ouvert == f['id'] ? schema.secondaryContainer.withValues(alpha: .5) : Colors.transparent,
      child: InkWell(
        onTap: () => _ouvrir(f['id'] as String),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text('${f['nom_complet']}',
                        overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  for (final m in marques) ...[
                    const SizedBox(width: 6),
                    Text(m,
                        style: TextStyle(
                            fontSize: 11,
                            color: m == 'Doublon ?' ? Couleurs.attente : (m.startsWith('Fratrie') ? schema.primary : gris))),
                  ],
                ]),
                const SizedBox(height: 2),
                Text([qui, if (tel.isNotEmpty) tel].join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
              ]),
            ),
            const SizedBox(width: 12),
            montant,
          ]),
        ),
      ),
    );
  }
}

/// Parents probablement créés deux fois : même téléphone ; ou même nom quand l'un des
/// deux n'a pas de numéro (deux « Mamadou DIALLO » aux numéros différents sont des homonymes).
Set<String> famillesEnDouble(Iterable<Map<String, Object?>> familles) {
  String fin(Object? t) {
    final n = '${t ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '');
    return n.length < 8 ? '' : n.substring(n.length > 9 ? n.length - 9 : 0);
  }

  final parTel = <String, Set<String>>{};
  final parNom = <String, List<({String id, bool numero})>>{};
  for (final f in familles) {
    final id = f['id'] as String;
    final numeros = {fin(f['telephone']), fin(f['telephone2'])}..remove('');
    for (final n in numeros) {
      parTel.putIfAbsent(n, () => {}).add(id);
    }
    parNom.putIfAbsent(nomSimplifie('${f['nom_complet']}'), () => []).add((id: id, numero: numeros.isNotEmpty));
  }
  return {
    for (final s in parTel.values)
      if (s.length > 1) ...s,
    for (final l in parNom.values)
      if (l.length > 1 && l.any((x) => !x.numero)) ...l.map((x) => x.id),
  };
}

/// Coordonnées du parent : une seule fois pour tous ses enfants.
Future<void> _modifierParent(BuildContext context, String contactId, Map<String, Object?> c) async {
  final complet = '${c['nom_complet']}'.trim().split(RegExp(r'\s+'));
  final prenoms = TextEditingController(text: '${c['prenoms'] ?? (complet.length > 1 ? complet.sublist(0, complet.length - 1).join(' ') : '')}');
  final nom = TextEditingController(text: '${c['nom'] ?? complet.last}');
  final tel = TextEditingController(text: '${c['telephone'] ?? ''}');
  final tel2 = TextEditingController(text: '${c['telephone2'] ?? ''}');
  final profession = TextEditingController(text: '${c['profession'] ?? ''}');
  final adresse = TextEditingController(text: '${c['adresse'] ?? ''}');
  final ok = await _formulaire(context, 'Coordonnées du parent', (_) => [
        TextField(controller: prenoms, textCapitalization: TextCapitalization.words, decoration: _champ('Prénom(s)')),
        TextField(controller: nom, textCapitalization: TextCapitalization.characters, decoration: _champ('Nom')),
        TextField(controller: tel, keyboardType: TextInputType.phone, decoration: _champ('Téléphone')),
        TextField(controller: tel2, keyboardType: TextInputType.phone, decoration: _champ('Deuxième téléphone (facultatif)')),
        TextField(controller: profession, decoration: _champ('Profession (facultatif)')),
        TextField(controller: adresse, decoration: _champ('Adresse (facultatif)')),
      ]);
  if (!ok || nom.text.trim().isEmpty) return;
  String? val(TextEditingController t) => t.text.trim().isEmpty ? null : t.text.trim();
  String? numero(TextEditingController t) => t.text.trim().isEmpty ? null : numeroInternational(t.text);
  await db.execute(
      'UPDATE contacts SET nom_complet = ?, prenoms = ?, nom = ?, telephone = ?, telephone2 = ?, profession = ?, adresse = ?, '
      'updated_at = ? WHERE id = ?',
      [
        nomPersonne(prenoms.text, nom.text), val(prenoms), nom.text.trim().toUpperCase(), numero(tel), numero(tel2),
        val(profession), val(adresse), _maintenant(), contactId,
      ]);
}

/// Fusionne un autre parent (créé en double) dans celui-ci : ses enfants passent ici.
Future<void> _fusionner(BuildContext context, String contactId, Map<String, Object?> c) async {
  final messager = ScaffoldMessenger.of(context);
  final familles = [
    for (final f in await db.getAll(
        '''SELECT c.id, c.nom_complet, c.telephone, c.telephone2, group_concat(DISTINCT e.prenoms) AS prenoms_enfants
           FROM contacts c JOIN eleves_contacts ec ON ec.contact_id = c.id JOIN eleves e ON e.id = ec.eleve_id
           WHERE c.organisation_id = ? AND c.id <> ? GROUP BY c.id ORDER BY c.nom_complet''',
        [c['organisation_id'], contactId]))
      Map<String, Object?>.from(f),
  ];
  // Les doublons probables d'abord.
  final probables = famillesEnDouble([c, ...familles]);
  familles.sort((a, b) => (probables.contains(b['id']) ? 1 : 0) - (probables.contains(a['id']) ? 1 : 0));
  if (!context.mounted) return;
  String? autre = familles.firstOrNull?['id'] as String?;
  if (autre == null) {
    messager.showSnackBar(const SnackBar(content: Text('Aucun autre parent à fusionner.')));
    return;
  }
  final ok = await _formulaire(context, 'Fusionner avec ${c['nom_complet']}', (maj) => [
        const Text("Choisissez le parent créé en double. Ses enfants passent sur cette fiche ; s'il n'a pas de téléphone "
            "ici, le sien est repris. L'autre fiche reste dans l'historique des reçus, sans enfant.",
            style: TextStyle(fontSize: 13)),
        _liste<String>('Parent en double', autre!, {
          for (final f in familles)
            f['id'] as String: '${probables.contains(f['id']) ? '★ ' : ''}${f['nom_complet']}'
                '${f['telephone'] != null ? ' · ${f['telephone']}' : ''} (${'${f['prenoms_enfants'] ?? ''}'.replaceAll(',', ', ')})',
        }, (v) => maj(() => autre = v)),
      ]);
  if (!ok || autre == null) return;
  final enDouble = familles.firstWhere((f) => f['id'] == autre);
  final m = _maintenant();
  await db.writeTransaction((tx) async {
    for (final l in await tx.getAll('SELECT * FROM eleves_contacts WHERE contact_id = ?', [autre])) {
      final deja = await tx.getOptional(
          'SELECT id, tuteur_principal, responsable_financier FROM eleves_contacts WHERE eleve_id = ? AND contact_id = ?',
          [l['eleve_id'], contactId]);
      if (deja == null) {
        await tx.execute('UPDATE eleves_contacts SET contact_id = ?, updated_at = ? WHERE id = ?', [contactId, m, l['id']]);
      } else {
        // L'enfant était déjà relié aux deux : on garde un seul lien, avec les rôles des deux.
        await tx.execute('DELETE FROM eleves_contacts WHERE id = ?', [l['id']]);
        await tx.execute('UPDATE eleves_contacts SET tuteur_principal = ?, responsable_financier = ?, updated_at = ? WHERE id = ?', [
          deja['tuteur_principal'] == 1 || l['tuteur_principal'] == 1 ? 1 : 0,
          deja['responsable_financier'] == 1 || l['responsable_financier'] == 1 ? 1 : 0,
          m,
          deja['id'],
        ]);
      }
    }
    if (c['telephone'] == null && enDouble['telephone'] != null) {
      await tx.execute('UPDATE contacts SET telephone = ?, updated_at = ? WHERE id = ?', [enDouble['telephone'], m, contactId]);
    } else if (c['telephone2'] == null && enDouble['telephone'] != null && enDouble['telephone'] != c['telephone']) {
      await tx.execute('UPDATE contacts SET telephone2 = ?, updated_at = ? WHERE id = ?', [enDouble['telephone'], m, contactId]);
    }
  });
  messager.showSnackBar(SnackBar(content: Text('${enDouble['nom_complet']} fusionné dans ${c['nom_complet']}.')));
}


/// La fiche d'une personne, en plein écran (téléphone) ou à droite de la liste (PC).
class FicheFamilleScreen extends StatelessWidget {
  const FicheFamilleScreen({super.key, required this.espace, required this.contactId});

  final Espace espace;
  final String contactId;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(child: FicheFamille(espace: espace, contactId: contactId, fermer: () => Navigator.of(context).maybePop())),
      );
}

class FicheFamille extends StatelessWidget {
  const FicheFamille({super.key, required this.espace, required this.contactId, required this.fermer});

  final Espace espace;
  final String contactId;
  final VoidCallback fermer;

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT * FROM contacts WHERE id = ?',
        parametres: [contactId],
        builder: (context, contacts) {
          if (contacts.isEmpty) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Contact introuvable.'),
                TextButton(onPressed: fermer, child: const Text('Fermer')),
              ]),
            );
          }
          final c = contacts.first;
          return Requete(
            '''SELECT e.id, e.nom, e.prenoms, ec.lien, ec.tuteur_principal, ec.responsable_financier,
                 i.id AS inscription_id, i.statut, cl.nom AS classe
               FROM eleves_contacts ec JOIN eleves e ON e.id = ec.eleve_id
               LEFT JOIN annees_scolaires a ON a.organisation_id = e.organisation_id AND a.en_cours = 1
               LEFT JOIN inscriptions i ON i.eleve_id = e.id AND i.annee_id = a.id
               LEFT JOIN classes cl ON cl.id = i.classe_id
               WHERE ec.contact_id = ? ORDER BY e.date_naissance, e.prenoms''',
            parametres: [contactId],
            builder: (context, enfants) => _AvecSoldes(
              orgId: espace.orgId,
              builder: (context, soldes) => _contenu(context, c, enfants, soldes),
            ),
          );
        },
      );

  Widget _contenu(BuildContext context, Map<String, Object?> c, Lignes enfants, Map<String, _SoldeEleve>? soldes) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final aCharge = enfants.where((e) => e['responsable_financier'] == 1).toList();
    var du = 0, paye = 0, retard = 0;
    for (final e in aCharge) {
      final s = soldes?[e['id']];
      if (s == null) continue;
      du += s.du;
      paye += s.paye;
      retard += s.retard;
    }
    final reste = du - paye;
    final aEncaisser = aCharge.where((e) => e['inscription_id'] != null).toList();
    final peutEncaisser = espace.fondateur || espace.droits.contains('encaisser');
    final gere = espace.fondateur || espace.droits.contains('gerer_inscriptions');
    final tel = c['telephone'] == null ? null : '${c['telephone']}';
    final liens = _liensLisibles(enfants.map((e) => e['lien']).join(','), sep: ' / ');
    final details = [
      if (c['telephone2'] != null) 'Autre numéro : ${_telLisible(c['telephone2'])}',
      if (c['profession'] != null) '${c['profession']}',
      if (c['adresse'] != null) '${c['adresse']}',
    ];

    return ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 40), children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 8),
            Text('${c['nom_complet']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text([if (liens.isNotEmpty) liens, if (tel != null) _telLisible(tel)].join(' · '), style: TextStyle(fontSize: 13, color: gris)),
            if (details.isNotEmpty) Text(details.join(' · '), style: TextStyle(fontSize: 12, color: gris)),
          ]),
        ),
        if (gere)
          PopupMenuButton<String>(
            tooltip: "Plus d'actions",
            icon: Icon(Icons.more_horiz, color: gris),
            onSelected: (v) => v == 'corriger' ? _modifierParent(context, contactId, c) : _fusionner(context, contactId, c),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'corriger', child: Text('Corriger les coordonnées')),
              PopupMenuItem(value: 'fusionner', child: Text('Fusionner avec…')),
            ],
          ),
        IconButton(tooltip: 'Fermer', onPressed: fermer, icon: Icon(Icons.close, color: gris)),
      ]),
      if (tel != null) ...[
        const SizedBox(height: 12),
        Row(children: [
          IconButton.filledTonal(tooltip: 'Appeler', onPressed: () => _appeler(tel), icon: const Icon(Icons.call_outlined, size: 18)),
          const SizedBox(width: 8),
          IconButton.filledTonal(
              tooltip: 'WhatsApp', onPressed: () => _appeler(tel, whatsapp: true), icon: const Icon(Icons.chat_outlined, size: 18)),
        ]),
      ],
      const SizedBox(height: 20),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: schema.surfaceContainerHighest.withValues(alpha: .5), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Reste dû', style: TextStyle(fontSize: 12, color: gris)),
          const SizedBox(height: 2),
          if (aCharge.isEmpty)
            Text('Ne paie pour aucun enfant', style: TextStyle(fontSize: 16, color: gris))
          else if (soldes == null)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          else if (reste <= 0)
            const Text('À jour', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Couleurs.regle))
          else ...[
            Text(gnf(reste), style: _chiffres.copyWith(fontSize: 22, fontWeight: FontWeight.w600)),
            if (retard > 0) Text('dont ${gnf(retard)} en retard', style: const TextStyle(fontSize: 13, color: Couleurs.retard)),
          ],
          if (aCharge.length >= 2) ...[
            const SizedBox(height: 8),
            Text('Fratrie de ${aCharge.length} : la réduction s’applique sur la scolarité de chacun.',
                style: TextStyle(fontSize: 12, color: gris)),
          ],
        ]),
      ),
      if (peutEncaisser && aEncaisser.isNotEmpty && reste > 0) ...[
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => EncaisserScreen(espace: espace, eleveId: aEncaisser.first['id'] as String))),
            icon: const Icon(Icons.point_of_sale_outlined, size: 18),
            label: const Text('Encaisser'),
          ),
        ),
      ],
      const SizedBox(height: 24),
      Text('ENFANTS', style: TextStyle(fontSize: 12, letterSpacing: .6, color: gris)),
      const SizedBox(height: 4),
      for (final e in enfants) ...[
        Builder(builder: (context) {
          final s = soldes?[e['id']];
          final paie = e['responsable_financier'] == 1;
          return InkWell(
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: espace, eleveId: e['id'] as String))),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${e['prenoms']} ${e['nom']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    Text([
                      e['classe'] == null ? 'Pas inscrit cette année' : '${e['classe']}',
                      if (e['tuteur_principal'] != 1) 'pas tuteur principal',
                      if (!paie) 'ne paie pas',
                    ].join(' · '), style: TextStyle(fontSize: 12, color: gris)),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (e['statut'] != null) etatInscription('${e['statut']}'),
                  if (s != null && paie)
                    Text(s.du - s.paye > 0 ? _sansUnite(s.du - s.paye) : 'À jour',
                        style: _chiffres.copyWith(fontSize: 12, color: s.retard > 0 ? Couleurs.retard : gris)),
                ]),
              ]),
            ),
          );
        }),
        Divider(height: 1, color: schema.outlineVariant.withValues(alpha: .6)),
      ],
    ]);
  }
}
