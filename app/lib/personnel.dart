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

/// Comme Élèves et Familles : la liste, ses filtres, et la fiche dans un panneau à
/// droite (grand écran), un tiroir (tablette) ou une page (téléphone).
class _ListePersonnelState extends State<_ListePersonnel> {
  final _q = TextEditingController();
  String? _fonction;
  String? _statut;
  String? _site;
  String? _ouvert;

  void _ouvrir(String id) {
    final largeur = MediaQuery.sizeOf(context).width;
    if (largeur >= 1280) {
      setState(() => _ouvert = id);
    } else if (largeur < 640) {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (route) => Scaffold(
                body: SafeArea(child: FichePersonnel(espace: widget.espace, ficheId: id, onFermer: () => Navigator.of(route).pop())),
              )));
    } else {
      setState(() => _ouvert = id);
      showGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Fermer',
        barrierColor: Colors.black26,
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (dialogue, _, _) => Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Theme.of(dialogue).colorScheme.surface,
            elevation: 8,
            child: SizedBox(
              width: largeur < 600 ? largeur : 576,
              height: double.infinity,
              child: SafeArea(child: FichePersonnel(espace: widget.espace, ficheId: id, onFermer: () => Navigator.of(dialogue).pop())),
            ),
          ),
        ),
        transitionBuilder: (_, animation, _, enfant) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: enfant,
        ),
      ).then((_) {
        if (mounted) setState(() => _ouvert = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final largeur = MediaQuery.sizeOf(context).width;
    final telephone = largeur < 640;
    final panneau = largeur >= 1280 && _ouvert != null;
    String libelles(Map<String, Object?> p) =>
        (p['fonctions'] as String? ?? '').split(', ').where((f) => f.isNotEmpty).map((f) => fonctions[f] ?? f).join(', ');
    final q = nomSimplifie(_q.text);
    final liste = widget.personnes.where((p) {
      if (_fonction != null && !'${p['fonctions'] ?? ''}'.split(', ').contains(_fonction)) return false;
      if (_statut != null && p['statut'] != _statut) return false;
      if (_site != null && '${p['site_id'] ?? ''}' != _site) return false;
      return q.isEmpty || nomSimplifie('${p['nom_complet']} ${p['telephone'] ?? ''} ${libelles(p)}').contains(q);
    }).toList();
    final enPoste = widget.personnes.where((p) => p['statut'] != 'sorti').length;
    final utilisent = widget.personnes.where((p) => p['user_id'] != null && p['statut'] == 'actif').length;
    final presentes = <String>{
      for (final p in widget.personnes) ...'${p['fonctions'] ?? ''}'.split(', ').where((f) => f.isNotEmpty),
    };
    final sites = <String, String>{
      for (final p in widget.personnes) '${p['site_id'] ?? ''}': '${p['site'] ?? 'Tout le groupe'}',
    };
    final nbFiltres = [_fonction, _statut, _site].where((x) => x != null).length;
    void reinitialiser() => setState(() {
          _fonction = null;
          _statut = null;
          _site = null;
          _q.clear();
        });
    List<Widget> menus(double largeurMenu, VoidCallback rafraichir) => [
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
          MenuCompact<String>(
            largeur: largeurMenu,
            valeur: _statut,
            tous: 'Tous les statuts',
            choix: statutsPersonnel,
            onChanged: (v) {
              setState(() => _statut = v);
              rafraichir();
            },
          ),
          if (sites.length > 1)
            MenuCompact<String>(
              largeur: largeurMenu,
              valeur: _site,
              tous: 'Tous les sites',
              choix: sites,
              onChanged: (v) {
                setState(() => _site = v);
                rafraichir();
              },
            ),
        ];

    final contenuListe = ListView(children: [
      EnTetePage(
        titre: 'Personnel',
        sousTitre: "$enPoste personne(s) en poste · $utilisent utilise(nt) l'app",
        actions: [
          if (widget.espace.gestionnaire)
            FilledButton.icon(onPressed: widget.ajouter, icon: const Icon(Icons.person_add_alt, size: 16), label: const Text('Ajouter une personne')),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: telephone ? largeur - 24 - 52 : 340,
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
          BoutonFiltres(actifs: nbFiltres, reinitialiser: reinitialiser, menus: menus)
        else
          ...menus(180, () {}),
        if (!telephone && (nbFiltres > 0 || _q.text.isNotEmpty))
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: gris, minimumSize: const Size(36, 36)),
            onPressed: reinitialiser,
            icon: const Icon(Icons.close, size: 14),
            label: const Text('Réinitialiser', style: TextStyle(fontSize: 14)),
          ),
      ]),
      const SizedBox(height: 12),
      Tableau(
        vide: widget.personnes.isEmpty ? 'Aucune fiche pour le moment.' : 'Personne ne correspond.',
        colonnes: [
          ColonneTableau('', largeur: telephone ? 56 : 72),
          const ColonneTableau('Nom', flex: 3),
          if (!telephone && !panneau) const ColonneTableau('Fonction', flex: 3),
          if (largeur >= 1024 && !panneau) const ColonneTableau('Site', largeur: 160),
          ColonneTableau('État', largeur: telephone ? 110 : 140),
          const ColonneTableau('', largeur: 40),
        ],
        lignes: [
          for (final p in liste)
            [
              Initiales('${p['nom_complet']}', taille: telephone ? 40 : 56),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p['nom_complet']}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: p['id'] == _ouvert ? FontWeight.w700 : FontWeight.w500)),
                if (telephone || panneau)
                  Text(libelles(p), overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris))
                else if (p['telephone'] != null)
                  Text('${p['telephone']}', style: TextStyle(fontSize: 12, color: gris)),
              ]),
              if (!telephone && !panneau) Text(libelles(p), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
              if (largeur >= 1024 && !panneau)
                Text('${p['site'] ?? 'Tout le groupe'}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
              etatPersonnel(p),
              Icon(Icons.chevron_right, size: 16, color: gris),
            ],
        ],
        onTap: (i) => _ouvrir(liste[i]['id'] as String),
      ),
      const SizedBox(height: 8),
      Text("Tout le personnel a une fiche, même sans utiliser Scolagrid. Invitez ceux qui utiliseront l'app.",
          style: TextStyle(fontSize: 12, color: gris)),
    ]);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: Padding(
          padding: EdgeInsets.all(telephone ? 12 : 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: contenuListe),
            if (panneau) ...[
              const SizedBox(width: 16),
              _PanneauLateral(
                key: const ValueKey('panneau-personnel'),
                child: FichePersonnel(
                  key: ValueKey(_ouvert),
                  espace: widget.espace,
                  ficheId: _ouvert!,
                  onFermer: () => setState(() => _ouvert = null),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// L'état d'une personne en une pastille : parti, en congé, suspendu, utilise l'app, sans accès.
Widget etatPersonnel(Map<String, Object?> p) => switch (p['statut']) {
      'sorti' => const Etat('Parti'),
      'conge' => const Etat('En congé', ton: Ton.attente),
      'suspendu' => const Etat('Suspendu', ton: Ton.retard),
      _ => p['user_id'] != null ? const Etat("Utilise l'app", ton: Ton.regle) : const Etat('Sans accès'),
    };

// Fiche d'une personne --------------------------------------------------------

/// La fiche, comme celle d'un élève : en-tête (initiales, nom, état, appeler),
/// onglets Dossier · Fonctions et droits · Enseignements · Paie, actions en bas.
class FichePersonnel extends StatelessWidget {
  const FichePersonnel({super.key, required this.espace, required this.ficheId, required this.onFermer});

  final Espace espace;
  final String ficheId;
  final VoidCallback onFermer;

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
  Widget build(BuildContext context) => Requete(
        'SELECT p.*, s.nom AS site FROM personnel p LEFT JOIN sites s ON s.id = p.site_id WHERE p.id = ?',
        parametres: [ficheId],
        builder: (context, l) {
          if (l.isEmpty) return const Center(child: Text('Fiche introuvable sur ce poste.'));
          final fiche = l.first;
          return Requete(
            'SELECT a.*, s.nom AS site FROM affectations a LEFT JOIN sites s ON s.id = a.site_id '
            'WHERE a.personnel_id = ? ORDER BY a.actif DESC, a.created_at',
            parametres: [ficheId],
            builder: (context, affectations) {
              final actives = [for (final a in affectations) if (a['actif'] == 1) a];
              final gere = _peutGerer(fiche, actives);
              final enseignant = actives.any((a) => a['fonction'] == 'enseignant');
              final paie = gerePaie(espace);
              final onglets = ['Dossier', 'Fonctions et droits', if (enseignant) 'Enseignements', if (paie) 'Paie'];
              return DefaultTabController(
                key: ValueKey(onglets.length),
                length: onglets.length,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _entete(context, fiche, actives),
                  const SizedBox(height: 12),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _OngletsFiche(onglets)),
                  Expanded(
                    child: TabBarView(children: [
                      _ongletDossier(context, fiche, actives, gere),
                      _ongletFonctions(context, fiche, actives, gere),
                      if (enseignant)
                        ListView(padding: const EdgeInsets.all(16), children: [
                          EnseignementsFiche(
                              espace: espace, fiche: fiche, peutModifier: (gere || espace.gereMatieres) && fiche['statut'] == 'actif'),
                        ]),
                      if (paie) _onglePaie(context, fiche),
                    ]),
                  ),
                  if (gere) _pied(context, fiche, actives),
                ]),
              );
            },
          );
        },
      );

  Widget _entete(BuildContext context, Map<String, Object?> fiche, Lignes actives) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final telephone = MediaQuery.sizeOf(context).width < 640;
    final tel = fiche['telephone'] as String?;
    final libelles = actives.map((a) => '${a['libelle'] ?? fonctions[a['fonction']] ?? a['fonction']}').toSet().join(', ');
    final details = [
      '${fiche['site'] ?? 'Tout le groupe'}',
      if (fiche['statut'] != 'actif' && fiche['statut_depuis'] != null) 'depuis le ${_dateLisible(fiche['statut_depuis'])}',
      if (fiche['statut'] != 'actif' && fiche['statut_jusqu_au'] != null) "jusqu'au ${_dateLisible(fiche['statut_jusqu_au'])}",
      if (fiche['statut'] == 'sorti' && fiche['motif_depart'] != null) motifsDepart[fiche['motif_depart']] ?? '',
    ];
    return Container(
      padding: EdgeInsets.all(telephone ? 12 : 16),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Initiales('${fiche['nom_complet']}', taille: telephone ? 56 : 64),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${fiche['nom_complet']}', style: TextStyle(fontSize: telephone ? 16 : 18, fontWeight: FontWeight.w600)),
              etatPersonnel(fiche),
            ]),
            const SizedBox(height: 4),
            Text(libelles.isEmpty ? 'Aucune fonction' : libelles, style: TextStyle(fontSize: 14, color: gris)),
            Text(details.where((d) => d.isNotEmpty).join(' · '), style: TextStyle(fontSize: 13, color: gris)),
            if (tel != null) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                OutlinedButton.icon(onPressed: () => _appeler(tel), icon: const Icon(Icons.call_outlined, size: 15), label: Text(tel)),
                OutlinedButton.icon(
                    onPressed: () => _appeler(tel, whatsapp: true), icon: const Icon(Icons.chat_outlined, size: 15), label: const Text('WhatsApp')),
              ]),
            ],
          ]),
        ),
        IconButton(tooltip: 'Fermer', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 18), onPressed: onFermer),
      ]),
    );
  }

  Widget _ongletDossier(BuildContext context, Map<String, Object?> fiche, Lignes actives, bool gere) {
    String? v(String c) => fiche[c] == null || '${fiche[c]}'.isEmpty ? null : '${fiche[c]}';
    return ListView(padding: const EdgeInsets.all(16), children: [
      _rubrique(context, 'Identité et contact'),
      const SizedBox(height: 12),
      _deuxColonnes([
        _ChampLu('Prénom(s)', v('prenoms')),
        _ChampLu('Nom', v('nom')),
        _ChampLu('Sexe', switch (fiche['sexe']) { 'M' => 'Homme', 'F' => 'Femme', _ => null }),
        _ChampLu('Date de naissance', v('date_naissance') == null ? null : _dateLisible(v('date_naissance'))),
        _ChampLu('Lieu de naissance', v('lieu_naissance')),
        _ChampLu('Nationalité', v('nationalite')),
        _ChampLu("Pièce d'identité", v('piece_identite'), mono: true),
        _ChampLu('Téléphone', v('telephone'), mono: true),
        _ChampLu('2e téléphone', v('telephone2'), mono: true),
        _ChampLu('Adresse', v('adresse')),
        _ChampLu('Personne à prévenir', v('contact_urgence')),
        _ChampLu('Site', '${fiche['site'] ?? 'Tout le groupe'}'),
      ]),
      const SizedBox(height: 24),
      _rubrique(context, 'Emploi'),
      const SizedBox(height: 12),
      _deuxColonnes([
        _ChampLu("Date d'embauche", v('date_embauche') == null ? null : _dateLisible(v('date_embauche'))),
        _ChampLu('Contrat', contratsPersonnel[fiche['contrat']]),
        _ChampLu('Diplôme', v('diplome')),
        _ChampLu('Statut', statutsPersonnel[fiche['statut']] ?? '${fiche['statut']}'),
      ]),
      const SizedBox(height: 24),
      _rubrique(context, "Accès à l'app"),
      const SizedBox(height: 4),
      fiche['user_id'] != null
          ? const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.verified_user_outlined, color: Couleurs.regle),
              title: Text("Utilise l'app"),
              subtitle: Text('Son compte est relié à cette fiche.'),
            )
          : ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_add_alt_outlined),
              title: const Text("N'utilise pas l'app"),
              subtitle: const Text('Invitez-la si elle doit utiliser Scolagrid (internet nécessaire).'),
              trailing: gere && actives.isNotEmpty && fiche['statut'] == 'actif'
                  ? FilledButton(onPressed: () => _inviter(context, fiche), child: const Text('Inviter'))
                  : null,
            ),
    ]);
  }

  Widget _ongletFonctions(BuildContext context, Map<String, Object?> fiche, Lignes actives, bool gere) {
    final modifiable = gere && fiche['statut'] == 'actif';
    final fondateur = actives.any((a) => a['fonction'] == 'fondateur');
    return ListView(padding: const EdgeInsets.all(16), children: [
      _rubrique(context, 'Fonctions',
          droite: modifiable
              ? TextButton.icon(onPressed: () => _ajouterFonction(context, fiche), icon: const Icon(Icons.add, size: 16), label: const Text('Ajouter'))
              : null),
      const SizedBox(height: 4),
      if (actives.isEmpty) const Text('Aucune fonction.'),
      for (final a in actives)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.work_outline),
          title: Text('${a['libelle'] ?? fonctions[a['fonction']] ?? a['fonction']}'),
          subtitle: Text('${a['site'] ?? 'Tous les sites'}'),
          trailing: modifiable && a['fonction'] != 'fondateur'
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
      const SizedBox(height: 16),
      _Droits(
        ficheId: ficheId,
        fonctionsActives: actives.map((a) => a['fonction'] as String),
        modifiable: espace.fondateur && !fondateur,
        changer: _changerDroit,
      ),
      if (!fondateur) ...[
        const SizedBox(height: 16),
        _PagesVisibles(ficheId: ficheId, modifiable: espace.fondateur, changer: _changerDroit),
      ],
    ]);
  }

  Widget _onglePaie(BuildContext context, Map<String, Object?> fiche) => ListView(padding: const EdgeInsets.all(16), children: [
        RemunerationFiche(espace: espace, fiche: fiche),
        const SizedBox(height: 20),
        _rubrique(context, 'Dernières paies'),
        const SizedBox(height: 4),
        Requete(
          'SELECT l.net_gnf, l.versee_le, l.versement_mode, p.mois, p.statut FROM lignes_paie l JOIN paies p ON p.id = l.paie_id '
          'WHERE l.personnel_id = ? ORDER BY p.mois DESC LIMIT 6',
          parametres: [ficheId],
          builder: (context, paies) => paies.isEmpty
              ? Text('Aucune paie pour le moment.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))
              : Column(children: [
                  for (final x in paies)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(() {
                        final d = DateTime.tryParse('${x['mois']}');
                        return d == null ? '' : '${_moisNoms[d.month - 1]} ${d.year}';
                      }()),
                      subtitle: Text(x['versee_le'] != null
                          ? 'Versée le ${_dateLisible(x['versee_le'])}'
                          : (x['statut'] == 'validee' ? 'Validée, à verser' : 'En préparation')),
                      trailing: Text(gnf(x['net_gnf']), style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                ]),
        ),
      ]);

  /// En bas, comme la fiche élève : Modifier, puis les autres gestes.
  Widget _pied(BuildContext context, Map<String, Object?> fiche, Lignes actives) {
    final fondateur = actives.any((a) => a['fonction'] == 'fondateur');
    final gestes = <(String, IconData, VoidCallback)>[
      if (!fondateur) ('Changer le statut', Icons.swap_horiz, () => changerStatut(context, espace, fiche)),
      if (fiche['statut'] == 'actif') ('Ajouter une fonction', Icons.work_outline, () => _ajouterFonction(context, fiche)),
      if (fiche['user_id'] == null && actives.isNotEmpty && fiche['statut'] == 'actif')
        ('Inviter', Icons.person_add_alt_outlined, () => _inviter(context, fiche)),
    ];
    final decoration =
        BoxDecoration(color: Theme.of(context).colorScheme.surface, border: Border(top: BorderSide(color: Theme.of(context).dividerColor)));
    final modifier = FilledButton.icon(
      onPressed: () => modifierDossier(context, fiche),
      icon: const Icon(Icons.edit_outlined, size: 15),
      label: const Text('Modifier'),
    );
    if (MediaQuery.sizeOf(context).width < 640 || gestes.length > 2) {
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: decoration,
        child: Row(children: [
          Expanded(child: modifier),
          if (gestes.isNotEmpty) ...[
            const SizedBox(width: 4),
            PopupMenuButton<int>(
              tooltip: 'Autres actions',
              icon: const Icon(Icons.more_horiz),
              onSelected: (i) => gestes[i].$3(),
              itemBuilder: (_) => [
                for (var i = 0; i < gestes.length; i++)
                  PopupMenuItem(value: i, child: Row(children: [Icon(gestes[i].$2, size: 18), const SizedBox(width: 10), Text(gestes[i].$1)])),
              ],
            ),
          ],
        ]),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: decoration,
      child: Row(children: [
        Expanded(child: modifier),
        for (final g in gestes) ...[
          const SizedBox(width: 8),
          OutlinedButton.icon(onPressed: g.$3, icon: Icon(g.$2, size: 15), label: Text(g.$1)),
        ],
      ]),
    );
  }
}

/// Onglets en « pilule », comme la fiche élève.
class _OngletsFiche extends StatelessWidget {
  const _OngletsFiche(this.onglets);

  final List<String> onglets;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        height: 36,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: Couleurs.doux(context), borderRadius: BorderRadius.circular(8)),
        child: TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerHeight: 0,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(
            color: schema.surface,
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 2, offset: Offset(0, 1))],
          ),
          labelColor: schema.onSurface,
          unselectedLabelColor: schema.onSurfaceVariant,
          labelStyle: const TextStyle(fontFamily: policeTexte, fontSize: 14, fontWeight: FontWeight.w500),
          unselectedLabelStyle: const TextStyle(fontFamily: policeTexte, fontSize: 14, fontWeight: FontWeight.w400),
          labelPadding: const EdgeInsets.symmetric(horizontal: 10),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          tabs: [for (final o in onglets) Tab(height: 30, text: o)],
        ),
      ),
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
