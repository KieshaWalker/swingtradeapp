// =============================================================================
// features/greek_grid/services/greek_interpreter.dart
// =============================================================================
// Models for InterpretationResult returned by POST /greek-grid/interpret-grid
// and POST /greek-grid/interpret-chart (Python backend).
// =============================================================================

// ── Output model ──────────────────────────────────────────────────────────────

enum InterpretationSignal { neutral, bullish, bearish, caution }

InterpretationSignal _sigFromString(String s) => switch (s) {
  'bullish' => InterpretationSignal.bullish,
  'bearish' => InterpretationSignal.bearish,
  'caution' => InterpretationSignal.caution,
  _         => InterpretationSignal.neutral,
};

class InterpretationLine {
  final String               label;
  final String               text;
  final InterpretationSignal signal;
  const InterpretationLine(this.label, this.text, this.signal);

  factory InterpretationLine.fromJson(Map<String, dynamic> j) => InterpretationLine(
    j['label']  as String? ?? '',
    j['text']   as String? ?? '',
    _sigFromString(j['signal'] as String? ?? 'neutral'),
  );
}

class InterpretationResult {
  final String               headline;
  final InterpretationSignal headlineSignal;
  final List<InterpretationLine> today;
  final List<InterpretationLine> period;
  final int                  periodObs;

  const InterpretationResult({
    required this.headline,
    required this.headlineSignal,
    required this.today,
    required this.period,
    required this.periodObs,
  });

  bool get hasData => today.isNotEmpty || period.isNotEmpty;

  factory InterpretationResult.fromJson(Map<String, dynamic> j) => InterpretationResult(
    headline:       j['headline']        as String? ?? '',
    headlineSignal: _sigFromString(j['headline_signal'] as String? ?? 'neutral'),
    today:          (j['today']  as List? ?? []).map((l) => InterpretationLine.fromJson(l as Map<String, dynamic>)).toList(),
    period:         (j['period'] as List? ?? []).map((l) => InterpretationLine.fromJson(l as Map<String, dynamic>)).toList(),
    periodObs:      (j['period_obs'] as num? ?? 0).toInt(),
  );
}
