part of 'configuration.dart';

/// Identité de l'école : ce qui figure sur les documents (attestations, reçus)
/// et les codes qui entrent dans les numéros (matricules, reçus).

class IdentiteEcoleScreen extends StatelessWidget {
  const IdentiteEcoleScreen({super.key, required this.espace});

  final Espace espace;

  Future<void> _choisirSigle(BuildContext context, Map<String, Object?> org) async {
    final code = TextEditingController(text: codeSuggere('${org['nom']}'));
    final ok = await _formulaire(context, "Sigle de l'école", (_) => [
          const Text('Le sigle entre dans les matricules et les numéros de reçu, '
              'par exemple ALPHA-DONKA-2026-B042. Il ne pourra plus être modifié.'),
          TextField(
            controller: code,
            textCapitalization: TextCapitalization.characters,
            maxLength: 10,
            decoration: _champ('Sigle', aide: '2 à 10 lettres ou chiffres, sans espace'),
          ),
        ]);
    final c = code.text.trim().toUpperCase();
    if (!ok || !context.mounted) return;
    final messager = ScaffoldMessenger.of(context);
    if (!codeValide(c)) {
      messager.showSnackBar(const SnackBar(content: Text('Le sigle doit avoir 2 à 10 lettres ou chiffres.')));
      return;
    }
    try {
      await definirSigle(org['id'] as String, c);
      messager.showSnackBar(SnackBar(content: Text('Sigle $c enregistré.')));
    } on PostgrestException catch (e) {
      messager.showSnackBar(SnackBar(
          content: Text(e.code == '23505' ? 'Le sigle $c est déjà pris par une autre école.' : e.message)));
    } catch (_) {
      messager.showSnackBar(const SnackBar(content: Text('Il faut internet pour enregistrer le sigle.')));
    }
  }

  /// Modifie un groupe de champs de l'école (une carte de l'écran).
  Future<void> _modifierGroupe(BuildContext context, Map<String, Object?> org, String titre,
      List<(String col, String libelle, String? aide, TextInputType? clavier)> champs) async {
    final ctrl = {
      for (final c in champs)
        c.$1: TextEditingController(text: c.$1 == 'date_creation' && org[c.$1] != null ? _dateLisible(org[c.$1]) : '${org[c.$1] ?? ''}'),
    };
    final ok = await _formulaire(context, titre, (_) => [
          for (final c in champs)
            TextField(controller: ctrl[c.$1], keyboardType: c.$4, decoration: _champ(c.$2, aide: c.$3)),
        ]);
    if (!ok || !context.mounted) return;
    final valeurs = <String, Object?>{};
    for (final c in champs) {
      final v = ctrl[c.$1]!.text.trim();
      if (v.isEmpty) {
        valeurs[c.$1] = null;
      } else if (c.$1 == 'date_creation') {
        final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(v);
        final d = m != null ? DateTime(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!)) : DateTime.tryParse(v);
        if (d == null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Date de création : écrivez jj/mm/aaaa.')));
          return;
        }
        valeurs[c.$1] = _date(d);
      } else if (c.$1.contains('telephone')) {
        valeurs[c.$1] = numeroInternational(v);
      } else if (c.$1.contains('email') && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${c.$2} : adresse invalide.')));
        return;
      } else {
        valeurs[c.$1] = v;
      }
    }
    await _modifier('organisations', org['id'] as String, valeurs);
  }

  /// Logo, signature ou cachet : une image choisie sur le poste.
  Future<void> _image(BuildContext context, String sorte) async {
    final p = await choisirPhoto(context, camera: false);
    if (p == null) return;
    final m = _maintenant();
    await db.writeTransaction((tx) async {
      final deja = await tx.getOptional('SELECT id FROM images_ecole WHERE organisation_id = ? AND sorte = ?', [espace.orgId, sorte]);
      if (deja != null) {
        await tx.execute('UPDATE images_ecole SET type_image = ?, image = ?, updated_at = ? WHERE id = ?', [p.type, p.base64, m, deja['id']]);
      } else {
        await tx.execute(
            'INSERT INTO images_ecole (id, organisation_id, sorte, type_image, image, created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?)',
            [espace.orgId, sorte, p.type, p.base64, m, m]);
      }
    });
  }

  Future<void> _codeSite(BuildContext context, Map<String, Object?> site) async {
    final code = TextEditingController(text: codeSuggere('${site['nom']}'));
    final ok = await _formulaire(context, 'Code du site ${site['nom']}', (_) => [
          const Text('Le code du site entre dans les matricules et les numéros de reçu. '
              'Il ne pourra plus être modifié.'),
          TextField(
            controller: code,
            textCapitalization: TextCapitalization.characters,
            maxLength: 10,
            decoration: _champ('Code', aide: 'Par exemple DONKA, ou S01'),
          ),
        ]);
    final c = code.text.trim().toUpperCase();
    if (!ok || !context.mounted) return;
    final pris = await db.getOptional('SELECT 1 FROM sites WHERE organisation_id = ? AND code = ?', [espace.orgId, c]);
    if (!context.mounted) return;
    if (!codeValide(c) || pris != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(pris != null ? 'Ce code est déjà utilisé par un autre site.' : 'Le code doit avoir 2 à 10 lettres ou chiffres.')));
      return;
    }
    await _modifier('sites', site['id'] as String, {'code': c});
  }

  @override
  Widget build(BuildContext context) => _Page(
        titre: "L'école",
        corps: Requete('SELECT * FROM organisations WHERE id = ?', parametres: [espace.orgId], builder: (context, l) {
          if (l.isEmpty) return _vide('Organisation introuvable.');
          final org = l.first;
          final f = espace.fondateur;
          return Requete('SELECT * FROM sites WHERE organisation_id = ? ORDER BY created_at', parametres: [espace.orgId],
              builder: (context, sites) => Requete(
                  'SELECT sorte, image, updated_at FROM images_ecole WHERE organisation_id = ?',
                  parametres: [espace.orgId],
                  builder: (context, imgs) {
                    final images = {for (final i in imgs) i['sorte'] as String: i};
                    Widget vignette(String sorte, double taille, String vide) {
                      final i = images[sorte];
                      Widget dedans;
                      try {
                        dedans = i == null
                            ? Center(child: Text(vide, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)))
                            : Image.memory(base64Decode(i['image'] as String), fit: BoxFit.contain, gaplessPlayback: true);
                      } catch (_) {
                        dedans = const Icon(Icons.broken_image_outlined);
                      }
                      return InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: f ? () => _image(context, sorte) : null,
                        child: Container(
                          width: taille,
                          height: taille,
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Couleurs.doux(context),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                          ),
                          child: dedans,
                        ),
                      );
                    }

                    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
                      LayoutBuilder(builder: (context, c) {
                        final deux = c.maxWidth >= 760;
                        final w = deux ? (c.maxWidth - 12) / 2 : c.maxWidth;
                        Widget bloc(Widget x) => SizedBox(width: w, child: x);
                        return Wrap(spacing: 12, runSpacing: 12, children: [
                          bloc(_CarteEcole(
                            titre: 'Informations de base',
                            modifier: f
                                ? () => _modifierGroupe(context, org, 'Informations de base', [
                                      ('nom_officiel', 'Nom officiel', 'En tête de tous les documents', null),
                                      ('slogan', 'Devise', 'Excellence et Discipline', null),
                                    ])
                                : null,
                            enfants: [
                              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Column(children: [
                                  vignette('logo', 72, 'Logo'),
                                  const SizedBox(height: 4),
                                  Text('Logo', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                ]),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    _LuEcole('Nom officiel', '${org['nom_officiel'] ?? org['nom']}'),
                                    _LuEcole('Devise', org['slogan'] as String?),
                                    Row(children: [
                                      Expanded(child: _LuEcole('Sigle (matricules, reçus)', org['code'] as String?, mono: true)),
                                      if (org['code'] == null && f)
                                        TextButton(onPressed: () => _choisirSigle(context, org), child: const Text('Choisir')),
                                    ]),
                                  ]),
                                ),
                              ]),
                            ],
                          )),
                          bloc(_CarteEcole(
                            titre: 'Adresse',
                            modifier: f
                                ? () => _modifierGroupe(context, org, 'Adresse', [
                                      ('quartier', 'Quartier', 'Donka', null),
                                      ('commune', 'Commune', 'Dixinn', null),
                                    ])
                                : null,
                            enfants: [
                              _LuEcole('Quartier', org['quartier'] as String?),
                              _LuEcole('Commune', org['commune'] as String?),
                              _LuEcole('Ville', org['ville'] as String?),
                            ],
                          )),
                          bloc(_CarteEcole(
                            titre: 'Contacts',
                            modifier: f
                                ? () => _modifierGroupe(context, org, 'Contacts', [
                                      ('telephone', 'Téléphone principal', null, TextInputType.phone),
                                      ('telephone2', 'Téléphone secondaire', null, TextInputType.phone),
                                      ('email', 'E-mail', null, TextInputType.emailAddress),
                                      ('site_web', 'Site web', 'www.monecole.gn', TextInputType.url),
                                    ])
                                : null,
                            enfants: [
                              _LuEcole('Téléphone principal', org['telephone'] as String?),
                              _LuEcole('Téléphone secondaire', org['telephone2'] as String?),
                              _LuEcole('E-mail', org['email'] as String?),
                              _LuEcole('Site web', org['site_web'] as String?),
                            ],
                          )),
                          bloc(_CarteEcole(
                            titre: 'Responsable légal',
                            aide: 'Signe les attestations et les certificats.',
                            modifier: f
                                ? () => _modifierGroupe(context, org, 'Responsable légal', [
                                      ('responsable_nom', 'Nom complet', null, null),
                                      ('responsable_titre', 'Titre', 'Directeur, Fondateur, Proviseur…', null),
                                      ('responsable_telephone', 'Téléphone', null, TextInputType.phone),
                                      ('responsable_email', 'E-mail', null, TextInputType.emailAddress),
                                    ])
                                : null,
                            enfants: [
                              _LuEcole('Nom complet', org['responsable_nom'] as String?),
                              _LuEcole('Titre', org['responsable_titre'] as String?),
                              _LuEcole('Téléphone', org['responsable_telephone'] as String?),
                              _LuEcole('E-mail', org['responsable_email'] as String?),
                            ],
                          )),
                          bloc(_CarteEcole(
                            titre: 'Informations administratives',
                            modifier: f
                                ? () => _modifierGroupe(context, org, 'Informations administratives', [
                                      ('numero_autorisation', "N° d'autorisation d'ouverture", 'Par exemple MEPU-A 2011/0042', null),
                                      ('nif', 'Identification fiscale (NIF)', null, null),
                                      ('date_creation', 'Date de création', 'jj/mm/aaaa', TextInputType.datetime),
                                    ])
                                : null,
                            enfants: [
                              _LuEcole("N° d'autorisation", org['numero_autorisation'] as String?, mono: true),
                              _LuEcole('NIF', org['nif'] as String?, mono: true),
                              _LuEcole('Date de création', org['date_creation'] == null ? null : _dateLisible(org['date_creation'])),
                            ],
                          )),
                          bloc(_CarteEcole(
                            titre: 'Sites',
                            aide: 'Le code du site entre dans les matricules et les reçus. Définitif.',
                            enfants: [
                              for (final x in sites)
                                Row(children: [
                                  Expanded(child: _LuEcole('${x['nom']}', x['code'] == null ? null : 'Code ${x['code']}', mono: true)),
                                  if (x['code'] == null && espace.gereSite(x['id'] as String))
                                    TextButton(onPressed: () => _codeSite(context, x), child: const Text('Choisir le code')),
                                ]),
                            ],
                          )),
                        ]);
                      }),
                      const SizedBox(height: 12),
                      _CarteEcole(
                        titre: 'Sur les documents',
                        aide: 'Reçus, attestations, certificats et décharges.',
                        enfants: [
                          Wrap(spacing: 16, runSpacing: 12, children: [
                            Column(children: [
                              vignette('signature', 96, 'Signature scannée'),
                              const SizedBox(height: 4),
                              const Text('Signature', style: TextStyle(fontSize: 11)),
                            ]),
                            Column(children: [
                              vignette('cachet', 96, 'Cachet scanné'),
                              const SizedBox(height: 4),
                              const Text('Cachet', style: TextStyle(fontSize: 11)),
                            ]),
                          ]),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: org['signature_documents'] == 1,
                            onChanged: f ? (v) => _modifier('organisations', espace.orgId, {'signature_documents': v ? 1 : 0}) : null,
                            title: const Text('Imprimer la signature et le cachet sur les documents'),
                            subtitle: const Text('Sinon, la place reste libre pour signer et tamponner à la main.'),
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Mention en bas des reçus'),
                            subtitle: Text('${org['mention_recu'] ?? 'Aucune'}'),
                            trailing: f ? const Icon(Icons.edit_outlined, size: 18) : null,
                            onTap: f
                                ? () => _modifierGroupe(context, org, 'Mention en bas des reçus', [
                                      ('mention_recu', 'Mention', 'Les frais versés ne sont pas remboursables.', null),
                                    ])
                                : null,
                          ),
                          if (f)
                            Text('Touchez une image pour la changer (fichier PNG ou JPEG).',
                                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ]);
                  }));
        }),
      );
}

/// Une carte de l'écran « L'école » : titre, aide, bouton Modifier, contenu.
class _CarteEcole extends StatelessWidget {
  const _CarteEcole({required this.titre, required this.enfants, this.aide, this.modifier});

  final String titre;
  final String? aide;
  final VoidCallback? modifier;
  final List<Widget> enfants;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: schema.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: schema.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: schema.outlineVariant))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(titre, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                if (aide != null) Text(aide!, style: TextStyle(fontSize: 12, color: schema.onSurfaceVariant)),
              ]),
            ),
            if (modifier != null) TextButton(onPressed: modifier, child: const Text('Modifier')),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: enfants),
        ),
      ]),
    );
  }
}

/// Un champ lu : libellé gris, valeur dessous (ou « — »).
class _LuEcole extends StatelessWidget {
  const _LuEcole(this.libelle, this.valeur, {this.mono = false});

  final String libelle;
  final String? valeur;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(libelle, style: TextStyle(fontSize: 12, color: gris)),
        Text(valeur ?? '—',
            style: mono && valeur != null ? styleMono.copyWith(fontSize: 14) : TextStyle(fontSize: 14, color: valeur == null ? gris : null)),
      ]),
    );
  }
}
