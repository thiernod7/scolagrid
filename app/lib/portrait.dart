/// Photo d'identité d'un élève : redressée, cadrée au format 3:4 (35 × 45 mm),
/// le visage placé tout seul, puis enregistrée nette (600 × 800, JPEG).
///
/// Le cadrage automatique s'appuie sur le fond uni (drap rouge, mur blanc…) :
/// le haut de la tête est la première ligne qui n'est plus du fond, et la
/// largeur de la tête donne l'échelle. On garde la tête et les épaules : le bas
/// de la photo (mur, sol, drap trop court) tombe hors du cadre.
///
/// Sans fond uni, le cadre se place au tiers supérieur (le visage d'une photo
/// prise de loin est en haut : un centrage strict le décapiterait).
/// Pur Dart : testé sans Flutter (test/portrait_test.dart).
library;

import 'dart:math' as math;
import 'dart:typed_data' show Uint8List;

import 'package:image/image.dart' as img;

/// Format de la photo enregistrée : 3:4, assez fine pour un plein écran de
/// téléphone et une carte scolaire, assez légère pour tous les postes (≈ 50 à 100 Ko).
const largeurPortrait = 600;
const hauteurPortrait = 800;

/// Un cadre dans les pixels de l'image (redressée).
class CadrePortrait {
  const CadrePortrait(this.x, this.y, this.largeur, this.hauteur);

  final double x;
  final double y;
  final double largeur;
  final double hauteur;

  @override
  String toString() => 'Cadre(${x.round()}, ${y.round()}, ${largeur.round()} × ${hauteur.round()})';
}

/// Image prête à cadrer : redressée, son cadre proposé et un aperçu léger pour l'écran.
class PhotoACadrer {
  const PhotoACadrer(this.image, this.cadre, this.apercu, this.largeurApercu, this.hauteurApercu);

  final img.Image image;
  final CadrePortrait cadre;
  final Uint8List apercu;
  final int largeurApercu;
  final int hauteurApercu;
}

/// Décode la photo, la redresse selon l'appareil (EXIF), la limite à 2400 px
/// et propose un cadre. Null : ce n'est pas une image lisible.
PhotoACadrer? preparerPortrait(Uint8List octets) {
  var im = img.decodeImage(octets);
  if (im == null) return null;
  im = img.bakeOrientation(im);
  if (im.numChannels == 4 || im.hasPalette) im = im.convert(numChannels: 3);
  final grand = math.max(im.width, im.height);
  if (grand > 2400) {
    final k = 2400 / grand;
    im = img.copyResize(im, width: (im.width * k).round(), height: (im.height * k).round(), interpolation: img.Interpolation.average);
  }
  final k = math.min(1.0, 1000 / grand);
  final petit = k == 1 ? im : img.copyResize(im, width: (im.width * k).round(), height: (im.height * k).round(), interpolation: img.Interpolation.average);
  return PhotoACadrer(im, cadreAutomatique(im), img.encodeJpg(petit, quality: 85, chroma: img.JpegChroma.yuv420), petit.width, petit.height);
}

/// Découpe le cadre et l'enregistre en 600 × 800 ; la qualité baisse un peu
/// seulement si la photo est très chargée (tissu à carreaux…).
Uint8List exporterPortrait(img.Image image, CadrePortrait c) {
  final x = c.x.round().clamp(0, image.width - 1);
  final y = c.y.round().clamp(0, image.height - 1);
  final l = c.largeur.round().clamp(1, image.width - x);
  final h = c.hauteur.round().clamp(1, image.height - y);
  final coupe = img.copyCrop(image, x: x, y: y, width: l, height: h);
  final finale = img.copyResize(coupe,
      width: largeurPortrait,
      height: hauteurPortrait,
      interpolation: l > largeurPortrait ? img.Interpolation.average : img.Interpolation.cubic);
  for (final q in [85, 78, 70]) {
    final jpeg = img.encodeJpg(finale, quality: q, chroma: img.JpegChroma.yuv420);
    if (jpeg.length <= 160000 || q == 70) return jpeg;
  }
  throw StateError('inaccessible');
}

/// Le plus grand cadre 3:4 de l'image, au tiers supérieur.
CadrePortrait cadreParDefaut(int largeur, int hauteur) {
  var l = largeur.toDouble();
  var h = l * 4 / 3;
  if (h > hauteur) {
    h = hauteur.toDouble();
    l = h * 3 / 4;
  }
  return CadrePortrait((largeur - l) / 2, (hauteur - h) / 3, l, h);
}

/// Cadre proposé : la tête en haut (12 % de marge), centrée, avec les épaules.
CadrePortrait cadreAutomatique(img.Image im) {
  const a = 240; // largeur d'analyse
  final s = a / im.width;
  final hA = math.max(8, (im.height * s).round());
  final p = img.copyResize(im, width: a, height: hA, interpolation: img.Interpolation.average);

  // La couleur du fond : les deux coins du haut.
  final cy = math.max(1, (hA * .12).round());
  const cx = (a * .15) ~/ 1;
  final rs = <int>[], gs = <int>[], bs = <int>[];
  for (var y = 0; y < cy; y++) {
    for (final x in [for (var i = 0; i < cx; i++) i, for (var i = a - cx; i < a; i++) i]) {
      final px = p.getPixel(x, y);
      rs.add(px.r.toInt());
      gs.add(px.g.toInt());
      bs.add(px.b.toInt());
    }
  }
  int mediane(List<int> v) => (v..sort())[v.length ~/ 2];
  final fr = mediane(rs), fg = mediane(gs), fb = mediane(bs);
  // Le fond est-il uni ? L'écart des coins entre eux fixe le seuil.
  final ecarts = [for (var i = 0; i < rs.length; i++) (rs[i] - fr).abs() + (gs[i] - fg).abs() + (bs[i] - fb).abs()]..sort();
  final ecart95 = ecarts[(ecarts.length * .95).floor().clamp(0, ecarts.length - 1)];
  if (ecart95 > 120) return cadreParDefaut(im.width, im.height); // fond chargé : pas de détection
  final seuil = math.max(60, ecart95 * 2.5);

  bool sujet(int x, int y) {
    final px = p.getPixel(x, y);
    return (px.r.toInt() - fr).abs() + (px.g.toInt() - fg).abs() + (px.b.toInt() - fb).abs() > seuil;
  }

  // Le haut de la tête : trois lignes de suite où le sujet occupe la partie centrale.
  final c0 = (a * .2).round(), c1 = (a * .8).round();
  int compte(int y) {
    var n = 0;
    for (var x = c0; x < c1; x++) {
      if (sujet(x, y)) n++;
    }
    return n;
  }

  final minimum = a * .03;
  int? haut;
  for (var y = 0; y < hA - 2; y++) {
    if (compte(y) > minimum && compte(y + 1) > minimum && compte(y + 2) > minimum) {
      haut = y;
      break;
    }
  }
  if (haut == null || haut > hA * .6) return cadreParDefaut(im.width, im.height);

  // Largeur et centre de la tête : sous le sommet, entre 25 % et 60 % de la zone étudiée.
  final largeurs = <double>[], centres = <double>[];
  for (var y = haut; y < math.min(hA, haut + (a * .45).round()); y++) {
    int? g, d;
    for (var x = 0; x < a; x++) {
      if (sujet(x, y)) {
        g ??= x;
        d = x;
      }
    }
    if (g == null || d == null || d - g < 3) continue;
    largeurs.add((d - g).toDouble());
    centres.add((d + g) / 2);
  }
  if (largeurs.length < 4) return cadreParDefaut(im.width, im.height);
  final n = largeurs.length;
  double med(List<double> v) {
    final t = v.sublist((n * .25).floor(), math.max((n * .25).floor() + 1, (n * .6).floor()))..sort();
    return t[t.length ~/ 2];
  }

  final tete = med(largeurs), centre = med(centres);
  var h = tete * 2.9 / s;
  var l = h * .75;
  var x = centre / s - l / 2;
  var y = haut / s - h * .12;
  if (l > im.width) {
    l = im.width.toDouble();
    h = l * 4 / 3;
  }
  if (h > im.height) {
    h = im.height.toDouble();
    l = h * .75;
  }
  x = x.clamp(0, im.width - l).toDouble();
  y = y.clamp(0, im.height - h).toDouble();
  return CadrePortrait(x, y, l, h);
}

/// Pour un calcul hors du fil de l'écran (compute) : la photo et le cadre choisi.
Uint8List exporterCadre((PhotoACadrer, CadrePortrait) a) => exporterPortrait(a.$1.image, a.$2);
