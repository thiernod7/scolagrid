import 'dart:async' show Timer, unawaited;
import 'dart:convert' show base64Decode, base64Encode, base64Url, utf8;
import 'dart:math' show Random;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' show sha256;
import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart' show FilePicker, FileType;
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart' show CameraDevice, ImagePicker, ImageSource;
import 'package:printing/printing.dart' show Printing;
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'base.dart';
import 'caisse.dart';
import 'cloud.dart';
import 'echeancier.dart';
import 'fonctions.dart';
import 'graphiques.dart';
import 'import_eleves.dart';
import 'matricule.dart';
import 'modele_excel.dart';
import 'modele_guineen.dart';
import 'recu_pdf.dart';
import 'theme.dart';

part 'annees.dart';
part 'eleves.dart';
part 'encaissement.dart';
part 'fiche_eleve.dart';
part 'frais.dart';
part 'identite.dart';
part 'import_ecran.dart';
part 'inscription.dart';
part 'mise_en_route.dart';
part 'personnel.dart';
part 'photo.dart';
part 'poste.dart';
part 'reductions.dart';
part 'regles.dart';
part 'remboursements.dart';
part 'structure.dart';
part 'tableau_de_bord.dart';

/// Étape 2 de l'onboarding : configurer l'établissement.
/// Tout s'écrit dans la base locale, donc fonctionne hors ligne ;
/// le serveur vérifie les droits à la synchronisation.

/// Qui configure, et sur quel périmètre.
class Espace {
  const Espace({required this.orgId, required this.ville, required this.role, this.siteId, this.droits = const {}});

  final String orgId;
  final String ville;
  final String role;
  final String? siteId; // vide = tous les sites

  /// Droits de la personne connectée, sur au moins un site (fonctions et exceptions comprises).
  final Set<String> droits;

  bool get fondateur => role == 'fondateur';
  bool get gestionnaire => fondateur || role == 'directeur';
  bool gereSite(String site) => fondateur || (role == 'directeur' && (siteId == null || siteId == site));

  /// Matières et coefficients : le fondateur et ceux qui planifient les évaluations.
  bool get gereMatieres => fondateur || droits.contains('planifier_evaluations');

  /// Chiffres financiers de l'école (tableau de bord).
  bool get voitFinances => fondateur || droits.contains('consulter_tableau_bord');

  /// Le menu Paramètres : la direction, la direction des études, la comptabilité.
  bool get voitParametres => gestionnaire || gereMatieres || voitFinances;
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
  Widget build(BuildContext context) {
    final retour = Navigator.of(context).canPop();
    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // En-tête fin, comme la maquette : retour, titre, action principale.
              Padding(
                padding: EdgeInsets.fromLTRB(retour ? 4 : 16, 12, 16, 0),
                child: Row(children: [
                  if (retour)
                    IconButton(
                      tooltip: 'Retour',
                      icon: const Icon(Icons.arrow_back, size: 18),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  Expanded(
                    child: Text(titre,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -.2)),
                  ),
                  if (ajouter != null)
                    FilledButton.icon(
                        onPressed: ajouter, icon: const Icon(Icons.add, size: 16), label: Text(libelleAjouter ?? 'Ajouter')),
                ]),
              ),
              Expanded(child: corps),
            ]),
          ),
        ),
      ),
    );
  }
}


Widget _vide(String message) => Center(
      child: Padding(padding: const EdgeInsets.all(32), child: Text(message, textAlign: TextAlign.center)),
    );

Future<bool> _confirmer(BuildContext context, String question) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: Text(question)),
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
          // Largeur d'un formulaire, pas de l'écran : sur PC la fenêtre ne s'étire plus.
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final c in champs(maj)) Padding(padding: const EdgeInsets.only(bottom: 12), child: c),
              ]),
            ),
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

// Paramètres ------------------------------------------------------------------

/// Une rubrique des paramètres, rangée dans un groupe du volet de gauche.
class _Reglage {
  const _Reglage(this.cle, this.titre, this.aide, this.icone, this.groupe, this.ecran);

  final String cle;
  final String titre;
  final String aide;
  final IconData icone;
  final String groupe;
  final Widget Function(Espace espace) ecran;
}

final _reglages = <_Reglage>[
  _Reglage('demarrage', 'Mise en route', "Les étapes pour démarrer, puis l'import des élèves", Icons.flag_outlined, 'Démarrage',
      (e) => MiseEnRouteScreen(espace: e)),
  _Reglage('ecole', "L'école", 'Logo, contacts, responsable, documents', Icons.apartment_outlined, 'Établissement',
      (e) => IdentiteEcoleScreen(espace: e)),
  _Reglage('regles', 'Règles générales', 'Documents si arriérés, seuil, redoublements', Icons.rule_outlined, 'Établissement',
      (e) => ReglesGeneralesScreen(espace: e)),
  _Reglage('annee', 'Année scolaire', "L'année en cours et ses dates", Icons.event_outlined, 'Scolarité',
      (e) => AnneesScreen(espace: e)),
  _Reglage('niveaux', 'Niveaux', "Noms d'usage, examens, séries, dernier niveau", Icons.layers_outlined, 'Scolarité',
      (e) => NiveauxScreen(espace: e)),
  _Reglage('matieres', 'Matières', 'Matières et coefficients par niveau', Icons.menu_book_outlined, 'Scolarité',
      (e) => MatieresScreen(espace: e)),
  _Reglage('classes', 'Classes', 'Groupes, effectifs, professeur principal', Icons.grid_view_outlined, 'Scolarité',
      (e) => ClassesScreen(espace: e)),
  _Reglage('pieces', 'Pièces du dossier', 'Ce que les familles fournissent', Icons.folder_open_outlined, 'Scolarité',
      (e) => PiecesDossierScreen(espace: e)),
  _Reglage('frais', 'Frais scolaires', 'Inscription, scolarité en tranches, options', Icons.payments_outlined, 'Argent',
      (e) => FraisScreen(espace: e)),
  _Reglage('reductions', 'Réductions', 'Fratrie, paiement annuel, bourses', Icons.percent, 'Argent',
      (e) => ReductionsScreen(espace: e)),
  _Reglage('remboursements', 'Remboursements', "Ce que l'école accepte de rembourser", Icons.undo, 'Argent',
      (e) => PolitiqueRemboursementScreen(espace: e)),
];

/// Les paramètres de l'école. Sur grand écran, un volet à gauche (groupes et
/// rubriques) et la rubrique ouverte à droite ; sur téléphone, la liste des
/// rubriques, chacune s'ouvrant en plein écran.
class ConfigurationScreen extends StatefulWidget {
  const ConfigurationScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<ConfigurationScreen> createState() => _ConfigurationScreenState();
}

class _ConfigurationScreenState extends State<ConfigurationScreen> {
  String? _choisi;

  Espace get _e => widget.espace;

  /// Qui voit quelle rubrique : la direction voit tout ; la direction des
  /// études voit la scolarité ; la comptabilité voit l'argent.
  bool _voit(String cle) => switch (cle) {
        'demarrage' || 'ecole' || 'regles' || 'pieces' => _e.gestionnaire,
        'annee' || 'niveaux' || 'matieres' || 'classes' => _e.gestionnaire || _e.gereMatieres,
        'frais' || 'reductions' || 'remboursements' => _e.gestionnaire || _e.voitFinances,
        _ => false,
      };

  /// Qui peut modifier (le serveur applique les mêmes règles).
  bool _modifie(String cle) => switch (cle) {
        'demarrage' || 'ecole' || 'classes' || 'frais' => _e.gestionnaire,
        'matieres' => _e.gereMatieres,
        'annee' || 'niveaux' || 'reductions' || 'remboursements' || 'regles' || 'pieces' => _e.fondateur,
        _ => false,
      };

  List<_Reglage> get _visibles => _reglages.where((r) => _voit(r.cle)).toList();

  String get _actif {
    final v = _visibles;
    return v.any((r) => r.cle == _choisi) ? _choisi! : (v.isEmpty ? _reglages.first.cle : v.first.cle);
  }

  /// Où en est chaque rubrique : faite ou non, et un résumé.
  Map<String, (bool, String)> _etat(Map<String, Object?> r) {
    int n(String c) => r[c] as int? ?? 0;
    return {
      'demarrage': (
        n('eleves') > 0,
        n('eleves') > 0 ? '${n('eleves')} élève(s) dans ScolaGrid' : "Les réglages dans l'ordre, puis les élèves",
      ),
      'ecole': (
        r['sigle'] != null && n('sites_sans_code') == 0 && r['responsable'] != null,
        r['sigle'] == null
            ? 'Sigle, code du site, responsable légal'
            : 'Sigle ${r['sigle']}${n('sites_sans_code') > 0 ? ' · code du site à choisir' : ''}'
      ),
      'annee': (r['annee'] != null, r['annee'] == null ? 'À créer' : '${r['annee']} en cours'),
      'niveaux': (n('niveaux') > 0, n('niveaux') == 0 ? 'Partir du modèle guinéen' : '${n('niveaux')} niveaux'),
      'matieres': (n('matieres') > 0, '${n('matieres')} matières'),
      'classes': (n('classes') > 0, '${n('classes')} classes'),
      'frais': (n('frais') > 0, '${n('frais')} frais'),
      'reductions': (n('reductions') > 0, n('reductions') == 0 ? 'Aucune réduction' : '${n('reductions')} réduction(s)'),
      'remboursements': (true, "Ce que l'école accepte de rembourser"),
      'regles': (true, 'Documents si arriérés, seuil, redoublements'),
      'pieces': (true, 'Ce que les familles fournissent'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.espace.orgId;
    return Requete(
      '''SELECT
           (SELECT libelle FROM annees_scolaires WHERE organisation_id = ? AND en_cours = 1) AS annee,
           (SELECT count(*) FROM niveaux WHERE organisation_id = ?) AS niveaux,
           (SELECT count(*) FROM matieres WHERE organisation_id = ?) AS matieres,
           (SELECT count(*) FROM classes WHERE organisation_id = ?) AS classes,
           (SELECT count(*) FROM frais WHERE organisation_id = ?) AS frais,
           (SELECT count(*) FROM regles_reduction WHERE organisation_id = ? AND actif = 1) AS reductions,
           (SELECT code FROM organisations WHERE id = ?) AS sigle,
           (SELECT nom FROM organisations WHERE id = ?) AS ecole,
           (SELECT count(*) FROM sites WHERE organisation_id = ? AND code IS NULL) AS sites_sans_code,
           (SELECT responsable_nom FROM organisations WHERE id = ?) AS responsable,
           (SELECT count(*) FROM eleves WHERE organisation_id = ?) AS eleves''',
      parametres: [o, o, o, o, o, o, o, o, o, o, o],
      builder: (context, l) {
        final r = l.first;
        final etat = _etat(r);
        return LayoutBuilder(
          builder: (context, c) => c.maxWidth >= 860 ? _deuxVolets(context, r, etat) : _liste(context, etat),
        );
      },
    );
  }

  /// Rubriques par groupe, dans l'ordre.
  Map<String, List<_Reglage>> get _groupes {
    final g = <String, List<_Reglage>>{};
    for (final r in _visibles) {
      g.putIfAbsent(r.groupe, () => []).add(r);
    }
    return g;
  }

  Widget _deuxVolets(BuildContext context, Map<String, Object?> r, Map<String, (bool, String)> etat) {
    final schema = Theme.of(context).colorScheme;
    final texte = Theme.of(context).textTheme;
    final actif = _reglages.firstWhere((x) => x.cle == _actif);
    Widget rubrique(_Reglage x) {
      final choisie = x.cle == _actif;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: choisie ? schema.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _choisi = x.cle),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Icon(x.icone, size: 18, color: choisie ? schema.onSecondaryContainer : schema.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(x.titre,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: choisie ? FontWeight.w600 : FontWeight.w400,
                          color: choisie ? schema.onSecondaryContainer : schema.onSurfaceVariant)),
                ),
                if (!_modifie(x.cle))
                  Tooltip(
                    message: 'Lecture seule',
                    child: Icon(Icons.lock_outline, size: 14, color: schema.onSurfaceVariant.withValues(alpha: .7)),
                  )
                else if (etat[x.cle]?.$1 == false)
                  Tooltip(
                    message: 'À compléter',
                    child: Container(
                        width: 8, height: 8, decoration: const BoxDecoration(color: Couleurs.attente, shape: BoxShape.circle)),
                  ),
              ]),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          width: 250,
          margin: const EdgeInsets.fromLTRB(12, 12, 0, 12),
          decoration: BoxDecoration(
            color: schema.surface,
            border: Border.all(color: schema.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Paramètres', style: texte.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text([r['ecole'], r['annee']].whereType<String>().join(' · '),
                    style: texte.bodySmall, overflow: TextOverflow.ellipsis),
              ]),
            ),
            Divider(height: 1, color: schema.outlineVariant),
            Expanded(
              child: ListView(padding: const EdgeInsets.all(8), children: [
                for (final g in _groupes.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Text(g.key.toUpperCase(),
                        style: texte.labelSmall?.copyWith(letterSpacing: .8, color: schema.onSurfaceVariant)),
                  ),
                  for (final x in g.value) rubrique(x),
                ],
              ]),
            ),
          ]),
        ),
        // La rubrique ouverte, avec sa propre pile d'écrans.
        Expanded(
          child: Navigator(
            key: ValueKey(_actif),
            onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => actif.ecran(widget.espace)),
          ),
        ),
      ]),
    );
  }

  Widget _liste(BuildContext context, Map<String, (bool, String)> etat) {
    final texte = Theme.of(context).textTheme;
    return _Page(
      titre: 'Paramètres',
      corps: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Tout fonctionne hors ligne : la synchronisation suivra.'),
        for (final g in _groupes.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
            child: Text(g.key.toUpperCase(), style: texte.labelSmall?.copyWith(letterSpacing: .8)),
          ),
          for (final x in g.value)
            Card(
              child: ListTile(
                leading: Icon(x.icone),
                title: Text(x.titre),
                subtitle: Text(etat[x.cle]?.$2 ?? x.aide),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (!_modifie(x.cle))
                    const Etat('Lecture seule', icone: Icons.lock_outline)
                  else if (etat[x.cle]?.$1 == false)
                    const Etat('À faire', ton: Ton.attente),
                  const Icon(Icons.chevron_right),
                ]),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => x.ecran(widget.espace))),
              ),
            ),
        ],
      ]),
    );
  }
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
      ajouter: e.gereMatieres && _niveau != null ? () => _editer() : null,
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
                        if (e.gereMatieres)
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
                      onTap: e.gereMatieres ? () => _editer(matiere: m) : null,
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
