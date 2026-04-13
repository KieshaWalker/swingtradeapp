// =============================================================================
// core/theme.dart — Global dark theme & semantic color palette
// =============================================================================
// Exports:
//   • AppTheme.dark         — ThemeData applied in main.dart → MaterialApp.router
//   • AppTheme.profitColor  — lime-green (#4ADE80); gains, Call badges, FABs,
//                             focused borders, selected nav items
//   • AppTheme.lossColor    — rose-pink (#FF6B8A); losses, Put badges, errors,
//                             delete actions
//   • AppTheme.neutralColor — lavender (#A09FC8); labels, subtitles,
//                             inactive icons
//   • AppTheme.cardColor    — deep purple (#57558A); containers, toggles
//   • AppTheme.elevatedColor— darker purple (#4B4978); dialogs, dropdowns
//   • AppTheme.borderColor  — mid lavender (#7A78A8); dividers, outlines
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
  // ── Background hierarchy ───────────────────────────────────────────────────
  static const _bg       = Color(0xFF666591); // scaffold — medium purple
  static const _surface  = Color(0xFF9795BE); // app bar, bottom nav — lighter purple
  static const _card     = Color(0xFF57558A); // cards & containers — deeper purple
  static const _elevated = Color(0xFF4B4978); // dialogs, dropdowns — darkest purple
  static const _border   = Color(0xFF7A78A8); // borders & dividers — mid lavender

  // ── Semantic accent colors ─────────────────────────────────────────────────
  static const _green = Color(0xFF4ADE80); // lime-green — profit (pops on purple)
  static const _red   = Color(0xFFFF6B8A); // rose-pink  — loss   (warm on purple)

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
          backgroundColor: Color.fromARGB(121, 102, 101, 145),
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
          fillColor: _elevated,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _green),
          ),
          labelStyle: const TextStyle(color: Color(0xFFA09FC8)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _green,
            foregroundColor: Colors.black,
            minimumSize: const Size(64, 50),
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
          selectedColor: _green.withValues(alpha: 0.25),
          labelStyle: const TextStyle(fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      );

  // ── Public semantic colors ─────────────────────────────────────────────────
  static const profitColor   = _green;
  static const lossColor     = _red;
  static const neutralColor  = Color(0xFFA09FC8); // muted lavender

  // ── Public structural colors (containers not covered by ThemeData) ─────────
  static const cardColor     = _card;
  static const elevatedColor = _elevated;
  static const borderColor   = _border;
}
