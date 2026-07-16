// Implémentation Web réelle — utilise dart:html pour déclencher le téléchargement
// dart:html reste fonctionnel dans Flutter Web (Dart 3.x) même si marqué deprecated
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

void downloadPdfBytes(List<int> bytes, String filename) {
  final blob = html.Blob([bytes], 'application/pdf');
  final url = html.Url.createObjectUrlFromBlob(blob);
  // ignore: unused_local_variable
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}
