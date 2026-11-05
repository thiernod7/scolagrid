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
const _sqlFamilles = '''SELECT c.*,
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

/// Même présentation que la page Élèves : en-tête, filtres en menus, tableau
/// encadré, pied avec les pages, et la fiche qui s'ouvre à droite.
class _FamillesScreenState extends State<FamillesScreen> {
  final _recherche = TextEditingController();
  String? _role; // tuteurs, payeurs, fratrie
  String? _situation; // retard, reste, ajour, doublons
  String _tri = 'nom';
  int _ordre = 1;
  int _page = 0;
  int _parPage = 50;
  String? _ouvert;

  bool get _gere => widget.espace.fondateur || widget.espace.droits.contains('gerer_inscriptions');

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
    final largeur = MediaQuery.sizeOf(context).width;
    if (largeur >= 1280) {
      setState(() => _ouvert = id);
    } else if (largeur < 640) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => FicheFamilleScreen(espace: widget.espace, contactId: id)));
    } else {
      // Tiroir qui glisse depuis la droite, comme pour un élève.
      setState(() => _ouvert = id);
      showGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Fermer',
        barrierColor: Colors.black26,
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, _, _) => Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 8,
            child: SizedBox(
              width: largeur < 600 ? largeur : 576,
              height: double.infinity,
              child: SafeArea(
                child: FicheFamille(espace: widget.espace, contactId: id, fermer: () => Navigator.of(context).pop()),
              ),
            ),
          ),
        ),
        transitionBuilder: (context, animation, _, enfant) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero)
              .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: enfant,
        ),
      ).then((_) {
        if (mounted) setState(() => _ouvert = null);
      });
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
      await FilePicker.saveFile(dialogTitle: 'Exporter la liste', fileName: 'familles.xlsx', bytes: Uint8List.fromList(octets));
      messager.showSnackBar(SnackBar(content: Text('${familles.length} parent(s) exporté(s).')));
    } catch (_) {
      messager.showSnackBar(const SnackBar(content: Text("Impossible d'enregistrer le fichier sur cet appareil.")));
    }
  }

  Future<void> _action(String action, Map<String, Object?> f) async {
    final id = f['id'] as String;
    switch (action) {
      case 'ouvrir':
        _ouvrir(id);
      case 'appeler':
        await _appeler('${f['telephone']}');
      case 'whatsapp':
        await _appeler('${f['telephone']}', whatsapp: true);
      case 'corriger':
        await _modifierParent(context, id, f);
      case 'fusionner':
        await _fusionner(context, id, f);
    }
  }

  /// Les gestes possibles sur une personne : (action, icône, libellé). `null` sépare.
  List<(String, IconData, String)?> _gestes(Map<String, Object?> f) => [
        ('ouvrir', Icons.description_outlined, 'Ouvrir la fiche'),
        if (f['telephone'] != null) ...[
          null,
          ('appeler', Icons.call_outlined, 'Appeler'),
          ('whatsapp', Icons.chat_outlined, 'WhatsApp'),
        ],
        if (_gere) ...[
          null,
          ('corriger', Icons.edit_outlined, 'Corriger les coordonnées'),
          ('fusionner', Icons.merge_type, 'Fusionner avec…'),
        ],
      ];

  Future<void> _feuilleGestes(Map<String, Object?> f) async {
    final choix = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('${f['nom_complet']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          for (final g in _gestes(f))
            if (g == null)
              const Divider(height: 1)
            else
              ListTile(leading: Icon(g.$2), title: Text(g.$3), onTap: () => Navigator.pop(context, g.$1)),
        ]),
      ),
    );
    if (choix != null && mounted) await _action(choix, f);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Requete(
          _sqlFamilles,
          parametres: [widget.espace.orgId],
          builder: (context, familles) => _AvecSoldes(
            orgId: widget.espace.orgId,
            builder: (context, soldes) => _contenu(context, familles, soldes),
          ),
        ),
      );

  Widget _contenu(BuildContext context, Lignes familles, Map<String, _SoldeEleve>? soldes) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final largeur = MediaQuery.sizeOf(context).width;
    final telephone = largeur < 640;
    final panneau = largeur >= 1280 && _ouvert != null;
    final doublons = famillesEnDouble(familles);

    // Filtres, puis tri, puis page.
    final q = nomSimplifie(_recherche.text);
    final chiffres = _recherche.text.replaceAll(RegExp(r'[^0-9]'), '');
    bool garde(Map<String, Object?> f, {String? role, String? situation}) {
      final s = _soldeACharge(f, soldes);
      final charge = f['charge'] as int? ?? 0;
      final okRole = switch (role) {
        'tuteurs' => (f['tutelle'] as int? ?? 0) > 0,
        'payeurs' => charge > 0,
        'fratrie' => charge >= 2,
        _ => true,
      };
      final okSituation = switch (situation) {
        'retard' => s.retard > 0,
        'reste' => s.du - s.paye > 0,
        'ajour' => charge > 0 && s.du - s.paye <= 0,
        'doublons' => doublons.contains(f['id']),
        _ => true,
      };
      return okRole && okSituation;
    }

    int reste(Map<String, Object?> f) {
      final s = _soldeACharge(f, soldes);
      return (f['charge'] as int? ?? 0) == 0 ? -1 : s.du - s.paye;
    }

    final liste = familles.where((f) {
      if (!garde(f, role: _role, situation: _situation)) return false;
      if (q.isEmpty) return true;
      return nomSimplifie('${f['nom_complet']} ${f['enfants'] ?? ''}').contains(q) ||
          (chiffres.length >= 3 && '${f['telephone'] ?? ''}${f['telephone2'] ?? ''}'.replaceAll(' ', '').contains(chiffres));
    }).map((f) => Map<String, Object?>.from(f)).toList()
      ..sort((a, b) {
        final v = switch (_tri) {
          'reste' => reste(a).compareTo(reste(b)),
          'enfants' => (a['nb'] as int? ?? 0).compareTo(b['nb'] as int? ?? 0),
          _ => nomSimplifie('${a['nom_complet']}').compareTo(nomSimplifie('${b['nom_complet']}')),
        };
        return v * _ordre;
      });
    final nbRetard = soldes == null ? 0 : familles.where((f) => garde(f, situation: 'retard')).length;
    final nbFratries = familles.where((f) => garde(f, role: 'fratrie')).length;
    final filtres = _recherche.text.isNotEmpty || _role != null || _situation != null;
    final pages = liste.isEmpty ? 1 : (liste.length / _parPage).ceil();
    final page = _page.clamp(0, pages - 1);
    final affiches = liste.skip(page * _parPage).take(_parPage).toList();

    void filtrer(VoidCallback f) => setState(() {
          f();
          _page = 0;
        });

    // En-tête ----------------------------------------------------------------
    Widget pastille(String texte, VoidCallback auClic) => InkWell(
          onTap: auClic,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: Couleurs.doux(context), borderRadius: BorderRadius.circular(4)),
            child: Text(texte, style: TextStyle(fontSize: 12, color: gris)),
          ),
        );
    final titre = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 12, children: [
        const Text('Parents & tuteurs', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -.2)),
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text('${liste.length}${liste.length != familles.length ? ' sur ${familles.length}' : ''}',
              style: TextStyle(fontSize: 14, color: gris)),
        ),
      ]),
      if (nbRetard > 0 || nbFratries > 0 || doublons.isNotEmpty) ...[
        const SizedBox(height: 2),
        Wrap(spacing: 8, runSpacing: 4, children: [
          if (nbRetard > 0) pastille('$nbRetard en retard', () => filtrer(() => _situation = 'retard')),
          if (nbFratries > 0) pastille('$nbFratries fratrie(s)', () => filtrer(() => _role = 'fratrie')),
          if (doublons.isNotEmpty) pastille('${doublons.length} doublon(s) probable(s)', () => filtrer(() => _situation = 'doublons')),
        ]),
      ],
    ]);
    final boutons = telephone
        ? const SizedBox.shrink()
        : PopupMenuButton<String>(
            tooltip: 'Exporter',
            icon: const Icon(Icons.more_horiz),
            onSelected: (_) => _exporter(liste, soldes),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'exporter', enabled: liste.isNotEmpty, child: const _ItemMenu(Icons.download_outlined, 'Exporter en Excel')),
            ],
          );

    // Filtres ------------------------------------------------------------------
    Widget menu<T>(double largeurMenu, T? valeur, String tous, Map<T, String> choix, ValueChanged<T?> change) => SizedBox(
          width: largeurMenu,
          height: 36,
          child: DropdownButtonHideUnderline(
            child: Container(
              padding: const EdgeInsets.only(left: 12, right: 8),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(6),
                color: schema.surface,
              ),
              child: DropdownButton<T?>(
                value: valeur,
                isExpanded: true,
                isDense: true,
                icon: Icon(Icons.keyboard_arrow_down, size: 18, color: gris),
                style: TextStyle(fontFamily: policeTexte, fontSize: 14, color: schema.onSurface),
                items: [
                  DropdownMenuItem<T?>(value: null, child: Text(tous, overflow: TextOverflow.ellipsis)),
                  for (final c in choix.entries)
                    DropdownMenuItem<T?>(value: c.key, child: Text(c.value, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: change,
              ),
            ),
          ),
        );
    List<Widget> menusFiltres(VoidCallback apres, {double? largeurFixe}) => [
          menu<String>(largeurFixe ?? 200, _role, 'Tous les rôles', const {
            'tuteurs': 'Tuteurs principaux',
            'payeurs': 'Responsables financiers',
            'fratrie': 'Fratries (2 enfants et +)',
          }, (v) {
            filtrer(() => _role = v);
            apres();
          }),
          menu<String>(largeurFixe ?? 200, _situation, 'Toutes les situations', {
            'retard': 'En retard de paiement',
            'reste': 'Avec un reste à payer',
            'ajour': 'À jour',
            if (doublons.isNotEmpty || _situation == 'doublons') 'doublons': 'Doublons probables',
          }, (v) {
            filtrer(() => _situation = v);
            apres();
          }),
        ];
    void reinitialiser() => filtrer(() {
          _recherche.clear();
          _role = null;
          _situation = null;
        });
    final nbFiltres = [_role, _situation].where((x) => x != null).length;
    final barreFiltres = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SizedBox(
        width: telephone ? largeur - 24 - 52 : (panneau ? 260 : 340),
        height: 36,
        child: TextField(
          controller: _recherche,
          onChanged: (_) => filtrer(() {}),
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            prefixIcon: Icon(Icons.search, size: 18, color: gris),
            prefixIconConstraints: const BoxConstraints(minWidth: 36),
            hintText: "Nom, téléphone, prénom d'un enfant…",
            hintStyle: TextStyle(fontSize: 14, color: gris),
          ),
        ),
      ),
      if (telephone)
        SizedBox(
          width: 44,
          height: 36,
          child: Badge(
            isLabelVisible: nbFiltres > 0,
            label: Text('$nbFiltres'),
            child: IconButton.outlined(
              tooltip: 'Filtres',
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.tune, size: 18),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                builder: (context) => StatefulBuilder(
                  builder: (context, maj) => SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const Text('Filtres', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 12),
                        for (final m in menusFiltres(() => maj(() {}), largeurFixe: double.infinity)) ...[m, const SizedBox(height: 10)],
                        Row(children: [
                          TextButton(
                            onPressed: () {
                              reinitialiser();
                              maj(() {});
                            },
                            child: const Text('Réinitialiser'),
                          ),
                          const Spacer(),
                          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Voir la liste')),
                        ]),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        )
      else
        ...menusFiltres(() {}),
      if (filtres && !telephone)
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: gris, minimumSize: const Size(36, 36)),
          onPressed: reinitialiser,
          icon: const Icon(Icons.close, size: 14),
          label: const Text('Réinitialiser', style: TextStyle(fontSize: 14)),
        ),
    ]);

    // Pied : position et pages -----------------------------------------------------
    final pied = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        Text(liste.isEmpty ? 'Aucun résultat' : '${page * _parPage + 1}–${page * _parPage + affiches.length} sur ${liste.length}',
            style: TextStyle(fontSize: 14, color: gris)),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (!telephone) ...[
            menu<int>(136, _parPage == 50 ? null : _parPage, '50 par page', {25: '25 par page', 100: '100 par page'},
                (v) => filtrer(() => _parPage = v ?? 50)),
            const SizedBox(width: 8),
          ],
          _BoutonPage(icone: Icons.chevron_left, onPressed: page == 0 ? null : () => setState(() => _page = page - 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('${page + 1} / $pages', style: TextStyle(fontSize: 14, color: gris)),
          ),
          _BoutonPage(icone: Icons.chevron_right, onPressed: page >= pages - 1 ? null : () => setState(() => _page = page + 1)),
        ]),
      ],
    );

    final vide = familles.isEmpty
        ? 'Aucun parent pour le moment : ils sont créés en inscrivant les élèves.'
        : 'Personne ne correspond.';
    final tableau = telephone
        ? _cartes(context, affiches, soldes, doublons, vide)
        : _tableau(context, affiches, soldes, doublons, vide,
            telephoneCol: !panneau && largeur >= 1024, enfants: !panneau, roles: !panneau && largeur >= 1366);

    final colonne = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (telephone)
        titre
      else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: titre), boutons]),
      const SizedBox(height: 12),
      barreFiltres,
      if (_situation == 'doublons') ...[
        const SizedBox(height: 8),
        Text("Même téléphone, ou même nom quand l'un n'a pas de numéro : sans doute la même personne créée deux fois. "
            'Ouvrez celle à garder, puis « Fusionner avec… ».', style: TextStyle(fontSize: 12, color: gris)),
      ],
      const SizedBox(height: 12),
      Expanded(child: tableau),
      const SizedBox(height: 12),
      pied,
    ]);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: Padding(
          padding: EdgeInsets.all(telephone ? 12 : 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: colonne),
            if (panneau) ...[
              const SizedBox(width: 16),
              _PanneauLateral(
                key: const ValueKey('panneau'),
                child: FicheFamille(
                  key: ValueKey(_ouvert),
                  espace: widget.espace,
                  contactId: _ouvert!,
                  fermer: () => setState(() => _ouvert = null),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  /// Reste dû d'une personne, à la façon de la colonne « Inscription » des élèves.
  Widget _montant(BuildContext context, Map<String, Object?> f, Map<String, _SoldeEleve>? soldes) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final s = _soldeACharge(f, soldes);
    final reste = s.du - s.paye;
    if (soldes == null) return const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2));
    if ((f['charge'] as int? ?? 0) == 0) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('—', style: TextStyle(fontSize: 14, color: gris)),
        Text('ne paie pas', style: TextStyle(fontSize: 11, color: gris)),
      ]);
    }
    if (reste <= 0) return const Etat('À jour', ton: Ton.regle);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(gnf(reste), style: _chiffres.copyWith(fontSize: 14, color: s.retard > 0 ? Couleurs.retard : null)),
      if (s.retard > 0) Text('dont ${_sansUnite(s.retard)} en retard', style: const TextStyle(fontSize: 11, color: Couleurs.retard)),
    ]);
  }

  List<Widget> _marques(Map<String, Object?> f, bool doublon) {
    final charge = f['charge'] as int? ?? 0;
    return [
      if (charge >= 2) ...[const SizedBox(width: 8), Etat('Fratrie de $charge', ton: Ton.info)],
      if (doublon) ...[const SizedBox(width: 8), const Etat('Doublon ?', ton: Ton.attente)],
    ];
  }

  Widget _tableau(BuildContext context, Lignes familles, Map<String, _SoldeEleve>? soldes, Set<String> doublons, String vide,
      {required bool telephoneCol, required bool enfants, required bool roles}) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    const entete = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);
    final petit = TextStyle(fontSize: 12, color: gris);

    Widget triable(String libelle, String cle) => InkWell(
          onTap: () => _trier(cle),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(libelle, style: entete),
            const SizedBox(width: 4),
            Icon(_tri == cle ? Icons.swap_vert : Icons.unfold_more, size: 13, color: gris.withValues(alpha: _tri == cle ? 1 : .6)),
          ]),
        );
    Widget cellule(double? largeur, Widget enfant, {int flex = 1}) {
      final contenu = Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: enfant);
      return largeur == null ? Expanded(flex: flex, child: contenu) : SizedBox(width: largeur, child: contenu);
    }

    final enTete = Container(
      height: 36,
      decoration: BoxDecoration(color: schema.surface, border: Border(bottom: BorderSide(color: bordure))),
      child: Row(children: [
        const SizedBox(width: 72),
        cellule(null, Align(alignment: Alignment.centerLeft, child: triable('Parent', 'nom')), flex: 3),
        if (telephoneCol) cellule(152, const Text('Téléphone', style: entete)),
        if (enfants) cellule(null, Align(alignment: Alignment.centerLeft, child: triable('Enfants', 'enfants')), flex: 3),
        if (roles) cellule(160, const Text('Rôles', style: entete)),
        cellule(176, Align(alignment: Alignment.centerLeft, child: triable('Reste dû', 'reste'))),
        const SizedBox(width: 48),
      ]),
    );

    Widget ligne(Map<String, Object?> f) {
      final id = f['id'] as String;
      final liste = _enfantsDe(f);
      final tutelle = f['tutelle'] as int? ?? 0;
      final charge = f['charge'] as int? ?? 0;
      final sous = [
        _liensLisibles(f['liens'], sep: ' / '),
        if (!telephoneCol && f['telephone'] != null) _telLisible(f['telephone']),
        if (telephoneCol && f['profession'] != null) '${f['profession']}',
      ].where((x) => x.isNotEmpty).join(' · ');
      return Material(
        color: id == _ouvert ? Couleurs.doux(context) : Colors.transparent,
        child: InkWell(
          onTap: () => _ouvrir(id),
          hoverColor: Couleurs.doux(context).withValues(alpha: .5),
          child: Container(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bordure))),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Padding(padding: const EdgeInsets.only(left: 8), child: Initiales('${f['nom_complet']}', taille: 56)),
              cellule(
                null,
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text('${f['nom_complet']}',
                          overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    ),
                    ..._marques(f, doublons.contains(id)),
                  ]),
                  if (sous.isNotEmpty) Text(sous, overflow: TextOverflow.ellipsis, style: petit),
                ]),
                flex: 3,
              ),
              if (telephoneCol)
                cellule(
                  152,
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(f['telephone'] == null ? '—' : _telLisible(f['telephone']), style: _chiffres.copyWith(fontSize: 14)),
                    if (f['telephone2'] != null) Text(_telLisible(f['telephone2']), style: _chiffres.merge(petit)),
                  ]),
                ),
              if (enfants)
                cellule(
                  null,
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final e in liste.take(2)) Text(e, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                    if (liste.length > 2) Text('+ ${liste.length - 2} autre(s)', style: petit),
                  ]),
                  flex: 3,
                ),
              if (roles)
                cellule(
                  160,
                  Wrap(spacing: 4, runSpacing: 4, children: [
                    if (tutelle > 0) Etat('tuteur${tutelle > 1 ? ' ×$tutelle' : ''}', ton: Ton.info),
                    if (charge > 0) Etat('payeur${charge > 1 ? ' ×$charge' : ''}'),
                  ]),
                ),
              cellule(176, Align(alignment: Alignment.centerLeft, child: _montant(context, f, soldes))),
              SizedBox(
                width: 48,
                child: PopupMenuButton<String>(
                  tooltip: 'Actions',
                  icon: const Icon(Icons.more_horiz, size: 18),
                  onSelected: (a) => _action(a, f),
                  itemBuilder: (_) => [
                    for (final g in _gestes(f))
                      if (g == null) const PopupMenuDivider() else PopupMenuItem(value: g.$1, child: _ItemMenu(g.$2, g.$3)),
                  ],
                ),
              ),
            ]),
          ),
        ),
      );
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: bordure)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        enTete,
        Expanded(
          child: familles.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(vide, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: gris)),
                  ),
                )
              : ListView.builder(itemCount: familles.length, itemBuilder: (context, i) => ligne(familles[i])),
        ),
      ]),
    );
  }

  /// Téléphone : des cartes, comme la liste des élèves.
  Widget _cartes(BuildContext context, Lignes familles, Map<String, _SoldeEleve>? soldes, Set<String> doublons, String vide) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    if (familles.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(vide, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: gris)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: familles.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final f = familles[i];
        final enfants = _enfantsDe(f);
        return Material(
          color: schema.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: bordure)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _ouvrir(f['id'] as String),
            onLongPress: () => _feuilleGestes(f),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                Initiales('${f['nom_complet']}', taille: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(
                        child: Text('${f['nom_complet']}',
                            overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                      ..._marques(f, doublons.contains(f['id'])),
                    ]),
                    const SizedBox(height: 2),
                    Text('${_liensLisibles(f['liens'], sep: ' / ')} de ${enfants.take(2).join(', ')}${enfants.length > 2 ? ' +${enfants.length - 2}' : ''}',
                        overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
                    if (f['telephone'] != null) Text(_telLisible(f['telephone']), style: TextStyle(fontSize: 12, color: gris)),
                  ]),
                ),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  _montant(context, f, soldes),
                  IconButton(
                    tooltip: 'Actions',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.more_horiz, size: 18),
                    onPressed: () => _feuilleGestes(f),
                  ),
                ]),
              ]),
            ),
          ),
        );
      },
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


/// La fiche d'une personne, en plein écran (téléphone) ou à droite de la liste (PC),
/// présentée comme la fiche d'un élève : en-tête, rubriques, pied d'actions.
class FicheFamilleScreen extends StatelessWidget {
  const FicheFamilleScreen({super.key, required this.espace, required this.contactId});

  final Espace espace;
  final String contactId;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: FicheFamille(espace: espace, contactId: contactId, fermer: () => Navigator.of(context).maybePop()),
            ),
          ),
        ),
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
                const Text('Contact introuvable sur ce poste.'),
                TextButton(onPressed: fermer, child: const Text('Fermer')),
              ]),
            );
          }
          final c = contacts.first;
          return Requete(
            '''SELECT e.id, e.nom, e.prenoms, ec.lien, ec.tuteur_principal, ec.responsable_financier,
                 (SELECT p.updated_at FROM photos_eleves p WHERE p.eleve_id = e.id) AS photo_maj,
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
    final telephone = MediaQuery.sizeOf(context).width < 640;
    final aCharge = enfants.where((e) => e['responsable_financier'] == 1).toList();
    final tutelle = enfants.where((e) => e['tuteur_principal'] == 1).length;
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

    // En-tête, comme la fiche d'un élève.
    final entete = Container(
      padding: EdgeInsets.all(telephone ? 12 : 16),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Initiales('${c['nom_complet']}', taille: telephone ? 52 : 72),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${c['nom_complet']}', style: TextStyle(fontSize: telephone ? 16 : 18, fontWeight: FontWeight.w600)),
              if (aCharge.length >= 2) Etat('Fratrie de ${aCharge.length}', ton: Ton.info),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 12, runSpacing: 2, children: [
              if (liens.isNotEmpty) Text(liens, style: TextStyle(fontSize: telephone ? 13 : 14, color: gris)),
              if (tel != null) Text(_telLisible(tel), style: _chiffres.copyWith(fontSize: telephone ? 13 : 14, color: gris)),
            ]),
          ]),
        ),
        IconButton(tooltip: 'Fermer', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 18), onPressed: fermer),
      ]),
    );

    final String resteTexte;
    if (aCharge.isEmpty) {
      resteTexte = 'ne paie pour aucun enfant';
    } else if (soldes == null) {
      resteTexte = '…';
    } else {
      resteTexte = reste > 0 ? gnf(reste) : 'à jour';
    }

    final corps = ListView(padding: const EdgeInsets.all(16), children: [
      _rubrique(context, 'Situation'),
      const SizedBox(height: 12),
      _deuxColonnes([
        _ChampLu('Tuteur principal de', '$tutelle enfant(s)'),
        _ChampLu('Responsable financier de', '${aCharge.length} enfant(s)'),
        _ChampLu('Reste dû (enfants à sa charge)', resteTexte, attenue: aCharge.isEmpty),
        _ChampLu('Dont en retard', retard > 0 ? gnf(retard) : '—'),
      ]),
      if (aCharge.length >= 2) ...[
        const SizedBox(height: 12),
        Text('Fratrie de ${aCharge.length} : la réduction s’applique sur la scolarité de chacun.', style: TextStyle(fontSize: 12, color: gris)),
      ],
      const SizedBox(height: 24),
      _rubrique(context, 'Enfants', droite: Text('${enfants.length}', style: TextStyle(fontSize: 12, color: gris))),
      const SizedBox(height: 4),
      for (final e in enfants)
        Builder(builder: (context) {
          final s = soldes?[e['id']];
          final paie = e['responsable_financier'] == 1;
          final nom = '${e['nom']} ${e['prenoms']}';
          return InkWell(
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: espace, eleveId: e['id'] as String))),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
              child: Row(children: [
                PhotoEleve(eleveId: e['id'] as String, nom: nom, version: e['photo_maj'] as String?, taille: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(nom, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    Text([
                      e['classe'] == null ? 'Pas inscrit cette année' : '${e['classe']}',
                      '${liensFamille[e['lien']] ?? e['lien']}',
                      if (e['tuteur_principal'] == 1) 'tuteur',
                      if (paie) 'payeur',
                    ].join(' · '), style: TextStyle(fontSize: 12, color: gris)),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (e['statut'] != null) etatInscription('${e['statut']}') else const Etat('Pas inscrit'),
                  if (s != null && paie)
                    Text(s.du - s.paye > 0 ? gnf(s.du - s.paye) : 'à jour',
                        style: _chiffres.copyWith(fontSize: 12, color: s.retard > 0 ? Couleurs.retard : gris)),
                ]),
              ]),
            ),
          );
        }),
      const SizedBox(height: 24),
      _rubrique(context, 'Coordonnées'),
      const SizedBox(height: 12),
      _deuxColonnes([
        _ChampLu('Téléphone', tel == null ? null : _telLisible(tel)),
        _ChampLu('Deuxième téléphone', c['telephone2'] == null ? null : _telLisible(c['telephone2'])),
        _ChampLu('Profession', c['profession'] as String?),
        _ChampLu('Adresse', c['adresse'] as String?),
      ]),
    ]);

    // Pied d'actions, comme la fiche d'un élève.
    final encaisser = peutEncaisser && aEncaisser.isNotEmpty && reste > 0
        ? () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => EncaisserScreen(espace: espace, eleveId: aEncaisser.first['id'] as String)))
        : null;
    final gestes = <(String, IconData, VoidCallback)>[
      if (tel != null) ('WhatsApp', Icons.chat_outlined, () => _appeler(tel, whatsapp: true)),
      if (gere) ...[
        ('Corriger les coordonnées', Icons.edit_outlined, () => _modifierParent(context, contactId, c)),
        ('Fusionner avec…', Icons.merge_type, () => _fusionner(context, contactId, c)),
      ],
    ];
    final decoration =
        BoxDecoration(color: schema.surface, border: Border(top: BorderSide(color: Theme.of(context).dividerColor)));
    final Widget pied;
    if (telephone) {
      pied = Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: decoration,
        child: Row(children: [
          Expanded(
            child: encaisser != null
                ? FilledButton.icon(
                    onPressed: encaisser,
                    icon: const Icon(Icons.account_balance_wallet_outlined, size: 16),
                    label: const Text('Encaisser'))
                : FilledButton.icon(
                    onPressed: tel == null ? null : () => _appeler(tel),
                    icon: const Icon(Icons.call_outlined, size: 16),
                    label: const Text('Appeler')),
          ),
          if (encaisser != null && tel != null) ...[
            const SizedBox(width: 6),
            IconButton.outlined(tooltip: 'Appeler', onPressed: () => _appeler(tel), icon: const Icon(Icons.call_outlined, size: 18)),
          ],
          if (gestes.isNotEmpty)
            PopupMenuButton<int>(
              tooltip: 'Autres actions',
              icon: const Icon(Icons.more_horiz),
              onSelected: (i) => gestes[i].$3(),
              itemBuilder: (_) => [
                for (var i = 0; i < gestes.length; i++) PopupMenuItem(value: i, child: _ItemMenu(gestes[i].$2, gestes[i].$1)),
              ],
            ),
        ]),
      );
    } else {
      pied = Container(
        padding: const EdgeInsets.all(12),
        decoration: decoration,
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          if (encaisser != null)
            FilledButton.icon(
                onPressed: encaisser, icon: const Icon(Icons.account_balance_wallet_outlined, size: 15), label: const Text('Encaisser')),
          if (tel != null)
            OutlinedButton.icon(onPressed: () => _appeler(tel), icon: const Icon(Icons.call_outlined, size: 15), label: const Text('Appeler')),
          for (final g in gestes) OutlinedButton.icon(onPressed: g.$3, icon: Icon(g.$2, size: 15), label: Text(g.$1)),
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      entete,
      Expanded(child: corps),
      if (encaisser != null || tel != null || gestes.isNotEmpty) pied,
    ]);
  }
}
