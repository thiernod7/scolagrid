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
    group_concat(DISTINCT e.prenoms) AS prenoms_enfants
  FROM contacts c
  JOIN eleves_contacts ec ON ec.contact_id = c.id
  JOIN eleves e ON e.id = ec.eleve_id
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

String _liensLisibles(Object? liens) =>
    '${liens ?? ''}'.split(',').where((x) => x.isNotEmpty).map((l) => liensFamille[l] ?? l).toSet().join(', ');

class FamillesScreen extends StatefulWidget {
  const FamillesScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<FamillesScreen> createState() => _FamillesScreenState();
}

class _FamillesScreenState extends State<FamillesScreen> {
  final _recherche = TextEditingController();
  String? _filtre; // tuteurs, payeurs, fratrie, retard, reste, doublons
  String _tri = 'nom';
  int _ordre = 1;
  int _page = 0;
  int _parPage = 50;
  String? _ouvert;

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
        t(f['adresse']), t('${f['prenoms_enfants'] ?? ''}'.replaceAll(',', ', ')), xl.IntCellValue(f['tutelle'] as int? ?? 0),
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
                  width: 520,
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
    final liste = familles.where((f) {
      if (q.isNotEmpty &&
          !nomSimplifie('${f['nom_complet']} ${f['prenoms_enfants'] ?? ''}').contains(q) &&
          !(chiffres.length >= 3 && '${f['telephone'] ?? ''}${f['telephone2'] ?? ''}'.replaceAll(' ', '').contains(chiffres))) {
        return false;
      }
      final s = _soldeACharge(f, soldes);
      return switch (_filtre) {
        'tuteurs' => (f['tutelle'] as int? ?? 0) > 0,
        'payeurs' => (f['charge'] as int? ?? 0) > 0,
        'fratrie' => (f['charge'] as int? ?? 0) >= 2,
        'retard' => s.retard > 0,
        'reste' => s.du - s.paye > 0,
        'doublons' => doublons.contains(f['id']),
        _ => true,
      };
    }).map((f) => Map<String, Object?>.from(f)).toList()
      ..sort((a, b) {
        final v = _tri == 'enfants'
            ? (a['nb'] as int? ?? 0).compareTo(b['nb'] as int? ?? 0)
            : nomSimplifie('${a['nom_complet']}').compareTo(nomSimplifie('${b['nom_complet']}'));
        return v * _ordre;
      });
    final fratries = familles.where((f) => (f['charge'] as int? ?? 0) >= 2).length;
    final enRetard = soldes == null ? 0 : familles.where((f) => _soldeACharge(f, soldes).retard > 0).length;
    final pages = liste.isEmpty ? 1 : (liste.length / _parPage).ceil();
    final page = _page.clamp(0, pages - 1);
    final affiches = liste.skip(page * _parPage).take(_parPage).toList();
    void filtrer(VoidCallback f) => setState(() {
          f();
          _page = 0;
        });

    Widget triable(String libelle, String cle) => InkWell(
          onTap: () => _trier(cle),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(libelle, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(width: 4),
            Icon(_tri == cle ? Icons.swap_vert : Icons.unfold_more, size: 13, color: gris),
          ]),
        );

    Widget roles(Map<String, Object?> f) => Wrap(spacing: 4, runSpacing: 4, children: [
          if ((f['tutelle'] as int? ?? 0) > 0) Etat('tuteur${(f['tutelle'] as int) > 1 ? ' ×${f['tutelle']}' : ''}', ton: Ton.info),
          if ((f['charge'] as int? ?? 0) > 0) Etat('payeur${(f['charge'] as int) > 1 ? ' ×${f['charge']}' : ''}', ton: Ton.neutre),
        ]);

    return ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8, children: [
        EnTetePage(
          titre: 'Parents & tuteurs',
          sousTitre: '${liste.length}${liste.length != familles.length ? ' sur ${familles.length}' : ''} · $fratries fratrie(s)'
              '${enRetard > 0 ? ' · $enRetard en retard' : ''}',
        ),
        OutlinedButton.icon(
          onPressed: liste.isEmpty ? null : () => _exporter(liste, soldes),
          icon: const Icon(Icons.download_outlined, size: 16),
          label: const Text('Exporter'),
        ),
      ]),
      const SizedBox(height: 8),
      Text('Une ligne par personne. Le reste dû ne compte que les enfants à sa charge (ceux dont elle est responsable financier).',
          style: TextStyle(fontSize: 12, color: gris)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: telephone ? double.infinity : 340,
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
              hintText: "Parent, téléphone ou prénom d'un enfant",
              hintStyle: TextStyle(fontSize: 14, color: gris),
            ),
          ),
        ),
        MenuCompact<String>(
          largeur: 250,
          valeur: _filtre,
          tous: 'Tous les contacts',
          choix: {
            'tuteurs': 'Tuteurs principaux',
            'payeurs': 'Responsables financiers',
            'fratrie': 'Fratries (2 enfants et plus)',
            'retard': 'En retard de paiement',
            'reste': 'Avec un reste à payer',
            if (doublons.isNotEmpty) 'doublons': 'Doublons probables (${doublons.length})',
          },
          onChanged: (v) => filtrer(() => _filtre = v),
        ),
        if (telephone)
          MenuCompact<String>(
            largeur: 200,
            valeur: _tri == 'enfants' ? 'enfants' : null,
            tous: 'Trier par nom',
            choix: const {'enfants': "Trier par nombre d'enfants"},
            onChanged: (v) => setState(() {
              _tri = v ?? 'nom';
              _ordre = v == null ? 1 : -1;
            }),
          ),
        if (_filtre != null || _recherche.text.isNotEmpty)
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: gris, minimumSize: const Size(36, 36)),
            onPressed: () => filtrer(() {
              _filtre = null;
              _recherche.clear();
            }),
            icon: const Icon(Icons.close, size: 14),
            label: const Text('Réinitialiser', style: TextStyle(fontSize: 14)),
          ),
      ]),
      const SizedBox(height: 12),
      if (_filtre == 'doublons')
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text("Même téléphone, ou même nom quand l'un n'a pas de numéro : sans doute le même parent créé deux fois. "
              'Ouvrez celui à garder et choisissez « Fusionner avec… ».', style: TextStyle(fontSize: 12, color: gris)),
        ),
      if (!telephone)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(children: [
            const SizedBox(width: 48),
            Expanded(flex: 3, child: Align(alignment: Alignment.centerLeft, child: triable('Contact', 'nom'))),
            const SizedBox(width: 150, child: Text('Rôles', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
            Expanded(flex: 3, child: Text('Enfants', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: gris))),
            SizedBox(width: 60, child: Align(alignment: Alignment.centerRight, child: triable('Liés', 'enfants'))),
            const SizedBox(width: 150, child: Text('Reste dû', textAlign: TextAlign.right, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
          ]),
        ),
      if (affiches.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text('Aucun contact.', style: TextStyle(color: gris))),
      for (final f in affiches)
        Builder(builder: (context) {
          final s = _soldeACharge(f, soldes);
          final reste = s.du - s.paye;
          final paie = (f['charge'] as int? ?? 0) > 0;
          final montant = soldes == null
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(!paie ? '—' : (reste > 0 ? gnf(reste) : 'À jour'), style: styleMono.copyWith(fontSize: 13)),
                  if (s.retard > 0) Etat('${gnf(s.retard)} en retard', ton: Ton.retard),
                  if (doublons.contains(f['id']) && s.retard == 0) const Etat('Doublon ?', ton: Ton.attente),
                ]);
          final sousTitre = [
            _liensLisibles(f['liens']),
            if (f['profession'] != null) '${f['profession']}',
            if (telephone && f['telephone'] != null) '${f['telephone']}',
          ].where((x) => x.isNotEmpty).join(' · ');
          return Card(
            color: _ouvert == f['id'] ? schema.secondaryContainer.withValues(alpha: .4) : null,
            child: InkWell(
              onTap: () => _ouvrir(f['id'] as String),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: telephone
                    ? Row(children: [
                        Initiales('${f['nom_complet']}', taille: 36),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${f['nom_complet']}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
                            if (sousTitre.isNotEmpty) Text(sousTitre, style: TextStyle(fontSize: 12, color: gris)),
                            const SizedBox(height: 4),
                            roles(f),
                          ]),
                        ),
                        montant,
                      ])
                    : Row(children: [
                        Initiales('${f['nom_complet']}', taille: 36),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${f['nom_complet']}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
                            Text([sousTitre, if (f['telephone'] != null) '${f['telephone']}'].where((x) => x.isNotEmpty).join(' · '),
                                overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
                          ]),
                        ),
                        SizedBox(width: 150, child: roles(f)),
                        Expanded(
                          flex: 3,
                          child: Text('${f['prenoms_enfants'] ?? ''}'.replaceAll(',', ', '),
                              maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                        ),
                        SizedBox(width: 60, child: Text('${f['nb']}', textAlign: TextAlign.right, style: styleMono.copyWith(fontSize: 13))),
                        SizedBox(width: 150, child: Align(alignment: Alignment.centerRight, child: montant)),
                      ]),
              ),
            ),
          );
        }),
      const SizedBox(height: 8),
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8, children: [
        Text(liste.isEmpty ? 'Aucun résultat' : '${page * _parPage + 1}–${page * _parPage + affiches.length} sur ${liste.length}',
            style: TextStyle(fontSize: 14, color: gris)),
        Row(mainAxisSize: MainAxisSize.min, children: [
          MenuCompact<int>(
            largeur: 140,
            valeur: _parPage == 50 ? null : _parPage,
            tous: '50 par page',
            choix: const {25: '25 par page', 100: '100 par page'},
            onChanged: (v) => filtrer(() => _parPage = v ?? 50),
          ),
          IconButton(
              tooltip: 'Page précédente',
              onPressed: page > 0 ? () => setState(() => _page = page - 1) : null,
              icon: const Icon(Icons.chevron_left)),
          Text('${page + 1} / $pages', style: TextStyle(fontSize: 14, color: gris)),
          IconButton(
              tooltip: 'Page suivante',
              onPressed: page < pages - 1 ? () => setState(() => _page = page + 1) : null,
              icon: const Icon(Icons.chevron_right)),
        ]),
      ]),
    ]);
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
          if (contacts.isEmpty) return const Center(child: Text('Contact introuvable.'));
          final c = contacts.first;
          return Requete(
            '''SELECT e.id, e.nom, e.prenoms, e.matricule, ec.lien, ec.tuteur_principal, ec.responsable_financier,
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
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
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
    final aEncaisser = aCharge.where((e) => e['inscription_id'] != null).toList();
    final peutEncaisser = espace.fondateur || espace.droits.contains('encaisser');
    final gere = espace.fondateur || espace.droits.contains('gerer_inscriptions');
    Widget chiffre(String libelle, String valeur, {Color? couleur, String? dessous}) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(libelle, style: TextStyle(fontSize: 12, color: gris)),
            Text(valeur, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: couleur)),
            if (dessous != null) Text(dessous, style: TextStyle(fontSize: 12, color: couleur ?? gris)),
          ]),
        );

    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
      Row(children: [
        Initiales('${c['nom_complet']}', taille: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${c['nom_complet']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            Text([
              _liensLisibles(enfants.map((e) => e['lien']).join(',')),
              if (c['profession'] != null) '${c['profession']}',
            ].where((x) => x.isNotEmpty).join(' · '), style: TextStyle(fontSize: 12, color: gris)),
            Text([if (c['telephone'] != null) '${c['telephone']}', if (c['telephone2'] != null) '${c['telephone2']}'].join(' · '),
                style: TextStyle(fontSize: 13, color: gris)),
            if (c['adresse'] != null) Text('${c['adresse']}', style: TextStyle(fontSize: 12, color: gris)),
          ]),
        ),
        IconButton(tooltip: 'Fermer', onPressed: fermer, icon: const Icon(Icons.close)),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        chiffre('Tutelle', '$tutelle'),
        chiffre('À sa charge', '${aCharge.length}'),
        chiffre(
          'Reste dû',
          aCharge.isEmpty ? '—' : (soldes == null ? '…' : (du - paye > 0 ? gnf(du - paye) : 'à jour')),
          couleur: retard > 0 ? Couleurs.retard : (aCharge.isNotEmpty && soldes != null && du - paye == 0 ? Couleurs.regle : null),
          dessous: retard > 0 ? '${gnf(retard)} en retard' : null,
        ),
      ]),
      if (aCharge.length >= 2) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Couleurs.regle.withValues(alpha: .08), borderRadius: BorderRadius.circular(8)),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: 'Fratrie de ${aCharge.length}. ', style: const TextStyle(fontWeight: FontWeight.w600)),
            TextSpan(text: "La réduction fratrie (si l'école en a une) s'applique sur la scolarité de chacun.", style: TextStyle(color: gris)),
          ])),
        ),
      ],
      const SizedBox(height: 16),
      Text('ÉLÈVES RATTACHÉS', style: TextStyle(fontSize: 12, letterSpacing: .6, fontWeight: FontWeight.w500, color: gris)),
      const SizedBox(height: 4),
      for (final e in enfants)
        Builder(builder: (context) {
          final s = soldes?[e['id']];
          return InkWell(
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: espace, eleveId: e['id'] as String))),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Initiales('${e['nom']} ${e['prenoms']}', taille: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${e['nom']} ${e['prenoms']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    Text([
                      e['classe'] == null ? 'Pas inscrit cette année' : '${e['classe']}',
                      '${liensFamille[e['lien']] ?? e['lien']}',
                      if (e['tuteur_principal'] == 1) 'tuteur',
                      if (e['responsable_financier'] == 1) 'payeur',
                    ].join(' · '), style: TextStyle(fontSize: 12, color: gris)),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  e['statut'] == null ? const Etat('Pas inscrit') : etatInscription('${e['statut']}'),
                  if (s != null && e['responsable_financier'] == 1)
                    Text(s.du - s.paye > 0 ? gnf(s.du - s.paye) : 'à jour', style: styleMono.copyWith(fontSize: 12)),
                ]),
              ]),
            ),
          );
        }),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (c['telephone'] != null) ...[
          OutlinedButton.icon(
              onPressed: () => _appeler('${c['telephone']}'), icon: const Icon(Icons.call_outlined, size: 16), label: const Text('Appeler')),
          OutlinedButton.icon(
              onPressed: () => _appeler('${c['telephone']}', whatsapp: true),
              icon: const Icon(Icons.chat_outlined, size: 16),
              label: const Text('WhatsApp')),
        ],
        if (gere) ...[
          OutlinedButton.icon(
              onPressed: () => _modifierParent(context, contactId, c),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Corriger les coordonnées')),
          OutlinedButton.icon(
              onPressed: () => _fusionner(context, contactId, c),
              icon: const Icon(Icons.merge_type, size: 16),
              label: const Text('Fusionner avec…')),
        ],
        if (peutEncaisser && aEncaisser.isNotEmpty && du - paye > 0)
          FilledButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => EncaisserScreen(espace: espace, eleveId: aEncaisser.first['id'] as String))),
            icon: const Icon(Icons.point_of_sale_outlined, size: 16),
            label: const Text('Encaisser'),
          ),
      ]),
      if (peutEncaisser && aEncaisser.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Les autres enfants à sa charge sont proposés sur le même reçu.', style: TextStyle(fontSize: 12, color: gris)),
        ),
    ]);
  }
}

