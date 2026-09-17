import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const navy = Color(0xFF173B57);
  static const navyDark = Color(0xFF0D2639);
  static const teal = Color(0xFF148F8B);
  static const tealLight = Color(0xFFDBF1EF);
  static const background = Color(0xFFF5F7FA);
  static const surface = Colors.white;
  static const ink = Color(0xFF17232D);
  static const muted = Color(0xFF6C7A86);
  static const success = Color(0xFF16865C);
  static const danger = Color(0xFFC43B4D);
  static const warning = Color(0xFFB56A12);
}

ThemeData buildTheme() {
  final textTheme = GoogleFonts.interTextTheme().copyWith(
    displaySmall: GoogleFonts.inter(fontSize: 34, fontWeight: FontWeight.w800, color: AppColors.ink, height: 1.08),
    headlineMedium: GoogleFonts.inter(fontSize: 25, fontWeight: FontWeight.w700, color: AppColors.ink),
    titleLarge: GoogleFonts.inter(fontSize: 19, fontWeight: FontWeight.w700, color: AppColors.ink),
    titleMedium: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.ink),
    bodyLarge: GoogleFonts.inter(fontSize: 16, height: 1.5, color: AppColors.ink),
    bodyMedium: GoogleFonts.inter(fontSize: 14, height: 1.45, color: AppColors.muted),
    labelLarge: GoogleFonts.inter(fontWeight: FontWeight.w700),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: ColorScheme.fromSeed(seedColor: AppColors.teal, primary: AppColors.navy, secondary: AppColors.teal, surface: AppColors.surface),
    textTheme: textTheme,
    appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, centerTitle: false, surfaceTintColor: Colors.transparent),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFD9E1E8))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFD9E1E8))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: AppColors.teal, width: 1.7)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: AppColors.danger)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        side: const BorderSide(color: Color(0xFFCCD7DF)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      insetPadding: const EdgeInsets.all(18),
    ),
  );
}
