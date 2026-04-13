// =============================================================================
// features/blotter/models/phase_result.dart
// =============================================================================
// Shared model for all 5 phases of the trade evaluation workflow.
//
// PhaseResult is computed by each phase panel and reported to the parent
// screen via an onResult callback.  The parent uses the statuses to gate the
// blotter lifecycle (Draft → Validated → Committed → Transmitted).
// =============================================================================

import 'package:flutter/material.dart';

// ── Status ────────────────────────────────────────────────────────────────────

enum PhaseStatus { pending, pass, warn, fail }

extension PhaseStatusExt on PhaseStatus {
  String get label => switch (this) {
        PhaseStatus.pending => 'Pending',
        PhaseStatus.pass    => 'Pass',
        PhaseStatus.warn    => 'Warn',
        PhaseStatus.fail    => 'Fail',
      };

  Color get color => switch (this) {
        PhaseStatus.pending => const Color(0xFF94A3B8), // slate
        PhaseStatus.pass    => const Color(0xFF4ADE80), // lime-green
        PhaseStatus.warn    => const Color(0xFFFBBF24), // amber
        PhaseStatus.fail    => const Color(0xFFFF6B8A), // rose
      };

  IconData get icon => switch (this) {
        PhaseStatus.pending => Icons.radio_button_unchecked,
        PhaseStatus.pass    => Icons.check_circle_outline,
        PhaseStatus.warn    => Icons.warning_amber_outlined,
        PhaseStatus.fail    => Icons.cancel_outlined,
      };
}

// ── Result ────────────────────────────────────────────────────────────────────

class PhaseResult {
  final PhaseStatus status;

  /// One-line summary shown in collapsed phase tile header.
  final String headline;

  /// Bullet-point signals shown when the tile is expanded.
  final List<String> signals;

  /// True once the user has opened the phase panel.
  final bool reviewed;

  const PhaseResult({
    required this.status,
    required this.headline,
    this.signals = const [],
    this.reviewed = false,
  });

  /// Default state before any data has loaded.
  static const none = PhaseResult(
    status: PhaseStatus.pending,
    headline: 'Not evaluated',
  );

  PhaseResult copyWith({bool? reviewed}) => PhaseResult(
        status:   status,
        headline: headline,
        signals:  signals,
        reviewed: reviewed ?? this.reviewed,
      );
}
