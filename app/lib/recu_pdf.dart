/// Reçu de paiement en PDF, fabriqué sur le poste (fonctionne sans internet).
/// Format A5, lisible en noir et blanc. Une réimpression porte « DUPLICATA »,
/// un reçu annulé porte « ANNULÉ ».
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'caisse.dart';

class LigneRecu {
  const LigneRecu({required this.eleve, required this.matricule, required this.classe, required this.frais, required this.montant});

  final String eleve;
  final String matricule;
  final String classe;
  final String frais;
  final int montant;
}

/// Logo, signature et cachet de l'école, quand elle en a.
class ImagesEcole {
  const ImagesEcole({this.logo, this.signature, this.cachet});

  final Uint8List? logo;
  final Uint8List? signature;
  final Uint8List? cachet;
}

/// En-tête d'un document : logo, nom, devise, adresse, contacts, autorisation.
pw.Widget _enTete(Map<String, Object?> ecole, ImagesEcole images, {double titre = 16, double petit = 10}) {
  final st = pw.TextStyle(fontSize: petit);
  final adresse = [ecole['quartier'], ecole['commune'], ecole['ville']].where((x) => x != null && '$x'.isNotEmpty).join(', ');
  final contacts = [
    if (ecole['telephone'] != null) 'Tél. ${ecole['telephone']}',
    if (ecole['telephone2'] != null) '${ecole['telephone2']}',
    if (ecole['email'] != null) '${ecole['email']}',
    if (ecole['site_web'] != null) '${ecole['site_web']}',
  ].join(' · ');
  final admin = [
    if (ecole['numero_autorisation'] != null) 'Autorisation : ${ecole['numero_autorisation']}',
    if (ecole['nif'] != null) 'NIF : ${ecole['nif']}',
  ].join(' · ');
  return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    if (images.logo != null) ...[
      pw.SizedBox(width: titre * 3.6, height: titre * 3.6, child: pw.Image(pw.MemoryImage(images.logo!), fit: pw.BoxFit.contain)),
      pw.SizedBox(width: 12),
    ],
    pw.Expanded(
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('${ecole['nom_officiel'] ?? ecole['nom']}', style: pw.TextStyle(fontSize: titre, fontWeight: pw.FontWeight.bold)),
        if (ecole['slogan'] != null) pw.Text('« ${ecole['slogan']} »', style: st),
        if (adresse.isNotEmpty) pw.Text(adresse, style: st),
        if (contacts.isNotEmpty) pw.Text(contacts, style: st),
        if (admin.isNotEmpty) pw.Text(admin, style: st),
      ]),
    ),
  ]);
}

/// Bloc de signature : signature et cachet scannés si l'école l'a choisi,
/// sinon la place pour signer à la main.
pw.Widget _signer(Map<String, Object?> ecole, ImagesEcole images, {double hauteur = 70}) {
  final scannes = (ecole['signature_documents'] == 1 || ecole['signature_documents'] == true) &&
      (images.signature != null || images.cachet != null);
  if (!scannes) {
    return pw.Column(children: [
      pw.SizedBox(height: hauteur),
      pw.Text('Signature et cachet', style: const pw.TextStyle(fontSize: 10)),
    ]);
  }
  return pw.SizedBox(
    height: hauteur + 14,
    width: hauteur * 2.4,
    child: pw.Stack(alignment: pw.Alignment.center, children: [
      if (images.cachet != null)
        pw.Positioned(left: 0, top: 0, child: pw.SizedBox(width: hauteur * 1.2, height: hauteur * 1.2, child: pw.Opacity(opacity: .85, child: pw.Image(pw.MemoryImage(images.cachet!), fit: pw.BoxFit.contain)))),
      if (images.signature != null)
        pw.Positioned(right: 0, bottom: 0, child: pw.SizedBox(width: hauteur * 1.5, height: hauteur, child: pw.Image(pw.MemoryImage(images.signature!), fit: pw.BoxFit.contain))),
    ]),
  );
}

String _gnf(int m) {
  final s = '$m';
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return '$b GNF';
}

String _date(String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  if (d == null) return '';
  final l = d.toLocal();
  String deux(int n) => n.toString().padLeft(2, '0');
  return '${deux(l.day)}/${deux(l.month)}/${l.year}';
}

String _heure(String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  if (d == null) return '';
  return '${_date(iso)} à ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

Future<Uint8List> recuPdf({
  required Map<String, Object?> ecole,
  required Map<String, Object?> recu,
  required List<LigneRecu> lignes,
  required String encaissePar,
  required bool duplicata,
  ImagesEcole images = const ImagesEcole(),
}) {
  final doc = pw.Document(title: 'Reçu ${recu['numero']}');
  final annule = recu['statut'] == 'annule';
  final sousReserve = recu['confirmation'] == 'en_attente';
  final marque = [if (annule) 'ANNULÉ', if (duplicata) 'DUPLICATA'].join(' - ');
  final petit = pw.TextStyle(fontSize: 8);
  final gras = pw.TextStyle(fontWeight: pw.FontWeight.bold);

  pw.Widget cellule(String t, {bool droite = false, pw.TextStyle? style}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: pw.Text(t, textAlign: droite ? pw.TextAlign.right : pw.TextAlign.left, style: style ?? petit),
      );

  doc.addPage(pw.Page(
    pageTheme: pw.PageTheme(
      pageFormat: PdfPageFormat.a5,
      margin: const pw.EdgeInsets.all(28),
      buildBackground: marque.isEmpty
          ? null
          : (_) => pw.FullPage(
                ignoreMargins: true,
                child: pw.Center(
                  child: pw.Transform.rotate(
                    angle: 0.6,
                    child: pw.Text(marque, style: pw.TextStyle(fontSize: 44, color: PdfColors.grey400)),
                  ),
                ),
              ),
    ),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _enTete(ecole, images, titre: 13, petit: 8),
      pw.Divider(),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('REÇU DE PAIEMENT', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
        pw.Text('${recu['numero']}', style: gras),
      ]),
      if (recu['feuille'] != null)
        pw.Text('Reçu papier : ${recu['carnet'] != null ? 'carnet ${recu['carnet']}, ' : ''}feuille ${recu['feuille']}', style: petit),
      pw.SizedBox(height: 8),
      pw.Text('Reçu de : ${recu['payeur_nom']}'),
      pw.Text('Date du paiement : ${_date(recu['date_effective'] as String?)}'),
      pw.Text('Mode : ${modesPaiement[recu['mode']] ?? recu['mode']}${recu['reference'] != null ? ' (réf. ${recu['reference']})' : ''}'),
      pw.SizedBox(height: 10),
      pw.Table(
        border: pw.TableBorder.all(width: 0.5),
        columnWidths: const {
          0: pw.FlexColumnWidth(3),
          1: pw.FlexColumnWidth(2),
          2: pw.FlexColumnWidth(2),
        },
        children: [
          pw.TableRow(children: [
            cellule('Élève', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
            cellule('Frais', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
            cellule('Montant', droite: true, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
          ]),
          for (final l in lignes)
            pw.TableRow(children: [
              cellule('${l.eleve}\n${l.matricule} - ${l.classe}'),
              cellule(l.frais),
              cellule(_gnf(l.montant), droite: true),
            ]),
          pw.TableRow(children: [
            cellule('TOTAL', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            cellule(''),
            cellule(_gnf(recu['total_gnf'] as int), droite: true, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
          ]),
        ],
      ),
      if (sousReserve)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Text("Paiement reçu sous réserve de bon encaissement.", style: petit),
        ),
      if (annule)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Text('Reçu annulé : ${recu['motif_annulation'] ?? ''}', style: gras),
        ),
      pw.SizedBox(height: 10),
      pw.Text('Encaissé par : $encaissePar', style: petit),
      pw.Text('Saisi le ${_heure(recu['created_at'] as String?)}', style: petit),
      pw.Spacer(),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [_signer(ecole, images, hauteur: 40)]),
      if (ecole['mention_recu'] != null)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Center(child: pw.Text('${ecole['mention_recu']}', style: pw.TextStyle(fontSize: 8, fontStyle: pw.FontStyle.italic))),
        ),
    ]),
  ));
  return doc.save();
}

/// Liste de classe imprimable (document de travail).
Future<Uint8List> listeClassePdf({
  required String ecole,
  required String classe,
  required String annee,
  required List<Map<String, Object?>> eleves,
}) {
  final doc = pw.Document(title: 'Liste $classe');
  final petit = pw.TextStyle(fontSize: 9);
  pw.Widget cellule(String t, {bool gras = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: pw.Text(t, style: gras ? pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold) : petit),
      );
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    header: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text(ecole, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
      pw.Text('Liste de la classe $classe - $annee - ${eleves.length} élèves'),
      pw.SizedBox(height: 8),
    ]),
    build: (_) => [
      pw.Table(
        border: pw.TableBorder.all(width: 0.5),
        columnWidths: const {
          0: pw.FixedColumnWidth(24),
          1: pw.FlexColumnWidth(3),
          2: pw.FlexColumnWidth(4),
          3: pw.FixedColumnWidth(28),
          4: pw.FlexColumnWidth(2),
        },
        children: [
          pw.TableRow(children: [
            cellule('N°', gras: true),
            cellule('Matricule', gras: true),
            cellule('Nom et prénoms', gras: true),
            cellule('Sexe', gras: true),
            cellule('Naissance', gras: true),
          ]),
          for (var i = 0; i < eleves.length; i++)
            pw.TableRow(children: [
              cellule('${i + 1}'),
              cellule('${eleves[i]['matricule']}'),
              cellule('${eleves[i]['nom']} ${eleves[i]['prenoms']}'),
              cellule('${eleves[i]['sexe'] ?? ''}'),
              cellule(_date(eleves[i]['date_naissance'] as String?)),
            ]),
        ],
      ),
    ],
  ));
  return doc.save();
}

const _mois = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];

String _dateLongue(DateTime d) => '${d.day} ${_mois[d.month - 1]} ${d.year}';

/// Attestation d'inscription (A4) : document officiel, « DUPLICATA n° » dès la
/// deuxième impression.
Future<Uint8List> attestationPdf({
  required Map<String, Object?> ecole,
  required Map<String, Object?> eleve,
  required String classe,
  required String annee,
  required DateTime date,
  required int rang,
  Uint8List? photo,
  ImagesEcole images = const ImagesEcole(),
}) {
  final doc = pw.Document(title: 'Attestation ${eleve['matricule']}');
  final duplicata = rang > 1;
  final nomEcole = '${ecole['nom_officiel'] ?? ecole['nom']}';
  final ville = '${ecole['ville'] ?? ''}';
  final ne = eleve['sexe'] == 'F' ? 'née' : (eleve['sexe'] == 'M' ? 'né' : 'né(e)');
  final inscrit = eleve['sexe'] == 'F' ? 'inscrite' : (eleve['sexe'] == 'M' ? 'inscrit' : 'inscrit(e)');
  final naissance = DateTime.tryParse('${eleve['date_naissance']}');
  final corps = pw.TextStyle(fontSize: 12, lineSpacing: 4);
  final gras = pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold);
  pw.Widget ligne(String libelle, String valeur) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Row(children: [
          pw.SizedBox(width: 150, child: pw.Text(libelle, style: corps)),
          pw.Expanded(child: pw.Text(valeur, style: gras)),
        ]),
      );
  doc.addPage(pw.Page(
    pageTheme: pw.PageTheme(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(56, 48, 56, 48),
      buildBackground: !duplicata
          ? null
          : (_) => pw.FullPage(
                ignoreMargins: true,
                child: pw.Center(
                  child: pw.Transform.rotate(
                    angle: 0.6,
                    child: pw.Text('DUPLICATA', style: pw.TextStyle(fontSize: 90, color: PdfColors.grey300)),
                  ),
                ),
              ),
    ),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _enTete(ecole, images),
      pw.SizedBox(height: 36),
      pw.Center(child: pw.Text("ATTESTATION D'INSCRIPTION", style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, letterSpacing: 1))),
      if (duplicata)
        pw.Center(child: pw.Padding(padding: const pw.EdgeInsets.only(top: 4), child: pw.Text('Duplicata n° ${rang - 1}', style: gras))),
      pw.SizedBox(height: 32),
      pw.Text(
        'Je soussigné(e), ${ecole['responsable_nom'] ?? '[nom du responsable]'}, '
        '${ecole['responsable_titre'] ?? '[titre]'} de $nomEcole, certifie que l\'élève :',
        style: corps,
      ),
      pw.SizedBox(height: 16),
      // Identité, avec la photo d'identité à droite quand l'élève en a une.
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            ligne('Nom et prénoms', '${eleve['nom']} ${eleve['prenoms']}'),
            ligne('${ne[0].toUpperCase()}${ne.substring(1)} le',
                naissance == null ? '—' : '${_date(eleve['date_naissance'] as String?)}${eleve['lieu_naissance'] != null ? ' à ${eleve['lieu_naissance']}' : ''}'),
            ligne('Matricule', '${eleve['matricule']}'),
            if (eleve['matricule_etat'] != null) ligne("Matricule d'État", '${eleve['matricule_etat']}'),
          ]),
        ),
        if (photo != null) ...[
          pw.SizedBox(width: 16),
          pw.Container(
            width: 90,
            height: 110,
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.8, color: PdfColors.grey600)),
            child: pw.Image(pw.MemoryImage(photo), fit: pw.BoxFit.cover),
          ),
        ],
      ]),
      pw.SizedBox(height: 16),
      pw.Text('est régulièrement $inscrit en classe de $classe pour l\'année scolaire $annee.', style: corps),
      pw.SizedBox(height: 16),
      pw.Text('En foi de quoi, la présente attestation lui est délivrée pour servir et valoir ce que de droit.', style: corps),
      pw.SizedBox(height: 32),
      pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          pw.Text('Fait à ${ville.isEmpty ? '[ville]' : ville}, le ${_dateLongue(date)}', style: corps),
          pw.SizedBox(height: 8),
          pw.Text('${ecole['responsable_titre'] ?? 'Le responsable'}', style: gras),
          _signer(ecole, images),
          if (ecole['responsable_nom'] != null) pw.Text('${ecole['responsable_nom']}', style: corps),
        ]),
      ),
      pw.Spacer(),
      pw.Divider(color: PdfColors.grey500),
      pw.Text('Attestation éditée par Scolagrid le ${_dateLongue(date)}${duplicata ? ' (duplicata n° ${rang - 1})' : ''}.',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
    ]),
  ));
  return doc.save();
}

/// Décharge de remboursement : le parent signe qu'il a reçu l'argent.
Future<Uint8List> dechargePdf(
    {required Map<String, Object?> ecole,
    required Map<String, Object?> remboursement,
    required int rang,
    ImagesEcole images = const ImagesEcole()}) {
  final r = remboursement;
  final doc = pw.Document(title: 'Décharge ${r['matricule']}');
  final montant = r['montant_gnf'] as int;
  final corps = pw.TextStyle(fontSize: 11, lineSpacing: 3);
  final gras = pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold);
  pw.Widget ligne(String a, String b) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(children: [pw.SizedBox(width: 130, child: pw.Text(a, style: corps)), pw.Expanded(child: pw.Text(b, style: gras))]),
      );
  doc.addPage(pw.Page(
    pageTheme: pw.PageTheme(
      pageFormat: PdfPageFormat.a5,
      margin: const pw.EdgeInsets.all(28),
      buildBackground: rang == 1
          ? null
          : (_) => pw.FullPage(
                ignoreMargins: true,
                child: pw.Center(
                  child: pw.Transform.rotate(angle: 0.6, child: pw.Text('DUPLICATA', style: pw.TextStyle(fontSize: 54, color: PdfColors.grey300))),
                ),
              ),
    ),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _enTete(ecole, images, titre: 13, petit: 8),
      pw.Divider(),
      pw.Center(child: pw.Text('DÉCHARGE DE REMBOURSEMENT', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold))),
      if (r['decharge'] != null) pw.Center(child: pw.Text('Décharge papier : ${r['decharge']}', style: const pw.TextStyle(fontSize: 9))),
      pw.SizedBox(height: 14),
      pw.Text('Je soussigné(e), ${r['beneficiaire']}, reconnais avoir reçu de ${ecole['nom_officiel'] ?? ecole['nom']} la somme de :', style: corps),
      pw.SizedBox(height: 8),
      pw.Center(child: pw.Text(_gnf(montant), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold))),
      pw.Center(child: pw.Text('(${enLettres(montant)} francs guinéens)', style: corps)),
      pw.SizedBox(height: 10),
      ligne('Élève', '${r['nom']} ${r['prenoms']} (${r['matricule']})'),
      ligne('Frais remboursés', '${r['frais']}'),
      ligne('Reçu d\'origine', '${r['numero']}${r['feuille'] != null ? ' (papier ${r['feuille']})' : ''}'),
      ligne('Mode', '${modesPaiement[r['mode']] ?? r['mode']}'),
      ligne('Motif', '${r['motif']}'),
      ligne('Date', _date(r['verse_le'] as String?)),
      pw.Spacer(),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Column(children: [pw.Text('Signature du bénéficiaire', style: const pw.TextStyle(fontSize: 9)), pw.SizedBox(height: 40)]),
        pw.Column(children: [pw.Text('Pour l\'école (caisse)', style: const pw.TextStyle(fontSize: 9)), pw.SizedBox(height: 40)]),
      ]),
    ]),
  ));
  return doc.save();
}

/// Certificat de scolarité (A4) : tout le parcours de l'élève dans l'école,
/// année par année. Reste disponible après son départ.
Future<Uint8List> certificatPdf({
  required Map<String, Object?> ecole,
  required Map<String, Object?> eleve,
  required List<({String annee, String classe})> parcours,
  String? sortie,
  required DateTime date,
  required int rang,
  Uint8List? photo,
  ImagesEcole images = const ImagesEcole(),
}) {
  final doc = pw.Document(title: 'Certificat ${eleve['matricule']}');
  final duplicata = rang > 1;
  final nomEcole = '${ecole['nom_officiel'] ?? ecole['nom']}';
  final ville = '${ecole['ville'] ?? ''}';
  final fille = eleve['sexe'] == 'F';
  final ne = fille ? 'née' : (eleve['sexe'] == 'M' ? 'né' : 'né(e)');
  final inscrit = fille ? 'inscrite' : (eleve['sexe'] == 'M' ? 'inscrit' : 'inscrit(e)');
  final corps = pw.TextStyle(fontSize: 12, lineSpacing: 4);
  final gras = pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold);
  final naissance = eleve['date_naissance'] == null
      ? ''
      : ', $ne le ${_date(eleve['date_naissance'] as String?)}${eleve['lieu_naissance'] != null ? ' à ${eleve['lieu_naissance']}' : ''}';
  doc.addPage(pw.Page(
    pageTheme: pw.PageTheme(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(56, 48, 56, 48),
      buildBackground: !duplicata
          ? null
          : (_) => pw.FullPage(
                ignoreMargins: true,
                child: pw.Center(
                  child: pw.Transform.rotate(angle: 0.6, child: pw.Text('DUPLICATA', style: pw.TextStyle(fontSize: 90, color: PdfColors.grey300))),
                ),
              ),
    ),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _enTete(ecole, images),
      pw.SizedBox(height: 36),
      pw.Center(child: pw.Text('CERTIFICAT DE SCOLARITÉ', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, letterSpacing: 1))),
      if (duplicata) pw.Center(child: pw.Padding(padding: const pw.EdgeInsets.only(top: 4), child: pw.Text('Duplicata n° ${rang - 1}', style: gras))),
      pw.SizedBox(height: 32),
      // Le texte, avec la photo d'identité à droite quand l'élève en a une.
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Text(
            'Je soussigné(e), ${ecole['responsable_nom'] ?? '[nom du responsable]'}, ${ecole['responsable_titre'] ?? '[titre]'} '
            'de $nomEcole, certifie que l\'élève ${eleve['nom']} ${eleve['prenoms']}$naissance, matricule ${eleve['matricule']}'
            '${eleve['matricule_etat'] != null ? " (matricule d'État ${eleve['matricule_etat']})" : ''}, '
            'a été régulièrement $inscrit dans notre établissement pour les années scolaires suivantes :',
            style: corps,
          ),
        ),
        if (photo != null) ...[
          pw.SizedBox(width: 16),
          pw.Container(
            width: 90,
            height: 110,
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.8, color: PdfColors.grey600)),
            child: pw.Image(pw.MemoryImage(photo), fit: pw.BoxFit.cover),
          ),
        ],
      ]),
      pw.SizedBox(height: 16),
      pw.Table(
        border: pw.TableBorder.all(width: 0.5),
        columnWidths: const {0: pw.FixedColumnWidth(140), 1: pw.FlexColumnWidth()},
        children: [
          pw.TableRow(children: [
            pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('Année scolaire', style: gras)),
            pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('Classe', style: gras)),
          ]),
          for (final p in parcours)
            pw.TableRow(children: [
              pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(p.annee, style: corps)),
              pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(p.classe, style: corps)),
            ]),
        ],
      ),
      if (sortie != null) ...[
        pw.SizedBox(height: 12),
        pw.Text('${fille ? 'Elle' : 'Il'} a quitté l\'établissement le ${_date(sortie)}.', style: corps),
      ],
      pw.SizedBox(height: 16),
      pw.Text('En foi de quoi, le présent certificat est délivré pour servir et valoir ce que de droit.', style: corps),
      pw.SizedBox(height: 32),
      pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Column(children: [
          pw.Text('Fait à ${ville.isEmpty ? '[ville]' : ville}, le ${_dateLongue(date)}', style: corps),
          pw.SizedBox(height: 8),
          pw.Text('${ecole['responsable_titre'] ?? 'Le responsable'}', style: gras),
          _signer(ecole, images),
          if (ecole['responsable_nom'] != null) pw.Text('${ecole['responsable_nom']}', style: corps),
        ]),
      ),
      pw.Spacer(),
      pw.Divider(color: PdfColors.grey500),
      pw.Text('Seules figurent les années enregistrées dans Scolagrid. Certificat édité le ${_dateLongue(date)}'
          '${duplicata ? ' (duplicata n° ${rang - 1})' : ''}.',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
    ]),
  ));
  return doc.save();
}

/// Bon de sortie de caisse (A5) : le pendant du reçu. Le reçu prouve ce qui
/// entre, le bon prouve ce qui sort. Signé par le bénéficiaire et la caisse.
Future<Uint8List> bonDeSortiePdf({
  required Map<String, Object?> ecole,
  required Map<String, Object?> depense,
  required String autorisation,
  ImagesEcole images = const ImagesEcole(),
}) {
  final d = depense;
  final doc = pw.Document(title: 'Bon de sortie ${d['bon'] ?? ''}');
  final montant = d['montant_gnf'] as int;
  final corps = pw.TextStyle(fontSize: 11, lineSpacing: 3);
  final gras = pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold);
  pw.Widget ligne(String a, String b) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.SizedBox(width: 110, child: pw.Text(a, style: corps)),
          pw.Expanded(child: pw.Text(b, style: gras)),
        ]),
      );
  doc.addPage(pw.Page(
    pageTheme: const pw.PageTheme(pageFormat: PdfPageFormat.a5, margin: pw.EdgeInsets.all(28)),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _enTete(ecole, images, titre: 13, petit: 8),
      pw.Divider(),
      pw.Center(child: pw.Text('BON DE SORTIE DE CAISSE', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold))),
      if (d['bon'] != null) pw.Center(child: pw.Text('N° ${d['bon']}', style: const pw.TextStyle(fontSize: 10))),
      pw.SizedBox(height: 14),
      pw.Center(child: pw.Text(_gnf(montant), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold))),
      pw.Center(child: pw.Text('(${enLettres(montant)} francs guinéens)', style: corps)),
      pw.SizedBox(height: 12),
      ligne('Date', _date(d['date_effective'] as String?)),
      ligne('Catégorie', '${d['categorie']}'),
      ligne('Motif', '${d['motif']}'),
      ligne('Bénéficiaire', '${d['beneficiaire'] ?? '—'}'),
      ligne('Autorisation', autorisation),
      if (d['par'] != null) ligne('Enregistré par', '${d['par']}'),
      pw.Spacer(),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Column(children: [pw.Text('Le bénéficiaire', style: const pw.TextStyle(fontSize: 9)), pw.SizedBox(height: 40)]),
        pw.Column(children: [pw.Text('La caisse', style: const pw.TextStyle(fontSize: 9)), pw.SizedBox(height: 40)]),
      ]),
    ]),
  ));
  return doc.save();
}

/// État de recouvrement d'une classe (A4 paysage) : chaque élève, ce qui reste
/// à payer colonne par colonne (inscription, tranches, autres frais), le dû,
/// le réglé et le reste ; totaux en bas.
Future<Uint8List> etatRecouvrementPdf({
  required Map<String, Object?> ecole,
  required String classe,
  required String annee,
  required List<String> colonnes,
  required List<({String nom, String matricule, List<int?> cases, int du, int paye})> lignes,
  ImagesEcole images = const ImagesEcole(),
}) {
  final doc = pw.Document(title: 'Recouvrement $classe');
  String n(int v) => _gnf(v).replaceAll(' GNF', '');
  final aujourdhui = DateTime.now();
  final st = const pw.TextStyle(fontSize: 8);
  final gras = pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold);
  pw.Widget cel(String t, {bool droite = true, pw.TextStyle? style}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
        child: pw.Text(t, textAlign: droite ? pw.TextAlign.right : pw.TextAlign.left, style: style ?? st),
      );
  final totalCases = List<int>.filled(colonnes.length, 0);
  for (final l in lignes) {
    for (var i = 0; i < colonnes.length; i++) {
      totalCases[i] += l.cases[i] ?? 0;
    }
  }
  final du = lignes.fold(0, (s, l) => s + l.du), paye = lignes.fold(0, (s, l) => s + l.paye);
  doc.addPage(pw.MultiPage(
    pageTheme: const pw.PageTheme(pageFormat: PdfPageFormat.a4, orientation: pw.PageOrientation.landscape, margin: pw.EdgeInsets.all(24)),
    header: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _enTete(ecole, images, titre: 12, petit: 8),
      pw.Divider(),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('ÉTAT DE RECOUVREMENT — $classe', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        pw.Text('$annee · arrêté au ${_date(aujourdhui.toIso8601String())} · ${lignes.length} élève(s)',
            style: const pw.TextStyle(fontSize: 9)),
      ]),
      pw.SizedBox(height: 6),
    ]),
    footer: (c) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('Page ${c.pageNumber} / ${c.pagesCount} · Chaque colonne : reste à payer (GNF)',
          style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
    ),
    build: (_) => [
      pw.Table(
        border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColors.grey400, width: .5)),
        columnWidths: {0: const pw.FlexColumnWidth(3)},
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(width: .8))),
            children: [
              cel('Élève', droite: false, style: gras),
              for (final k in colonnes) cel(k, style: gras),
              cel('Dû', style: gras),
              cel('Réglé', style: gras),
              cel('Reste', style: gras),
            ],
          ),
          for (final l in lignes)
            pw.TableRow(children: [
              cel('${l.nom}  ${l.matricule}', droite: false),
              for (final x in l.cases) cel(x == null ? '—' : (x <= 0 ? 'payé' : n(x))),
              cel(n(l.du)),
              cel(n(l.paye)),
              cel(l.du - l.paye <= 0 ? 'soldé' : n(l.du - l.paye), style: gras),
            ]),
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey200),
            children: [
              cel('Total', droite: false, style: gras),
              for (final t in totalCases) cel(n(t), style: gras),
              cel(n(du), style: gras),
              cel(n(paye), style: gras),
              cel(n(du - paye), style: gras),
            ],
          ),
        ],
      ),
      pw.SizedBox(height: 8),
      pw.Text('Recouvrement : ${du <= 0 ? '—' : '${(paye * 100 / du).round()} %'} '
          '(${n(paye)} réglés sur ${n(du)} GNF)', style: const pw.TextStyle(fontSize: 9)),
    ],
  ));
  return doc.save();
}
