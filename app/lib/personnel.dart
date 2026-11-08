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
    final prenoms = TextEditingController();
    final nom = TextEditingController();
    final telephone = TextEditingController();
    final libelle = TextEditingController();
    var site = sites.keys.first;
    final choisis = <String>{'enseignant'};
    final choixTitres = [
      for (final t in titres.entries)
        if (espace.fondateur || !fonctionsDeDirection.contains(t.value.fonction)) t.key,
    ];
    final ok = await _formulaire(context, 'Nouvelle personne', (maj) => [
          TextField(
              controller: prenoms,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: _champ('Prénom(s)')),
          TextField(
              controller: nom,
              textCapitalization: TextCapitalization.characters,
              decoration: _champ('Nom')),
          TextField(
              controller: telephone,
              keyboardType: TextInputType.phone,
              decoration: _champ('Téléphone (facultatif)',
                  aide: "Si renseigné, seul ce numéro pourra utiliser l'invitation")),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Fonctions (plusieurs possibles : les droits s\'additionnent)', style: TextStyle(fontSize: 13)),
          ),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in choixTitres)
              FilterChip(
                label: Text(nomTitre(t)),
                selected: choisis.contains(t),
                onSelected: (v) => maj(() => v ? choisis.add(t) : choisis.remove(t)),
              ),
          ]),
          if (choisis.contains('autre'))
            TextField(controller: libelle, decoration: _champ('Précisez', aide: 'Gardien, chauffeur, cuisinière…')),
          if (sites.length > 1) _liste('Site', site, sites, (v) => maj(() => site = v)),
        ]);
    if (!ok || prenoms.text.trim().isEmpty || nom.text.trim().isEmpty || choisis.isEmpty) {
      if (ok && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Le prénom, le nom et au moins une fonction sont demandés.')));
      }
      return;
    }
    final tel = telephone.text.trim().isEmpty ? null : numeroInternational(telephone.text);
    final maintenant = _maintenant();
    await db.writeTransaction((tx) async {
      final id = (await tx.get('SELECT uuid() AS id'))['id'];
      await tx.execute(
          'INSERT INTO personnel (id, organisation_id, site_id, nom_complet, prenoms, nom, telephone, statut, created_at, updated_at) '
          "VALUES (?, ?, ?, ?, ?, ?, ?, 'actif', ?, ?)",
          [id, espace.orgId, site, nomPersonne(prenoms.text, nom.text), prenoms.text.trim(), nom.text.trim().toUpperCase(), tel,
            maintenant, maintenant]);
      for (final t in choisis) {
        final titre = titres[t]!;
        await tx.execute(
            'INSERT INTO affectations (id, organisation_id, personnel_id, site_id, fonction, libelle, actif, created_at, updated_at) '
            'VALUES (uuid(), ?, ?, ?, ?, ?, 1, ?, ?)',
            [
              espace.orgId, id, site, titre.fonction,
              t == 'autre' ? (libelle.text.trim().length >= 2 ? libelle.text.trim() : null) : titre.libelle,
              maintenant, maintenant,
            ]);
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Requete(
          '''SELECT p.*, s.nom AS site,
               (SELECT group_concat(coalesce(a.libelle, a.fonction), ', ') FROM affectations a
                WHERE a.personnel_id = p.id AND a.actif = 1) AS fonctions
             FROM personnel p LEFT JOIN sites s ON s.id = p.site_id
             WHERE p.organisation_id = ?
             ORDER BY p.statut = 'sorti', p.nom_complet''',
          parametres: [espace.orgId],
          builder: (context, personnes) => _ListePersonnel(espace: espace, personnes: personnes, ajouter: () => _ajouter(context)),
        ),
      );
}

class _ListePersonnel extends StatefulWidget {
  const _ListePersonnel({required this.espace, required this.personnes, required this.ajouter});

  final Espace espace;
  final Lignes personnes;
  final VoidCallback ajouter;

  @override
  State<_ListePersonnel> createState() => _ListePersonnelState();
}

class _ListePersonnelState extends State<_ListePersonnel> {
  final _q = TextEditingController();
  String? _fonction;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final largeur = MediaQuery.sizeOf(context).width;
    final telephone = largeur < 640;
    String libelles(Map<String, Object?> p) =>
        (p['fonctions'] as String? ?? '').split(', ').where((f) => f.isNotEmpty).map((f) => fonctions[f] ?? f).join(', ');
    final q = nomSimplifie(_q.text);
    final liste = widget.personnes.where((p) {
      if (_fonction != null && !'${p['fonctions'] ?? ''}'.split(', ').contains(_fonction)) return false;
      return q.isEmpty || nomSimplifie('${p['nom_complet']} ${p['telephone'] ?? ''} ${libelles(p)}').contains(q);
    }).toList();
    final utilisent = widget.personnes.where((p) => p['user_id'] != null && p['statut'] != 'sorti').length;
    final presentes = <String>{
      for (final p in widget.personnes) ...'${p['fonctions'] ?? ''}'.split(', ').where((f) => f.isNotEmpty),
    };

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
          EnTetePage(
            titre: 'Personnel',
            sousTitre: '${widget.personnes.length} personne(s) · $utilisent utilise(nt) l\'app',
            actions: [
              if (widget.espace.gestionnaire)
                FilledButton.icon(
                    onPressed: widget.ajouter, icon: const Icon(Icons.person_add_alt, size: 16), label: const Text('Ajouter une personne')),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: telephone ? MediaQuery.sizeOf(context).width - 24 - 52 : 340,
              height: 36,
              child: TextField(
                controller: _q,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  prefixIcon: Icon(Icons.search, size: 18, color: gris),
                  prefixIconConstraints: const BoxConstraints(minWidth: 36),
                  hintText: 'Nom, téléphone ou fonction',
                  hintStyle: TextStyle(fontSize: 14, color: gris),
                ),
              ),
            ),
            if (telephone)
              BoutonFiltres(
                actifs: _fonction == null ? 0 : 1,
                reinitialiser: () => setState(() {
                  _fonction = null;
                  _q.clear();
                }),
                menus: (largeurMenu, rafraichir) => [
                  MenuCompact<String>(
                    largeur: largeurMenu,
                    valeur: _fonction,
                    tous: 'Toutes les fonctions',
                    choix: {for (final f in presentes) f: fonctions[f] ?? f},
                    onChanged: (v) {
                      setState(() => _fonction = v);
                      rafraichir();
                    },
                  ),
                ],
              )
            else
              MenuCompact<String>(
                largeur: 200,
                valeur: _fonction,
                tous: 'Toutes les fonctions',
                choix: {for (final f in presentes) f: fonctions[f] ?? f},
                onChanged: (v) => setState(() => _fonction = v),
              ),
            if (!telephone && (_fonction != null || _q.text.isNotEmpty))
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: gris, minimumSize: const Size(36, 36)),
                onPressed: () => setState(() {
                  _fonction = null;
                  _q.clear();
                }),
                icon: const Icon(Icons.close, size: 14),
                label: const Text('Réinitialiser', style: TextStyle(fontSize: 14)),
              ),
          ]),
          const SizedBox(height: 8),
          Text("Tout le personnel a une fiche, même sans utiliser Scolagrid. Invitez ceux qui utiliseront l'app.",
              style: TextStyle(fontSize: 12, color: gris)),
          const SizedBox(height: 12),
          Tableau(
            vide: widget.personnes.isEmpty ? 'Aucune fiche pour le moment.' : 'Personne ne correspond.',
            colonnes: [
              ColonneTableau('', largeur: telephone ? 48 : 56),
              const ColonneTableau('Nom', flex: 3),
              if (!telephone) const ColonneTableau('Fonction', flex: 3),
              if (largeur >= 1024) const ColonneTableau('Site', largeur: 160),
              ColonneTableau('Accès', largeur: telephone ? 110 : 150),
              const ColonneTableau('', largeur: 40),
            ],
            lignes: [
              for (final p in liste)
                [
                  Initiales('${p['nom_complet']}', taille: telephone ? 32 : 36),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${p['nom_complet']}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    if (telephone)
                      Text(libelles(p), overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris))
                    else if (p['telephone'] != null)
                      Text('${p['telephone']}', style: TextStyle(fontSize: 12, color: gris)),
                  ]),
                  if (!telephone) Text(libelles(p), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                  if (largeur >= 1024) Text('${p['site'] ?? 'Tout le groupe'}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                  p['statut'] == 'sorti'
                      ? const Etat('Parti')
                      : (p['user_id'] != null ? const Etat("Utilise l'app", ton: Ton.regle) : const Etat('Sans accès')),
                  Icon(Icons.chevron_right, size: 16, color: gris),
                ],
            ],
            onTap: (i) => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => FicheScreen(espace: widget.espace, ficheId: liste[i]['id'] as String))),
          ),
        ]),
      ),
    );
  }
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
      for (final t in titres.entries)
        if (espace.fondateur || !fonctionsDeDirection.contains(t.value.fonction)) t.key: nomTitre(t.key),
    };
    var cle = 'enseignant';
    String? site = sites.containsKey(fiche['site_id']) ? fiche['site_id'] as String? : sites.keys.first;
    final libelle = TextEditingController();
    final ok = await _formulaire(context, 'Ajouter une fonction', (maj) => [
          _liste('Fonction', cle, choix, (v) => maj(() => cle = v)),
          if (cle == 'autre') TextField(controller: libelle, decoration: _champ('Précisez')),
          const Text('Elle s\'ajoute aux fonctions actuelles : les droits s\'additionnent.', style: TextStyle(fontSize: 12)),
          if (sites.length > 1) _liste('Sur', site, sites, (v) => maj(() => site = v)),
        ]);
    if (!ok) return;
    final fonction = titres[cle]!.fonction;
    final titre = cle == 'autre' ? (libelle.text.trim().length >= 2 ? libelle.text.trim() : null) : titres[cle]!.libelle;
    // Une fonction retirée puis redonnée : on réactive la ligne existante.
    final existante = await db.getOptional(
        'SELECT id FROM affectations WHERE personnel_id = ? AND fonction = ? AND site_id IS ? AND libelle IS ?',
        [ficheId, fonction, site, titre]);
    if (existante != null) {
      await _modifier('affectations', existante['id'] as String, {'actif': 1});
    } else {
      await _inserer('affectations', {
        'organisation_id': espace.orgId,
        'personnel_id': ficheId,
        'site_id': site,
        'fonction': fonction,
        'libelle': titre,
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
    // Avec un numéro : le serveur peut envoyer le code par SMS directement.
    var parSms = false;
    if (fiche['telephone'] != null) {
      final choix = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Inviter ${fiche['nom_complet']}'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Text("ScolaGrid peut envoyer le code d'invitation par SMS au ${fiche['telephone']}, avec le lien de "
                "l'application. Ou bien affichez le code pour le transmettre vous-même."),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
            OutlinedButton(onPressed: () => Navigator.pop(context, 'code'), child: const Text('Afficher le code')),
            FilledButton.icon(
                onPressed: () => Navigator.pop(context, 'sms'), icon: const Icon(Icons.sms_outlined, size: 18), label: const Text('Envoyer par SMS')),
          ],
        ),
      );
      if (choix == null) return;
      parSms = choix == 'sms';
    }
    String code;
    try {
      code = parSms ? await envoyerInvitationSms(ficheId) : await inviterPersonnel(ficheId);
    } on PostgrestException catch (e) {
      messager.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } catch (_) {
      messager.showSnackBar(const SnackBar(content: Text('Il faut internet pour créer une invitation.')));
      return;
    }
    if (!context.mounted) return;
    if (parSms) {
      messager.showSnackBar(SnackBar(
          duration: const Duration(seconds: 8),
          content: Text('Invitation envoyée par SMS au ${fiche['telephone']} (code ${codeLisible(code)}, valable 7 jours).')));
      return;
    }
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
                          leading: Icon(Icons.verified_user_outlined, color: Couleurs.regle),
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
                if (!actives.any((a) => a['fonction'] == 'fondateur')) ...[
                  const SizedBox(height: 12),
                  _PagesVisibles(ficheId: ficheId, modifiable: espace.fondateur, changer: _changerDroit),
                ],
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

/// Pages de l'app que la personne voit dans son menu. Le fondateur peut en
/// masquer « pour le moment », sans toucher à ses droits ; une page qu'elle
/// n'a pas le droit d'ouvrir reste de toute façon absente.
class _PagesVisibles extends StatelessWidget {
  const _PagesVisibles({required this.ficheId, required this.modifiable, required this.changer});

  final String ficheId;
  final bool modifiable;
  final Future<void> Function(String droit, bool parDefaut, bool voulu, String? exceptionId) changer;

  @override
  Widget build(BuildContext context) => Requete(
        "SELECT * FROM droits_personnel WHERE personnel_id = ? AND site_id IS NULL AND droit LIKE 'masquer_%'",
        parametres: [ficheId],
        builder: (context, l) {
          final masquees = {for (final e in l) (e['droit'] as String).substring('masquer_'.length): e};
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pages visibles', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(modifiable
                ? 'Décochez une page pour la cacher de son menu, quels que soient ses droits. Vous pourrez la rendre à tout moment.'
                : 'Pages que le fondateur lui laisse voir.'),
            Card(
              child: Column(children: [
                for (final p in pagesMasquables.entries)
                  SwitchListTile(
                    dense: true,
                    title: Text(p.value),
                    subtitle: masquees[p.key]?['accorde'] == 1 ? const Text('Masquée par le fondateur') : null,
                    value: masquees[p.key]?['accorde'] != 1,
                    // « masquer » accordé = page cachée ; le retour à « visible » supprime l'exception.
                    onChanged: modifiable
                        ? (visible) => changer('masquer_${p.key}', false, !visible, masquees[p.key]?['id'] as String?)
                        : null,
                  ),
              ]),
            ),
          ]);
        },
      );
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
