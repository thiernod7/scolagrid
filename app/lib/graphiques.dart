/// Cartes de chiffres et graphiques simples (barres, barres couchées, anneau),
/// dessinés sans bibliothèque : fins, lisibles, en clair comme en sombre.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Palette des graphiques (la même que la maquette).
abstract final class Viz {
  static const bleu = Color(0xFF2A78D6);
  static const orange = Color(0xFFEB6834);
  static const vert = Color(0xFF1BAF7A);
  static const rouge = Color(0xFFE34948);
  static const rampe = [Color(0xFF86B6EF), Color(0xFF2A78D6), Color(0xFF104281)];
  static const violet = Color(0xFF8B5CF6);
}

/// « 59,2 % »
String pourcent(double v, {int decimales = 1}) => '${v.toStringAsFixed(decimales).replaceAll('.', ',')} %';

/// Millions de GNF pour les axes : « 28,5 M ».
String millions(num v) {
  if (v == 0) return '0';
  if (v.abs() < 1000000) return '${(v / 1000).round()} k';
  final m = v / 1000000;
  return '${(m == m.roundToDouble() ? m.round().toString() : m.toStringAsFixed(1)).replaceAll('.', ',')} M';
}

/// Titre de section du tableau de bord (« FINANCES »).
class TitreSection extends StatelessWidget {
  const TitreSection(this.titre, {super.key});

  final String titre;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(titre.toUpperCase(),
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

/// Grille qui place des cartes sur 1, 2 ou 4 colonnes selon la largeur ;
/// une carte « large » prend deux colonnes.
class GrilleCartes extends StatelessWidget {
  const GrilleCartes({super.key, required this.cartes, this.larges = const {}, this.colonnesMax = 4});

  final List<Widget> cartes;
  final Set<int> larges;
  final int colonnesMax;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        // Téléphone (dès 320 px) : deux cartes par ligne, plus compactes.
        final n = math.min(colonnesMax, c.maxWidth >= 1100 ? 4 : (c.maxWidth >= 320 ? 2 : 1));
        const espace = 12.0;
        final col = (c.maxWidth - espace * (n - 1)) / n;
        return Wrap(spacing: espace, runSpacing: espace, children: [
          for (var i = 0; i < cartes.length; i++)
            SizedBox(width: larges.contains(i) && n > 1 ? col * 2 + espace : col, child: cartes[i]),
        ]);
      });
}

/// Une comparaison sous un chiffre : « ↗ +17,4 % vs mois précédent ».
class Comparaison {
  const Comparaison(this.libelle, this.delta, {this.unite = '%', this.bonSens = true});

  final String libelle;

  /// null : pas de référence.
  final double? delta;
  final String unite;

  /// true : une hausse est une bonne nouvelle.
  final bool bonSens;
}

enum NiveauSeuil { bon, vigilance, alerte }

Color couleurSeuil(NiveauSeuil n) => switch (n) {
      NiveauSeuil.bon => Couleurs.regle,
      NiveauSeuil.vigilance => Couleurs.attente,
      NiveauSeuil.alerte => Couleurs.retard,
    };

/// Carte d'un indicateur, comme la maquette : titre gris, grand chiffre,
/// barre éventuelle, comparaisons, et un clic qui mène au détail.
class CarteKpi extends StatelessWidget {
  const CarteKpi({
    super.key,
    required this.titre,
    required this.valeur,
    this.aide,
    this.vedette = false,
    this.seuil,
    this.texteSeuil,
    this.barre,
    this.comparaisons = const [],
    this.detail,
    this.onTap,
  });

  final String titre;
  final String valeur;
  final String? aide;
  final bool vedette;
  final NiveauSeuil? seuil;
  final String? texteSeuil;

  /// De 0 à 100.
  final double? barre;
  final List<Comparaison> comparaisons;
  final Widget? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) => _carte(context, c.maxWidth < 260));
  }

  /// [serre] : carte étroite (deux par ligne sur téléphone) — marges et chiffres plus petits.
  Widget _carte(BuildContext context, bool serre) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final titreTexte = Text(titre,
        style: TextStyle(
          fontSize: serre ? 12 : 14,
          fontWeight: FontWeight.w500,
          color: gris,
          decoration: aide != null ? TextDecoration.underline : null,
          decorationStyle: TextDecorationStyle.dotted,
          decorationColor: gris,
        ));
    return Material(
      color: schema.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: schema.outlineVariant)),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(serre ? 12 : 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: aide != null ? Tooltip(message: aide!, child: titreTexte) : titreTexte),
              if (seuil != null && texteSeuil != null)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 6, height: 6, decoration: BoxDecoration(color: couleurSeuil(seuil!), shape: BoxShape.circle)),
                  const SizedBox(width: 4),
                  Text(texteSeuil!, style: TextStyle(fontSize: 12, color: gris)),
                ])
              else if (onTap != null)
                Icon(Icons.chevron_right, size: 16, color: gris.withValues(alpha: .6)),
            ]),
            const SizedBox(height: 2),
            FittedBox(
              alignment: Alignment.centerLeft,
              fit: BoxFit.scaleDown,
              child: Text(valeur,
                  style: TextStyle(
                    fontSize: serre ? (vedette ? 28 : 22) : (vedette ? 36 : 30),
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.5,
                    color: seuil == null ? schema.onSurface : couleurSeuil(seuil!),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
            ),
            if (barre != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: (barre! / 100).clamp(0, 1).toDouble(),
                  minHeight: 4,
                  backgroundColor: Couleurs.doux(context),
                  color: seuil == null ? schema.primary : couleurSeuil(seuil!),
                ),
              ),
            ],
            if (comparaisons.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final c in comparaisons) _LigneComparaison(c),
            ],
            ?detail,
          ]),
        ),
      ),
    );
  }
}

class _LigneComparaison extends StatelessWidget {
  const _LigneComparaison(this.c);

  final Comparaison c;

  @override
  Widget build(BuildContext context) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final d = c.delta;
    if (d == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(children: [
          Icon(Icons.arrow_forward, size: 14, color: gris.withValues(alpha: .4)),
          const SizedBox(width: 4),
          Flexible(child: Text('pas de référence ${c.libelle.replaceFirst(RegExp(r'^vs '), '')}', style: TextStyle(fontSize: 14, color: gris))),
        ]),
      );
    }
    final neutre = d.abs() < .5;
    final hausse = d > 0;
    final bon = neutre ? null : hausse == c.bonSens;
    final couleur = bon == null ? gris : (bon ? Couleurs.regle : Couleurs.retard);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(children: [
        Icon(neutre ? Icons.arrow_forward : (hausse ? Icons.north_east : Icons.south_east), size: 14, color: couleur),
        const SizedBox(width: 4),
        Text('${hausse ? '+' : '−'}${d.abs().toStringAsFixed(1).replaceAll('.', ',')} ${c.unite == 'pts' ? 'pts' : '%'}',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: couleur)),
        const SizedBox(width: 4),
        Flexible(child: Text(c.libelle, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: gris))),
      ]),
    );
  }
}

/// Une entrée de légende : un carré (ou un trait) et son libellé.
class EntreeLegende {
  const EntreeLegende(this.couleur, this.libelle, {this.ligne = false});

  final Color couleur;
  final String libelle;
  final bool ligne;
}

/// Enveloppe d'un graphique : titre, précision à droite, légende, puis le dessin.
class CarteGraphique extends StatelessWidget {
  const CarteGraphique({
    super.key,
    required this.titre,
    required this.enfant,
    this.indice,
    this.legende = const [],
    this.hauteur = 200,
  });

  final String titre;
  final String? indice;
  final List<EntreeLegende> legende;
  final double hauteur;
  final Widget enfant;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: schema.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: schema.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(titre, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              if (indice != null) Text(indice!, style: TextStyle(fontSize: 12, color: gris)),
            ]),
            if (legende.isNotEmpty)
              Wrap(spacing: 12, runSpacing: 4, children: [
                for (final e in legende)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: e.ligne ? 14 : 8,
                      height: e.ligne ? 2 : 8,
                      decoration: BoxDecoration(color: e.couleur, borderRadius: BorderRadius.circular(2)),
                    ),
                    const SizedBox(width: 6),
                    Text(e.libelle, style: TextStyle(fontSize: 12, color: gris)),
                  ]),
              ]),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(height: hauteur, child: enfant),
      ]),
    );
  }
}

/// Une valeur à dessiner.
class Barre {
  const Barre(this.libelle, this.valeur, {this.couleur, this.infobulle});

  final String libelle;
  final num valeur;
  final Color? couleur;
  final String? infobulle;
}

/// Graduation « ronde » au-dessus de [max] en [n] intervalles.
double _pas(num max, int n) {
  if (max <= 0) return 1;
  final brut = max / n;
  final mag = math.pow(10, (math.log(brut) / math.ln10).floor()).toDouble();
  final r = brut / mag;
  final double f = r <= 1 ? 1.0 : (r <= 2 ? 2.0 : (r <= 2.5 ? 2.5 : (r <= 5 ? 5.0 : 10.0)));
  return f * mag;
}

/// Barres verticales avec grille horizontale et axe gradué.
class GraphBarres extends StatelessWidget {
  const GraphBarres({super.key, required this.barres, this.format, this.couleur = Viz.bleu, this.largeurMax = 34});

  final List<Barre> barres;
  final String Function(num)? format;
  final Color couleur;
  final double largeurMax;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final gris = schema.onSurfaceVariant;
    final f = format ?? (num v) => '${v.round()}';
    final maxi = barres.fold<num>(0, (m, b) => math.max(m, b.valeur));
    final pas = _pas(maxi, 4);
    final haut = pas * 4;
    const axe = TextStyle(fontSize: 12);
    return Column(children: [
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 46,
            child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (var i = 4; i >= 0; i--)
                Text(f(pas * i), style: axe.copyWith(color: gris, height: 1)),
            ]),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Stack(children: [
              Positioned.fill(child: CustomPaint(painter: _Grille(schema.outlineVariant, 4))),
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    for (final b in barres)
                      Expanded(
                        child: Tooltip(
                          message: b.infobulle ?? '${b.libelle} : ${f(b.valeur)}',
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: haut == 0 ? 0 : (b.valeur / haut).clamp(0, 1).toDouble(),
                              child: Container(
                                constraints: BoxConstraints(maxWidth: largeurMax),
                                margin: const EdgeInsets.symmetric(horizontal: 4),
                                decoration: BoxDecoration(
                                  color: b.couleur ?? couleur,
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 6),
      Row(children: [
        const SizedBox(width: 54),
        for (final b in barres)
          Expanded(
            child: Text(b.libelle,
                textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.clip, style: axe.copyWith(color: gris)),
          ),
      ]),
    ]);
  }
}

class _Grille extends CustomPainter {
  _Grille(this.couleur, this.n);

  final Color couleur;
  final int n;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = couleur
      ..strokeWidth = 1;
    for (var i = 0; i <= n; i++) {
      final y = 6 + (size.height - 6) * i / n;
      canvas.drawLine(Offset(0, y.floorToDouble() + .5), Offset(size.width, y.floorToDouble() + .5), p);
    }
  }

  @override
  bool shouldRepaint(_Grille ancien) => ancien.couleur != couleur || ancien.n != n;
}

/// Barres couchées, étiquetées à gauche et chiffrées à droite.
class GraphBarresH extends StatelessWidget {
  const GraphBarresH({super.key, required this.barres, this.format, this.largeurLibelle = 96});

  final List<Barre> barres;
  final String Function(num)? format;
  final double largeurLibelle;

  @override
  Widget build(BuildContext context) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final f = format ?? (num v) => '${v.round()}';
    final maxi = barres.fold<num>(0, (m, b) => math.max(m, b.valeur));
    return Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      for (final b in barres)
        Tooltip(
          message: b.infobulle ?? '${b.libelle} : ${f(b.valeur)}',
          child: Row(children: [
            SizedBox(
              width: largeurLibelle,
              child: Text(b.libelle, textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: gris)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                final l = maxi == 0 ? 0.0 : (c.maxWidth - 56) * (b.valeur / maxi);
                return Row(children: [
                  Container(
                    width: math.max(l, b.valeur > 0 ? 2 : 0),
                    height: 24,
                    decoration: BoxDecoration(
                      color: b.couleur ?? Viz.bleu,
                      borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(f(b.valeur), style: TextStyle(fontSize: 12, color: gris)),
                ]);
              }),
            ),
          ]),
        ),
    ]);
  }
}

/// Anneau (part du tout) avec ses étiquettes à côté.
class GraphAnneau extends StatelessWidget {
  const GraphAnneau({super.key, required this.parts});

  final List<Barre> parts;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final total = parts.fold<num>(0, (s, p) => s + p.valeur);
    return Row(children: [
      Expanded(
        child: Center(
          child: AspectRatio(
            aspectRatio: 1,
            child: CustomPaint(painter: _Anneau(parts, total, schema.surface, Couleurs.doux(context))),
          ),
        ),
      ),
      const SizedBox(width: 12),
      SizedBox(
        width: 150,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (final p in parts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Container(
                    width: 8, height: 8, decoration: BoxDecoration(color: p.couleur, borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(p.libelle,
                      overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: schema.onSurfaceVariant)),
                ),
                Text(total == 0 ? '—' : '${(p.valeur * 100 / total).round()} %',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              ]),
            ),
        ]),
      ),
    ]);
  }
}

class _Anneau extends CustomPainter {
  _Anneau(this.parts, this.total, this.fond, this.vide);

  final List<Barre> parts;
  final num total;
  final Color fond;
  final Color vide;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2;
    final centre = size.center(Offset.zero);
    final epaisseur = r * .32;
    final rect = Rect.fromCircle(center: centre, radius: r - epaisseur / 2);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = epaisseur;
    if (total == 0) {
      canvas.drawArc(rect, 0, math.pi * 2, false, p..color = vide);
      return;
    }
    var debut = -math.pi / 2;
    final ecart = parts.where((x) => x.valeur > 0).length > 1 ? .03 : 0.0;
    for (final x in parts) {
      if (x.valeur <= 0) continue;
      final angle = math.pi * 2 * x.valeur / total;
      canvas.drawArc(rect, debut + ecart / 2, math.max(angle - ecart, .001), false, p..color = x.couleur ?? Viz.bleu);
      debut += angle;
    }
  }

  @override
  bool shouldRepaint(_Anneau ancien) => true;
}

/// Menu déroulant compact (36 px), comme les filtres de la maquette.
class MenuCompact<T> extends StatelessWidget {
  const MenuCompact({
    super.key,
    required this.largeur,
    required this.valeur,
    required this.tous,
    required this.choix,
    required this.onChanged,
  });

  final double largeur;
  final T? valeur;
  final String tous;
  final Map<T, String> choix;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return SizedBox(
      width: largeur,
      height: 36,
      child: DropdownButtonHideUnderline(
        child: Container(
          padding: const EdgeInsets.only(left: 12, right: 8),
          decoration: BoxDecoration(
            border: Border.all(color: schema.outlineVariant),
            borderRadius: BorderRadius.circular(6),
            color: schema.surface,
          ),
          child: DropdownButton<T?>(
            value: valeur,
            isExpanded: true,
            isDense: true,
            icon: Icon(Icons.keyboard_arrow_down, size: 18, color: schema.onSurfaceVariant),
            style: TextStyle(fontFamily: policeTexte, fontSize: 14, color: schema.onSurface),
            items: [
              DropdownMenuItem<T?>(value: null, child: Text(tous, overflow: TextOverflow.ellipsis)),
              for (final c in choix.entries) DropdownMenuItem<T?>(value: c.key, child: Text(c.value, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

/// Téléphone : un bouton « Filtres » (avec le nombre de filtres actifs) qui
/// ouvre les menus dans un panneau en bas de l'écran, comme la page Élèves.
/// [menus] reçoit la largeur à donner aux menus et une fonction qui rafraîchit
/// le panneau après un choix.
class BoutonFiltres extends StatelessWidget {
  const BoutonFiltres({super.key, required this.actifs, required this.menus, this.reinitialiser});

  final int actifs;
  final List<Widget> Function(double largeur, VoidCallback rafraichir) menus;
  final VoidCallback? reinitialiser;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 44,
        height: 36,
        child: Badge(
          isLabelVisible: actifs > 0,
          label: Text('$actifs'),
          child: IconButton.outlined(
            tooltip: 'Filtres',
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.tune, size: 18),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              isScrollControlled: true,
              builder: (context) => StatefulBuilder(
                builder: (context, maj) => SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Text('Filtres', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      for (final m in menus(double.infinity, () => maj(() {}))) ...[m, const SizedBox(height: 10)],
                      Row(children: [
                        if (reinitialiser != null)
                          TextButton(
                            onPressed: () {
                              reinitialiser!();
                              maj(() {});
                            },
                            child: const Text('Réinitialiser'),
                          ),
                        const Spacer(),
                        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Voir les résultats')),
                      ]),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

/// Sélecteur en « pilule » (Mois / Trimestre / Année).
class Segments<T> extends StatelessWidget {
  const Segments({super.key, required this.valeur, required this.choix, required this.onChanged});

  final T valeur;
  final Map<T, String> choix;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return Container(
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Couleurs.doux(context), borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final c in choix.entries)
          GestureDetector(
            onTap: () => onChanged(c.key),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.key == valeur ? schema.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                boxShadow: c.key == valeur ? const [BoxShadow(color: Color(0x14000000), blurRadius: 2, offset: Offset(0, 1))] : null,
              ),
              child: Text(c.value,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: c.key == valeur ? FontWeight.w500 : FontWeight.w400,
                      color: c.key == valeur ? schema.onSurface : schema.onSurfaceVariant)),
            ),
          ),
      ]),
    );
  }
}

/// En-tête d'une page : titre, précision grise, boutons à droite.
class EnTetePage extends StatelessWidget {
  const EnTetePage({super.key, required this.titre, this.sousTitre, this.actions = const []});

  final String titre;
  final String? sousTitre;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 10,
        children: [
          Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 12, children: [
            Text(titre, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -.2)),
            if (sousTitre != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(sousTitre!, style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
          ]),
          if (actions.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      );
}

/// Une colonne de tableau : largeur fixe, ou part de la place restante.
class ColonneTableau {
  const ColonneTableau(this.titre, {this.largeur, this.flex = 1, this.droite = false});

  final String titre;
  final double? largeur;
  final int flex;
  final bool droite;
}

/// Tableau fin : en-tête de 36 px, lignes séparées d'un trait, survol gris.
class Tableau extends StatelessWidget {
  const Tableau({super.key, required this.colonnes, required this.lignes, this.onTap, this.vide = 'Aucune ligne.'});

  final List<ColonneTableau> colonnes;
  final List<List<Widget>> lignes;
  final void Function(int index)? onTap;
  final String vide;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    Widget cellule(ColonneTableau c, Widget enfant) {
      final contenu = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(alignment: c.droite ? Alignment.centerRight : Alignment.centerLeft, child: enfant),
      );
      return c.largeur == null ? Expanded(flex: c.flex, child: contenu) : SizedBox(width: c.largeur, child: contenu);
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: schema.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: schema.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 36,
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: schema.outlineVariant))),
          child: Row(children: [
            for (final c in colonnes) cellule(c, Text(c.titre, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
          ]),
        ),
        if (lignes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
            child: Text(vide, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: schema.onSurfaceVariant)),
          ),
        for (var i = 0; i < lignes.length; i++)
          InkWell(
            onTap: onTap == null ? null : () => onTap!(i),
            hoverColor: Couleurs.doux(context).withValues(alpha: .5),
            child: Container(
              constraints: const BoxConstraints(minHeight: 52),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: i == lignes.length - 1
                  ? null
                  : BoxDecoration(border: Border(bottom: BorderSide(color: schema.outlineVariant))),
              child: Row(children: [
                for (var j = 0; j < colonnes.length; j++) cellule(colonnes[j], j < lignes[i].length ? lignes[i][j] : const SizedBox()),
              ]),
            ),
          ),
      ]),
    );
  }
}
