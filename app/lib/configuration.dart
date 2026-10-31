import 'dart:convert' show base64Url, utf8;
import 'dart:math' show Random;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'base.dart';
import 'cloud.dart';
import 'echeancier.dart';
import 'fonctions.dart';
import 'modele_guineen.dart';

part 'frais.dart';
part 'identite.dart';
part 'personnel.dart';
part 'poste.dart';

/// Étape 2 de l'onboarding : configurer l'établissement.
/// Tout s'écrit dans la base locale, donc fonctionne hors ligne ;
/// le serveur vérifie les droits à la synchronisation.

/// Qui configure, et sur quel périmètre.
class Espace {
  const Espace({required this.orgId, required this.ville, required this.role, this.siteId});

  final String orgId;
  final String ville;
  final String role;
  final String? siteId; // vide = tous les sites

  bool get fondateur => role == 'fondateur';
  bool get gestionnaire => fondateur || role == 'directeur';
  bool gereSite(String site) => fondateur || (role == 'directeur' && (siteId == null || siteId == site));
}

// Écriture locale -------------------------------------------------------------

String _maintenant() => DateTime.now().toUtc().toIso8601String();

Future<void> _inserer(String table, Map<String, Object?> valeurs) {
  final donnees = {...valeurs, 'created_at': _maintenant(), 'updated_at': _maintenant()};
  final colonnes = donnees.keys.join(', ');
  final marques = List.filled(donnees.length, '?').join(', ');
  return db.execute('INSERT INTO $table (id, $colonnes) VALUES (uuid(), $marques)', donnees.values.toList());
}

Future<void> _modifier(String table, String id, Map<String, Object?> valeurs) {
  final donnees = {...valeurs, 'updated_at': _maintenant()};
  final affectations = donnees.keys.map((c) => '$c = ?').join(', ');
  return db.execute('UPDATE $table SET $affectations WHERE id = ?', [...donnees.values, id]);
}

Future<void> _supprimer(String table, String id) => db.execute('DELETE FROM $table WHERE id = ?', [id]);

String gnf(Object? montant) {
  final s = '${montant ?? 0}';
  final groupes = <String>[];
  for (var i = s.length; i > 0; i -= 3) {
    groupes.insert(0, s.substring(i - 3 < 0 ? 0 : i - 3, i));
  }
  return '${groupes.join(' ')} GNF';
}

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _dateLisible(Object? iso) {
  final d = DateTime.tryParse('$iso');
  return d == null ? '' : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

// Lecture locale réactive -----------------------------------------------------

typedef Lignes = List<Map<String, Object?>>;

/// Affiche le résultat d'une requête locale et se met à jour à chaque changement
/// (saisie sur ce poste ou données reçues par la synchro).
class Requete extends StatefulWidget {
  const Requete(this.sql, {super.key, this.parametres = const [], required this.builder});

  final String sql;
  final List<Object?> parametres;
  final Widget Function(BuildContext context, Lignes lignes) builder;

  @override
  State<Requete> createState() => _RequeteState();
}

class _RequeteState extends State<Requete> {
  late Stream<Lignes> _flux;

  void _abonner() => _flux = db
      .watch(widget.sql, parameters: widget.parametres)
      .map((r) => [for (final l in r) Map<String, Object?>.from(l)]);

  @override
  void initState() {
    super.initState();
    _abonner();
  }

  @override
  void didUpdateWidget(Requete ancien) {
    super.didUpdateWidget(ancien);
    if (ancien.sql != widget.sql || !listEquals(ancien.parametres, widget.parametres)) _abonner();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Lignes>(
        stream: _flux,
        builder: (context, s) =>
            s.hasData ? widget.builder(context, s.data!) : const Center(child: CircularProgressIndicator()),
      );
}

// Éléments communs ------------------------------------------------------------

class _Page extends StatelessWidget {
  const _Page({required this.titre, required this.corps, this.ajouter, this.libelleAjouter});

  final String titre;
  final Widget corps;
  final VoidCallback? ajouter;
  final String? libelleAjouter;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(titre)),
        floatingActionButton: ajouter == null
            ? null
            : FloatingActionButton.extended(
                onPressed: ajouter, icon: const Icon(Icons.add), label: Text(libelleAjouter ?? 'Ajouter')),
        body: Center(
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: corps),
        ),
      );
}

Widget _vide(String message) => Center(
      child: Padding(padding: const EdgeInsets.all(32), child: Text(message, textAlign: TextAlign.center)),
    );

Future<bool> _confirmer(BuildContext context, String question) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(question),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirmer')),
        ],
      ),
    ) ??
    false;

/// Boîte de saisie : construit ses champs, renvoie vrai si l'on valide.
Future<bool> _formulaire(BuildContext context, String titre, List<Widget> Function(StateSetter maj) champs) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, maj) => AlertDialog(
          title: Text(titre),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final c in champs(maj)) Padding(padding: const EdgeInsets.only(bottom: 12), child: c),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
          ],
        ),
      ),
    ) ??
    false;

InputDecoration _champ(String label, {String? aide, String? suffixe}) =>
    InputDecoration(labelText: label, helperText: aide, suffixText: suffixe, border: const OutlineInputBorder());

Widget _liste<T>(String label, T valeur, Map<T, String> choix, ValueChanged<T> change) =>
    DropdownButtonFormField<T>(
      initialValue: valeur,
      isExpanded: true,
      decoration: _champ(label),
      items: [for (final e in choix.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
      onChanged: (v) => change(v as T),
    );

// Liste de contrôle -----------------------------------------------------------

class ConfigurationScreen extends StatelessWidget {
  const ConfigurationScreen({super.key, required this.espace});

  final Espace espace;

  @override
  Widget build(BuildContext context) {
    final o = espace.orgId;
    return _Page(
      titre: "Configurer l'établissement",
      corps: Requete(
        '''SELECT
             (SELECT libelle FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1) AS annee,
             (SELECT count(*) FROM niveaux WHERE organisation_id = ?) AS niveaux,
             (SELECT count(*) FROM matieres WHERE organisation_id = ?) AS matieres,
             (SELECT count(*) FROM classes WHERE organisation_id = ?) AS classes,
             (SELECT count(*) FROM frais WHERE organisation_id = ?) AS frais,
             (SELECT code FROM organisations WHERE id = ?) AS sigle,
             (SELECT count(*) FROM sites WHERE organisation_id = ? AND code IS NULL) AS sites_sans_code,
             (SELECT responsable_nom FROM organisations WHERE id = ?) AS responsable''',
        parametres: [o, o, o, o, o, o, o, o],
        builder: (context, l) {
          final r = l.first;
          Widget etape(int n, String titre, String detail, bool fait, Widget ecran) => Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: fait ? Colors.teal : null,
                    foregroundColor: fait ? Colors.white : null,
                    child: fait ? const Icon(Icons.check) : Text('$n'),
                  ),
                  title: Text(titre),
                  subtitle: Text(detail),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ecran)),
                ),
              );
          final niveaux = r['niveaux'] as int? ?? 0;
          return ListView(padding: const EdgeInsets.all(16), children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Étape 2 sur 6. Tout fonctionne hors ligne : la synchronisation suivra.'),
            ),
            etape(0, "Identité de l'école", r['sigle'] == null ? 'Sigle, code du site, responsable légal'
                : 'Sigle ${r['sigle']}${(r['sites_sans_code'] as int? ?? 0) > 0 ? ' · code du site à choisir' : ''}',
                r['sigle'] != null && r['sites_sans_code'] == 0 && r['responsable'] != null,
                IdentiteEcoleScreen(espace: espace)),
            etape(1, 'Année scolaire', r['annee'] == null ? 'À créer' : '${r['annee']} en cours', r['annee'] != null,
                AnneesScreen(espace: espace)),
            etape(2, 'Niveaux', niveaux == 0 ? 'Partir du modèle guinéen' : '$niveaux niveaux', niveaux > 0,
                NiveauxScreen(espace: espace)),
            etape(3, 'Matières et coefficients', '${r['matieres']} matières', (r['matieres'] as int? ?? 0) > 0,
                MatieresScreen(espace: espace)),
            etape(4, 'Classes et salles', '${r['classes']} classes', (r['classes'] as int? ?? 0) > 0,
                ClassesScreen(espace: espace)),
            etape(5, 'Frais scolaires', '${r['frais']} frais · inscription, scolarité en tranches', (r['frais'] as int? ?? 0) > 0,
                FraisScreen(espace: espace)),
          ]);
        },
      ),
    );
  }
}

// Années scolaires ------------------------------------------------------------

class AnneesScreen extends StatelessWidget {
  const AnneesScreen({super.key, required this.espace});

  final Espace espace;

  Future<void> _ajouter(BuildContext context) async {
    final libelle = TextEditingController(text: anneeScolairePour(DateTime.now()));
    final depart = int.parse(libelle.text.substring(0, 4));
    var debut = DateTime(depart, 10, 1);
    var fin = DateTime(depart + 1, 7, 15);
    Future<void> choisir(StateSetter maj, bool estDebut) async {
      final d = await showDatePicker(
          context: context, initialDate: estDebut ? debut : fin, firstDate: DateTime(2020), lastDate: DateTime(2040));
      if (d != null) maj(() => estDebut ? debut = d : fin = d);
    }

    final ok = await _formulaire(context, 'Nouvelle année scolaire', (maj) => [
          TextField(controller: libelle, decoration: _champ('Année', aide: 'Par exemple 2026-2027')),
          OutlinedButton.icon(
              onPressed: () => choisir(maj, true),
              icon: const Icon(Icons.event),
              label: Text('Rentrée : ${_dateLisible(_date(debut))}')),
          OutlinedButton.icon(
              onPressed: () => choisir(maj, false),
              icon: const Icon(Icons.event_available),
              label: Text('Fin : ${_dateLisible(_date(fin))}')),
        ]);
    if (!ok || libelle.text.trim().length < 4 || !fin.isAfter(debut)) return;
    final enCours = await db.getOptional(
        'SELECT id FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1', [espace.orgId]);
    await _inserer('annees_scolaires', {
      'organisation_id': espace.orgId,
      'libelle': libelle.text.trim(),
      'debut': _date(debut),
      'fin': _date(fin),
      'en_cours': enCours == null ? 1 : 0,
    });
  }

  Future<void> _mettreEnCours(String id) => db.writeTransaction((tx) async {
        // D'abord retirer l'ancienne, pour respecter « une seule année en cours ».
        await tx.execute('UPDATE annees_scolaires SET en_cours = 0, updated_at = ? '
            'WHERE organisation_id = ? AND en_cours = 1', [_maintenant(), espace.orgId]);
        await tx.execute(
            'UPDATE annees_scolaires SET en_cours = 1, updated_at = ? WHERE id = ?', [_maintenant(), id]);
      });

  @override
  Widget build(BuildContext context) => _Page(
        titre: 'Années scolaires',
        ajouter: espace.fondateur ? () => _ajouter(context) : null,
        libelleAjouter: 'Nouvelle année',
        corps: Requete('SELECT * FROM annees_scolaires WHERE organisation_id = ? ORDER BY debut DESC',
            parametres: [espace.orgId], builder: (context, annees) {
          if (annees.isEmpty) return _vide("Aucune année scolaire. Créez celle de cette rentrée.");
          return ListView(padding: const EdgeInsets.all(16), children: [
            for (final a in annees)
              Card(
                child: ListTile(
                  leading: Icon(a['en_cours'] == 1 ? Icons.radio_button_checked : Icons.radio_button_off,
                      color: a['en_cours'] == 1 ? Colors.teal : null),
                  title: Text('${a['libelle']}'),
                  subtitle: Text('Du ${_dateLisible(a['debut'])} au ${_dateLisible(a['fin'])}'
                      '${a['en_cours'] == 1 ? ' · en cours' : ''}'),
                  onTap: espace.fondateur && a['en_cours'] != 1 ? () => _mettreEnCours(a['id'] as String) : null,
                ),
              ),
            if (espace.fondateur && annees.length > 1)
              const Padding(
                  padding: EdgeInsets.all(8), child: Text("Touchez une année pour en faire l'année en cours.")),
          ]);
        }),
      );
}

// Niveaux ---------------------------------------------------------------------

class NiveauxScreen extends StatelessWidget {
  const NiveauxScreen({super.key, required this.espace});

  final Espace espace;

  Future<void> _appliquerModele(BuildContext context) async {
    final choisis = {'primaire', 'college'};
    final ok = await _formulaire(context, 'Quels cycles avez-vous ?', (maj) => [
          for (final c in cycles.entries)
            CheckboxListTile(
              value: choisis.contains(c.key),
              title: Text(c.value),
              subtitle: Text(niveauxParCycle[c.key]!.map((n) => n.nom).join(', ')),
              onChanged: (v) => maj(() => v == true ? choisis.add(c.key) : choisis.remove(c.key)),
            ),
          const Text('Les matières et coefficients indicatifs sont ajoutés aussi. Vous pourrez tout modifier.'),
        ]);
    if (!ok || choisis.isEmpty) return;
    final maintenant = _maintenant();
    await db.writeTransaction((tx) async {
      for (final cycle in cycles.keys.where(choisis.contains)) {
        for (final n in niveauxParCycle[cycle]!) {
          // Les tables locales de PowerSync sont des vues : pas de RETURNING, on choisit l'id avant.
          final id = (await tx.get('SELECT uuid() AS id'))['id'];
          await tx.execute(
              'INSERT INTO niveaux (id, organisation_id, cycle, nom, ordre, created_at, updated_at) '
              'VALUES (?, ?, ?, ?, ?, ?, ?)',
              [id, espace.orgId, cycle, n.nom, n.ordre, maintenant, maintenant]);
          for (final m in (matieresParCycle[cycle] ?? const <String, double>{}).entries) {
            await tx.execute(
                'INSERT INTO matieres (id, organisation_id, niveau_id, nom, coefficient, created_at, updated_at) '
                'VALUES (uuid(), ?, ?, ?, ?, ?, ?)',
                [espace.orgId, id, m.key, m.value, maintenant, maintenant]);
          }
        }
      }
    });
  }

  Future<void> _ajouter(BuildContext context) async {
    var cycle = 'primaire';
    final nom = TextEditingController();
    final ok = await _formulaire(context, 'Nouveau niveau', (maj) => [
          _liste('Cycle', cycle, cycles, (v) => maj(() => cycle = v)),
          TextField(controller: nom, decoration: _champ('Nom', aide: 'Par exemple CM2 ou 10ème')),
        ]);
    if (!ok || nom.text.trim().isEmpty) return;
    final dernier = await db.get('SELECT coalesce(max(ordre), 0) AS o FROM niveaux WHERE organisation_id = ?',
        [espace.orgId]);
    await _inserer('niveaux', {
      'organisation_id': espace.orgId,
      'cycle': cycle,
      'nom': nom.text.trim(),
      'ordre': (dernier['o'] as int) + 1,
    });
  }

  @override
  Widget build(BuildContext context) => _Page(
        titre: 'Niveaux',
        ajouter: espace.fondateur ? () => _ajouter(context) : null,
        libelleAjouter: 'Niveau',
        corps: Requete('SELECT * FROM niveaux WHERE organisation_id = ? ORDER BY ordre, nom',
            parametres: [espace.orgId], builder: (context, niveaux) {
          if (niveaux.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Aucun niveau pour le moment.', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  if (espace.fondateur)
                    FilledButton.icon(
                      onPressed: () => _appliquerModele(context),
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Utiliser le modèle guinéen'),
                    ),
                ]),
              ),
            );
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
            for (final n in niveaux)
              Card(
                child: ListTile(
                  title: Text('${n['nom']}'),
                  subtitle: Text(cycles[n['cycle']] ?? ''),
                  trailing: espace.fondateur
                      ? IconButton(
                          tooltip: 'Supprimer',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            if (await _confirmer(context,
                                'Supprimer le niveau ${n['nom']} ? Ses matières et ses classes seront supprimées aussi.')) {
                              await _supprimer('niveaux', n['id'] as String);
                            }
                          },
                        )
                      : null,
                ),
              ),
          ]);
        }),
      );
}

// Matières et coefficients ----------------------------------------------------

class MatieresScreen extends StatefulWidget {
  const MatieresScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<MatieresScreen> createState() => _MatieresScreenState();
}

class _MatieresScreenState extends State<MatieresScreen> {
  String? _niveau;

  Future<void> _editer({Map<String, Object?>? matiere}) async {
    final nom = TextEditingController(text: matiere?['nom'] as String? ?? '');
    final coef = TextEditingController(text: '${matiere?['coefficient'] ?? 1}'.replaceAll('.0', ''));
    final ok = await _formulaire(context, matiere == null ? 'Nouvelle matière' : 'Modifier la matière', (_) => [
          TextField(controller: nom, decoration: _champ('Matière')),
          TextField(
              controller: coef,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _champ('Coefficient')),
        ]);
    final c = double.tryParse(coef.text.replaceAll(',', '.'));
    if (!ok || nom.text.trim().isEmpty || c == null || c <= 0) return;
    if (matiere == null) {
      await _inserer('matieres', {
        'organisation_id': widget.espace.orgId,
        'niveau_id': _niveau,
        'nom': nom.text.trim(),
        'coefficient': c,
      });
    } else {
      await _modifier('matieres', matiere['id'] as String, {'nom': nom.text.trim(), 'coefficient': c});
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.espace;
    return _Page(
      titre: 'Matières et coefficients',
      ajouter: e.fondateur && _niveau != null ? () => _editer() : null,
      libelleAjouter: 'Matière',
      corps: Requete('SELECT id, nom FROM niveaux WHERE organisation_id = ? ORDER BY ordre, nom',
          parametres: [e.orgId], builder: (context, niveaux) {
        if (niveaux.isEmpty) return _vide("Créez d'abord les niveaux.");
        final niveau = niveaux.any((n) => n['id'] == _niveau) ? _niveau! : niveaux.first['id'] as String;
        if (niveau != _niveau) WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => _niveau = niveau));
        return Column(children: [
          SizedBox(
            height: 56,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(8), children: [
              for (final n in niveaux)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text('${n['nom']}'),
                    selected: n['id'] == niveau,
                    onSelected: (_) => setState(() => _niveau = n['id'] as String),
                  ),
                ),
            ]),
          ),
          Expanded(
            child: Requete('SELECT * FROM matieres WHERE niveau_id = ? ORDER BY coefficient DESC, nom',
                parametres: [niveau], builder: (context, matieres) {
              if (matieres.isEmpty) return _vide('Aucune matière pour ce niveau.');
              return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 88), children: [
                for (final m in matieres)
                  Card(
                    child: ListTile(
                      title: Text('${m['nom']}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('coef. ${'${m['coefficient']}'.replaceAll('.0', '')}'),
                        if (e.fondateur)
                          IconButton(
                            tooltip: 'Supprimer',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              if (await _confirmer(context, 'Supprimer ${m['nom']} ?')) {
                                await _supprimer('matieres', m['id'] as String);
                              }
                            },
                          ),
                      ]),
                      onTap: e.fondateur ? () => _editer(matiere: m) : null,
                    ),
                  ),
              ]);
            }),
          ),
        ]);
      }),
    );
  }
}

// Classes ---------------------------------------------------------------------

class ClassesScreen extends StatelessWidget {
  const ClassesScreen({super.key, required this.espace});

  final Espace espace;

  Future<void> _ajouter(BuildContext context) async {
    final annee = await db.getOptional(
        'SELECT id FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1', [espace.orgId]);
    final sites = {
      for (final s in await db.getAll('SELECT id, nom FROM sites WHERE organisation_id = ? ORDER BY created_at',
          [espace.orgId]))
        if (espace.gereSite(s['id'] as String)) s['id'] as String: s['nom'] as String,
    };
    final niveaux = {
      for (final n in await db.getAll('SELECT id, nom FROM niveaux WHERE organisation_id = ? ORDER BY ordre, nom',
          [espace.orgId]))
        n['id'] as String: n['nom'] as String,
    };
    if (!context.mounted) return;
    if (annee == null || sites.isEmpty || niveaux.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Il faut d'abord une année scolaire en cours et des niveaux.")));
      return;
    }
    var site = sites.keys.first;
    var niveau = niveaux.keys.first;
    final nom = TextEditingController(text: '${niveaux[niveau]} A');
    final salle = TextEditingController();
    final ok = await _formulaire(context, 'Nouvelle classe', (maj) => [
          if (sites.length > 1) _liste('Site', site, sites, (v) => maj(() => site = v)),
          _liste('Niveau', niveau, niveaux, (v) => maj(() {
                niveau = v;
                nom.text = '${niveaux[v]} A';
              })),
          TextField(controller: nom, decoration: _champ('Nom de la classe', aide: 'Par exemple 7ème A')),
          TextField(controller: salle, decoration: _champ('Salle (facultatif)')),
        ]);
    if (!ok || nom.text.trim().isEmpty) return;
    await _inserer('classes', {
      'organisation_id': espace.orgId,
      'site_id': site,
      'annee_id': annee['id'],
      'niveau_id': niveau,
      'nom': nom.text.trim(),
      'salle': salle.text.trim().isEmpty ? null : salle.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) => _Page(
        titre: 'Classes et salles',
        ajouter: espace.gestionnaire ? () => _ajouter(context) : null,
        libelleAjouter: 'Classe',
        corps: Requete(
            '''SELECT c.*, n.nom AS niveau, s.nom AS site
               FROM classes c
               JOIN annees_scolaires a ON a.id = c.annee_id AND a.en_cours = 1
               JOIN niveaux n ON n.id = c.niveau_id
               JOIN sites s ON s.id = c.site_id
               WHERE c.organisation_id = ?
               ORDER BY s.created_at, n.ordre, c.nom''',
            parametres: [espace.orgId], builder: (context, classes) {
          if (classes.isEmpty) return _vide("Aucune classe pour l'année en cours.");
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
            for (final c in classes)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.meeting_room_outlined),
                  title: Text('${c['nom']}'),
                  subtitle: Text([c['site'], if (c['salle'] != null) c['salle']].join(' · ')),
                  trailing: espace.gereSite(c['site_id'] as String)
                      ? IconButton(
                          tooltip: 'Supprimer',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            if (await _confirmer(context, 'Supprimer la classe ${c['nom']} ?')) {
                              await _supprimer('classes', c['id'] as String);
                            }
                          },
                        )
                      : null,
                ),
              ),
          ]);
        }),
      );
}
