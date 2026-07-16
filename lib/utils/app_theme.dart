import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

class AppTheme {
  static TextTheme _buildTextTheme() {
    return TextTheme(
      displayLarge: GoogleFonts.bricolageGrotesque(
        fontWeight: FontWeight.w800,
        fontSize: 30,
        color: AppColors.encre,
        letterSpacing: -0.6,
      ),
      displayMedium: GoogleFonts.bricolageGrotesque(
        fontWeight: FontWeight.w700,
        fontSize: 24,
        color: AppColors.encre,
        letterSpacing: -0.5,
      ),
      titleLarge: GoogleFonts.bricolageGrotesque(
        fontWeight: FontWeight.w700,
        fontSize: 19,
        color: AppColors.encre,
      ),
      titleMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w600,
        fontSize: 16,
        color: AppColors.encre,
      ),
      bodyLarge: GoogleFonts.inter(
        fontWeight: FontWeight.w400,
        fontSize: 15,
        color: AppColors.texte,
      ),
      bodyMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w400,
        fontSize: 13.5,
        color: AppColors.texteDoux,
      ),
      labelLarge: GoogleFonts.inter(
        fontWeight: FontWeight.w700,
        fontSize: 15.5,
      ),
    );
  }

  static ThemeData get theme {
    final textTheme = _buildTextTheme();
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.encre,
        primary: AppColors.encre,
        secondary: AppColors.or,
        surface: AppColors.fondPapier,
        onPrimary: Colors.white,
        onSecondary: const Color(0xFF2A1E05),
      ),
      scaffoldBackgroundColor: AppColors.fondPapier,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.fondPapier,
        foregroundColor: AppColors.encre,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: GoogleFonts.bricolageGrotesque(
          fontWeight: FontWeight.w800,
          fontSize: 20,
          color: AppColors.encre,
          letterSpacing: -0.4,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.encre,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w700,
            fontSize: 15.5,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.lignes, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.lignes, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.encre, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        labelStyle: GoogleFonts.inter(
          fontWeight: FontWeight.w600,
          fontSize: 13.5,
          color: AppColors.encre,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.carte,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.lignes, width: 1),
        ),
        margin: const EdgeInsets.only(bottom: 14),
      ),
    );
  }
}
