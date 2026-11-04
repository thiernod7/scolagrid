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

class _DepensesScreenState extends State<DepensesScreen> {
  bool _caisse = false;
  bool _autorise = false;
  DateTime _mois = DateTime(DateTime.now().year, DateTime.now().month);
  String? _categorie;

  Espace get _e => widget.espace;

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
    final ok = await _formulaire(context, 'Nouvelle dépense', (maj) {
      final auDessus = (m() ?? 0) > seuil && !_autorise;
      return [
        TextField(
          controller: montant,
          autofocus: true,
          keyboardType: TextInputType.number,
          onChanged: (_) => maj(() {}),
          decoration: _champ('Montant', suffixe: 'GNF', aide: 'Sorti de la caisse, en espèces'),
        ),
        if (sites.length > 1) _liste('Site', site, sites, (v) => maj(() => site = v)),
        OutlinedButton.icon(
          onPressed: () async {
            final d = await _choisirDate(context, date, premier: DateTime.now().subtract(const Duration(days: 60)));
            if (d != null) maj(() => date = d);
          },
          icon: const Icon(Icons.event_outlined, size: 16),
          label: Text('Date de la dépense : ${_dateLisible(_date(date))}'),
        ),
        _liste('Catégorie', categorie, {
          for (final c in [...categoriesDepenses, ...dejaUtilisees]) c: c,
          '…': 'Autre catégorie…',
        }, (v) => maj(() => categorie = v)),
        if (categorie == '…')
          TextField(controller: autreCategorie, decoration: _champ('Nouvelle catégorie', aide: 'Par exemple : Cantine, Sécurité')),
        TextField(
          controller: motif,
          textCapitalization: TextCapitalization.sentences,
          decoration: _champ('Motif', aide: 'Obligatoire. Par exemple : 3 ramettes A4 pour le secrétariat'),
        ),
        TextField(
          controller: beneficiaire,
          textCapitalization: TextCapitalization.words,
          decoration: _champ('Bénéficiaire (facultatif)', aide: "Qui a reçu l'argent : Librairie du Centre, le menuisier…"),
        ),
        TextField(controller: bon, decoration: _champ('N° du bon de sortie (facultatif)', aide: 'Si l\'école a un carnet de bons')),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          OutlinedButton.icon(
            onPressed: () async {
              final p = await choisirPhoto(context, camera: cameraDisponible, taille: 1000);
              if (p != null) maj(() => justificatif = p);
            },
            icon: Icon(justificatif == null ? Icons.receipt_long_outlined : Icons.check, size: 16),
            label: Text(justificatif == null ? 'Joindre le reçu du fournisseur (facultatif)' : 'Reçu joint'),
          ),
        ]),
        if (auDessus) ...[
          Text('Au-dessus de ${gnf(seuil)} : il faut l\'accord de la direction.',
              style: const TextStyle(fontWeight: FontWeight.w500, color: Couleurs.attente)),
          if (orale && direction.isNotEmpty)
            Segments<bool>(
              valeur: deVive,
              choix: const {false: "Demander l'autorisation", true: 'Déjà autorisée de vive voix'},
              onChanged: (v) => maj(() => deVive = v),
            ),
          if (deVive && orale && direction.isNotEmpty) ...[
            _liste('Autorisée par', qui ?? direction.keys.first, direction, (v) => maj(() => qui = v)),
            const Text("L'argent sort tout de suite ; la direction confirmera dans l'app (ou signera le bon).",
                style: TextStyle(fontSize: 12)),
          ] else
            const Text("La demande part à la direction ; l'argent sortira une fois autorisée.", style: TextStyle(fontSize: 12)),
        ],
      ];
    });
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

  /// Une dépense : son détail et ce qu'on peut en faire, selon son étape et mes droits.
  Future<void> _ouvrir(Map<String, Object?> d) async {
    final justificatif = await db.getOptional('SELECT type_image, image FROM justificatifs_depenses WHERE depense_id = ?', [d['id']]);
    if (!mounted) return;
    final moi = d['cree_par'] == monId;
    final actions = <(String, String)>[
      if (d['statut'] == 'demande' && _autorise) ...[('autoriser', 'Autoriser'), ('refuser', 'Refuser')],
      if (d['statut'] == 'autorisee' && (_caisse || _autorise)) ('sortir', "Sortir l'argent aujourd'hui"),
      if (d['confirmation'] == 'attendue' && _autorise) ...[('confirmer', "Confirmer l'autorisation"), ('contester', 'Contester')],
      if (d['bon'] == null && d['statut'] != 'annulee' && (_caisse || _autorise)) ('bon', 'Ajouter le n° du bon'),
      if (justificatif == null && d['statut'] != 'annulee' && (_caisse || _autorise)) ('justificatif', 'Joindre le reçu'),
      if (d['statut'] != 'annulee' && d['statut'] != 'refusee' && (_autorise || (moi && d['statut'] != 'sortie'))) ('annuler', 'Annuler'),
    ];
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
              if (d['autorisation_orale'] == 1)
                Text('Autorisée de vive voix par ${d['oral'] ?? 'la direction'}'
                    '${d['confirmation'] == 'attendue' ? ' : à confirmer' : d['confirmation'] == 'confirmee' ? ' : confirmée' : ' : contestée'}'),
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
          for (final a in actions)
            TextButton(onPressed: () => Navigator.pop(context, a.$1), child: Text(a.$2)),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer')),
        ],
      ),
    );
    if (choix == null || !mounted) return;
    Future<String?> motif(String titre, String aide) async {
      final c = TextEditingController();
      final ok = await _formulaire(context, titre, (_) => [TextField(controller: c, autofocus: true, decoration: _champ(aide))]);
      return ok && c.text.trim().length >= 3 ? c.text.trim() : null;
    }

    final id = d['id'] as String;
    switch (choix) {
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

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT * FROM organisations WHERE id = ?',
        parametres: [_e.orgId],
        builder: (context, orgs) {
          if (orgs.isEmpty) return const SizedBox.shrink();
          final org = orgs.first;
          final debut = _date(_mois);
          final fin = _date(DateTime(_mois.year, _mois.month + 1, 0));
          return _Page(
            titre: 'Dépenses',
            ajouter: _caisse || _autorise ? () => _nouvelle(org) : null,
            libelleAjouter: 'Nouvelle dépense',
            corps: Requete(
              '''SELECT d.*, p.nom_complet AS par, o.nom_complet AS oral
                 FROM depenses d
                 LEFT JOIN personnel p ON p.user_id = d.cree_par AND p.organisation_id = d.organisation_id
                 LEFT JOIN personnel o ON o.id = d.autorise_oralement_par
                 WHERE d.organisation_id = ?
                   AND (d.date_effective BETWEEN ? AND ? OR d.statut IN ('demande', 'autorisee') OR d.confirmation = 'attendue')
                 ORDER BY d.date_effective DESC, d.created_at DESC''',
              parametres: [_e.orgId, debut, fin],
              builder: (context, lignes) => _contenu(context, org, lignes, debut, fin),
            ),
          );
        },
      );

  Widget _contenu(BuildContext context, Map<String, Object?> org, Lignes lignes, String debut, String fin) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final delai = Duration(hours: org['delai_confirmation_heures'] as int? ?? 48);
    final aAutoriser = lignes.where((d) => d['statut'] == 'demande').toList();
    final aSortir = lignes.where((d) => d['statut'] == 'autorisee').toList();
    final aConfirmer = lignes.where((d) => d['confirmation'] == 'attendue').toList();
    final duMois = lignes
        .where((d) => '${d['date_effective']}'.compareTo(debut) >= 0 && '${d['date_effective']}'.compareTo(fin) <= 0)
        .where((d) => _categorie == null || d['categorie'] == _categorie)
        .toList();
    final sorties = duMois.where((d) => d['statut'] == 'sortie').toList();
    final parCategorie = <String, int>{};
    for (final d in sorties) {
      parCategorie[d['categorie'] as String] = (parCategorie[d['categorie']] ?? 0) + (d['montant_gnf'] as int? ?? 0);
    }
    final total = parCategorie.values.fold(0, (s, v) => s + v);
    final trous = bonsManquants(lignes.where((d) => d['statut'] != 'annulee').map((d) => d['bon'] as String?));
    const moisNoms = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];

    Widget ligne(Map<String, Object?> d) {
      final enRetard = d['confirmation'] == 'attendue' &&
          DateTime.now().difference(DateTime.tryParse('${d['autorise_le'] ?? d['created_at']}') ?? DateTime.now()) > delai;
      return Card(
        child: ListTile(
          onTap: () => _ouvrir(d),
          title: Text('${d['categorie']} · ${d['motif']}', maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text([
            _dateLisible(d['date_effective']),
            if (d['beneficiaire'] != null) '${d['beneficiaire']}',
            if (d['bon'] != null) 'bon ${d['bon']}',
            if (d['confirmation'] == 'attendue') enRetard ? 'confirmation en retard' : 'autorisée de vive voix, à confirmer',
          ].join(' · ')),
          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(gnf(d['montant_gnf']), style: styleMono.copyWith(fontSize: 13)),
            const SizedBox(height: 2),
            Etat(_statutsDepense[d['statut']]?.$1.split(' :').first ?? '${d['statut']}',
                ton: enRetard ? Ton.retard : _statutsDepense[d['statut']]?.$2 ?? Ton.neutre),
          ]),
        ),
      );
    }

    Widget encadre(String titre, List<Map<String, Object?>> liste, Color couleur) => Card(
          color: couleur.withValues(alpha: .08),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('$titre · ${liste.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
              for (final d in liste) ligne(d),
            ]),
          ),
        );

    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
      Text("Ce qui sort de la caisse en dehors des remboursements et des salaires : fournitures, carburant, réparations… "
          "Motif obligatoire, reçu du fournisseur facultatif. Au-dessus de ${gnf(org['seuil_depense_gnf'] ?? 100000)}, "
          "il faut l'accord de la direction.", style: TextStyle(fontSize: 13, color: gris)),
      if (_e.fondateur)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
              onPressed: () => _regles(org), icon: const Icon(Icons.tune, size: 16), label: const Text('Règles : seuil, vive voix')),
        ),
      const SizedBox(height: 8),
      if (aAutoriser.isNotEmpty) encadre(_autorise ? 'À autoriser' : 'En attente de la direction', aAutoriser, Couleurs.attente),
      if (aSortir.isNotEmpty) encadre("Autorisées : l'argent reste à sortir", aSortir, Couleurs.info),
      if (aConfirmer.isNotEmpty) encadre('Autorisées de vive voix, à confirmer', aConfirmer, Couleurs.attente),
      if (trous.isNotEmpty)
        Card(
          color: Couleurs.retard.withValues(alpha: .08),
          child: ListTile(
            leading: const Icon(Icons.warning_amber, color: Couleurs.retard),
            title: Text('Bons de sortie manquants : ${trous.take(12).join(', ')}${trous.length > 12 ? '…' : ''}'),
            subtitle: const Text('Un numéro absent : une erreur de saisie, ou une sortie d\'argent non enregistrée.'),
          ),
        ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        IconButton(
            tooltip: 'Mois précédent',
            onPressed: () => setState(() => _mois = DateTime(_mois.year, _mois.month - 1)),
            icon: const Icon(Icons.chevron_left)),
        Text('${moisNoms[_mois.month - 1]} ${_mois.year}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        IconButton(
            tooltip: 'Mois suivant',
            onPressed: () => setState(() => _mois = DateTime(_mois.year, _mois.month + 1)),
            icon: const Icon(Icons.chevron_right)),
        MenuCompact<String>(
          largeur: 230,
          valeur: _categorie,
          tous: 'Toutes les catégories',
          choix: {
            for (final c in {...categoriesDepenses, ...lignes.map((d) => '${d['categorie']}')}) c: c,
          },
          onChanged: (v) => setState(() => _categorie = v),
        ),
        if (_categorie != null || _mois != DateTime(DateTime.now().year, DateTime.now().month))
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: gris, minimumSize: const Size(36, 36)),
            onPressed: () => setState(() {
              _categorie = null;
              _mois = DateTime(DateTime.now().year, DateTime.now().month);
            }),
            icon: const Icon(Icons.close, size: 14),
            label: const Text('Réinitialiser', style: TextStyle(fontSize: 14)),
          ),
      ]),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(child: Text('Sorti de la caisse ce mois', style: TextStyle(fontWeight: FontWeight.w600))),
              Text(gnf(total), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ]),
            for (final c in parCategorie.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  Expanded(child: Text(c.key, style: TextStyle(color: gris))),
                  Text(gnf(c.value), style: styleMono.copyWith(fontSize: 13)),
                ]),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      if (duMois.isEmpty) Text('Aucune dépense ce mois-ci.', style: TextStyle(color: gris)),
      for (final d in duMois) ligne(d),
    ]);
  }
}
