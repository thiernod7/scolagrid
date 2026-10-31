part of 'configuration.dart';

/// Étape 4 de l'onboarding : activer les postes de travail.
/// L'activation (en ligne, une fois) donne au poste son code (A, B, C…) : il
/// fabriquera seul, hors ligne, des numéros uniques (matricules, reçus).
/// Le code PIN, propre à ce poste, rouvre l'app sans réseau.

const versionApp = '0.4.0';

/// Ce poste, tel qu'enregistré localement (table locale, jamais synchronisée).
Future<Map<String, Object?>?> cePoste() => db.getOptional('SELECT * FROM ce_poste LIMIT 1');

// Code PIN --------------------------------------------------------------------

/// Empreinte du PIN : salée et répétée, pour qu'on ne puisse pas le retrouver
/// en lisant la base du poste.
String empreintePin(String pin, String sel) {
  List<int> h = utf8.encode('$sel:$pin');
  for (var i = 0; i < 20000; i++) {
    h = sha256.convert(h).bytes;
  }
  return base64Url.encode(h);
}

String _nouveauSel() {
  final r = Random.secure();
  return base64Url.encode(List.generate(16, (_) => r.nextInt(256)));
}

bool pinValide(String pin) => RegExp(r'^[0-9]{4,6}$').hasMatch(pin);

// Activation ------------------------------------------------------------------

class ActiverPosteScreen extends StatefulWidget {
  const ActiverPosteScreen({super.key, required this.orgId});

  final String orgId;

  @override
  State<ActiverPosteScreen> createState() => _ActiverPosteScreenState();
}

class _ActiverPosteScreenState extends State<ActiverPosteScreen> {
  final _nom = TextEditingController(text: switch (defaultTargetPlatform) {
    _ when kIsWeb => 'Navigateur',
    TargetPlatform.android || TargetPlatform.iOS => 'Téléphone',
    _ => 'PC',
  });
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  Map<String?, String> _sites = {};
  String? _site;
  bool _envoi = false;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _chargerSites();
  }

  /// Sites où je travaille ; « tout le groupe » pour le fondateur.
  Future<void> _chargerSites() async {
    final mes = await db.getAll('SELECT site_id, role FROM rattachements WHERE user_id = ? AND organisation_id = ? AND actif = 1',
        [monId, widget.orgId]);
    final tous = mes.any((r) => r['site_id'] == null);
    final sites = await db.getAll('SELECT id, nom FROM sites WHERE organisation_id = ? ORDER BY created_at', [widget.orgId]);
    setState(() {
      _sites = {
        for (final s in sites)
          if (tous || mes.any((r) => r['site_id'] == s['id'])) s['id'] as String: s['nom'] as String,
        if (mes.any((r) => r['role'] == 'fondateur')) null: 'Tout le groupe (poste du fondateur)',
      };
      _site = _sites.keys.isEmpty ? null : _sites.keys.first;
    });
  }

  Future<void> _activer() async {
    if (_nom.text.trim().length < 2) {
      setState(() => _erreur = 'Donnez un nom au poste.');
      return;
    }
    if (!pinValide(_pin.text)) {
      setState(() => _erreur = 'Le code PIN a 4 à 6 chiffres.');
      return;
    }
    if (_pin.text != _pin2.text) {
      setState(() => _erreur = 'Les deux codes PIN sont différents.');
      return;
    }
    setState(() {
      _envoi = true;
      _erreur = null;
    });
    try {
      final poste = await activerPoste(
        organisation: widget.orgId,
        site: _site,
        nom: _nom.text.trim(),
        plateforme: kIsWeb ? 'web' : defaultTargetPlatform.name,
        version: versionApp,
      );
      final sel = _nouveauSel();
      await db.execute('DELETE FROM ce_poste');
      await db.execute(
          'INSERT INTO ce_poste (id, poste_id, organisation_id, code, nom, pin_empreinte, pin_sel, echecs) '
          'VALUES (uuid(), ?, ?, ?, ?, ?, ?, 0)',
          [poste.id, widget.orgId, poste.code, _nom.text.trim(), empreintePin(_pin.text, sel), sel]);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Poste ${poste.code} activé'),
          content: Text('Ce poste porte la lettre ${poste.code} : elle apparaîtra dans les matricules '
              'et les numéros de reçu créés ici.\n\nRetenez votre code PIN : il rouvre l\'app, même sans internet.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Compris'))],
        ),
      );
      if (mounted) Navigator.pop(context);
    } on PostgrestException catch (e) {
      setState(() => _erreur = e.message);
    } catch (_) {
      setState(() => _erreur = "Il faut internet pour activer le poste. Réessayez une fois connecté.");
    } finally {
      if (mounted) setState(() => _envoi = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Page(
        titre: 'Activer ce poste',
        corps: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('À faire une fois sur chaque appareil, avec internet. '
              'Le poste reçoit une lettre (A, B, C…) qui rend ses numéros uniques, même hors ligne.'),
          const SizedBox(height: 20),
          TextField(controller: _nom, decoration: _champ('Nom du poste', aide: 'Par exemple : PC du secrétariat')),
          const SizedBox(height: 14),
          if (_sites.length > 1) ...[
            _liste('Site', _site, _sites, (v) => setState(() => _site = v)),
            const SizedBox(height: 14),
          ],
          TextField(
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: _champ('Code PIN (4 à 6 chiffres)', aide: "Pour rouvrir l'app sur ce poste")),
          const SizedBox(height: 8),
          TextField(
              controller: _pin2,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: _champ('Confirmer le code PIN')),
          if (_erreur != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_erreur!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _envoi || _sites.isEmpty ? null : _activer,
            child: Text(_envoi ? 'Activation…' : 'Activer ce poste'),
          ),
        ]),
      );
}

// Ouverture de l'app : code PIN -----------------------------------------------

/// Si ce poste a un code PIN, on le demande avant d'ouvrir l'accueil.
class PorteDuPoste extends StatelessWidget {
  const PorteDuPoste({super.key, required this.accueil, required this.sortie});

  final Widget accueil;

  /// Écran affiché si la personne choisit de se déconnecter (PIN oublié).
  final Widget sortie;

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: cePoste(),
        builder: (context, s) {
          if (s.connectionState != ConnectionState.done) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          final poste = s.data;
          if (poste == null || poste['pin_empreinte'] == null) return accueil;
          return _PinScreen(poste: poste, accueil: accueil, sortie: sortie);
        },
      );
}

class _PinScreen extends StatefulWidget {
  const _PinScreen({required this.poste, required this.accueil, required this.sortie});

  final Map<String, Object?> poste;
  final Widget accueil;
  final Widget sortie;

  @override
  State<_PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<_PinScreen> {
  final _pin = TextEditingController();
  String? _erreur;

  static const _essaisAvantAttente = 5;

  Future<void> _valider() async {
    final p = await cePoste();
    if (p == null) return;
    final attendre = DateTime.tryParse('${p['attendre_jusqu']}');
    if (attendre != null && DateTime.now().isBefore(attendre)) {
      final min = attendre.difference(DateTime.now()).inMinutes + 1;
      setState(() => _erreur = 'Trop d\'essais. Réessayez dans $min min.');
      return;
    }
    if (empreintePin(_pin.text, p['pin_sel'] as String) == p['pin_empreinte']) {
      await db.execute('UPDATE ce_poste SET echecs = 0, attendre_jusqu = NULL');
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => widget.accueil));
      return;
    }
    final echecs = ((p['echecs'] as int?) ?? 0) + 1;
    final bloque = echecs % _essaisAvantAttente == 0;
    await db.execute('UPDATE ce_poste SET echecs = ?, attendre_jusqu = ?', [
      echecs,
      bloque ? DateTime.now().add(Duration(minutes: 5 * (echecs ~/ _essaisAvantAttente))).toIso8601String() : null,
    ]);
    _pin.clear();
    setState(() => _erreur = bloque ? 'Trop d\'essais. Patientez quelques minutes.' : 'Code PIN incorrect.');
  }

  Future<void> _oublie() async {
    final enAttente = (await db.getUploadQueueStats()).count;
    if (!mounted) return;
    final ok = await _confirmer(
        context,
        'Pour choisir un nouveau code, il faut vous reconnecter par SMS (avec internet). '
        'Les données de ce poste seront effacées${enAttente > 0 ? ', dont $enAttente changement(s) pas encore envoyé(s)' : ''}. '
        'Le poste devra être activé de nouveau.');
    if (!ok) return;
    await deconnecter(db);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => widget.sortie), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
            Icon(Icons.lock_outline, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text('Poste ${widget.poste['code']}', style: texte.headlineSmall, textAlign: TextAlign.center),
            Text('${widget.poste['nom']}', style: texte.bodyMedium, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            TextField(
              controller: _pin,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: texte.headlineSmall?.copyWith(letterSpacing: 8),
              decoration: InputDecoration(labelText: 'Code PIN', errorText: _erreur, border: const OutlineInputBorder()),
              onSubmitted: (_) => _valider(),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _valider, child: const Text('Ouvrir')),
            const SizedBox(height: 8),
            TextButton(onPressed: _oublie, child: const Text('Code PIN oublié')),
          ]),
        ),
      ),
    );
  }
}

// Liste des postes ------------------------------------------------------------

String _depuis(Object? iso) {
  final d = DateTime.tryParse('$iso');
  if (d == null) return 'jamais synchronisé';
  final e = DateTime.now().difference(d.toLocal());
  if (e.inMinutes < 60) return 'synchronisé il y a ${e.inMinutes} min';
  if (e.inHours < 24) return 'synchronisé il y a ${e.inHours} h';
  return 'synchronisé il y a ${e.inDays} j';
}

class PostesScreen extends StatelessWidget {
  const PostesScreen({super.key, required this.espace});

  final Espace espace;

  bool _gere(Map<String, Object?> p) =>
      p['site_id'] == null ? espace.fondateur : espace.gereSite(p['site_id'] as String);

  @override
  Widget build(BuildContext context) => _Page(
        titre: "Postes de l'école",
        corps: Requete(
            '''SELECT p.*, s.nom AS site, pe.nom_complet AS par,
                 p.id = (SELECT poste_id FROM ce_poste) AS celui_ci
               FROM postes p
               LEFT JOIN sites s ON s.id = p.site_id
               LEFT JOIN personnel pe ON pe.user_id = p.user_id AND pe.organisation_id = p.organisation_id
               WHERE p.organisation_id = ?
               ORDER BY p.numero''',
            parametres: [espace.orgId], builder: (context, postes) {
          if (postes.isEmpty) return _vide('Aucun poste activé pour le moment.');
          return ListView(padding: const EdgeInsets.all(16), children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Un poste perdu ou volé ? Bloquez-le : à sa prochaine connexion, '
                  'il efface ses données. Sa lettre ne sera jamais réutilisée.'),
            ),
            for (final p in postes)
              Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: p['statut'] == 'bloque' ? Theme.of(context).colorScheme.errorContainer : null,
                    child: Text('${p['code']}'),
                  ),
                  title: Text('${p['nom']}${p['celui_ci'] == 1 ? ' (ce poste)' : ''}'),
                  subtitle: Text([
                    p['site'] ?? 'Tout le groupe',
                    if (p['par'] != null) 'activé par ${p['par']}',
                    p['statut'] == 'bloque' ? 'BLOQUÉ' : _depuis(p['derniere_synchro']),
                  ].join(' · ')),
                  trailing: _gere(p)
                      ? TextButton(
                          onPressed: () async {
                            final bloquer = p['statut'] != 'bloque';
                            if (await _confirmer(
                                context,
                                bloquer
                                    ? 'Bloquer le poste ${p['code']} (${p['nom']}) ? Il effacera ses données à sa prochaine connexion.'
                                    : 'Débloquer le poste ${p['code']} ?')) {
                              await _modifier('postes', p['id'] as String, {'statut': bloquer ? 'bloque' : 'actif'});
                            }
                          },
                          child: Text(p['statut'] == 'bloque' ? 'Débloquer' : 'Bloquer'),
                        )
                      : null,
                ),
              ),
          ]);
        }),
      );
}
