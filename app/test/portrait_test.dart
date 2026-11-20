import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scolagrid/portrait.dart';

/// Une « photo » fabriquée : fond rouge uni, une tête (ovale sombre) et des
/// épaules, puis un mur sombre en bas que le drap ne couvre pas.
img.Image photoFabriquee({int largeur = 1500, int hauteur = 2000, int centreX = 750, int hautTete = 400}) {
  final im = img.Image(width: largeur, height: hauteur);
  img.fill(im, color: img.ColorRgb8(215, 40, 60));
  img.fillRect(im, x1: 0, y1: (hauteur * .8).round(), x2: largeur, y2: hauteur, color: img.ColorRgb8(90, 30, 35));
  img.fillRect(im, x1: centreX - 400, y1: hautTete + 450, x2: centreX + 400, y2: hauteur, color: img.ColorRgb8(220, 190, 120));
  img.fillCircle(im, x: centreX, y: hautTete + 200, radius: 200, color: img.ColorRgb8(70, 45, 35));
  return im;
}

void main() {
  test('le visage est placé : tête en haut du cadre, centrée, sans le mur du bas', () {
    final c = cadreAutomatique(photoFabriquee());
    expect(c.hauteur / c.largeur, closeTo(4 / 3, .01));
    // Le haut de la tête à environ 12 % du haut du cadre.
    expect((400 - c.y) / c.hauteur, closeTo(.12, .04));
    // Centré sur la tête.
    expect(c.x + c.largeur / 2, closeTo(750, 40));
    // Le mur (à partir de 1600 px) reste hors du cadre.
    expect(c.y + c.hauteur, lessThan(1600));
  });

  test('un élève décalé sur la photo est recentré', () {
    final c = cadreAutomatique(photoFabriquee(centreX: 950));
    expect(c.x + c.largeur / 2, closeTo(950, 40));
  });

  test('sans fond uni : le plus grand cadre 3:4, au tiers supérieur', () {
    final im = img.Image(width: 1200, height: 2000);
    for (var y = 0; y < 2000; y++) {
      for (var x = 0; x < 1200; x++) {
        im.setPixelRgb(x, y, (x * 37 + y * 11) % 256, (x * 7 + y * 53) % 256, (x * y) % 256);
      }
    }
    final c = cadreAutomatique(im);
    expect(c.largeur, 1200);
    expect(c.hauteur, 1600);
    expect(c.y, closeTo(400 / 3, 1));
  });

  test("l'export fait 600 × 800 en JPEG, assez léger pour la synchronisation", () {
    final im = photoFabriquee();
    final jpeg = exporterPortrait(im, cadreAutomatique(im));
    final relu = img.decodeJpg(jpeg)!;
    expect(relu.width, largeurPortrait);
    expect(relu.height, hauteurPortrait);
    expect(jpeg.length, lessThan(160000));
  });
}
