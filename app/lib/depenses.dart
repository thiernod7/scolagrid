part of 'configuration.dart';

/// Dépenses : les sorties de caisse courantes (craie, carburant, réparations…),
/// pour que la clôture du soir tombe juste. Motif obligatoire, justificatif
/// facultatif, n° du bon de sortie facultatif. Au-dessus du seuil de l'école,
/// il faut l'accord de la direction : dans l'app, ou de vive voix (à confirmer).
/// Les salaires et les remboursements n'en font pas partie : ils ont leurs écrans.

const categoriesDepenses = [
  'Fournitures',
  'Entretien et réparation',
  'Carburant et énergie',
  'Transport et mission',
  'Communication',
  'Divers',
];

const _statutsDepense = {
  'demande': ('À autoriser', Ton.attente),
  'autorisee': ("Autorisée : l'argent n'est pas encore sorti", Ton.info),
  'refusee': ('Refusée', Ton.neutre),
  'sortie': ('Sortie de caisse', Ton.regle),
  'annulee': ('Annulée', Ton.neutre),
};

class DepensesScreen extends StatefulWidget {
  const DepensesScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<DepensesScreen> createState() => _DepensesScreenState();
}

/// Même présentation que les pages Élèves et Familles : en-tête, bandeau de la
/// caisse du jour, filtres, tableau encadré, et une colonne de contrôle à droite.
class _DepensesScreenState extends State<DepensesScreen> {
  bool _caisse = false;
  bool _autorise = false;
  final _recherche = TextEditingController();
  String _periode = 'mois'; // jour, semaine, mois, tout, perso
  DateTimeRange? _plage;
  String? _categorie;
  int _page = 0;
  int _parPage = 50;

  Espace get _e => widget.espace;

  /// Toute l'école (direction, comptabilité) ou seulement ma caisse.
  bool get _voitTout => _e.fondateur || _e.droits.contains('voir_caisse') || _autorise;

  @override
  void initState() {
    super.initState();
    Future.wait([
      jAiLeDroitQuelquePart(_e.orgId, 'encaisser'),
      jAiLeDroitQuelquePart(_e.orgId, 'autoriser_depense'),
    ]).then((r) {
      if (mounted) {
        setState(() {
          _caisse = r[0];
          _autorise = r[1];
        });
      }
    });
  }

  @override
  void dispose() {
    _recherche.dispose();
    super.dispose();
  }

  /// Sites où je peux sortir de l'argent.
  Future<Map<String, String>> _mesSites() async => {
        for (final s in await db.getAll('SELECT id, nom FROM sites WHERE organisation_id = ? ORDER BY created_at', [_e.orgId]))
          if (await jAiLeDroit(_e.orgId, s['id'] as String, 'encaisser') ||
              await jAiLeDroit(_e.orgId, s['id'] as String, 'autoriser_depense'))
            s['id'] as String: s['nom'] as String,
      };

  Future<void> _nouvelle(Map<String, Object?> org) async {
    final messager = ScaffoldMessenger.of(context);
    final sites = await _mesSites();
    if (sites.isEmpty) {
      messager.showSnackBar(const SnackBar(content: Text("Enregistrer une dépense demande le droit d'encaisser ou d'autoriser une dépense.")));
      return;
    }
    final dejaUtilisees = [
      for (final c in await db.getAll('SELECT DISTINCT categorie FROM depenses WHERE organisation_id = ? ORDER BY categorie', [_e.orgId]))
        if (!categoriesDepenses.contains(c['categorie'])) '${c['categorie']}',
    ];
    // Qui peut autoriser de vive voix : la direction, sauf moi.
    final direction = {
      for (final p in await db.getAll(
          '''SELECT DISTINCT p.id, p.nom_complet FROM personnel p JOIN affectations a ON a.personnel_id = p.id AND a.actif = 1
             WHERE p.organisation_id = ? AND p.statut = 'actif' AND a.fonction IN ('fondateur', 'directeur')
               AND (p.user_id IS NULL OR p.user_id <> ?) ORDER BY p.nom_complet''',
          [_e.orgId, monId]))
        p['id'] as String: '${p['nom_complet']}',
    };
    if (!mounted) return;
    final seuil = org['seuil_depense_gnf'] as int? ?? 100000;
    final orale = org['depense_orale'] == 1;
    final montant = TextEditingController();
    final motif = TextEditingController();
    final beneficiaire = TextEditingController();
    final bon = TextEditingController();
    final autreCategorie = TextEditingController();
    var site = sites.keys.first;
    var categorie = categoriesDepenses.first;
    var date = DateTime.now();
    var deVive = false;
    String? qui = direction.keys.firstOrNull;
    PhotoPrete? justificatif;
    int? m() => int.tryParse(montant.text.replaceAll(RegExp(r'[^0-9]'), ''));
    Widget deux(Widget a, Widget b) =>
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: 12), Expanded(child: b)]);
    final ok = await _formulaire(
      context,
      'Nouvelle dépense',
      (maj) {
        final auDessus = (m() ?? 0) > seuil && !_autorise;
        return [
          deux(
            TextField(
              controller: montant,
              autofocus: true,
              keyboardType: TextInputType.number,
              onChanged: (_) => maj(() {}),
              decoration: _champ('Montant', suffixe: 'GNF'),
            ),
            InkWell(
              onTap: () async {
                final d = await _choisirDate(context, date, premier: DateTime.now().subtract(const Duration(days: 60)));
                if (d != null) maj(() => date = d);
              },
              child: InputDecorator(
                decoration: _champ('Date', suffixe: '').copyWith(suffixIcon: const Icon(Icons.event_outlined, size: 18)),
                child: Text(_dateLisible(_date(date))),
              ),
            ),
          ),
          if (sites.length > 1) _liste('Site', site, sites, (v) => maj(() => site = v)),
          deux(
            _liste('Catégorie', categorie, {
              for (final c in [...categoriesDepenses, ...dejaUtilisees]) c: c,
              '…': 'Autre catégorie…',
            }, (v) => maj(() => categorie = v)),
            TextField(
              controller: beneficiaire,
              textCapitalization: TextCapitalization.words,
              decoration: _champ('Bénéficiaire', aide: "Qui a reçu l'argent"),
            ),
          ),
          if (categorie == '…')
            TextField(controller: autreCategorie, decoration: _champ('Nouvelle catégorie', aide: 'Par exemple : Cantine, Sécurité')),
          TextField(
            controller: motif,
            textCapitalization: TextCapitalization.sentences,
            decoration: _champ('Motif', aide: 'Obligatoire. Par exemple : 3 ramettes A4 pour le secrétariat'),
          ),
          deux(
            TextField(controller: bon, decoration: _champ('N° du bon de sortie', aide: 'Facultatif')),
            SizedBox(
              height: 56,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final p = await choisirPhoto(context, camera: cameraDisponible, taille: 1000);
                  if (p != null) maj(() => justificatif = p);
                },
                icon: Icon(justificatif == null ? Icons.receipt_long_outlined : Icons.check, size: 16),
                label: Text(justificatif == null ? 'Joindre le reçu' : 'Reçu joint'),
              ),
            ),
          ),
          if (auDessus)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(8)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const Expanded(child: Text('Autorisation requise', style: TextStyle(fontWeight: FontWeight.w600))),
                  Text('seuil ${gnf(seuil)}', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ]),
                const SizedBox(height: 8),
                if (orale && direction.isNotEmpty) ...[
                  Segments<bool>(
                    valeur: deVive,
                    choix: const {false: "Demander l'autorisation", true: 'Déjà accordée de vive voix'},
                    onChanged: (v) => maj(() => deVive = v),
                  ),
                  const SizedBox(height: 8),
                ],
                if (deVive && orale && direction.isNotEmpty) ...[
                  _liste('Accordée par', qui ?? direction.keys.first, direction, (v) => maj(() => qui = v)),
                  const SizedBox(height: 6),
                  Text("L'argent sort tout de suite ; la direction confirmera dans l'app "
                      '(sous ${org['delai_confirmation_heures'] ?? 48} h).', style: const TextStyle(fontSize: 12)),
                ] else
                  const Text("La demande part à la direction ; l'argent sortira une fois autorisée.", style: TextStyle(fontSize: 12)),
              ]),
            ),
        ];
      },
      valider: () {
        final v = m() ?? 0;
        final demande = v > seuil && !_autorise && !(deVive && orale && direction.isNotEmpty);
        return v <= 0 ? 'Enregistrer' : '${demande ? 'Demander' : 'Enregistrer'} · ${gnf(v)}';
      },
    );
    if (!ok) return;
    final montantSaisi = m();
    final cat = categorie == '…' ? autreCategorie.text.trim() : categorie;
    if (montantSaisi == null || montantSaisi <= 0 || motif.text.trim().length < 3 || cat.length < 2) {
      messager.showSnackBar(const SnackBar(content: Text('Le montant, la catégorie et le motif sont obligatoires.')));
      return;
    }
    String? val(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    // Même règle que le serveur, pour l'afficher tout de suite (même hors ligne).
    final auDessus = montantSaisi > seuil;
    final vive = auDessus && !_autorise && deVive && orale && qui != null;
    final sortie = !auDessus || _autorise || vive;
    final jour = _date(date);
    final poste = await cePoste();
    final m0 = _maintenant();
    await db.writeTransaction((tx) async {
      final id = (await tx.get('SELECT uuid() AS id'))['id'] as String;
      await tx.execute(
          '''INSERT INTO depenses (id, organisation_id, site_id, montant_gnf, date_effective, categorie, motif, beneficiaire, bon,
               statut, cree_par, autorise_par, autorise_le, autorisation_orale, autorise_oralement_par, confirmation,
               sortie_par, sortie_le, poste_id, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            id, _e.orgId, site, montantSaisi, jour, cat, motif.text.trim(), val(beneficiaire), val(bon),
            sortie ? 'sortie' : 'demande', monId, auDessus && _autorise ? monId : null, auDessus && sortie ? m0 : null,
            vive ? 1 : 0, vive ? qui : null, vive ? 'attendue' : null,
            sortie ? monId : null, sortie ? jour : null, poste?['poste_id'], m0, m0,
          ]);
      final j = justificatif;
      if (j != null) {
        await tx.execute(
            'INSERT INTO justificatifs_depenses (id, organisation_id, depense_id, type_image, image, par, created_at, updated_at) '
            'VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?)',
            [_e.orgId, id, j.type, j.base64, monId, m0, m0]);
      }
    });
    messager.showSnackBar(SnackBar(
        content: Text(sortie
            ? 'Dépense enregistrée : ${gnf(montantSaisi)} sortis de la caisse.'
            : 'Demande envoyée à la direction : ${gnf(montantSaisi)}.')));
  }

  /// Ce qu'on peut faire d'une dépense, selon son étape et mes droits : (action, icône, libellé).
  List<(String, IconData, String)> _gestes(Map<String, Object?> d) {
    final moi = d['cree_par'] == monId;
    final agit = _caisse || _autorise;
    return [
      if (d['statut'] == 'demande' && _autorise) ...[
        ('autoriser', Icons.check_circle_outline, 'Autoriser'),
        ('refuser', Icons.block, 'Refuser'),
      ],
      if (d['statut'] == 'autorisee' && agit) ('sortir', Icons.payments_outlined, "Sortir l'argent aujourd'hui"),
      if (d['confirmation'] == 'attendue' && _autorise) ...[
        ('confirmer', Icons.verified_outlined, "Confirmer l'autorisation"),
        ('contester', Icons.report_outlined, 'Contester'),
      ],
      if (d['statut'] == 'sortie' || d['statut'] == 'autorisee') ('imprimer', Icons.print_outlined, 'Imprimer le bon de sortie'),
      if (d['bon'] == null && d['statut'] != 'annulee' && agit) ('bon', Icons.tag, 'Ajouter le n° du bon'),
      if (d['a_justif'] != 1 && d['statut'] != 'annulee' && agit) ('justificatif', Icons.receipt_long_outlined, 'Joindre le reçu'),
      if (d['statut'] != 'annulee' && d['statut'] != 'refusee' && (_autorise || (moi && d['statut'] != 'sortie')))
        ('annuler', Icons.cancel_outlined, 'Annuler'),
    ];
  }

  /// Une dépense : son détail (avec la photo du reçu) et ce qu'on peut en faire.
  Future<void> _ouvrir(Map<String, Object?> d) async {
    final justificatif = await db.getOptional('SELECT type_image, image FROM justificatifs_depenses WHERE depense_id = ?', [d['id']]);
    if (!mounted) return;
    final gestes = _gestes(d);
    final choix = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${d['categorie']} · ${gnf(d['montant_gnf'])}'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Etat(_statutsDepense[d['statut']]?.$1 ?? '${d['statut']}', ton: _statutsDepense[d['statut']]?.$2 ?? Ton.neutre),
              const SizedBox(height: 8),
              Text('${d['motif']}', style: const TextStyle(fontSize: 15)),
              const SizedBox(height: 6),
              Text([
                'Le ${_dateLisible(d['date_effective'])}',
                if (d['beneficiaire'] != null) 'remis à ${d['beneficiaire']}',
                if (d['bon'] != null) 'bon n° ${d['bon']}',
                if (d['par'] != null) 'saisie par ${d['par']}',
              ].join(' · ')),
              Text(_autorisationTexte(d)),
              if (d['motif_refus'] != null) Text('Refus : ${d['motif_refus']}'),
              if (d['motif_contestation'] != null) Text('Contestation : ${d['motif_contestation']}'),
              if (d['motif_annulation'] != null) Text('Annulation : ${d['motif_annulation']}'),
              if (justificatif != null) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.memory(base64Decode('${justificatif['image']}'), fit: BoxFit.contain),
                ),
              ],
            ]),
          ),
        ),
        actions: [
          for (final g in gestes) TextButton(onPressed: () => Navigator.pop(context, g.$1), child: Text(g.$3)),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer')),
        ],
      ),
    );
    if (choix != null && mounted) await _agir(choix, d);
  }

  /// L'autorisation, en clair (fiche, bon de sortie).
  String _autorisationTexte(Map<String, Object?> d) {
    if (d['autorisation_orale'] == 1) {
      final etat = switch (d['confirmation']) { 'confirmee' => 'confirmée', 'contestee' => 'contestée', _ => 'à confirmer' };
      return 'De vive voix, par ${d['oral'] ?? 'la direction'} ($etat)';
    }
    if (d['autorise_par'] != null) return 'Accordée par ${d['autorisateur'] ?? 'la direction'}';
    return 'Non requise : sous le seuil';
  }

  Future<void> _agir(String choix, Map<String, Object?> d) async {
    Future<String?> motif(String titre, String aide) async {
      final c = TextEditingController();
      final ok = await _formulaire(context, titre, (_) => [TextField(controller: c, autofocus: true, decoration: _champ(aide))]);
      return ok && c.text.trim().length >= 3 ? c.text.trim() : null;
    }

    final id = d['id'] as String;
    switch (choix) {
      case 'ouvrir':
        await _ouvrir(d);
      case 'imprimer':
        final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [_e.orgId]);
        final pdf = await bonDeSortiePdf(
            ecole: Map.of(ecole), depense: d, autorisation: _autorisationTexte(d), images: await _imagesEcole(_e.orgId));
        await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Bon de sortie ${d['bon'] ?? ''}'.trim());
      case 'autoriser':
        if (await _confirmer(context, 'Autoriser ${gnf(d['montant_gnf'])} pour « ${d['motif']} » ?')) {
          await _modifier('depenses', id, {'statut': 'autorisee', 'autorise_par': monId, 'autorise_le': _maintenant()});
        }
      case 'refuser':
        final m = await motif('Refuser la dépense', 'Motif du refus');
        if (m != null) await _modifier('depenses', id, {'statut': 'refusee', 'autorise_par': monId, 'motif_refus': m});
      case 'sortir':
        if (await _confirmer(context, 'Remettre ${gnf(d['montant_gnf'])} aujourd\'hui ? La somme sort de votre caisse du jour.')) {
          final j = _date(DateTime.now());
          await _modifier('depenses', id, {'statut': 'sortie', 'sortie_par': monId, 'sortie_le': j, 'date_effective': j});
        }
      case 'confirmer':
        if (await _confirmer(context, 'Confirmer avoir autorisé cette dépense de ${gnf(d['montant_gnf'])} ?')) {
          await _modifier('depenses', id, {'confirmation': 'confirmee', 'confirme_par': monId, 'confirme_le': _maintenant()});
        }
      case 'contester':
        final m = await motif('Contester la dépense', 'Motif (la dépense reste enregistrée)');
        if (m != null) {
          await _modifier('depenses', id,
              {'confirmation': 'contestee', 'confirme_par': monId, 'confirme_le': _maintenant(), 'motif_contestation': m});
        }
      case 'bon':
        final c = TextEditingController();
        final ok = await _formulaire(context, 'N° du bon de sortie', (_) => [TextField(controller: c, autofocus: true, decoration: _champ('N° du bon'))]);
        if (ok && c.text.trim().isNotEmpty) await _modifier('depenses', id, {'bon': c.text.trim()});
      case 'justificatif':
        final p = await choisirPhoto(context, camera: cameraDisponible, taille: 1000);
        if (p != null) {
          await _inserer('justificatifs_depenses',
              {'organisation_id': _e.orgId, 'depense_id': id, 'type_image': p.type, 'image': p.base64, 'par': monId});
        }
      case 'annuler':
        final m = await motif('Annuler la dépense', "Motif de l'annulation");
        if (m != null) {
          await _modifier('depenses', id, {'statut': 'annulee', 'motif_annulation': m, 'annule_par': monId, 'annule_le': _maintenant()});
        }
    }
  }

  /// Seuil et autorisation de vive voix : réglés par le fondateur.
  Future<void> _regles(Map<String, Object?> org) async {
    final seuil = TextEditingController(text: '${org['seuil_depense_gnf'] ?? 100000}');
    var orale = org['depense_orale'] == 1;
    final ok = await _formulaire(context, 'Règles des dépenses', (maj) => [
          TextField(
            controller: seuil,
            keyboardType: TextInputType.number,
            decoration: _champ('Seuil', suffixe: 'GNF', aide: "Au-dessus, il faut l'accord de la direction (0 : toujours)"),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: orale,
            onChanged: (v) => maj(() => orale = v),
            title: const Text('Accepter une autorisation donnée de vive voix'),
            subtitle: Text("Au téléphone par exemple : l'argent sort, et la direction confirme ensuite dans l'app "
                '(rappel après ${org['delai_confirmation_heures'] ?? 48} h).'),
          ),
        ]);
    final s = int.tryParse(seuil.text.replaceAll(RegExp(r'[^0-9]'), ''));
    if (!ok || s == null) return;
    await _modifier('organisations', _e.orgId, {'seuil_depense_gnf': s, 'depense_orale': orale ? 1 : 0});
  }

  /// La liste affichée (filtres compris), en fichier Excel.
  Future<void> _exporter(List<Map<String, Object?>> lignes) async {
    final messager = ScaffoldMessenger.of(context);
    final classeur = xl.Excel.createExcel();
    final feuille = classeur['Dépenses'];
    classeur.setDefaultSheet('Dépenses');
    xl.TextCellValue t(Object? v) => xl.TextCellValue(v == null ? '' : '$v');
    feuille.appendRow([
      for (final c in const ['Date', 'Catégorie', 'Motif', 'Bénéficiaire', 'Bon', 'Montant (GNF)', 'Étape', 'Autorisation', 'Saisie par'])
        t(c),
    ]);
    for (final d in lignes) {
      feuille.appendRow([
        t(_dateLisible(d['date_effective'])), t(d['categorie']), t(d['motif']), t(d['beneficiaire']), t(d['bon']),
        xl.IntCellValue(d['montant_gnf'] as int? ?? 0), t(_statutsDepense[d['statut']]?.$1 ?? d['statut']),
        t(_autorisationTexte(d)), t(d['par']),
      ]);
    }
    for (final f in classeur.tables.keys.toList()) {
      if (f != 'Dépenses') classeur.delete(f);
    }
    final octets = classeur.encode();
    if (octets == null) return;
    try {
      await FilePicker.saveFile(dialogTitle: 'Exporter les dépenses', fileName: 'depenses.xlsx', bytes: Uint8List.fromList(octets));
      messager.showSnackBar(SnackBar(content: Text('${lignes.length} dépense(s) exportée(s).')));
    } catch (_) {
      messager.showSnackBar(const SnackBar(content: Text("Impossible d'enregistrer le fichier sur cet appareil.")));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Requete(
          'SELECT * FROM organisations WHERE id = ?',
          parametres: [_e.orgId],
          builder: (context, orgs) {
            if (orgs.isEmpty) return const SizedBox.shrink();
            return Requete(
              '''SELECT d.*, p.nom_complet AS par, o.nom_complet AS oral, pa.nom_complet AS autorisateur,
                   EXISTS (SELECT 1 FROM justificatifs_depenses j WHERE j.depense_id = d.id) AS a_justif
                 FROM depenses d
                 LEFT JOIN personnel p ON p.user_id = d.cree_par AND p.organisation_id = d.organisation_id
                 LEFT JOIN personnel o ON o.id = d.autorise_oralement_par
                 LEFT JOIN personnel pa ON pa.user_id = d.autorise_par AND pa.organisation_id = d.organisation_id
                 WHERE d.organisation_id = ?
                 ORDER BY d.date_effective DESC, d.created_at DESC
                 LIMIT 3000''',
              parametres: [_e.orgId],
              builder: (context, lignes) => _contenu(context, orgs.first, lignes),
            );
          },
        ),
      );

  /// Début et fin de la période choisie (dates ISO), ou null pour « tout ».
  (String, String)? _bornes() {
    final aujourdhui = DateTime.now();
    final j = DateTime(aujourdhui.year, aujourdhui.month, aujourdhui.day);
    return switch (_periode) {
      'jour' => (_date(j), _date(j)),
      'semaine' => (_date(j.subtract(const Duration(days: 6))), _date(j)),
      'mois' => (_date(DateTime(j.year, j.month)), _date(j)),
      'perso' when _plage != null => (_date(_plage!.start), _date(_plage!.end)),
      _ => null,
    };
  }

  Widget _contenu(BuildContext context, Map<String, Object?> org, Lignes lignes) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final largeur = MediaQuery.sizeOf(context).width;
    final telephone = largeur < 640;
    final large = largeur >= 1280;
    final delai = Duration(hours: org['delai_confirmation_heures'] as int? ?? 48);
    bool enRetard(Map<String, Object?> d) =>
        d['confirmation'] == 'attendue' &&
        DateTime.now().difference(DateTime.tryParse('${d['autorise_le'] ?? d['created_at']}') ?? DateTime.now()) > delai;

    // À traiter : quelle que soit la période.
    final aAutoriser = lignes.where((d) => d['statut'] == 'demande').toList();
    final aSortir = lignes.where((d) => d['statut'] == 'autorisee').toList();
    final aConfirmer = lignes.where((d) => d['confirmation'] == 'attendue').toList();
    final bons = lignes.where((d) => d['statut'] != 'annulee' && d['bon'] != null).map((d) => '${d['bon']}').toList();
    final trous = bonsManquants(bons);

    // Filtres, puis page.
    final b = _bornes();
    final q = nomSimplifie(_recherche.text);
    final periode = lignes.where((d) {
      final j = '${d['date_effective']}';
      return b == null || (j.compareTo(b.$1) >= 0 && j.compareTo(b.$2) <= 0);
    }).toList();
    final liste = periode.where((d) {
      if (_categorie != null && d['categorie'] != _categorie) return false;
      return q.isEmpty || nomSimplifie('${d['motif']} ${d['beneficiaire'] ?? ''} ${d['bon'] ?? ''} ${d['categorie']}').contains(q);
    }).toList();
    final sorties = liste.where((d) => d['statut'] == 'sortie').toList();
    final total = sorties.fold<int>(0, (s, d) => s + (d['montant_gnf'] as int? ?? 0));
    final filtres = _recherche.text.isNotEmpty || _categorie != null || _periode != 'mois';
    final pages = liste.isEmpty ? 1 : (liste.length / _parPage).ceil();
    final page = _page.clamp(0, pages - 1);
    final affiches = liste.skip(page * _parPage).take(_parPage).toList();
    void filtrer(VoidCallback f) => setState(() {
          f();
          _page = 0;
        });

    // En-tête ----------------------------------------------------------------
    Widget pastille(String texte) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: Couleurs.doux(context), borderRadius: BorderRadius.circular(4)),
          child: Text(texte, style: TextStyle(fontSize: 12, color: gris)),
        );
    final titre = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, children: [
        // Ouverte depuis la caisse : un retour.
        if (Navigator.of(context).canPop())
          IconButton(
            tooltip: 'Retour',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back, size: 20),
          ),
        const Text('Dépenses', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -.2)),
        Text('${sorties.length} sortie(s) · ${gnf(total)}', style: TextStyle(fontSize: 14, color: gris)),
        Tooltip(
          message: 'Ce qui sort de la caisse en dehors des remboursements et des salaires : fournitures, carburant, '
              'réparations… Motif obligatoire, reçu facultatif. Au-dessus de ${gnf(org['seuil_depense_gnf'] ?? 100000)}, '
              "il faut l'accord de la direction.",
          child: Icon(Icons.info_outline, size: 16, color: gris),
        ),
      ]),
      if (aAutoriser.isNotEmpty || aConfirmer.isNotEmpty || trous.isNotEmpty) ...[
        const SizedBox(height: 2),
        Wrap(spacing: 8, runSpacing: 4, children: [
          if (aAutoriser.isNotEmpty) pastille('${aAutoriser.length} à autoriser'),
          if (aConfirmer.isNotEmpty) pastille('${aConfirmer.length} à confirmer'),
          if (trous.isNotEmpty) pastille('${trous.length} bon(s) manquant(s)'),
        ]),
      ],
    ]);
    final boutons = Wrap(spacing: 8, runSpacing: 8, children: [
      if (!telephone || _e.fondateur)
        PopupMenuButton<String>(
          tooltip: 'Exporter, règles',
          icon: const Icon(Icons.more_horiz),
          onSelected: (v) => v == 'regles' ? _regles(org) : _exporter(liste),
          itemBuilder: (_) => [
            if (!telephone)
              PopupMenuItem(value: 'exporter', enabled: liste.isNotEmpty, child: const _ItemMenu(Icons.download_outlined, 'Exporter en Excel')),
            if (_e.fondateur) const PopupMenuItem(value: 'regles', child: _ItemMenu(Icons.tune, 'Règles : seuil, vive voix')),
          ],
        ),
      if (_caisse || _autorise)
        FilledButton.icon(onPressed: () => _nouvelle(org), icon: const Icon(Icons.add, size: 16), label: const Text('Nouvelle dépense')),
    ]);

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
    final barreFiltres = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SizedBox(
        width: telephone ? double.infinity : 300,
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
            hintText: 'Motif, bénéficiaire, n° de bon…',
            hintStyle: TextStyle(fontSize: 14, color: gris),
          ),
        ),
      ),
      menu<String>(telephone ? (largeur - 32) / 2 : 200, _periode == 'mois' ? null : _periode, 'Ce mois-ci', {
        'jour': "Aujourd'hui",
        'semaine': '7 derniers jours',
        'tout': 'Toutes les dates',
        'perso': _periode == 'perso' && _plage != null
            ? 'Du ${_dateLisible(_date(_plage!.start))} au ${_dateLisible(_date(_plage!.end))}'
            : 'Une période…',
      }, (v) async {
        if (v == 'perso') {
          final p = await showDateRangePicker(
            context: context,
            firstDate: DateTime(2020),
            lastDate: DateTime.now(),
            initialDateRange: _plage,
            helpText: 'Dépenses entre le… et le…',
          );
          if (p == null) return;
          filtrer(() {
            _periode = 'perso';
            _plage = p;
          });
        } else {
          filtrer(() => _periode = v ?? 'mois');
        }
      }),
      menu<String>(telephone ? (largeur - 32) / 2 : 220, _categorie, 'Toutes les catégories', {
        for (final c in {...categoriesDepenses, ...lignes.map((d) => '${d['categorie']}')}) c: c,
      }, (v) => filtrer(() => _categorie = v)),
      if (filtres)
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: gris, minimumSize: const Size(36, 36)),
          onPressed: () => filtrer(() {
            _recherche.clear();
            _categorie = null;
            _periode = 'mois';
            _plage = null;
          }),
          icon: const Icon(Icons.close, size: 14),
          label: const Text('Réinitialiser', style: TextStyle(fontSize: 14)),
        ),
    ]);

    // Pied ---------------------------------------------------------------------
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

    final vide = lignes.isEmpty ? 'Aucune dépense enregistrée pour le moment.' : 'Aucune dépense sur cette période.';
    final tableau = telephone
        ? _cartes(context, affiches, enRetard, vide)
        : LayoutBuilder(
            // Les colonnes selon la place réelle (la colonne de droite en prend).
            builder: (context, c) => _tableau(context, affiches, enRetard, vide,
                categorie: c.maxWidth >= 820, autorisation: c.maxWidth >= 1020),
          );
    final aTraiter = _aTraiter(context, aAutoriser, aSortir, aConfirmer, enRetard, delai);
    final controle = [
      ?aTraiter,
      if (bons.isNotEmpty) _carnet(context, bons, trous),
      _parCategorie(context, sorties, total),
      _parBeneficiaire(context, sorties),
    ];

    final colonne = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (telephone) ...[titre, const SizedBox(height: 8), boutons]
      else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: titre),
          const SizedBox(width: 8),
          Flexible(child: Align(alignment: Alignment.topRight, child: boutons)),
        ]),
      if (_caisse || _voitTout) ...[const SizedBox(height: 12), _CaisseDuJour(orgId: _e.orgId, toute: _voitTout)],
      if (!large && aTraiter != null) ...[const SizedBox(height: 12), aTraiter],
      if (!large && trous.isNotEmpty) ...[const SizedBox(height: 12), _carnet(context, bons, trous)],
      const SizedBox(height: 12),
      barreFiltres,
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
            if (large) ...[
              const SizedBox(width: 16),
              SizedBox(
                width: 320,
                child: ListView(children: [
                  for (final c in controle) ...[c, const SizedBox(height: 12)],
                ]),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  /// Encadré de la colonne de droite.
  Widget _encadre(BuildContext context, {required String titre, IconData? icone, Color? couleur, required List<Widget> enfants}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: couleur?.withValues(alpha: .06) ?? Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: couleur?.withValues(alpha: .4) ?? Theme.of(context).dividerColor),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (icone != null) ...[Icon(icone, size: 16, color: couleur), const SizedBox(width: 6)],
          Expanded(child: Text(titre, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 8),
        ...enfants,
      ]),
    );
  }

  /// Les dépenses qui attendent quelqu'un : autorisation, sortie de l'argent, confirmation.
  Widget? _aTraiter(BuildContext context, Lignes aAutoriser, Lignes aSortir, Lignes aConfirmer,
      bool Function(Map<String, Object?>) enRetard, Duration delai) {
    if (aAutoriser.isEmpty && aSortir.isEmpty && aConfirmer.isEmpty) return null;
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final retard = aConfirmer.any(enRetard);
    Widget item(Map<String, Object?> d, String detail, (String, String)? action, {bool rouge = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InkWell(
              onTap: () => _ouvrir(d),
              child: Row(children: [
                Expanded(child: Text('${d['motif']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
                const SizedBox(width: 8),
                Text(gnf(d['montant_gnf']), style: _chiffresDep.copyWith(fontSize: 13)),
              ]),
            ),
            Text(detail, style: TextStyle(fontSize: 12, color: rouge ? Couleurs.retard : gris)),
            if (action != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 30), padding: const EdgeInsets.symmetric(horizontal: 10)),
                    onPressed: () => _agir(action.$1, d),
                    child: Text(action.$2, style: const TextStyle(fontSize: 13)),
                  ),
                ),
              ),
          ]),
        );
    String heures(Map<String, Object?> d) {
      final h = DateTime.now().difference(DateTime.tryParse('${d['autorise_le'] ?? d['created_at']}') ?? DateTime.now()).inHours;
      return '$h h sur ${delai.inHours} h';
    }

    return _encadre(context,
        titre: 'À traiter',
        icone: retard ? Icons.warning_amber : Icons.pending_actions_outlined,
        couleur: retard ? Couleurs.retard : Couleurs.attente,
        enfants: [
          for (final d in aAutoriser)
            item(d, 'Demande de ${d['par'] ?? '—'} · à autoriser', _autorise ? ('autoriser', 'Autoriser') : null),
          for (final d in aSortir)
            item(d, "Autorisée · l'argent n'est pas encore sorti", _caisse || _autorise ? ('sortir', "Sortir l'argent") : null),
          for (final d in aConfirmer)
            item(d, 'Vive voix, ${d['oral'] ?? 'direction'} · ${heures(d)}', _autorise ? ('confirmer', 'Confirmer') : null,
                rouge: enRetard(d)),
        ]);
  }

  Widget _carnet(BuildContext context, List<String> bons, List<int> trous) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final nombres = [
      for (final b in bons)
        if (RegExp(r'(\d+)\s*$').hasMatch(b)) int.parse(RegExp(r'(\d+)\s*$').firstMatch(b)![1]!),
    ]..sort();
    return _encadre(context,
        titre: 'Carnet de bons de sortie',
        icone: trous.isEmpty ? Icons.check_circle_outline : Icons.warning_amber,
        couleur: trous.isEmpty ? null : Couleurs.retard,
        enfants: [
          if (nombres.isNotEmpty)
            Text('${nombres.first} → ${nombres.last} · ${bons.length} bon(s)', style: styleMono.copyWith(fontSize: 12, color: gris)),
          const SizedBox(height: 4),
          if (trous.isEmpty)
            Text('Aucun numéro manquant.', style: TextStyle(fontSize: 12, color: gris))
          else ...[
            Text('Manquant : ${trous.take(12).join(', ')}${trous.length > 12 ? '…' : ''}',
                style: const TextStyle(fontSize: 14, color: Couleurs.retard)),
            Text("Erreur de saisie, ou sortie d'argent non enregistrée.", style: TextStyle(fontSize: 12, color: gris)),
          ],
        ]);
  }

  Widget _parCategorie(BuildContext context, Lignes sorties, int total) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final montants = <String, (int, int)>{};
    for (final d in sorties) {
      final v = montants['${d['categorie']}'] ?? (0, 0);
      montants['${d['categorie']}'] = (v.$1 + (d['montant_gnf'] as int? ?? 0), v.$2 + 1);
    }
    final tri = montants.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    return _encadre(context, titre: 'Par catégorie', enfants: [
      if (tri.isEmpty) Text('Rien sur cette période.', style: TextStyle(fontSize: 13, color: gris)),
      for (final c in tri)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(c.key, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
              Text(gnf(c.value.$1), style: _chiffresDep.copyWith(fontSize: 13)),
            ]),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : c.value.$1 / total,
                minHeight: 4,
                backgroundColor: Couleurs.doux(context),
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .7),
              ),
            ),
            Text('${c.value.$2} sortie(s) · ${total == 0 ? 0 : (c.value.$1 * 100 / total).round()} %',
                style: TextStyle(fontSize: 12, color: gris)),
          ]),
        ),
    ]);
  }

  Widget _parBeneficiaire(BuildContext context, Lignes sorties) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final montants = <String, int>{};
    for (final d in sorties) {
      final b = '${d['beneficiaire'] ?? 'Sans bénéficiaire'}';
      montants[b] = (montants[b] ?? 0) + (d['montant_gnf'] as int? ?? 0);
    }
    final tri = (montants.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(6);
    return _encadre(context, titre: 'Par bénéficiaire', enfants: [
      if (tri.isEmpty) Text('Rien sur cette période.', style: TextStyle(fontSize: 13, color: gris)),
      for (final b in tri)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Expanded(child: Text(b.key, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
            Text(gnf(b.value), style: _chiffresDep.copyWith(fontSize: 13)),
          ]),
        ),
    ]);
  }

  /// Colonne « Autorisation » : sous le seuil, accordée, de vive voix…
  Widget _autorisation(BuildContext context, Map<String, Object?> d, bool retard) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final petit = TextStyle(fontSize: 12, color: gris);
    Widget deux(Widget haut, String? bas, {Color? couleur}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [haut, if (bas != null) Text(bas, maxLines: 1, overflow: TextOverflow.ellipsis, style: petit.copyWith(color: couleur))],
        );
    switch (d['statut']) {
      case 'demande':
        return deux(const Etat('À autoriser', ton: Ton.attente), d['par'] == null ? null : 'demandé par ${d['par']}');
      case 'autorisee':
        return deux(const Etat('Autorisée', ton: Ton.info), "argent pas encore sorti");
      case 'refusee':
        return deux(const Etat('Refusée'), d['motif_refus'] as String?);
      case 'annulee':
        return deux(const Etat('Annulée'), d['motif_annulation'] as String?);
    }
    if (d['autorisation_orale'] == 1) {
      return switch (d['confirmation']) {
        'confirmee' => deux(const Text('Vive voix, confirmée', style: TextStyle(fontSize: 14)), '${d['oral'] ?? ''}'),
        'contestee' => deux(const Etat('Contestée', ton: Ton.retard), d['motif_contestation'] as String?),
        _ => deux(
            Text('Vive voix, à confirmer', style: TextStyle(fontSize: 14, color: retard ? Couleurs.retard : null)),
            '${d['oral'] ?? ''}',
            couleur: retard ? Couleurs.retard : null),
      };
    }
    if (d['autorise_par'] != null) {
      return deux(const Text('Accordée', style: TextStyle(fontSize: 14)), '${d['autorisateur'] ?? 'direction'}');
    }
    return Text('Sous le seuil', style: TextStyle(fontSize: 14, color: gris));
  }

  /// Date effective, et la date de saisie si elle diffère (saisie après coup).
  Widget _dateCellule(BuildContext context, Map<String, Object?> d) {
    final saisie = '${d['created_at'] ?? ''}';
    final jourSaisie = saisie.length >= 10 ? _date(DateTime.tryParse(saisie)?.toLocal() ?? DateTime.now()) : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(_dateLisible(d['date_effective']), style: _chiffresDep.copyWith(fontSize: 14)),
      if (jourSaisie != null && jourSaisie != d['date_effective'])
        Text('saisie le ${_dateLisible(jourSaisie)}', style: const TextStyle(fontSize: 11, color: Couleurs.attente)),
    ]);
  }

  Widget _montant(Map<String, Object?> d, {double taille = 14}) {
    final barre = d['statut'] == 'annulee' || d['statut'] == 'refusee';
    return Text(gnf(d['montant_gnf']),
        style: _chiffresDep.copyWith(
          fontSize: taille,
          fontWeight: FontWeight.w500,
          decoration: barre ? TextDecoration.lineThrough : null,
          color: barre ? Theme.of(context).colorScheme.onSurfaceVariant : null,
        ));
  }

  Widget _menuLigne(Map<String, Object?> d, {double taille = 18}) => PopupMenuButton<String>(
        tooltip: 'Actions',
        icon: Icon(Icons.more_horiz, size: taille),
        onSelected: (a) => _agir(a, d),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'ouvrir', child: _ItemMenu(Icons.description_outlined, 'Voir le détail et le reçu')),
          if (_gestes(d).isNotEmpty) const PopupMenuDivider(),
          for (final g in _gestes(d))
            PopupMenuItem(
                value: g.$1,
                child: _ItemMenu(g.$2, g.$3, couleur: g.$1 == 'annuler' || g.$1 == 'refuser' ? Couleurs.retard : null)),
        ],
      );

  Widget _tableau(BuildContext context, Lignes lignes, bool Function(Map<String, Object?>) enRetard, String vide,
      {required bool categorie, required bool autorisation}) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    const entete = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);
    final petit = TextStyle(fontSize: 12, color: gris);
    Widget cellule(double? largeur, Widget enfant, {int flex = 1, Alignment align = Alignment.centerLeft}) {
      final contenu = Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Align(alignment: align, child: enfant));
      return largeur == null ? Expanded(flex: flex, child: contenu) : SizedBox(width: largeur, child: contenu);
    }

    final enTete = Container(
      height: 36,
      decoration: BoxDecoration(color: schema.surface, border: Border(bottom: BorderSide(color: bordure))),
      child: Row(children: [
        const SizedBox(width: 8),
        cellule(104, const Text('Date', style: entete)),
        cellule(null, const Text('Motif', style: entete), flex: 3),
        if (categorie) cellule(160, const Text('Catégorie', style: entete)),
        if (autorisation) cellule(200, const Text('Autorisation', style: entete)),
        cellule(72, const Text('Bon', style: entete)),
        cellule(136, const Text('Montant', style: entete), align: Alignment.centerRight),
        const SizedBox(width: 48),
      ]),
    );

    Widget ligne(Map<String, Object?> d) => Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _ouvrir(d),
            hoverColor: Couleurs.doux(context).withValues(alpha: .5),
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bordure))),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                const SizedBox(width: 8),
                cellule(104, _dateCellule(context, d)),
                cellule(
                  null,
                  Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('${d['motif']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                    Row(children: [
                      Flexible(
                        child: Text(
                            [
                              if (d['beneficiaire'] != null) '${d['beneficiaire']}',
                              if (!categorie) '${d['categorie']}',
                            ].join(' · '),
                            overflow: TextOverflow.ellipsis,
                            style: petit),
                      ),
                      if (d['a_justif'] == 1) ...[
                        const SizedBox(width: 6),
                        Tooltip(message: 'Reçu joint', child: Icon(Icons.attach_file, size: 13, color: gris)),
                      ],
                    ]),
                    if (!autorisation && (d['statut'] != 'sortie' || d['autorisation_orale'] == 1 || d['autorise_par'] != null))
                      Padding(padding: const EdgeInsets.only(top: 2), child: _autorisation(context, d, enRetard(d))),
                  ]),
                  flex: 3,
                ),
                if (categorie) cellule(160, Text('${d['categorie']}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
                if (autorisation) cellule(200, _autorisation(context, d, enRetard(d))),
                cellule(72, Text('${d['bon'] ?? '—'}', overflow: TextOverflow.ellipsis, style: styleMono.copyWith(fontSize: 13, color: d['bon'] == null ? gris : null))),
                cellule(136, _montant(d), align: Alignment.centerRight),
                SizedBox(width: 48, child: _menuLigne(d)),
              ]),
            ),
          ),
        );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: schema.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: bordure)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        enTete,
        Expanded(
          child: lignes.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(vide, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: gris)),
                  ),
                )
              : ListView.builder(itemCount: lignes.length, itemBuilder: (context, i) => ligne(lignes[i])),
        ),
      ]),
    );
  }

  /// Téléphone : des cartes, comme la liste des élèves.
  Widget _cartes(BuildContext context, Lignes lignes, bool Function(Map<String, Object?>) enRetard, String vide) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final bordure = Theme.of(context).dividerColor;
    if (lignes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(vide, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: gris)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: lignes.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final d = lignes[i];
        return Material(
          color: schema.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: bordure)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _ouvrir(d),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${d['motif']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                        [
                          _dateLisible(d['date_effective']),
                          '${d['categorie']}',
                          if (d['beneficiaire'] != null) '${d['beneficiaire']}',
                          if (d['bon'] != null) 'bon ${d['bon']}',
                        ].join(' · '),
                        style: TextStyle(fontSize: 12, color: gris)),
                    const SizedBox(height: 4),
                    _autorisation(context, d, enRetard(d)),
                  ]),
                ),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  _montant(d),
                  _menuLigne(d),
                ]),
              ]),
            ),
          ),
        );
      },
    );
  }
}

const _chiffresDep = TextStyle(fontFeatures: [ui.FontFeature.tabularFigures()]);

/// Ce que la caisse doit retrouver ce soir : le même calcul que la clôture
/// (espèces encaissées − remboursements versés − dépenses sorties).
class _CaisseDuJour extends StatelessWidget {
  const _CaisseDuJour({required this.orgId, required this.toute});

  final String orgId;

  /// Toute l'école (direction, comptabilité), sinon seulement ma caisse.
  final bool toute;

  @override
  Widget build(BuildContext context) {
    final jour = _date(DateTime.now());
    final moi = toute ? null : monId;
    return Requete(
      '''SELECT
           (SELECT coalesce(sum(total_gnf), 0) FROM encaissements WHERE organisation_id = ? AND date_effective = ?
              AND statut = 'valide' AND mode = 'especes' AND (? IS NULL OR encaisse_par = ?)) AS encaisse,
           (SELECT count(*) FROM encaissements WHERE organisation_id = ? AND date_effective = ?
              AND statut = 'valide' AND mode = 'especes' AND (? IS NULL OR encaisse_par = ?)) AS nb_recus,
           (SELECT coalesce(sum(montant_gnf), 0) FROM remboursements WHERE organisation_id = ? AND verse_le = ?
              AND statut = 'verse' AND mode = 'especes' AND (? IS NULL OR verse_par = ?)) AS rembourse,
           (SELECT coalesce(sum(montant_gnf), 0) FROM depenses WHERE organisation_id = ? AND sortie_le = ?
              AND statut = 'sortie' AND (? IS NULL OR sortie_par = ?)) AS depense,
           (SELECT count(*) FROM depenses WHERE organisation_id = ? AND sortie_le = ?
              AND statut = 'sortie' AND (? IS NULL OR sortie_par = ?)) AS nb_depenses''',
      parametres: [for (var i = 0; i < 5; i++) ...[orgId, jour, moi, moi]],
      builder: (context, l) {
        final gris = Theme.of(context).colorScheme.onSurfaceVariant;
        final r = l.isEmpty ? const <String, Object?>{} : l.first;
        final encaisse = r['encaisse'] as int? ?? 0;
        final rembourse = r['rembourse'] as int? ?? 0;
        final depense = r['depense'] as int? ?? 0;
        final net = encaisse - rembourse - depense;
        Widget poste(String libelle, String valeur, String aide, {bool attenue = false}) => Tooltip(
              message: aide,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(libelle, style: TextStyle(fontSize: 12, color: gris)),
                Text(valeur, style: _chiffresDep.copyWith(fontSize: 14, color: attenue ? gris : null)),
              ]),
            );
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: Wrap(spacing: 28, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(toute ? 'Caisse du jour · toute l\'école' : 'Ma caisse du jour', style: TextStyle(fontSize: 12, color: gris)),
              Text(_dateLisible(jour), style: const TextStyle(fontSize: 14)),
            ]),
            poste('Encaissé', _sansUnite(encaisse), '${r['nb_recus'] ?? 0} reçu(s) en espèces'),
            poste('Remboursements', '− ${_sansUnite(rembourse)}', 'Remboursements versés en espèces', attenue: true),
            poste('Dépenses', '− ${_sansUnite(depense)}', '${r['nb_depenses'] ?? 0} dépense(s) sortie(s) de la caisse', attenue: true),
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Net en caisse', style: TextStyle(fontSize: 12, color: gris)),
              Text(gnf(net),
                  style: _chiffresDep.copyWith(fontSize: 18, fontWeight: FontWeight.w600, color: net < 0 ? Couleurs.retard : null)),
            ]),
          ]),
        );
      },
    );
  }
}
