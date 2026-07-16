// Stub pour plateformes non-web (Android, iOS, desktop)
// Implémentation vide — le téléchargement via Printing.sharePdf() est utilisé
void downloadPdfBytes(List<int> bytes, String filename) {
  // No-op sur mobile : Printing.sharePdf() est utilisé à la place
  throw UnsupportedError('downloadPdfBytes non disponible sur cette plateforme.');
}
