// Singleton léger pour partager l'état d'init SmileID entre main.dart et KycScreen
// Pas de Provider pour ne pas alourdir l'arbre — simple variable globale.
class SmileIdInitState {
  SmileIdInitState._();
  static bool initialized = false;
  static String? errorMessage;
}
