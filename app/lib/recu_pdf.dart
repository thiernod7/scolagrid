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
}) {
  final doc = pw.Document(title: 'Reçu ${recu['numero']}');
  final annule = recu['statut'] == 'annule';
  final sousReserve = recu['mode'] == 'cheque' || recu['mode'] == 'virement';
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
      pw.Text('${ecole['nom_officiel'] ?? ecole['nom']}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
      if (ecole['slogan'] != null) pw.Text('« ${ecole['slogan']} »', style: petit),
      pw.Text([ecole['quartier'], ecole['ville']].where((x) => x != null).join(', '), style: petit),
      if (ecole['telephone'] != null) pw.Text('Tél. ${ecole['telephone']}', style: petit),
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
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [
        pw.Column(children: [
          pw.Text('Signature et cachet', style: petit),
          pw.SizedBox(height: 36),
        ]),
      ]),
    ]),
  ));
  return doc.save();
}
