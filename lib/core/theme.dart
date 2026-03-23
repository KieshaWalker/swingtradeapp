// =============================================================================
// core/theme.dart — Global dark theme & semantic color palette
// =============================================================================
// Exports:
//   • AppTheme.dark       — ThemeData applied in main.dart → MaterialApp.router
//   • AppTheme.profitColor — green (#00C896); used for profit values, Call badges,
//                            FABs, focused borders, selected nav items
//   • AppTheme.lossColor   — red  (#FF4D6A); used for loss values, Put badges,
//                            error states, delete actions
//   • AppTheme.neutralColor — gray (#8B949E); used for labels, subtitles,
//                             inactive icons
//
// Consumers (every screen imports this for colors):
//   • DashboardScreen  — _StatCard, _PnLChart, _OpenTradeRow
//   • TradesScreen     — _TradeCard, _Badge, _InfoChip
//   • AddTradeScreen   — option type toggle, section labels
//   • TradeDetailScreen— _LiveQuoteCard, _SecFilingRow, _StatusBadge
//   • CalculatorScreen — result rows, R:R badge
//   • JournalScreen    — _JournalCard tags, FAB
//   • AddJournalScreen — mood picker, tag chips
//   • ResearchScreen   — _FilingCard category colors
// =============================================================================
import 'package:flutter/material.dart';

class AppTheme {
  static const _green = Color(0xFF00C896);
  static const _red = Color(0xFFFF4D6A);
  static const _bg = Color(0xFF0D1117);
  static const _surface = Color(0xFF161B22);
  static const _card = Color(0xFF1C2230);

  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(
          primary: _green,
          secondary: _green,
          error: _red,
          surface: _surface,
        ),
        cardTheme: CardThemeData(
          color: _card,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _bg,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _card,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF30363D)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _green),
          ),
          labelStyle: const TextStyle(color: Color(0xFF8B949E)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _green,
            foregroundColor: Colors.black,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: _green),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: _card,
          selectedColor: _green.withValues(alpha: 0.2),
          labelStyle: const TextStyle(fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      );

  // Semantic colors exposed for use throughout the app
  static const profitColor = _green;
  static const lossColor = _red;
  static const neutralColor = Color(0xFF8B949E);
}
