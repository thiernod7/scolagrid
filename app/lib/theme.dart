/// Charte de Scolagrid : couleurs, textes et petits éléments communs.
/// Une couleur à nous (indigo) pour les actions ; des états toujours écrits
/// en toutes lettres, pas seulement en couleur (lisibles en noir et blanc).
library;

import 'package:flutter/material.dart';

abstract final class Couleurs {
  static const indigo = Color(0xFF4F46B8);
  static const indigoFonce = Color(0xFF2E2680);
  static const indigoClair = Color(0xFFEEECFA);
  static const encre = Color(0xFF17171F);
  static const encreDouce = Color(0xFF5B5D6E);
  static const fond = Color(0xFFF6F6F9);
  static const bordure = Color(0xFFE4E4EC);

  static const regle = Color(0xFF14653F);
  static const regleFond = Color(0xFFE5F4EC);
  static const attente = Color(0xFF8A4F00);
  static const attenteFond = Color(0xFFFDF1DC);
  static const retard = Color(0xFF9B1C12);
  static const retardFond = Color(0xFFFDECEA);
  static const info = Color(0xFF1C4F8F);
  static const infoFond = Color(0xFFEAF1FB);
  static const neutre = Color(0xFF3D3F4C);
  static const neutreFond = Color(0xFFF1F1F5);
}

const policeTexte = 'Inter';
const policeChiffres = 'JetBrainsMono';

/// Matricules, numéros de reçu, feuilles du carnet : chaque caractère a la même
/// largeur, plus faciles à relire et à dicter.
const styleMono = TextStyle(fontFamily: policeChiffres, fontSize: 13, fontWeight: FontWeight.w500);

ThemeData themeScolagrid(Brightness luminosite) {
  final sombre = luminosite == Brightness.dark;
  final schema = sombre
      ? ColorScheme.fromSeed(seedColor: Couleurs.indigo, brightness: Brightness.dark)
      : ColorScheme.fromSeed(seedColor: Couleurs.indigo).copyWith(
          primary: Couleurs.indigo,
          onPrimary: Colors.white,
          primaryContainer: Couleurs.indigoClair,
          onPrimaryContainer: Couleurs.indigoFonce,
          secondaryContainer: Couleurs.indigoClair,
          onSecondaryContainer: Couleurs.indigoFonce,
          surface: Colors.white,
          onSurface: Couleurs.encre,
          onSurfaceVariant: Couleurs.encreDouce,
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: Couleurs.fond,
          surfaceContainer: Couleurs.fond,
          outline: const Color(0xFFDCDCE6),
          outlineVariant: Couleurs.bordure,
          error: Couleurs.retard,
        );
  final bordure = sombre ? schema.outlineVariant : Couleurs.bordure;
  final arrondi = BorderRadius.circular(6);
  final base = ThemeData(colorScheme: schema, fontFamily: policeTexte, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: sombre ? schema.surface : Couleurs.fond,
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
      color: sombre ? schema.surfaceContainer : Colors.white,
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
      fillColor: sombre ? schema.surfaceContainerHighest : Colors.white,
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
    final (texteC, fondC) = couleurs(ton);
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
    final sombre = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: taille,
      height: taille,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: sombre ? schema.surfaceContainerHighest : Couleurs.neutreFond, shape: BoxShape.circle),
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
