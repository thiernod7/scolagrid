part of 'configuration.dart';

/// Familles : on part du parent. Ses enfants, ce que la famille doit en tout,
/// encaisser pour toute la famille, l'appeler, corriger ses coordonnées une
/// seule fois pour tous ses enfants, et fusionner un parent créé deux fois.

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

class FamillesScreen extends StatefulWidget {
  const FamillesScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<FamillesScreen> createState() => _FamillesScreenState();
}

class _FamillesScreenState extends State<FamillesScreen> {
  final _recherche = TextEditingController();
  String? _filtre; // 'retard', 'reste', 'doublons'

  @override
  void dispose() {
    _recherche.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.espace.orgId;
    return Scaffold(
      body: Requete(
        '''SELECT c.id, c.nom_complet, c.telephone, c.telephone2, c.profession, c.adresse,
             count(DISTINCT ec.eleve_id) AS nb,
             group_concat(DISTINCT e.id) AS enfants,
             group_concat(DISTINCT e.prenoms) AS prenoms_enfants
           FROM contacts c
           JOIN eleves_contacts ec ON ec.contact_id = c.id
           JOIN eleves e ON e.id = ec.eleve_id
           WHERE c.organisation_id = ?
           GROUP BY c.id
           ORDER BY c.nom_complet''',
        parametres: [o],
        builder: (context, familles) => _AvecSoldes(
          orgId: o,
          builder: (context, soldes) => _contenu(context, familles, soldes),
        ),
      ),
    );
  }

  Widget _contenu(BuildContext context, Lignes familles, Map<String, _SoldeEleve>? soldes) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final telephone = MediaQuery.sizeOf(context).width < 640;
    _SoldeEleve total(Map<String, Object?> f) {
      var du = 0, paye = 0, retard = 0;
      for (final id in '${f['enfants'] ?? ''}'.split(',').where((x) => x.isNotEmpty)) {
        final s = soldes?[id];
        if (s == null) continue;
        du += s.du;
        paye += s.paye;
        retard += s.retard;
      }
      return (du: du, paye: paye, retard: retard);
    }

    final doublons = famillesEnDouble(familles);
    final q = nomSimplifie(_recherche.text);
    final chiffres = _recherche.text.replaceAll(RegExp(r'[^0-9]'), '');
    final liste = familles.where((f) {
      if (q.isNotEmpty &&
          !nomSimplifie('${f['nom_complet']} ${f['prenoms_enfants'] ?? ''}').contains(q) &&
          !(chiffres.length >= 3 && '${f['telephone'] ?? ''}${f['telephone2'] ?? ''}'.replaceAll(' ', '').contains(chiffres))) {
        return false;
      }
      final t = total(f);
      return switch (_filtre) {
        'retard' => t.retard > 0,
        'reste' => t.du - t.paye > 0,
        'doublons' => doublons.contains(f['id']),
        _ => true,
      };
    }).toList();
    final enRetard = familles.where((f) => total(f).retard > 0).length;

    return ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
      EnTetePage(
        titre: 'Familles',
        sousTitre: '${familles.length} famille(s)'
            '${soldes != null && enRetard > 0 ? ' · $enRetard en retard' : ''}'
            '${doublons.isNotEmpty ? ' · ${doublons.length} doublon(s) probable(s)' : ''}',
      ),
      const SizedBox(height: 8),
      Text('Un parent et tous ses enfants : ce que la famille doit, encaisser pour tous, appeler, corriger ses coordonnées.',
          style: TextStyle(fontSize: 12, color: gris)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: telephone ? double.infinity : 340,
          height: 36,
          child: TextField(
            controller: _recherche,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              prefixIcon: Icon(Icons.search, size: 18, color: gris),
              prefixIconConstraints: const BoxConstraints(minWidth: 36),
              hintText: 'Parent, téléphone ou prénom d\'un enfant',
              hintStyle: TextStyle(fontSize: 14, color: gris),
            ),
          ),
        ),
        MenuCompact<String>(
          largeur: telephone ? 220 : 240,
          valeur: _filtre,
          tous: 'Toutes les familles',
          choix: {
            'retard': 'En retard de paiement',
            'reste': 'Avec un reste à payer',
            if (doublons.isNotEmpty) 'doublons': 'Doublons probables (${doublons.length})',
          },
          onChanged: (v) => setState(() => _filtre = v),
        ),
        if (_filtre != null || _recherche.text.isNotEmpty)
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: gris, minimumSize: const Size(36, 36)),
            onPressed: () => setState(() {
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
          child: Text('Même nom, ou même téléphone : sans doute le même parent créé deux fois. '
              'Ouvrez la famille à garder et choisissez « Fusionner avec… ».', style: TextStyle(fontSize: 12, color: gris)),
        ),
      if (liste.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text('Aucune famille.', style: TextStyle(color: gris))),
      for (final f in liste.take(300))
        Builder(builder: (context) {
          final t = total(f);
          final reste = t.du - t.paye;
          return Card(
            child: ListTile(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => FicheFamilleScreen(espace: widget.espace, contactId: f['id'] as String))),
              leading: Initiales('${f['nom_complet']}', taille: 36),
              title: Text('${f['nom_complet']}', overflow: TextOverflow.ellipsis),
              subtitle: Text([
                if (f['telephone'] != null) '${f['telephone']}',
                '${f['nb']} enfant(s) : ${'${f['prenoms_enfants'] ?? ''}'.replaceAll(',', ', ')}',
              ].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: soldes == null
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(reste > 0 ? gnf(reste) : 'À jour', style: styleMono.copyWith(fontSize: 13)),
                      if (t.retard > 0) Etat('${gnf(t.retard)} en retard', ton: Ton.retard),
                      if (doublons.contains(f['id']) && t.retard == 0) const Etat('Doublon ?', ton: Ton.attente),
                    ]),
            ),
          );
        }),
      if (liste.length > 300)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text('300 premières familles affichées : précisez la recherche.', style: TextStyle(fontSize: 12, color: gris)),
        ),
    ]);
  }
}

/// Parents probablement créés deux fois : même nom, ou même téléphone.
Set<String> famillesEnDouble(Iterable<Map<String, Object?>> familles) {
  final parNom = <String, List<String>>{};
  final parTel = <String, List<String>>{};
  for (final f in familles) {
    final id = f['id'] as String;
    parNom.putIfAbsent(nomSimplifie('${f['nom_complet']}'), () => []).add(id);
    for (final t in [f['telephone'], f['telephone2']]) {
      final n = '${t ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '');
      if (n.length >= 8) parTel.putIfAbsent(n.substring(n.length - 9 < 0 ? 0 : n.length - 9), () => []).add(id);
    }
  }
  return {
    for (final l in [...parNom.values, ...parTel.values])
      if (l.toSet().length > 1) ...l,
  };
}

class FicheFamilleScreen extends StatelessWidget {
  const FicheFamilleScreen({super.key, required this.espace, required this.contactId});

  final Espace espace;
  final String contactId;

  /// Coordonnées du parent : une seule fois pour tous ses enfants.
  Future<void> _modifierParent(BuildContext context, Map<String, Object?> c) async {
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
  Future<void> _fusionner(BuildContext context, Map<String, Object?> c) async {
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

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT * FROM contacts WHERE id = ?',
        parametres: [contactId],
        builder: (context, contacts) {
          if (contacts.isEmpty) return const Scaffold(body: Center(child: Text('Famille introuvable.')));
          final c = contacts.first;
          return _Page(
            titre: '${c['nom_complet']}',
            corps: Requete(
              '''SELECT e.id, e.nom, e.prenoms, e.matricule, ec.lien, ec.tuteur_principal, ec.responsable_financier,
                   i.id AS inscription_id, i.statut, c.nom AS classe
                 FROM eleves_contacts ec JOIN eleves e ON e.id = ec.eleve_id
                 LEFT JOIN annees_scolaires a ON a.organisation_id = e.organisation_id AND a.en_cours = 1
                 LEFT JOIN inscriptions i ON i.eleve_id = e.id AND i.annee_id = a.id
                 LEFT JOIN classes c ON c.id = i.classe_id
                 WHERE ec.contact_id = ? ORDER BY e.date_naissance, e.prenoms''',
              parametres: [contactId],
              builder: (context, enfants) => _AvecSoldes(
                orgId: espace.orgId,
                builder: (context, soldes) => _contenu(context, c, enfants, soldes),
              ),
            ),
          );
        },
      );

  Widget _contenu(BuildContext context, Map<String, Object?> c, Lignes enfants, Map<String, _SoldeEleve>? soldes) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    var du = 0, paye = 0, retard = 0;
    for (final e in enfants) {
      final s = soldes?[e['id']];
      if (s == null) continue;
      du += s.du;
      paye += s.paye;
      retard += s.retard;
    }
    final aInscrire = enfants.where((e) => e['inscription_id'] != null).toList();
    final peutEncaisser = espace.fondateur || espace.droits.contains('encaisser');
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text([
              if (c['telephone'] != null) '${c['telephone']}',
              if (c['telephone2'] != null) '${c['telephone2']}',
            ].join(' · '), style: const TextStyle(fontSize: 15)),
            if (c['profession'] != null || c['adresse'] != null)
              Text([if (c['profession'] != null) '${c['profession']}', if (c['adresse'] != null) '${c['adresse']}'].join(' · '),
                  style: TextStyle(color: gris)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (c['telephone'] != null) ...[
                OutlinedButton.icon(
                    onPressed: () => _appeler('${c['telephone']}'), icon: const Icon(Icons.call_outlined, size: 16), label: const Text('Appeler')),
                OutlinedButton.icon(
                    onPressed: () => _appeler('${c['telephone']}', whatsapp: true),
                    icon: const Icon(Icons.chat_outlined, size: 16),
                    label: const Text('WhatsApp')),
              ],
              if (espace.droits.contains('gerer_inscriptions') || espace.fondateur) ...[
                OutlinedButton.icon(
                    onPressed: () => _modifierParent(context, c), icon: const Icon(Icons.edit_outlined, size: 16), label: const Text('Modifier')),
                OutlinedButton.icon(
                    onPressed: () => _fusionner(context, c),
                    icon: const Icon(Icons.merge_type, size: 16),
                    label: const Text('Fusionner avec…')),
              ],
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: soldes == null
              ? const Center(child: CircularProgressIndicator())
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    const Expanded(child: Text('Reste à payer pour la famille', style: TextStyle(fontWeight: FontWeight.w600))),
                    Text(gnf(du - paye), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  ]),
                  Text('Dû cette année ${gnf(du)} · payé ${gnf(paye)}', style: TextStyle(color: gris)),
                  if (retard > 0) ...[const SizedBox(height: 4), Etat('${gnf(retard)} en retard', ton: Ton.retard)],
                  if (peutEncaisser && aInscrire.isNotEmpty && du - paye > 0) ...[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => EncaisserScreen(espace: espace, eleveId: aInscrire.first['id'] as String))),
                      icon: const Icon(Icons.point_of_sale_outlined, size: 16),
                      label: const Text('Encaisser pour la famille'),
                    ),
                    Text('Les frères et sœurs sont proposés sur le même reçu.', style: TextStyle(fontSize: 12, color: gris)),
                  ],
                ]),
        ),
      ),
      const SizedBox(height: 12),
      Text('Enfants', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      for (final e in enfants)
        Builder(builder: (context) {
          final s = soldes?[e['id']];
          return Card(
            child: ListTile(
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => FicheEleveScreen(espace: espace, eleveId: e['id'] as String))),
              leading: Initiales('${e['nom']} ${e['prenoms']}', taille: 36),
              title: Text('${e['nom']} ${e['prenoms']}'),
              subtitle: Text([
                e['classe'] == null ? 'Pas inscrit cette année' : '${e['classe']}',
                '${liensFamille[e['lien']] ?? e['lien']}',
                if (e['responsable_financier'] == 1) 'paie',
                if (e['tuteur_principal'] == 1) 'tuteur principal',
              ].join(' · ')),
              trailing: s == null
                  ? null
                  : Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(s.du - s.paye > 0 ? gnf(s.du - s.paye) : 'À jour', style: styleMono.copyWith(fontSize: 13)),
                      if (s.retard > 0) Etat('${gnf(s.retard)} en retard', ton: Ton.retard),
                    ]),
            ),
          );
        }),
    ]);
  }
}
