/// Charte de Scolagrid : noir et gris, fine, comme la maquette de départ.
/// Les états sont toujours écrits en toutes lettres, pas seulement en couleur
/// (lisibles en noir et blanc). Mode clair, mode sombre, ou celui de l'appareil.
library;

import 'package:flutter/material.dart';

abstract final class Couleurs {
  // Neutres (mode clair).
  static const primaire = Color(0xFF171717);
  static const encre = Color(0xFF0A0A0A);
  static const encreDouce = Color(0xFF737373);
  static const fond = Color(0xFFFCFCFC);
  static const bordure = Color(0xFFE5E5E5);

  // États : un ton lisible sur fond clair comme sur fond sombre, et un fond
  // transparent qui prend la teinte de ce qu'il y a dessous.
  static const regle = Color(0xFF1A8C50);
  static const regleFond = Color(0x241A8C50);
  static const attente = Color(0xFFB7791F);
  static const attenteFond = Color(0x26B7791F);
  static const retard = Color(0xFFD23F31);
  static const retardFond = Color(0x1FD23F31);
  static const info = Color(0xFF2F72C4);
  static const infoFond = Color(0x1F2F72C4);
  static const neutre = Color(0xFF737373);
  static const neutreFond = Color(0xFFF5F5F5);

  /// Gris doux des pastilles, onglets, lignes choisies : selon le mode.
  static Color doux(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? const Color(0xFF262626) : neutreFond;
}

/// Mode d'affichage choisi (clair, sombre, ou celui de l'appareil).
final modeTheme = ValueNotifier<ThemeMode>(ThemeMode.system);

const policeTexte = 'Inter';
const policeChiffres = 'JetBrainsMono';

/// Matricules, numéros de reçu, feuilles du carnet : chaque caractère a la même
/// largeur, plus faciles à relire et à dicter.
const styleMono = TextStyle(fontFamily: policeChiffres, fontSize: 13, fontWeight: FontWeight.w500);

ThemeData themeScolagrid(Brightness luminosite) {
  final sombre = luminosite == Brightness.dark;
  final base0 = ColorScheme.fromSeed(
      seedColor: const Color(0xFF737373), brightness: luminosite, dynamicSchemeVariant: DynamicSchemeVariant.monochrome);
  final schema = sombre
      ? base0.copyWith(
          primary: const Color(0xFFE5E5E5),
          onPrimary: const Color(0xFF171717),
          primaryContainer: const Color(0xFF262626),
          onPrimaryContainer: const Color(0xFFFAFAFA),
          secondary: const Color(0xFF262626),
          onSecondary: const Color(0xFFFAFAFA),
          secondaryContainer: const Color(0xFF262626),
          onSecondaryContainer: const Color(0xFFFAFAFA),
          surface: const Color(0xFF121212),
          onSurface: const Color(0xFFFAFAFA),
          onSurfaceVariant: const Color(0xFFA1A1A1),
          surfaceContainerLowest: const Color(0xFF0A0A0A),
          surfaceContainerLow: const Color(0xFF121212),
          surfaceContainer: const Color(0xFF171717),
          surfaceContainerHigh: const Color(0xFF1F1F1F),
          surfaceContainerHighest: const Color(0xFF262626),
          outline: const Color(0xFF404040),
          outlineVariant: const Color(0x1FFFFFFF),
          error: const Color(0xFFF2877C),
          onError: const Color(0xFF171717),
        )
      : base0.copyWith(
          primary: Couleurs.primaire,
          onPrimary: const Color(0xFFFAFAFA),
          primaryContainer: Couleurs.neutreFond,
          onPrimaryContainer: Couleurs.primaire,
          secondary: Couleurs.neutreFond,
          onSecondary: Couleurs.primaire,
          secondaryContainer: Couleurs.neutreFond,
          onSecondaryContainer: Couleurs.primaire,
          surface: Colors.white,
          onSurface: Couleurs.encre,
          onSurfaceVariant: Couleurs.encreDouce,
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: Couleurs.fond,
          surfaceContainer: Couleurs.neutreFond,
          surfaceContainerHigh: Couleurs.neutreFond,
          surfaceContainerHighest: Couleurs.neutreFond,
          outline: const Color(0xFFD4D4D4),
          outlineVariant: Couleurs.bordure,
          error: Couleurs.retard,
          onError: Colors.white,
        );
  final bordure = schema.outlineVariant;
  final arrondi = BorderRadius.circular(6);
  final base = ThemeData(colorScheme: schema, fontFamily: policeTexte, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: sombre ? const Color(0xFF0A0A0A) : Couleurs.fond,
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: sombre ? schema.surface : Colors.white,
      foregroundColor: schema.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontFamily: policeTexte, fontSize: 18, fontWeight: FontWeight.w600, color: schema.onSurface),
      shape: Border(bottom: BorderSide(color: bordure)),
    ),
    cardTheme: CardThemeData(
      color: schema.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: bordure)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(36, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: arrondi),
        textStyle: const TextStyle(fontFamily: policeTexte, fontWeight: FontWeight.w500, fontSize: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(36, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: arrondi),
        side: BorderSide(color: bordure),
        foregroundColor: schema.onSurface,
        textStyle: const TextStyle(fontFamily: policeTexte, fontWeight: FontWeight.w500, fontSize: 14),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: schema.primary,
      foregroundColor: schema.onPrimary,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: sombre ? schema.surface : Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: bordure)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: bordure)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: schema.primary, width: 1.5)),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      side: BorderSide(color: schema.outline),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: sombre ? schema.surface : Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: schema.primaryContainer,
      height: 68,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: sombre ? schema.surface : Colors.white,
      indicatorColor: schema.primaryContainer,
    ),
    dividerTheme: DividerThemeData(color: bordure, space: 1),
    dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

enum Ton { regle, attente, retard, info, neutre }

/// Un état écrit en toutes lettres sur une pastille de couleur.
class Etat extends StatelessWidget {
  const Etat(this.texte, {super.key, this.ton = Ton.neutre, this.icone});

  final String texte;
  final Ton ton;
  final IconData? icone;

  static (Color, Color) couleurs(Ton ton) => switch (ton) {
        Ton.regle => (Couleurs.regle, Couleurs.regleFond),
        Ton.attente => (Couleurs.attente, Couleurs.attenteFond),
        Ton.retard => (Couleurs.retard, Couleurs.retardFond),
        Ton.info => (Couleurs.info, Couleurs.infoFond),
        Ton.neutre => (Couleurs.neutre, Couleurs.neutreFond),
      };

  @override
  Widget build(BuildContext context) {
    var (texteC, fondC) = couleurs(ton);
    if (ton == Ton.neutre) {
      fondC = Couleurs.doux(context);
      texteC = Theme.of(context).colorScheme.onSurfaceVariant;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: fondC, borderRadius: BorderRadius.circular(4)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icone != null) ...[Icon(icone, size: 13, color: texteC), const SizedBox(width: 4)],
        Text(texte, style: TextStyle(color: texteC, fontSize: 12, fontWeight: FontWeight.w500, height: 1.35)),
      ]),
    );
  }
}

/// Initiales d'un nom dans une pastille ronde grise (la photo, quand elle
/// existe, prend sa place).
class Initiales extends StatelessWidget {
  const Initiales(this.nom, {super.key, this.taille = 40});

  final String nom;
  final double taille;

  @override
  Widget build(BuildContext context) {
    final mots = nom.trim().split(RegExp(r'\s+')).where((m) => m.isNotEmpty).toList();
    final lettres = mots.isEmpty ? '?' : mots.take(2).map((m) => m[0].toUpperCase()).join();
    final schema = Theme.of(context).colorScheme;
    return Container(
      width: taille,
      height: taille,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: Couleurs.doux(context), shape: BoxShape.circle),
      child: Text(lettres,
          style: TextStyle(color: schema.onSurfaceVariant, fontWeight: FontWeight.w500, fontSize: taille * 0.36)),
    );
  }
}

/// Carte d'un chiffre clé (accueil).
class ChiffreCle extends StatelessWidget {
  const ChiffreCle({super.key, required this.libelle, required this.valeur, this.detail, this.etat, this.mono = false});

  final String libelle;
  final String valeur;
  final String? detail;
  final Widget? etat;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(libelle, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          Text(valeur,
              style: mono
                  ? styleMono.copyWith(fontSize: 22)
                  : t.headlineSmall?.copyWith(fontSize: 24, fontWeight: FontWeight.w700)),
          if (detail != null) ...[
            const SizedBox(height: 4),
            Text(detail!, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
          if (etat != null) ...[const SizedBox(height: 8), etat!],
        ]),
      ),
    );
  }
}

/// Bascule clair / sombre (la lune ou le soleil, dans l'en-tête).
class BoutonTheme extends StatelessWidget {
  const BoutonTheme({super.key});

  static void basculer(BuildContext context) =>
      modeTheme.value = Theme.of(context).brightness == Brightness.dark ? ThemeMode.light : ThemeMode.dark;

  @override
  Widget build(BuildContext context) {
    final sombre = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      tooltip: sombre ? 'Mode clair' : 'Mode sombre',
      onPressed: () => basculer(context),
      icon: Icon(sombre ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 18),
    );
  }
}
