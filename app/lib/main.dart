import 'dart:async';

import 'package:flutter/material.dart';

import 'accueil.dart';
import 'base.dart';
import 'cloud.dart';
import 'configuration.dart' show PorteDuPoste;
import 'onboarding.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ouvrirBase();
  await _chargerModeTheme();
  if (cloudConfigured) {
    await initCloud();
    // Session gardée sur le poste : on reprend la synchro, même hors ligne.
    unawaited(demarrerSynchro(db));
  }
  runApp(const ScolagridApp());
}

/// Le mode clair ou sombre choisi sur ce poste (« auto » = celui de l'appareil).
Future<void> _chargerModeTheme() async {
  try {
    final p = await db.getOptional("SELECT valeur FROM preferences WHERE id = 'theme'");
    modeTheme.value = switch (p?['valeur']) { 'clair' => ThemeMode.light, 'sombre' => ThemeMode.dark, _ => ThemeMode.system };
  } catch (_) {
    // Préférence illisible : on suit l'appareil.
  }
  modeTheme.addListener(() {
    final v = switch (modeTheme.value) { ThemeMode.light => 'clair', ThemeMode.dark => 'sombre', _ => 'auto' };
    unawaited(db.writeTransaction((tx) async {
      await tx.execute("DELETE FROM preferences WHERE id = 'theme'");
      await tx.execute("INSERT INTO preferences (id, valeur) VALUES ('theme', ?)", [v]);
    }).then((_) {}, onError: (_) {}));
  });
}

class ScolagridApp extends StatelessWidget {
  const ScolagridApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: modeTheme,
      builder: (context, mode, _) => MaterialApp(
      themeMode: mode,
      title: 'Scolagrid',
      debugShowCheckedModeBanner: false,
      theme: themeScolagrid(Brightness.light),
      darkTheme: themeScolagrid(Brightness.dark),
      // Bandeau visible sur les versions branchées sur l'environnement d'essai.
      builder: (context, child) => environnement == 'essai'
          ? Banner(message: 'ESSAI', location: BannerLocation.topEnd, child: child!)
          : child!,
      home: !cloudConfigured
          ? const _SansServeur()
          : estConnecte
              ? const PorteDuPoste(accueil: AccueilScreen(), sortie: BienvenueScreen())
              : const BienvenueScreen(),
      ),
    );
  }
}

class _SansServeur extends StatelessWidget {
  const _SansServeur();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text("Cette version n'est reliée à aucun serveur.\n"
              "Elle a été compilée sans l'adresse du serveur Scolagrid.",
              textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
