part of 'configuration.dart';

/// Étape 3 de l'onboarding : le personnel.
/// Fiche ≠ compte : on crée la fiche (hors ligne), on lui donne ses fonctions,
/// puis, si la personne utilise l'app, on l'invite avec un code (en ligne).

// Liste du personnel ----------------------------------------------------------

class PersonnelScreen extends StatelessWidget {
  const PersonnelScreen({super.key, required this.espace});

  final Espace espace;

  /// Sites où je peux ajouter du personnel ; null = personnel du groupe (fondateur).
  Future<Map<String?, String>> _mesSites() async => {
        for (final s in await db.getAll('SELECT id, nom FROM sites WHERE organisation_id = ? ORDER BY created_at',
            [espace.orgId]))
          if (espace.gereSite(s['id'] as String)) s['id'] as String: s['nom'] as String,
        if (espace.fondateur) null: 'Tout le groupe',
      };

  Future<void> _ajouter(BuildContext context) async {
    final sites = await _mesSites();
    if (!context.mounted || sites.isEmpty) return;
    final nom = TextEditingController();
    final telephone = TextEditingController();
    final libelle = TextEditingController();
    var site = sites.keys.first;
    var fonction = 'enseignant';
    final choixFonctions = {
      for (final f in fonctions.entries)
        if (f.key != 'fondateur' && (espace.fondateur || !fonctionsDeDirection.contains(f.key))) f.key: f.value,
    };
    final ok = await _formulaire(context, 'Nouvelle personne', (maj) => [
          TextField(
              controller: nom,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: _champ('Nom complet')),
          TextField(
              controller: telephone,
              keyboardType: TextInputType.phone,
              decoration: _champ('Téléphone (facultatif)',
                  aide: "Si renseigné, seul ce numéro pourra utiliser l'invitation")),
          _liste('Fonction', fonction, choixFonctions, (v) => maj(() => fonction = v)),
          if (fonction == 'autre')
            TextField(controller: libelle, decoration: _champ('Précisez', aide: 'Gardien, chauffeur, cuisinière…')),
          if (sites.length > 1) _liste('Site', site, sites, (v) => maj(() => site = v)),
        ]);
    if (!ok || nom.text.trim().length < 2) return;
    final tel = telephone.text.trim().isEmpty ? null : numeroInternational(telephone.text);
    final maintenant = _maintenant();
    await db.writeTransaction((tx) async {
      final id = (await tx.get('SELECT uuid() AS id'))['id'];
      await tx.execute(
          'INSERT INTO personnel (id, organisation_id, site_id, nom_complet, telephone, statut, created_at, updated_at) '
          "VALUES (?, ?, ?, ?, ?, 'actif', ?, ?)",
          [id, espace.orgId, site, nom.text.trim(), tel, maintenant, maintenant]);
      await tx.execute(
          'INSERT INTO affectations (id, organisation_id, personnel_id, site_id, fonction, libelle, actif, created_at, updated_at) '
          'VALUES (uuid(), ?, ?, ?, ?, ?, 1, ?, ?)',
          [
            espace.orgId, id, site, fonction,
            fonction == 'autre' && libelle.text.trim().length >= 2 ? libelle.text.trim() : null,
            maintenant, maintenant,
          ]);
    });
  }

  @override
  Widget build(BuildContext context) => _Page(
        titre: 'Personnel',
        ajouter: espace.gestionnaire ? () => _ajouter(context) : null,
        libelleAjouter: 'Personne',
        corps: Requete(
            '''SELECT p.*, s.nom AS site,
                 (SELECT group_concat(coalesce(a.libelle, a.fonction), ', ') FROM affectations a
                  WHERE a.personnel_id = p.id AND a.actif = 1) AS fonctions
               FROM personnel p LEFT JOIN sites s ON s.id = p.site_id
               WHERE p.organisation_id = ?
               ORDER BY p.statut = 'sorti', p.nom_complet''',
            parametres: [espace.orgId], builder: (context, personnes) {
          if (personnes.isEmpty) return _vide('Aucune fiche pour le moment.');
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Tout le personnel a une fiche, même sans utiliser Scolagrid. '
                  "Invitez ceux qui utiliseront l'app."),
            ),
            for (final p in personnes)
              Card(
                child: ListTile(
                  leading: Icon(
                    p['statut'] == 'sorti'
                        ? Icons.person_off_outlined
                        : p['user_id'] != null
                            ? Icons.verified_user_outlined
                            : Icons.person_outline,
                  ),
                  title: Text('${p['nom_complet']}'),
                  subtitle: Text([
                    (p['fonctions'] as String? ?? '').split(', ').map((f) => fonctions[f] ?? f).join(', '),
                    p['site'] ?? 'Tout le groupe',
                    if (p['statut'] == 'sorti') 'parti' else if (p['user_id'] != null) 'utilise l\'app',
                  ].where((t) => '$t'.isNotEmpty).join(' · ')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => FicheScreen(espace: espace, ficheId: p['id'] as String))),
                ),
              ),
          ]);
        }),
      );
}

// Fiche d'une personne --------------------------------------------------------

class FicheScreen extends StatelessWidget {
  const FicheScreen({super.key, required this.espace, required this.ficheId});

  final Espace espace;
  final String ficheId;

  bool _peutGerer(Map<String, Object?> fiche, Lignes fonctionsActives) {
    final direction = fonctionsActives.any((a) => fonctionsDeDirection.contains(a['fonction']));
    if (direction && !espace.fondateur) return false;
    final site = fiche['site_id'] as String?;
    return site == null ? espace.fondateur : espace.gereSite(site);
  }

  Future<void> _ajouterFonction(BuildContext context, Map<String, Object?> fiche) async {
    final sites = <String?, String>{
      for (final s in await db.getAll('SELECT id, nom FROM sites WHERE organisation_id = ? ORDER BY created_at',
          [espace.orgId]))
        if (espace.gereSite(s['id'] as String)) s['id'] as String: s['nom'] as String,
      if (espace.fondateur) null: 'Tous les sites',
    };
    if (!context.mounted || sites.isEmpty) return;
    final choix = {
      for (final f in fonctions.entries)
        if (espace.fondateur || !fonctionsDeDirection.contains(f.key)) f.key: f.value,
    };
    var fonction = 'enseignant';
    String? site = sites.containsKey(fiche['site_id']) ? fiche['site_id'] as String? : sites.keys.first;
    final libelle = TextEditingController();
    final ok = await _formulaire(context, 'Ajouter une fonction', (maj) => [
          _liste('Fonction', fonction, choix, (v) => maj(() => fonction = v)),
          if (fonction == 'autre') TextField(controller: libelle, decoration: _champ('Précisez')),
          if (sites.length > 1) _liste('Sur', site, sites, (v) => maj(() => site = v)),
        ]);
    if (!ok) return;
    // Une fonction retirée puis redonnée : on réactive la ligne existante.
    final existante = await db.getOptional(
        'SELECT id FROM affectations WHERE personnel_id = ? AND fonction = ? AND site_id IS ?', [ficheId, fonction, site]);
    if (existante != null) {
      await _modifier('affectations', existante['id'] as String, {'actif': 1});
    } else {
      await _inserer('affectations', {
        'organisation_id': espace.orgId,
        'personnel_id': ficheId,
        'site_id': site,
        'fonction': fonction,
        'libelle': fonction == 'autre' && libelle.text.trim().length >= 2 ? libelle.text.trim() : null,
        'actif': 1,
      });
    }
  }

  Future<void> _inviter(BuildContext context, Map<String, Object?> fiche) async {
    final messager = ScaffoldMessenger.of(context);
    if ((await db.getUploadQueueStats()).count > 0) {
      messager.showSnackBar(const SnackBar(
          content: Text('Des changements sont encore en cours d\'envoi. Réessayez dans un instant.')));
      return;
    }
    String code;
    try {
      code = await inviterPersonnel(ficheId);
    } on PostgrestException catch (e) {
      messager.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } catch (_) {
      messager.showSnackBar(const SnackBar(content: Text('Il faut internet pour créer une invitation.')));
      return;
    }
    if (!context.mounted) return;
    final message = 'Bonjour ${fiche['nom_complet']}, vous êtes invité(e) sur Scolagrid. '
        "Installez l'app, connectez-vous avec votre numéro, puis saisissez ce code : ${codeLisible(code)} "
        '(valable 7 jours).';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Code d'invitation"),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(codeLisible(code),
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 2)),
          const SizedBox(height: 12),
          Text(fiche['telephone'] != null
              ? 'Valable 7 jours, une seule fois, pour le numéro ${fiche['telephone']}.'
              : 'Valable 7 jours, une seule fois.'),
          const SizedBox(height: 8),
          const Text('Transmettez-le à la personne (SMS, WhatsApp ou de vive voix).'),
        ]),
        actions: [
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: message)),
            icon: const Icon(Icons.copy),
            label: const Text('Copier le message'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer')),
        ],
      ),
    );
  }

  Future<void> _changerDroit(String droit, bool parDefaut, bool voulu, String? exceptionId) async {
    if (voulu == parDefaut) {
      // Retour au comportement de la fonction : l'exception n'a plus lieu d'être.
      if (exceptionId != null) await _supprimer('droits_personnel', exceptionId);
    } else if (exceptionId != null) {
      await _modifier('droits_personnel', exceptionId, {'accorde': voulu ? 1 : 0});
    } else {
      await _inserer('droits_personnel', {
        'organisation_id': espace.orgId,
        'personnel_id': ficheId,
        'site_id': null,
        'droit': droit,
        'accorde': voulu ? 1 : 0,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    return Requete(
      '''SELECT p.*, s.nom AS site FROM personnel p LEFT JOIN sites s ON s.id = p.site_id WHERE p.id = ?''',
      parametres: [ficheId],
      builder: (context, l) {
        if (l.isEmpty) return const Scaffold(body: Center(child: Text('Fiche introuvable.')));
        final fiche = l.first;
        return Requete(
          '''SELECT a.*, s.nom AS site FROM affectations a LEFT JOIN sites s ON s.id = a.site_id
             WHERE a.personnel_id = ? ORDER BY a.actif DESC, a.created_at''',
          parametres: [ficheId],
          builder: (context, affectations) {
            final actives = [for (final a in affectations) if (a['actif'] == 1) a];
            final gere = _peutGerer(fiche, actives) && fiche['statut'] == 'actif';
            return _Page(
              titre: '${fiche['nom_complet']}',
              ajouter: gere ? () => _ajouterFonction(context, fiche) : null,
              libelleAjouter: 'Fonction',
              corps: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: Text('${fiche['telephone'] ?? 'Pas de téléphone'}'),
                    subtitle: Text('${fiche['site'] ?? 'Tout le groupe'}'
                        '${fiche['statut'] == 'sorti' ? ' · a quitté l\'établissement' : ''}'),
                  ),
                ),
                // Compte : relié, ou à inviter.
                Card(
                  child: fiche['user_id'] != null
                      ? const ListTile(
                          leading: Icon(Icons.verified_user_outlined, color: Colors.teal),
                          title: Text("Utilise l'app"),
                          subtitle: Text('Son compte est relié à cette fiche.'),
                        )
                      : ListTile(
                          leading: const Icon(Icons.person_add_alt_outlined),
                          title: const Text("N'utilise pas l'app"),
                          subtitle: const Text("Invitez-la si elle doit utiliser Scolagrid. Nécessite internet."),
                          trailing: gere && actives.isNotEmpty
                              ? FilledButton(onPressed: () => _inviter(context, fiche), child: const Text('Inviter'))
                              : null,
                        ),
                ),
                const SizedBox(height: 12),
                Text('Fonctions', style: texte.titleMedium),
                const SizedBox(height: 4),
                if (actives.isEmpty) const Text('Aucune fonction.'),
                for (final a in actives)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.work_outline),
                      title: Text('${a['libelle'] ?? fonctions[a['fonction']] ?? a['fonction']}'),
                      subtitle: Text('${a['site'] ?? 'Tous les sites'}'),
                      trailing: gere && (a['fonction'] != 'fondateur')
                          ? IconButton(
                              tooltip: 'Retirer cette fonction',
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: () async {
                                if (await _confirmer(context, 'Retirer cette fonction ?')) {
                                  await _modifier('affectations', a['id'] as String, {'actif': 0});
                                }
                              },
                            )
                          : null,
                    ),
                  ),
                const SizedBox(height: 12),
                _Droits(
                  ficheId: ficheId,
                  fonctionsActives: actives.map((a) => a['fonction'] as String),
                  modifiable: espace.fondateur && !actives.any((a) => a['fonction'] == 'fondateur'),
                  changer: _changerDroit,
                ),
                if (gere && actives.every((a) => a['fonction'] != 'fondateur')) ...[
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (await _confirmer(context,
                          '${fiche['nom_complet']} quitte l\'établissement ? Son accès à l\'app sera coupé. La fiche est conservée.')) {
                        await _modifier('personnel', ficheId, {'statut': 'sorti'});
                      }
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text("A quitté l'établissement"),
                  ),
                ],
              ]),
            );
          },
        );
      },
    );
  }
}

/// Droits de la personne : ceux de ses fonctions, plus ou moins les exceptions
/// décidées par le fondateur.
class _Droits extends StatelessWidget {
  const _Droits({required this.ficheId, required this.fonctionsActives, required this.modifiable, required this.changer});

  final String ficheId;
  final Iterable<String> fonctionsActives;
  final bool modifiable;
  final Future<void> Function(String droit, bool parDefaut, bool voulu, String? exceptionId) changer;

  @override
  Widget build(BuildContext context) => Requete(
        // Pour l'instant, les exceptions valent pour tous les sites.
        'SELECT * FROM droits_personnel WHERE personnel_id = ? AND site_id IS NULL',
        parametres: [ficheId],
        builder: (context, exceptions) {
          final parDefaut = droitsDesFonctions(fonctionsActives);
          final parDroit = {for (final e in exceptions) e['droit'] as String: e};
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Droits', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(fonctionsActives.contains('fondateur')
                ? 'Le fondateur a tous les droits.'
                : 'Donnés par ses fonctions.${modifiable ? ' Vous pouvez en accorder ou en retirer.' : ''}'),
            Card(
              child: Column(children: [
                for (final d in droits.entries)
                  SwitchListTile(
                    dense: true,
                    title: Text(d.value),
                    subtitle: parDroit[d.key] == null
                        ? null
                        : Text(parDroit[d.key]!['accorde'] == 1 ? 'Accordé en plus' : 'Retiré'),
                    value: parDroit[d.key] == null ? parDefaut.contains(d.key) : parDroit[d.key]!['accorde'] == 1,
                    onChanged: modifiable
                        ? (v) => changer(d.key, parDefaut.contains(d.key), v, parDroit[d.key]?['id'] as String?)
                        : null,
                  ),
              ]),
            ),
          ]);
        },
      );
}
